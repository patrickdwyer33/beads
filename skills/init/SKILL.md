---
name: init
description: Use when opting a repo under ~/dev into beads-orc issue tracking. Creates .beads, the dev branch, and documents the workflow in the repo.
---

# Initialize beads-orc in a repo

Run from inside the target repo (must be a git repo under ~/dev). The repo's
DIRECTORY NAME becomes the bead id prefix — confirm with the user if the name
looks wrong (renaming later breaks routing).

1. Verify preconditions: `git rev-parse --show-toplevel` succeeds, and the
   repo root's basename contains no spaces and is all-lowercase (br
   lowercases id prefixes at init — an uppercase dir name silently breaks
   prefix routing). Check `command -v br` — if
   missing, run the beads-orc:setup skill first.

2. Initialize beads (check `br init --help` for the prefix flag name first):

   ```bash
   br init --prefix "$(basename "$(git rev-parse --show-toplevel)")"
   ```

3. Ensure `.beads/.gitignore` keeps live-DB artifacts out of git:

   ```bash
   printf '%s\n' '*.db' '*.db-*' '*.lock' 'redirect' 'last-touched' '.br_history/' > .beads/.gitignore
   ```

4. Ensure the `dev` branch exists (the integration branch for the branch
   policy): `git rev-parse --verify --quiet dev || git branch dev`. Push it
   if the repo has a remote: `git push -u origin dev`.

5. Document the workflow in the repo. Append to the repo's CLAUDE.md (create
   it if missing):

   ```markdown
   ## Beads workflow (beads-orc)

   This repo's backlog is tracked with beads. The live DB is
   `.beads/beads.db` (gitignored, shared by all local sessions);
   `.beads/issues.jsonl` is the git-tracked ledger.

   - Pick work ONLY from `bd ready`. CLAIM BEFORE YOU WORK:
     `bd update <id> --claim` (atomic; instantly hides the bead from other
     sessions). Use `bd`, not bare `br`.
   - Work each bead on a feature branch in a worktree (EnterWorktree).
   - **Branch policy: push feature work to `dev` (review-gated). `main` is
     prod — agents NEVER push to main. A human promotes dev → main.**
   - Close when done: `bd close <id> --reason "<done note>"`.
   ```

6. Commit the opt-in ON THE `dev` BRANCH (switch first: `git checkout dev` —
   committing this to main would violate the policy you just documented):
   `git add .beads/issues.jsonl .beads/.gitignore CLAUDE.md`
   then commit with message `chore: init beads-orc issue tracking`.
   (If `br init` created other tracked files under .beads/, add those too —
   never add `*.db`.)
