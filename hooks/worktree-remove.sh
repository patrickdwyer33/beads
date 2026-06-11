#!/bin/sh
# worktree-remove.sh — WorktreeRemove hook (global).
#
# Fire-and-forget cleanup for worktrees created by worktree-create.sh. Removes
# the git worktree (and its directory) and prunes the now-unused branch.
#
# Contract: WorktreeRemove has NO decision control — exit codes and output are
# ignored, failures logged only in --debug. So we just do best-effort cleanup
# and always exit 0. ExitWorktree's keep/remove/discard_changes safety checks
# happen in Claude Code BEFORE this hook runs, so reaching here means removal
# was already authorized.
#
# stdin schema for this event isn't published; read tolerant variants and log
# the raw payload for verification.

set -u

LOG="$HOME/.claude/hooks/worktree-remove.log"

input=$(cat)
printf '%s\n---\n' "$input" >> "$LOG" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || exit 0

wt_path=$(printf '%s' "$input" | jq -r '.worktree_path // .path // empty' 2>/dev/null)
[ -n "$wt_path" ] || exit 0
[ -d "$wt_path" ] || exit 0

# Resolve the owning repo from the worktree itself (common-dir → repo root).
common_dir=$(git -C "$wt_path" rev-parse --git-common-dir 2>/dev/null)
if [ -n "$common_dir" ]; then
  case "$common_dir" in /*) ;; *) common_dir="$wt_path/$common_dir" ;; esac
  repo_dir=$(cd "$common_dir/.." 2>/dev/null && pwd)
fi

# Capture the branch checked out in this worktree before we remove it.
branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null)

if [ -n "${repo_dir:-}" ]; then
  git -C "$repo_dir" worktree remove --force "$wt_path" >/dev/null 2>&1 \
    || rm -rf "$wt_path" 2>/dev/null
  git -C "$repo_dir" worktree prune >/dev/null 2>&1 || true
  # Delete the branch only if it's fully merged-safe to force-drop a throwaway
  # worktree branch; -D since these are short-lived task branches.
  if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
    git -C "$repo_dir" branch -D "$branch" >/dev/null 2>&1 || true
  fi
else
  rm -rf "$wt_path" 2>/dev/null || true
fi

exit 0
