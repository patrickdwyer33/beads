---
name: finish
description: Use when a bead's implementation is complete and committed, to close it out and land the branch per the branch policy.
---

# Finish a bead

1. Verify the work is committed on the feature branch (clean `git status`).
2. Push the feature branch and integrate into `dev` per the branch policy:
   merge/push to `dev` only. The review gate (when installed) will require a
   fresh review before the dev push lands — follow its instructions.
   **NEVER push `main` — a human promotes dev → main.**
3. Close the bead with a closing note:
   `bd update <id> --status closed`
   and add context if useful: `bd comment <id> "<what landed, where>"`.
4. The git-tracked ledger (.beads/issues.jsonl) auto-flushes on mutation.
   Until automated sync (plan 2) is installed, commit it on dev with message
   `chore(beads): update ledger` if it changed.
5. Exit the worktree (ExitWorktree) and report what closed.
