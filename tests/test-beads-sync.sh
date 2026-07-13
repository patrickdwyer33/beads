#!/bin/sh
# test-beads-sync.sh — sandboxed behavior tests for hooks/beads-sync.sh.
# No network: bare repos on disk act as "origin". Requires git, jq, python3,
# and the REAL br (>= the pinned 0.2.15) on PATH — real DBs are created in
# the sandbox. BD_BR_OVERRIDE points the sync script at a logging shim so
# tests can assert WHICH br modes ran (the skip-import guard).
#
# Run: sh tests/test-beads-sync.sh   → ok/FAIL per case, non-zero exit on any FAIL.
set -u

SYNC="$(cd "$(dirname "$0")/.." && pwd)/hooks/beads-sync.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     got: %s\n' "$1" "$2"; }

command -v br >/dev/null 2>&1 || { echo "SKIP-ALL: br not installed"; exit 1; }
REAL_BR="$(command -v br)"

# Canonical (physical) sandbox root: macOS mktemp returns /var/folders/…,
# a symlink to /private/var — br's path-safety checks false-reject when
# logical and physical path forms mix (same quirk the sync script works
# around by running its merge with cwd in the repo).
T=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$T"; rm -f "$HOME/.claude/beads-orc-retry/proj"' EXIT INT TERM

# br shim: log argv, delegate to the real binary. If $T/fail-next-merge
# exists AND this invocation is a `sync --merge` (Case I: simulates a merge
# failure, e.g. a SQLite lock from a concurrent session), consume the file
# and exit 1 WITHOUT delegating — the real DB is left untouched.
cat > "$T/brshim" <<EOF
#!/bin/sh
echo "\$@" >> "$T/br-calls.log"
case " \$* " in
  *" sync --merge "*)
    if [ -f "$T/fail-next-merge" ]; then
      rm -f "$T/fail-next-merge"
      exit 1
    fi
    ;;
esac
exec "$REAL_BR" "\$@"
EOF
chmod +x "$T/brshim"
export BD_BR_OVERRIDE="$T/brshim"
reset_brlog() { : > "$T/br-calls.log"; }

# Sandbox DEV_ROOT with one beads repo (proj) + bare origin (main+dev).
export DEV_ROOT="$T/dev"
mkdir -p "$DEV_ROOT"
git init -q --bare "$T/origin.git"
git -c init.defaultBranch=main init -q "$DEV_ROOT/proj"
(
  cd "$DEV_ROOT/proj" || exit 1
  git config user.email t@t; git config user.name t
  printf 'hi\n' > README.md && git add -A && git commit -qm init
  "$REAL_BR" init --prefix proj >/dev/null 2>&1
  printf '%s\n' '*.db' '*.db-*' '*.lock' 'redirect' 'last-touched' '.br_history/' > .beads/.gitignore
  "$REAL_BR" create "first bead" --type task -p 2 >/dev/null 2>&1
  "$REAL_BR" sync --flush-only >/dev/null 2>&1
  git add .beads && git commit -qm "chore: init beads"
  git branch dev
  git remote add origin "$T/origin.git"
  git push -q origin main dev
)
PROJ="$DEV_ROOT/proj"
[ -f "$PROJ/.beads/beads.db" ] || { echo "PRECONDITION FAIL: br init did not create .beads/beads.db"; exit 1; }

origin_dev_sha() { git -C "$T/origin.git" rev-parse dev; }
origin_ledger()  { git -C "$T/origin.git" show "dev:.beads/issues.jsonl" 2>/dev/null; }
first_id() { head -1 "$PROJ/.beads/issues.jsonl" | jq -r '.id'; }
ID1=$(first_id)

# A "machine B" clone used to plant foreign changes on origin/dev.
git clone -q "$T/origin.git" "$T/machineB"
( cd "$T/machineB" && git config user.email b@b && git config user.name b && git checkout -q dev )
# plant_foreign <marker-title>: bump ID1's updated_at far into the future and
# retitle it in machine B's LEDGER, then push to origin/dev. (Edits JSONL
# directly — B does not need a DB to publish ledger state.) Resyncs machineB
# to origin/dev FIRST: earlier cases advance origin/dev after machineB was
# cloned, and a push from the stale tip would be rejected as non-fast-forward.
plant_foreign() {
  ( cd "$T/machineB" && git fetch -q origin dev && git reset -q --hard origin/dev )
  python3 - "$T/machineB/.beads/issues.jsonl" "$ID1" "$1" <<'PY'
import sys, json
path, target, title = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
with open(path, encoding='utf-8') as f:
    for line in f:
        s = line.rstrip('\n')
        if not s.strip():
            continue
        o = json.loads(s)
        if o.get('id') == target:
            o['title'] = title
            o['updated_at'] = '2030-01-01T00:00:00Z'
            s = json.dumps(o, separators=(',', ':'))
        lines.append(s)
with open(path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
PY
  ( cd "$T/machineB" && git add .beads/issues.jsonl \
    && git commit -qm "chore(beads): foreign update" && git push -q origin dev )
}

# --- cases -------------------------------------------------------------------

# A. already in sync → no push, no merge, flush only
reset_brlog
before=$(origin_dev_sha)
out=$(sh "$SYNC" "$PROJ" 2>&1)
if [ "$(origin_dev_sha)" = "$before" ] && printf '%s' "$out" | grep -q "in sync" \
   && ! grep -q -- "--merge" "$T/br-calls.log"; then
  ok "in-sync no-op"
else bad "in-sync no-op" "$out / $(cat "$T/br-calls.log")"; fi

# B. local-only new bead → pushed to origin/dev; ledger-only commit; NO db merge
reset_brlog
( cd "$PROJ" && "$REAL_BR" create "second bead" --type task -p 3 >/dev/null 2>&1 )
before=$(origin_dev_sha)
out=$(sh "$SYNC" "$PROJ" 2>&1)
after=$(origin_dev_sha)
newid=$(grep -v "$ID1" "$PROJ/.beads/issues.jsonl" | head -1 | jq -r '.id')
files=$(git -C "$T/origin.git" diff-tree --no-commit-id --name-only -r "$after")
parent=$(git -C "$T/origin.git" rev-parse "$after^")
if [ "$after" != "$before" ] && [ "$files" = ".beads/issues.jsonl" ] \
   && [ "$parent" = "$before" ] \
   && origin_ledger | grep -q "$newid" \
   && ! grep -q -- "--merge" "$T/br-calls.log"; then
  ok "local-only push (skip-import guard held)"
else bad "local-only push (skip-import guard held)" "$out / files=$files / $(cat "$T/br-calls.log")"; fi

# C. foreign-only change → db reconciled via 'sync --merge --force'; no push needed
reset_brlog
plant_foreign "RETITLED-BY-B"
before=$(origin_dev_sha)
out=$(sh "$SYNC" "$PROJ" 2>&1)
title_now=$("$REAL_BR" show "$ID1" --db "$PROJ/.beads/beads.db" --json 2>/dev/null | jq -r '.[0].title')
if grep -q -- "sync --merge --force" "$T/br-calls.log" \
   && [ "$title_now" = "RETITLED-BY-B" ] \
   && [ "$(origin_dev_sha)" = "$before" ] \
   && grep -q "RETITLED-BY-B" "$PROJ/.beads/issues.jsonl"; then
  ok "foreign pull (three-way merge into DB, no push)"
else bad "foreign pull (three-way merge into DB, no push)" "$out / title=$title_now / $(cat "$T/br-calls.log")"; fi

# D. both sides → import AND push; nothing dropped
reset_brlog
( cd "$PROJ" && "$REAL_BR" create "third bead" --type task -p 3 >/dev/null 2>&1 )
plant_foreign "RETITLED-AGAIN"
before=$(origin_dev_sha)
out=$(sh "$SYNC" "$PROJ" 2>&1)
lost=""
for id in $(git -C "$T/origin.git" show "$before:.beads/issues.jsonl" | jq -r '.id'); do
  origin_ledger | grep -q "\"$id\"" || lost="$lost $id"
done
if [ "$(origin_dev_sha)" != "$before" ] && [ -z "$lost" ] \
   && grep -q -- "sync --merge --force" "$T/br-calls.log" \
   && origin_ledger | grep -q "RETITLED-AGAIN" \
   && origin_ledger | grep -q "third bead"; then
  ok "bidirectional sync (import + push, no drops)"
else bad "bidirectional sync (import + push, no drops)" "$out / lost=[$lost]"; fi

# E. dry-run → reports, changes nothing
reset_brlog
( cd "$PROJ" && "$REAL_BR" create "fourth bead" --type task -p 3 >/dev/null 2>&1 \
  && "$REAL_BR" sync --flush-only >/dev/null 2>&1 )
before=$(origin_dev_sha)
ledger_before=$(cat "$PROJ/.beads/issues.jsonl")
out=$(sh "$SYNC" --dry-run "$PROJ" 2>&1)
if [ "$(origin_dev_sha)" = "$before" ] \
   && printf '%s' "$out" | grep -qi "dry-run" \
   && [ "$(cat "$PROJ/.beads/issues.jsonl")" = "$ledger_before" ] \
   && ! grep -q -- "--merge" "$T/br-calls.log" \
   && ! grep -q -- "--flush-only" "$T/br-calls.log"; then
  ok "dry-run touches nothing"
else bad "dry-run touches nothing" "$out / $(cat "$T/br-calls.log")"; fi
# clean up the pending change for later cases
out=$(sh "$SYNC" "$PROJ" 2>&1)

# F. repo without origin/dev → skipped with the RIGHT message, exit 0
git init -q --bare "$T/origin-nodev.git"
git -c init.defaultBranch=main init -q "$DEV_ROOT/nodev"
(
  cd "$DEV_ROOT/nodev" || exit 1
  git config user.email t@t; git config user.name t
  printf 'x\n' > f && mkdir -p .beads && printf '' > .beads/issues.jsonl
  git add -A && git commit -qm init
  git remote add origin "$T/origin-nodev.git" && git push -q origin main
)
out=$(sh "$SYNC" "$DEV_ROOT/nodev" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "no origin/dev"; then
  ok "no-origin-dev repo skipped"
else bad "no-origin-dev repo skipped" "rc=$rc $out"; fi

# G. SessionEnd cwd gate: outside DEV_ROOT → silent no-op; inside → syncs
( cd "$PROJ" && "$REAL_BR" create "fifth bead" --type task -p 3 >/dev/null 2>&1 )
before=$(origin_dev_sha)
out=$(printf '{"cwd":"%s"}' "$HOME/Documents" | sh "$SYNC" --from-session-end 2>&1)
if [ "$(origin_dev_sha)" = "$before" ] && [ -z "$out" ]; then
  ok "session-end gate: unrelated cwd skipped"
else bad "session-end gate: unrelated cwd skipped" "$out"; fi
out=$(printf '{"cwd":"%s"}' "$DEV_ROOT" | sh "$SYNC" --from-session-end 2>&1)
if [ "$(origin_dev_sha)" != "$before" ] && origin_ledger | grep -q "fifth bead"; then
  ok "session-end gate: dev cwd synced (quiet)"
else bad "session-end gate: dev cwd synced (quiet)" "$out"; fi

# H. two-level discovery: repo at $DEV_ROOT/group/nested (one group level
# down) — same fixture recipe as proj, but nested under a group dir. No-arg
# discovery must reach it via the "$DEV"/*/*/.beads glob; a named arg
# ("nested") must resolve it via the group-level fallback.
git init -q --bare "$T/origin-nested.git"
mkdir -p "$DEV_ROOT/group"
git -c init.defaultBranch=main init -q "$DEV_ROOT/group/nested"
(
  cd "$DEV_ROOT/group/nested" || exit 1
  git config user.email t@t; git config user.name t
  printf 'hi\n' > README.md && git add -A && git commit -qm init
  "$REAL_BR" init --prefix nested >/dev/null 2>&1
  printf '%s\n' '*.db' '*.db-*' '*.lock' 'redirect' 'last-touched' '.br_history/' > .beads/.gitignore
  "$REAL_BR" create "nested bead" --type task -p 2 >/dev/null 2>&1
  "$REAL_BR" sync --flush-only >/dev/null 2>&1
  git add .beads && git commit -qm "chore: init beads"
  git branch dev
  git remote add origin "$T/origin-nested.git"
  git push -q origin main dev
)
NESTED="$DEV_ROOT/group/nested"
[ -f "$NESTED/.beads/beads.db" ] || { echo "PRECONDITION FAIL: br init did not create nested .beads/beads.db"; exit 1; }
nested_origin_ledger() { git -C "$T/origin-nested.git" show "dev:.beads/issues.jsonl" 2>/dev/null; }
NID1=$(head -1 "$NESTED/.beads/issues.jsonl" | jq -r '.id')

reset_brlog
out=$(sh "$SYNC" 2>&1)
if printf '%s' "$out" | grep -q "nested: in sync" && nested_origin_ledger | grep -q "$NID1"; then
  ok "two-level discovery: no-arg sync reaches group/nested"
else bad "two-level discovery: no-arg sync reaches group/nested" "$out"; fi

out=$(sh "$SYNC" nested 2>&1)
if printf '%s' "$out" | grep -q "in sync"; then
  ok "named-arg group fallback resolves 'nested' to group/nested"
else bad "named-arg group fallback resolves 'nested' to group/nested" "$out"; fi

# I. WARN-path retry marker: a foreign-path `br sync --merge --force` failure
# (e.g. a SQLite lock from a concurrent session) must persist a machine-local
# marker and retry the DB merge on the NEXT sync — otherwise the subsequent
# push makes local ledger == origin's, FOREIGN drops to 0, and the DB stays
# wedged behind the ledger forever. NOTE: this mutates the real
# $HOME/.claude/beads-orc-retry/ (machine-local scratch, by design) — clean
# up after ourselves (also covered by the trap).
MARKER="$HOME/.claude/beads-orc-retry/proj"
rm -f "$MARKER"
reset_brlog
touch "$T/fail-next-merge"
plant_foreign "WEDGE-TEST"
out=$(sh "$SYNC" "$PROJ" 2>&1)
title_now=$("$REAL_BR" show "$ID1" --db "$PROJ/.beads/beads.db" --json 2>/dev/null | jq -r '.[0].title')
if printf '%s' "$out" | grep -q "will retry" \
   && [ -f "$MARKER" ] \
   && [ "$title_now" != "WEDGE-TEST" ]; then
  ok "WARN-path merge failure sets retry marker, DB not clobbered"
else bad "WARN-path merge failure sets retry marker, DB not clobbered" \
  "$out / marker=$([ -f "$MARKER" ] && echo present || echo absent) / title=$title_now"; fi

out=$(sh "$SYNC" "$PROJ" 2>&1)
title_now=$("$REAL_BR" show "$ID1" --db "$PROJ/.beads/beads.db" --json 2>/dev/null | jq -r '.[0].title')
if printf '%s' "$out" | grep -qF "[heal]" \
   && [ ! -f "$MARKER" ] \
   && [ "$title_now" = "WEDGE-TEST" ]; then
  ok "retry marker heals DB merge on next sync"
else bad "retry marker heals DB merge on next sync" \
  "$out / marker=$([ -f "$MARKER" ] && echo present || echo absent) / title=$title_now"; fi
rm -f "$MARKER" "$T/fail-next-merge"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
