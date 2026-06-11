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
3. Close the bead with a closing reason (br REFUSES `--status closed` via
   update — close is its own verb):
   `bd close <id> --reason "<what landed, where>"`
   and add context if useful: `bd comment add <id> "<note>"`.
4. The git-tracked ledger (.beads/issues.jsonl) auto-flushes on mutation —
   into the repo's MAIN checkout (a worktree's .beads is just a redirect).
   Until automated sync (plan 2) is installed, commit it from the main
   checkout on `dev` with message `chore(beads): update ledger` if changed.
5. Exit the worktree (ExitWorktree) and report what closed.
