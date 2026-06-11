#!/bin/sh
# review-gate.sh — PreToolUse hook (global) + companion `mark` mode.
#
# Enforces a fresh errors-and-omissions review before any push that updates
# origin/main (or origin/master). Built 2026-06-06.
#
# Two modes:
#   (hook)  sh review-gate.sh        — reads PreToolUse JSON on stdin. If the
#           Bash command is a `git push` targeting main/master AND no review
#           marker matches the exact diff about to land, prints a DENY decision
#           (permissionDecision:"deny") whose reason tells the model to review
#           with a FRESH SUBAGENT, then mark + retry. Allows otherwise.
#   mark    sh review-gate.sh mark [repo]  — records the review marker for the
#           current diff (origin/main...HEAD) so the next push is allowed. The
#           hook tells the model to run this AFTER the review passes.
#
# Honest limit: this guarantees the review STEP happens and is FRESH for the
# exact diff (can't skip; can't review-then-edit). It can't grade the review's
# quality — that's on the reviewer. Trigger is what was manual; now it's not.
#
# Fail-open by design: if it can't confidently resolve the repo / main ref /
# diff, it ALLOWS (exit 0, no output) and logs, so it never wedges an unrelated
# push. Contract: deny = print hookSpecificOutput JSON on stdout, exit 0.

set -u

LOG="$HOME/.claude/hooks/review-gate.log"
log() { printf '%s\n' "$*" >> "$LOG" 2>/dev/null || true; }

# --- shared helpers (used by both modes) ----------------------------------

# Echo the remote default-branch ref (origin/main or origin/master); fail if none.
main_ref() {
  for r in origin/main origin/master; do
    git -C "$1" rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { echo "$r"; return 0; }
  done
  return 1
}

# Echo a sha256 of exactly what a push would ADD to main: diff main_ref...HEAD.
# Empty output means "nothing new to land" (caller treats as allow).
diff_hash() {
  _repo="$1"; _ref="$2"
  _d=$(git -C "$_repo" diff "$_ref...HEAD" 2>/dev/null) || return 1
  [ -n "$_d" ] || { echo ""; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_d" | shasum -a 256 | cut -d' ' -f1
  else
    printf '%s' "$_d" | sha256sum | cut -d' ' -f1
  fi
}

marker_path() {
  _gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/REVIEW_OK' "$_gd"
}

# --- mode: mark ------------------------------------------------------------

if [ "${1:-}" = "mark" ]; then
  repo="${2:-$PWD}"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "review mark: '$repo' is not a git repo" >&2; exit 1; }
  ref=$(main_ref "$repo") || { echo "review mark: no origin/main|master in '$repo'" >&2; exit 1; }
  h=$(diff_hash "$repo" "$ref") || { echo "review mark: cannot compute diff" >&2; exit 1; }
  mp=$(marker_path "$repo") || { echo "review mark: cannot locate git dir" >&2; exit 1; }
  printf '%s\n' "$h" > "$mp" || { echo "review mark: cannot write $mp" >&2; exit 1; }
  log "MARK repo=$repo ref=$ref hash=${h:-<empty>}"
  echo "Review recorded for $repo (diff vs $ref). Push is now unblocked until the diff changes."
  exit 0
fi

# --- mode: hook ------------------------------------------------------------

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
payload_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

[ -n "$cmd" ] || exit 0

# Only care about git pushes.
case "$cmd" in *git*push*) ;; *) exit 0 ;; esac

# Resolve the repo dir: prefer an explicit `git -C <path>`, else a leading
# `cd <path> &&`, else the session cwd.
repo=""
case "$cmd" in
  *"git -C "*) repo=$(printf '%s' "$cmd" | sed -n 's/.*git -C[ ]*\([^ ]*\).*/\1/p') ;;
esac
if [ -z "$repo" ]; then
  case "$cmd" in
    "cd "*) repo=$(printf '%s' "$cmd" | sed -n 's/^cd[ ]*\([^&;|]*\).*/\1/p' | sed 's/[ ]*$//') ;;
  esac
fi
[ -n "$repo" ] || repo="$payload_cwd"
[ -n "$repo" ] || repo="$PWD"

# strip surrounding quotes if any
repo=$(printf '%s' "$repo" | sed 's/^["'"'"']//; s/["'"'"']$//')

if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  log "ALLOW (repo unresolved) cmd=[$cmd] tried=[$repo]"; exit 0
fi

# Does this push target main/master?
target_main=""
case "$cmd" in
  *" main"*|*" master"*|*:main|*:master|*:main\ *|*:master\ *|*"refs/heads/main"*|*"refs/heads/master"*)
    target_main=1 ;;
esac
if [ -z "$target_main" ]; then
  # No explicit ref naming main → bare/current-branch push. Targets main only
  # if the current branch IS main/master.
  cur=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
  case "$cur" in main|master) target_main=1 ;; esac
fi
[ -n "$target_main" ] || { log "ALLOW (not main) cmd=[$cmd] repo=[$repo]"; exit 0; }

ref=$(main_ref "$repo") || { log "ALLOW (no main ref) repo=[$repo]"; exit 0; }

# Beads-only exemption: a push whose ENTIRE diff is under .beads/ is a ledger
# DATA sync (issues.jsonl), not code. The review gate exists for code review, so
# let data-only ledger syncs through. Resolve what's being pushed: the source
# side of an explicit <src>:main refspec, else HEAD (bare current-branch push).
src=""
for w in $cmd; do
  case "$w" in
    *:main|*:refs/heads/main|*:master|*:refs/heads/master) src=${w%%:*}; break ;;
  esac
done
[ -n "$src" ] || src="HEAD"
beads_changed=$(git -C "$repo" diff --name-only "$ref...$src" 2>/dev/null)
if [ -n "$beads_changed" ] && ! printf '%s\n' "$beads_changed" | grep -qv '^\.beads/'; then
  log "ALLOW (beads-only data sync) repo=[$repo] src=$src"; exit 0
fi

h=$(diff_hash "$repo" "$ref") || { log "ALLOW (diff failed) repo=[$repo]"; exit 0; }
[ -n "$h" ] || { log "ALLOW (empty diff, nothing lands) repo=[$repo]"; exit 0; }

mp=$(marker_path "$repo") || { log "ALLOW (no git dir) repo=[$repo]"; exit 0; }
saved=$(cat "$mp" 2>/dev/null || printf '')

if [ "$saved" = "$h" ]; then
  log "ALLOW (reviewed) repo=[$repo] hash=$h"; exit 0
fi

# Not reviewed (or stale) → DENY with actionable instructions.
log "DENY (unreviewed) cmd=[$cmd] repo=[$repo] want=$h have=${saved:-<none>}"

reason="Pre-push review gate: this push updates ${ref#origin/} on origin, and that exact diff has NOT had a fresh review.

Do this before pushing:
1. Review precisely what will land:  git -C \"$repo\" diff $ref...HEAD
2. Spawn a FRESH, INDEPENDENT reviewer (Agent tool, or run /code-review) — separate context, NOT self-review. Hunt for both:
   - correctness bugs, and
   - OMISSIONS: missing migration for a schema change, untracked/forgotten files, unhandled edge cases, half-finished work, stray debug/console output.
3. Fix everything it flags (re-review if the fixes are non-trivial).
4. Record the review (keyed to this exact diff):
     sh \"\$HOME/.claude/hooks/review-gate.sh\" mark \"$repo\"
5. Re-run the push.

Any edit after step 4 changes the diff and requires a new review. This gate cannot be skipped, but it does not judge review quality — that's on the reviewer."

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
