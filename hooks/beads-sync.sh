#!/bin/sh
# beads-sync.sh — automated, idempotent sync of every beads-inited repo's
# ledger to origin/dev (beads-orc plugin; adapted from the Dwyer Lab
# original, which targeted origin/main with a hardcoded repo list).
#
# WHY origin/dev: branch policy — agents integrate on dev; main is prod and
# only a human promotes to it. The ledger must live on the branch agents
# actually share.
#
# WHAT it does, per beads-inited repo under $DEV_ROOT (dirs with .beads/):
#   1. Flush the live DB to .beads/issues.jsonl (local state).
#   2. Last-write-wins MERGE (per bead id, by updated_at) of local vs the
#      ledger published on origin/dev — origin's newer states are kept, our
#      new/newer beads are added. Never drops a bead present on origin.
#   3. SKIP-IMPORT GUARD: reconcile the live DB only when the merge brought
#      in FOREIGN content (a bead state that did not come from our own
#      ledger). Nothing foreign → the DB is already the superset; blindly
#      re-importing our own data (what the upstream original did) only
#      widens the window where a concurrent session's DB write gets
#      clobbered. Foreign content → write the merged ledger, then three-way
#      `br sync --merge --force` (base + DB + JSONL; conflicts resolve to
#      the newer timestamp — the same LWW policy as the ledger merge).
#      NEVER `--import-only` (blind upsert) and NEVER `--rebuild` (deletes
#      DB rows absent from JSONL — would destroy concurrent local creates).
#   4. If the merge differs from origin's ledger, commit ONLY
#      .beads/issues.jsonl onto origin/dev via git plumbing (no checkout,
#      no index disruption — works on any branch, any dirty tree) and push,
#      re-merging + retrying on a non-fast-forward race.
#   No-op when already in sync. Never touches anything outside .beads/.
#
# USAGE:
#   beads-sync.sh [--dry-run] [--quiet] [--from-session-end] [repo ...]
#     repo: a name under $DEV_ROOT (default ~/dev), one group level down
#           ($DEV_ROOT/<group>/<repo>), or an absolute path.
#     no repos → every dir under $DEV_ROOT (or one group level down)
#           containing .beads/.
#   --dry-run: read-only. Fetches + reports what WOULD change; writes
#              nothing, pushes nothing, touches no DB.
#   --from-session-end: SessionEnd hook mode — reads the event JSON on
#              stdin, runs quietly, and only for sessions rooted under
#              $DEV_ROOT or a Claude worktree.
#
# BD_BR_OVERRIDE: path to an alternative `br` binary (tests use a logging
# shim). Same contract as the bd dispatch wrapper.
#
# Exit: 0 always (a per-repo failure is logged, never wedges other repos or
# the session-end hook chain). Outcomes append to
# ~/.claude/beads-orc-sync.log so quiet SessionEnd runs stay observable.

export PATH="$HOME/.local/bin:$PATH"
export NO_COLOR=1

DRY=0
QUIET=0
SESSION_END=0
REPOS=""
for a in "$@"; do
  case "$a" in
    --dry-run)          DRY=1 ;;
    --quiet)            QUIET=1 ;;
    --from-session-end) SESSION_END=1; QUIET=1 ;;
    -*)                 echo "beads-sync: unknown option $a" >&2; exit 0 ;;
    *)                  REPOS="$REPOS $a" ;;
  esac
done

DEV="${DEV_ROOT:-$HOME/dev}"

BR="${BD_BR_OVERRIDE:-}"
[ -n "$BR" ] && [ -x "$BR" ] || BR="br"

LOG="$HOME/.claude/beads-orc-sync.log"
# Machine-local marker dir: records a foreign-path `br sync --merge` failure
# (e.g. a SQLite lock from a concurrent session) so the DB merge is retried
# on every subsequent run instead of getting silently wedged behind the
# ledger once the push makes local == origin (FOREIGN=0 forever after).
# Deliberately NOT in the repo — this is machine-local state for a
# machine-local condition.
RETRY_DIR="$HOME/.claude/beads-orc-retry"
# Cheap rotation: keep the tail once the log passes ~200 KB.
if [ -f "$LOG" ]; then
  _sz=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
  case "$_sz" in
    ''|*[!0-9]*) : ;;
    *) [ "$_sz" -gt 200000 ] && { tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; } ;;
  esac
fi
logline() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

# SessionEnd mode: the hook pipes the event JSON on stdin. Only run for
# sessions rooted in the dev tree (or a Claude worktree) so unrelated
# projects don't pay for git fetches on every exit.
if [ "$SESSION_END" -eq 1 ]; then
  _in=$(cat 2>/dev/null)
  if command -v jq >/dev/null 2>&1; then
    _cwd=$(printf '%s' "$_in" | jq -r '.cwd // empty' 2>/dev/null)
  else
    _cwd=$(printf '%s' "$_in" | sed -n 's/.*"cwd"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
  fi
  case "$_cwd" in
    "$DEV"|"$DEV"/*|"$HOME"/.claude-worktrees/*) : ;;
    *) exit 0 ;;
  esac
fi

# Discover beads-inited repos when none were named (dirs under $DEV, or one
# group level down at $DEV/<group>/<repo>). Emits PATHS, not names — they hit
# the "/*" absolute branch of the main loop below.
[ -n "$REPOS" ] || REPOS=$(for d in "$DEV"/*/.beads "$DEV"/*/*/.beads; do
  [ -d "$d" ] || continue
  printf '%s\n' "${d%/.beads}"
done)
[ -n "$REPOS" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || { echo "beads-sync: python3 required" >&2; exit 0; }

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# Last-write-wins merge. Args: <local.jsonl> <origin.jsonl>. Emits merged
# JSONL on stdout, preserving each winning bead's EXACT original line (no
# reserialization → minimal diffs). Origin order kept; local-only beads
# appended sorted. Stderr summary: "ADDED=<n> UPDATED=<n> FOREIGN=<n>".
#   ADDED   = beads only we have (origin gains them)
#   UPDATED = beads where our strictly-newer version wins
#   FOREIGN = beads whose WINNING line did not come from our ledger
#             (origin-only beads, or origin same-or-newer with different
#             content) — the DB-reconcile trigger. Ties with identical
#             lines are not foreign.
merge_ledger() {
  python3 - "$1" "$2" <<'PY'
import sys, json
def load(p):
    d, order = {}, []
    try:
        with open(p, encoding='utf-8') as f:
            for line in f:
                s = line.rstrip('\n')
                if not s.strip():
                    continue
                try:
                    o = json.loads(s)
                except Exception:
                    continue
                i = o.get('id')
                if i is None:
                    continue
                u = o.get('updated_at') or ''
                if i not in d:
                    order.append(i)
                d[i] = (u, s)
    except FileNotFoundError:
        pass
    return d, order

loc, _ = load(sys.argv[1])
ori, oorder = load(sys.argv[2])

out, seen, added, updated, foreign = [], set(), 0, 0, 0
for i in oorder:                      # keep origin's order
    seen.add(i)
    ou, os_ = ori[i]
    if i in loc and loc[i][0] > ou:   # local strictly newer → ours wins
        out.append(loc[i][1]); updated += 1
    else:                             # origin same-or-newer → keep origin
        out.append(os_)
        if i not in loc or loc[i][1] != os_:
            foreign += 1              # content we did not have
for i in sorted(k for k in loc if k not in seen):  # beads only we have
    out.append(loc[i][1]); added += 1

sys.stdout.write('\n'.join(out) + ('\n' if out else ''))
sys.stderr.write('ADDED=%d UPDATED=%d FOREIGN=%d\n' % (added, updated, foreign))
PY
}

ids_only() { grep -oE '"id":"[^"]+"' "$1" 2>/dev/null | sort -u; }

sync_one() {
  repo="$1"
  name=$(basename "$repo")
  [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { say "[skip] $name (not a git repo)"; return; }
  [ -d "$repo/.beads" ] || { say "[skip] $name (no .beads)"; return; }
  # Disambiguate fetch failure: a remote that HAS no dev branch is a
  # different situation from a network failure — and the latter must keep
  # the upstream safety property (never merge against a stale origin view).
  if ! git -C "$repo" fetch origin dev --quiet 2>/dev/null; then
    if git -C "$repo" rev-parse --verify --quiet origin/dev >/dev/null 2>&1; then
      say "[skip] $name (fetch failed)"; logline "SKIP $name fetch-failed"
    else
      say "[skip] $name (no origin/dev)"; logline "SKIP $name no-origin-dev"
    fi
    return
  fi

  db="$repo/.beads/beads.db"
  local_jsonl="$repo/.beads/issues.jsonl"
  marker="$RETRY_DIR/$name"

  # Retry hook: heal a DB left behind by a previous WARN-path merge failure
  # (see the foreign-path block below) before anything else runs. Placement
  # matters: a healed DB then flushes normally below.
  if [ -f "$marker" ] && [ "$DRY" -eq 0 ] && [ -f "$db" ] && [ -f "$local_jsonl" ]; then
    if ( cd "$repo" && "$BR" sync --merge --force >/dev/null 2>&1 ); then
      rm -f "$marker"
      say "[heal] $name: retried DB merge from previous failure"
      logline "HEAL $name"
    else
      logline "WARN $name retry-merge-failed"
    fi
  fi
  if [ "$DRY" -eq 1 ] && [ -f "$marker" ]; then
    say "[diff] $name: pending DB merge retry (marker present)"
  fi

  # Refresh the local export from the live DB (skip in dry-run: read-only).
  if [ "$DRY" -eq 0 ] && [ -f "$db" ]; then
    ( "$BR" sync --flush-only --db "$db" >/dev/null 2>&1 ) || true
  fi
  [ -f "$local_jsonl" ] || { say "[skip] $name (no issues.jsonl)"; return; }

  origin_tmp=$(mktemp) || return
  merged_tmp=$(mktemp) || { rm -f "$origin_tmp"; return; }
  git -C "$repo" show origin/dev:.beads/issues.jsonl > "$origin_tmp" 2>/dev/null || : > "$origin_tmp"

  sumfile=$(mktemp)
  merge_ledger "$local_jsonl" "$origin_tmp" > "$merged_tmp" 2>"$sumfile"
  oi=$(mktemp); mi=$(mktemp)
  ids_only "$origin_tmp" > "$oi"; ids_only "$merged_tmp" > "$mi"

  # Safety invariant: the merge must never drop a bead present on origin.
  dropped=$(comm -23 "$oi" "$mi" | wc -l | tr -d ' ')
  if [ "${dropped:-0}" -ne 0 ]; then
    echo "[ABORT] $name: merge would drop $dropped origin bead(s) — refusing to push" >&2
    logline "ABORT $name would-drop=$dropped"
    rm -f "$origin_tmp" "$merged_tmp" "$sumfile" "$oi" "$mi"; return
  fi

  foreign=$(sed -n 's/.*FOREIGN=\([0-9][0-9]*\).*/\1/p' "$sumfile" | head -1)
  msum=$(cat "$sumfile" 2>/dev/null | tr -d '\n')
  added_ids=$(comm -13 "$oi" "$mi")
  rm -f "$sumfile" "$oi" "$mi"

  need_push=1
  diff -q "$merged_tmp" "$origin_tmp" >/dev/null 2>&1 && need_push=0

  if [ "$need_push" -eq 0 ] && [ "${foreign:-0}" -eq 0 ]; then
    say "[ok]   $name: in sync"
    rm -f "$origin_tmp" "$merged_tmp"; return
  fi

  if [ "$DRY" -eq 1 ]; then
    [ "${foreign:-0}" -gt 0 ] && say "[diff] $name: would reconcile DB ($foreign foreign bead-state(s))"
    if [ "$need_push" -eq 1 ]; then
      say "[diff] $name: ledger differs from origin/dev (${msum:-changed})"
      [ -n "$added_ids" ] && [ "$QUIET" -eq 0 ] && printf '%s\n' "$added_ids" | sed 's/^/         + /'
      say "       (dry-run) not writing or pushing"
    fi
    rm -f "$origin_tmp" "$merged_tmp"; return
  fi

  # Foreign path: publish the merged ledger locally, then reconcile the DB
  # with a three-way merge (base + DB + JSONL). See header for why NOT
  # --import-only / --rebuild.
  # br 0.2.15 (probe-verified): a missing .beads/beads.base.jsonl is treated
  # as an empty ancestor, and br creates/refreshes the base snapshot itself
  # after each merge — no seeding needed.
  # Run the merge with cwd IN the repo and no --db: br canonicalizes the
  # .beads dir but not the JSONL path when --db is used, so on macOS
  # /var→/private/var symlinked paths its inside-.beads safety check
  # false-rejects ("Refusing to use JSONL path outside .beads" — observed
  # live 2026-07-06). cwd discovery keeps both paths consistent.
  if [ "${foreign:-0}" -gt 0 ]; then
    cp "$merged_tmp" "$local_jsonl"
    if [ -f "$db" ]; then
      if ( cd "$repo" && "$BR" sync --merge --force >/dev/null 2>&1 ); then
        say "[pull] $name: $foreign foreign bead-state(s) merged into local DB"
        logline "IMPORT $name foreign=$foreign"
        rm -f "$marker"
      else
        mkdir -p "$RETRY_DIR"
        date '+%F %T' > "$marker" 2>/dev/null
        echo "[warn] $name: br sync --merge failed — will retry at next sync (marker set)" >&2
        logline "WARN $name br-merge-failed marker-set"
      fi
    fi
  fi

  if [ "$need_push" -eq 1 ]; then
    say "[diff] $name: ledger differs from origin/dev (${msum:-changed})"
    [ -n "$added_ids" ] && [ "$QUIET" -eq 0 ] && printf '%s\n' "$added_ids" | sed 's/^/         + /'
    if push_beads "$repo"; then
      say "[push] $name: ledger synced to origin/dev"
      logline "PUSH $name ${msum:-}"
    else
      echo "[FAIL] $name: push failed (see above)" >&2
      logline "FAIL $name push"
    fi
  else
    say "[ok]   $name: origin already current (pulled foreign only)"
  fi
  rm -f "$origin_tmp" "$merged_tmp"
}

# Commit ONLY .beads/issues.jsonl onto the latest origin/dev and push,
# re-merging against origin on each attempt so a concurrent push can't be
# clobbered.
push_beads() {
  repo="$1"
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    git -C "$repo" fetch origin dev --quiet 2>/dev/null
    base=$(git -C "$repo" rev-parse origin/dev 2>/dev/null) || return 1

    o2=$(mktemp); m2=$(mktemp)
    git -C "$repo" show "$base:.beads/issues.jsonl" > "$o2" 2>/dev/null || : > "$o2"
    merge_ledger "$repo/.beads/issues.jsonl" "$o2" > "$m2" 2>/dev/null

    if diff -q "$m2" "$o2" >/dev/null 2>&1; then
      rm -f "$o2" "$m2"; return 0   # someone already published our state
    fi
    # Re-assert the no-drop invariant against the latest origin.
    oi2=$(mktemp); mi2=$(mktemp)
    ids_only "$o2" > "$oi2"; ids_only "$m2" > "$mi2"
    drop2=$(comm -23 "$oi2" "$mi2" | wc -l | tr -d ' ')
    rm -f "$oi2" "$mi2"
    if [ "${drop2:-0}" -ne 0 ]; then
      echo "[ABORT] $(basename "$repo"): re-merge would drop origin beads" >&2
      logline "ABORT $(basename "$repo") re-merge-drop"
      rm -f "$o2" "$m2"; return 1
    fi
    cp "$m2" "$repo/.beads/issues.jsonl"

    blob=$(git -C "$repo" hash-object -w "$repo/.beads/issues.jsonl" 2>/dev/null) || { rm -f "$o2" "$m2"; return 1; }
    idx=$(mktemp)
    GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$base" 2>/dev/null
    GIT_INDEX_FILE="$idx" git -C "$repo" update-index --add --cacheinfo 100644,"$blob",.beads/issues.jsonl 2>/dev/null
    tree=$(GIT_INDEX_FILE="$idx" git -C "$repo" write-tree 2>/dev/null)
    rm -f "$idx"
    [ -n "$tree" ] || { rm -f "$o2" "$m2"; return 1; }

    commit=$(printf 'chore(beads): sync ledger to dev\n\nAutomated additive ledger sync (last-write-wins). No code changes.\n' \
             | git -C "$repo" commit-tree "$tree" -p "$base" 2>/dev/null)
    [ -n "$commit" ] || { rm -f "$o2" "$m2"; return 1; }

    # --no-verify skips repo-level pre-push hooks (some rebase the working
    # checkout first, which fails on a dirty/behind tree). This push is a
    # controlled plumbing FF of a beads-only commit built on the LATEST
    # origin/dev; the retry loop supplies the concurrency safety such hooks
    # protect.
    if git -C "$repo" push --no-verify origin "$commit:refs/heads/dev" --quiet 2>/dev/null; then
      rm -f "$o2" "$m2"; return 0
    fi
    say "[retry] $(basename "$repo"): origin/dev moved, re-merging (attempt $attempt)"
    logline "RETRY $(basename "$repo") attempt=$attempt"
    rm -f "$o2" "$m2"
  done
  return 1
}

for r in $REPOS; do
  case "$r" in
    /*) p="$r" ;;
    *)  p="$DEV/$r"
        if [ ! -d "$p" ]; then
          for g in "$DEV"/*/"$r"; do [ -d "$g" ] && { p="$g"; break; }; done
        fi ;;
  esac
  [ -d "$p" ] || { say "[skip] $r (not found at $p)"; continue; }
  sync_one "$p"
done
exit 0
