#!/bin/sh
# beads-digest.sh — SessionStart cross-repo beads digest (beads-orc plugin).
#
# Prints, per beads repo under $DEV_ROOT:
#   ▸ ready     — scheduler-ranked, unblocked, NOT in-progress  → safe to claim
#   🔒 in-flight — already claimed/in-progress, shown WITH assignee → do NOT pick
#
# Read-only; never claims. The shared per-repo DB is the live source of truth —
# this is a point-in-time snapshot. The real anti-collision guarantee is
# claiming before you work (`bd update <id> --claim`).
#
# Only runs for sessions rooted under $DEV_ROOT or a Claude worktree, and only
# prints when at least one beads repo exists.

export PATH="$HOME/.local/bin:$PATH"
export NO_COLOR=1

DEV="${DEV_ROOT:-$HOME/dev}"
READY_N=5
INFLIGHT_N=8

# Gate on session cwd (SessionStart pipes event JSON on stdin).
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

# Discovery is unsorted (unlike bd's longest-first sort): the digest iterates
# every repo rather than routing ids by prefix, so order doesn't matter.
# Repos live under $DEV or one group level down ($DEV/<group>/<repo>).
# NOTE: relies on the convention that repo dir names have no whitespace.
REPO_DIRS=$(for d in "$DEV"/*/.beads "$DEV"/*/*/.beads; do
  [ -d "$d" ] || continue
  printf '%s\n' "${d%/.beads}"
done)
[ -n "$REPO_DIRS" ] || exit 0

# Beads repos exist but the toolchain is missing → loud setup banner instead of
# silence (plugins can't run install-time scripts; this is the discovery path).
if ! command -v br >/dev/null 2>&1 || ! command -v bd >/dev/null 2>&1; then
  echo '⛔ beads-orc: beads-inited repos exist under '"$DEV"' but `br`/`bd` are not on PATH.'
  echo '   AGENT: run the beads-orc:setup skill (installs the pinned br binary and links bd) BEFORE any beads work.'
  exit 0
fi

echo '## Beads — cross-repo backlog digest (beads-orc)'
echo 'CLAIM BEFORE YOU WORK with `bd`, NOT `br`: `bd update <id> --claim` is atomic (assignee + status=in_progress) and drops the bead from every other agent'\''s ready list. `bd` ROUTES a fully-qualified id (e.g. `taher-core-scope-8cda`) to its home repo'\''s DB from ANY cwd and stamps a SESSION-DISTINCT, USER-ATTRIBUTED actor (`<branch>-<username>`, or just `<username>` outside a repo), so the assignee shows whose session holds each claim. Bare `br` only sees the cwd'\''s DB. ▸ ready = safe to claim. 🔒 in-flight = already claimed (assignee shown) — do NOT pick.'
echo 'BRANCH POLICY (beads-inited repos): work on a feature branch in a worktree → push to `dev` (review-gated) → a HUMAN promotes dev → main (prod). NEVER push main yourself in a beads repo.'
echo 'AFTER YOU CLAIM, do the work IN THIS SESSION — NEVER tell the user to open a new terminal or session. Step into an isolated worktree with the **EnterWorktree** tool: from ~/dev use the repo-prefixed name, e.g. `EnterWorktree(name: "taher-core/my-branch")`; already inside a repo session use `EnterWorktree(name: "<branch>")`. NOTE: EnterWorktree/ExitWorktree are DEFERRED tools — FIRST run `ToolSearch(query: "select:EnterWorktree,ExitWorktree")` to load them, THEN call.'

for p in $REPO_DIRS; do
  d=$(basename "$p")
  db="$p/.beads/beads.db"
  [ -f "$db" ] || continue

  cs=$(br --db "$db" coordination status 2>/dev/null)
  sm=$(printf '%s\n' "$cs" | grep -E '^Workspace:' | head -1)
  echo "• $d — ${sm:-(empty)}"

  ready=$(br --db "$db" scheduler --limit "$READY_N" 2>/dev/null | grep -E '^[0-9]+\. score ' | head -"$READY_N")
  if [ -n "$ready" ]; then
    printf '    ▸ ready (claim before working):\n'
    printf '%s\n' "$ready" | sed 's/^/        /'
  fi

  inflight=$(printf '%s\n' "$cs" | grep -E '^- |^[[:space:]]+assignee:' | head -$((INFLIGHT_N * 2)))
  if [ -n "$inflight" ]; then
    printf '    🔒 in-flight (already claimed — do NOT pick):\n'
    printf '%s\n' "$inflight" | sed 's/^/        /'
  fi
done
true
