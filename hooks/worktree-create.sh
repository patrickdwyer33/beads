#!/bin/sh
# worktree-create.sh — WorktreeCreate hook (global).
#
# Purpose: let EnterWorktree / `claude --worktree` work from /Users/joedwy/dev,
# which is NOT a git repo but a parent folder of repos. A worktree is always a
# fork of ONE repo, so the requested name must encode which repo:
#
#       EnterWorktree(name: "<repo>/<branch>")
#       e.g.            "dwyerlab-api/w0s-trash-fix"
#
# The first "/"-segment selects /Users/joedwy/dev/<repo>; the rest is the new
# branch. We create a real `git worktree add` (so the SessionStart beads-link
# hook keeps working) under ~/.claude-worktrees/<repo>/<branch>, wire up the
# beads redirect ourselves (in case SessionStart doesn't re-fire on an
# in-session EnterWorktree switch), then print the worktree path on stdout.
#
# Contract (verified against code.claude.com/docs hooks ref):
#   - Command hook prints the created worktree PATH on stdout, exit 0.
#   - ANY non-zero exit aborts creation; stderr is shown to the user.
#   - Exit 0 with no path on stdout is ALSO treated as failure.
#
# stdin field names for this event are not published in the docs, so we read
# tolerant variants (.worktree_name|.name, .source_path|.cwd) AND log the raw
# payload to worktree-create.log so the real schema can be confirmed on first
# run.

set -u

DEV_ROOT="${DEV_ROOT_OVERRIDE:-$HOME/dev}"
WT_BASE="$HOME/.claude-worktrees"
LOG="$HOME/.claude/hooks/worktree-create.log"

fail() { echo "WorktreeCreate hook: $1" >&2; exit 1; }

input=$(cat)

# Log raw payload for first-run schema verification (best effort).
printf '%s\n---\n' "$input" >> "$LOG" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"

name=$(printf '%s' "$input" | jq -r '.worktree_name // .name // empty' 2>/dev/null)
source_path=$(printf '%s' "$input" | jq -r '.source_path // .cwd // empty' 2>/dev/null)

[ -n "$name" ] || fail "no worktree name in payload (need \"<repo>/<branch>\")"

# Repo selection: "<repo>/<branch>" picks $DEV_ROOT/<repo>. A BARE name (no "/")
# is valid from inside a repo session: infer the repo from the event's
# source_path and treat the whole name as the branch. Fail only when a bare
# name arrives with no git-repo context to infer from (e.g. from ~/dev).
case "$name" in
  */*)
    repo=${name%%/*}      # first segment
    branch=${name#*/}     # everything after the first slash (slashes allowed in branch refs)
    repo_dir="$DEV_ROOT/$repo"
    # One optional group level: $DEV_ROOT/<group>/<repo>. The worktree name
    # convention stays "<repo-basename>/<branch>" either way — never
    # "<group>/<repo>/<branch>".
    if [ ! -d "$repo_dir" ]; then
      for g in "$DEV_ROOT"/*/"$repo"; do [ -d "$g" ] && { repo_dir="$g"; break; }; done
    fi
    ;;
  *)
    # Resolve the MAIN checkout even when source_path is itself a linked
    # worktree: --git-common-dir points at the main repo's .git from anywhere
    # (mirrors beads-worktree-link.sh's absolutize pattern).
    common=$(git -C "${source_path:-.}" rev-parse --git-common-dir 2>/dev/null) \
      || fail "bare name \"$name\" needs a repo context. From ~/dev use \"<repo>/$name\"."
    case "$common" in /*) ;; *) common="${source_path:-.}/$common" ;; esac
    common=$(cd "$common" 2>/dev/null && pwd) \
      || fail "cannot resolve the owning repo for bare name \"$name\""
    src_root=$(dirname "$common")
    repo=$(basename "$src_root")
    branch="$name"
    repo_dir="$src_root"
    ;;
esac
[ -d "$repo_dir/.git" ] || git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "\"$repo\" is not a git repo under $DEV_ROOT. Valid repos: $(ls -d "$DEV_ROOT"/*/.git "$DEV_ROOT"/*/*/.git 2>/dev/null | sed 's@/.git@@;s@.*/@@' | tr '\n' ' ')"

# Directory name: flatten any slashes in the branch portion so we get one dir.
dir_name=$(printf '%s' "$branch" | tr '/' '-')
wt_path="$WT_BASE/$repo/$dir_name"

# Pick a base ref: prefer origin/<default> (fresh), then local default, then HEAD.
def=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -n "$def" ] || { for b in main master; do
  git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$b" && { def="$b"; break; }
done; }
[ -n "$def" ] || def="HEAD"

base=""
# Branch policy (beads-inited repos ONLY): feature work integrates into dev, so
# fork worktrees from the freshest dev when the repo has one. Non-beads repos
# keep the upstream behavior (default branch) — several ~/dev repos have
# unrelated/stale `dev` branches that must never become silent worktree bases.
if [ -d "$repo_dir/.beads" ]; then
  if git -C "$repo_dir" rev-parse --verify --quiet "origin/dev" >/dev/null 2>&1; then
    base="origin/dev"
  elif git -C "$repo_dir" rev-parse --verify --quiet "dev" >/dev/null 2>&1; then
    base="dev"
  fi
fi
if [ -z "$base" ]; then
  if git -C "$repo_dir" rev-parse --verify --quiet "origin/$def" >/dev/null 2>&1; then
    base="origin/$def"
  elif git -C "$repo_dir" rev-parse --verify --quiet "$def" >/dev/null 2>&1; then
    base="$def"
  fi
fi
# (No auto-fetch: branches from local origin/<default> tip to stay fast and
#  avoid network/auth hangs in a hook. Fetch in-session if you need newer.)

# Ensure a unique branch name (auto-suffix -2, -3, … if taken).
final_branch="$branch"
n=1
while git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$final_branch"; do
  n=$((n + 1))
  final_branch="$branch-$n"
done
if [ "$final_branch" != "$branch" ]; then
  dir_name=$(printf '%s' "$final_branch" | tr '/' '-')
  wt_path="$WT_BASE/$repo/$dir_name"
fi

mkdir -p "$WT_BASE/$repo" 2>/dev/null || fail "cannot create $WT_BASE/$repo"

if [ -n "$base" ]; then
  git -C "$repo_dir" worktree add -b "$final_branch" "$wt_path" "$base" >/dev/null 2>&1 \
    || fail "git worktree add failed (repo=$repo branch=$final_branch base=$base)"
else
  git -C "$repo_dir" worktree add -b "$final_branch" "$wt_path" >/dev/null 2>&1 \
    || fail "git worktree add failed (repo=$repo branch=$final_branch, from HEAD)"
fi

# Wire up the beads redirect so claims coordinate with the canonical DB even if
# SessionStart doesn't re-run on an in-session switch. Mirrors beads-worktree-link.sh.
canonical="$repo_dir/.beads"
if [ -d "$canonical" ]; then
  mkdir -p "$wt_path/.beads" 2>/dev/null && {
    [ -f "$wt_path/.beads/.gitignore" ] || \
      printf '%s\n' '*.db' '*.db-*' '*.lock' 'redirect' 'last-touched' 'beads.base.jsonl' '.br_history/' > "$wt_path/.beads/.gitignore" 2>/dev/null
    printf '%s\n' "$canonical" > "$wt_path/.beads/redirect" 2>/dev/null
  }
fi

# Success: print the worktree path on stdout (the contract), exit 0.
echo "$wt_path"
exit 0
