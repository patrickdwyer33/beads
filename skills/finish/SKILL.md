---
name: finish
description: Use when a bead's implementation is complete and committed, to close it out and land the branch per the branch policy.
---

# Finish a bead

1. Verify the work is committed on the feature branch (clean `git status`).
2. REVIEW BEFORE YOU PUSH (documented workflow — there is no enforcement
   hook; the discipline is yours): see exactly what will land with
   `git diff origin/dev...HEAD`, spawn a FRESH independent reviewer (Agent
   tool or /code-review) on it, fix findings, THEN merge/push to `dev` only.
   **NEVER push `main` — a human promotes dev → main.**
3. Close the bead with a closing reason (br REFUSES `--status closed` via
   update — close is its own verb):
   `bd close <id> --reason "<what landed, where>"`
   and add context if useful: `bd comment add <id> "<note>"`.
4. The ledger (.beads/issues.jsonl) syncs to origin/dev AUTOMATICALLY at
   session end — no manual ledger commit needed. To publish immediately:
   `sh "$CLAUDE_PLUGIN_ROOT/hooks/beads-sync.sh" <repo> 2>/dev/null || sh ~/dev/beads/hooks/beads-sync.sh <repo>`.
5. Exit the worktree (ExitWorktree) and report what closed.
