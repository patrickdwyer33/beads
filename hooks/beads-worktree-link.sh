#!/bin/sh
# beads-worktree-link.sh — SessionStart hook (global, repo-agnostic).
#
# Problem: each git worktree gets its OWN .beads/beads.db, so parallel Claude
# Code sessions in different worktrees would claim into separate databases and
# never see each other's claims. Beads supports a `.beads/redirect` file that
# points a worktree at a canonical .beads dir. This hook creates that redirect
# automatically whenever a session starts inside a linked worktree, so all
# sessions on a repo share ONE backlog + live claim coordination.
#
# Safe by design: exits 0 always; no-ops outside a worktree, in the main
# checkout, or in repos that have no .beads. Idempotent.

set -u

# Must be inside a git work tree.
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
git_dir=$(git rev-parse --git-dir 2>/dev/null) || exit 0

# Absolutize both paths.
case "$common_dir" in /*) ;; *) common_dir="$PWD/$common_dir" ;; esac
case "$git_dir"    in /*) ;; *) git_dir="$PWD/$git_dir" ;; esac
common_dir=$(cd "$common_dir" 2>/dev/null && pwd) || exit 0
git_dir=$(cd "$git_dir" 2>/dev/null && pwd) || exit 0

# In the MAIN checkout git-dir == common-dir → nothing to do.
[ "$common_dir" = "$git_dir" ] && exit 0

# Canonical beads dir lives next to the main repo's .git (common dir).
canonical=$(dirname "$common_dir")/.beads
[ -d "$canonical" ] || exit 0                 # repo doesn't use beads → skip.

# Never redirect a dir to itself.
[ "$canonical" = "$PWD/.beads" ] && exit 0

mkdir -p .beads 2>/dev/null || exit 0

# Keep worktree-local beads artifacts (db, redirect, locks) out of git in case
# this branch doesn't track .beads/.gitignore yet.
if [ ! -f .beads/.gitignore ]; then
  printf '%s\n' '*.db' '*.db-*' '*.lock' 'redirect' 'last-touched' 'beads.base.jsonl' '.br_history/' > .beads/.gitignore 2>/dev/null
fi

# Write/refresh the redirect only when it's missing or stale.
current=$(cat .beads/redirect 2>/dev/null || printf '')
if [ "$current" != "$canonical" ]; then
  # Drop any local db so the redirect (not a stale local copy) is authoritative.
  rm -f .beads/beads.db .beads/beads.db-wal .beads/beads.db-shm 2>/dev/null
  printf '%s\n' "$canonical" > .beads/redirect 2>/dev/null \
    && echo "beads: linked worktree → shared DB at $canonical"
fi

exit 0
