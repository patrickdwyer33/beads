---
name: init
description: Use when opting a repo under ~/dev into beads-orc issue tracking. Creates .beads, the dev branch, and documents the workflow in the repo.
---

# Initialize beads-orc in a repo

Run from inside the target repo (must be a git repo under ~/dev — directly,
or one group level down (~/dev/<group>/<repo>). Never beads-init a group
folder itself, and keep repo folder names unique across groups (the
directory name becomes the bead id prefix)). The repo's
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
   printf '%s\n' '*.db' '*.db-*' '*.lock' 'redirect' 'last-touched' 'beads.base.jsonl' '.br_history/' > .beads/.gitignore
   ```

4. Ensure the `dev` branch exists (the integration branch for the branch
   policy): `git rev-parse --verify --quiet dev || git branch dev`. Push it
   if the repo has a remote: `git push -u origin dev`. This matters beyond
   policy: the automated ledger sync targets `origin/dev` and SKIPS repos
   that don't have it.

5. Apply server-side branch rules IF the repo plan supports them (public
   repo, or a paid plan for private ones). Try; on HTTP 403
   ("Upgrade to GitHub Pro…") skip and note in the repo CLAUDE.md that
   branch policy is documentation + agent identity only.

   ```bash
   OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
   # main: PR-only (blocks direct pushes for everyone incl. the agent
   # machine account); repo admin (the human) can bypass.
   gh api "repos/$OWNER_REPO/rulesets" -X POST --input - <<'JSON' || echo "rulesets unavailable (private/free) — documented policy only"
   {"name":"beads-orc main policy","target":"branch","enforcement":"active",
    "conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},
    "rules":[{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false}},{"type":"non_fast_forward"},{"type":"deletion"}],
    "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}
   JSON
   # dev: no history rewrites, no deletion (normal pushes unaffected).
   gh api "repos/$OWNER_REPO/rulesets" -X POST --input - <<'JSON' || true
   {"name":"beads-orc dev policy","target":"branch","enforcement":"active",
    "conditions":{"ref_name":{"include":["refs/heads/dev"],"exclude":[]}},
    "rules":[{"type":"non_fast_forward"},{"type":"deletion"}],
    "bypass_actors":[]}
   JSON
   ```

6. Document the workflow in the repo. Append to the repo's CLAUDE.md (create
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
   - **Branch policy: review the diff (`git diff origin/dev...HEAD`) with a
     fresh subagent BEFORE pushing to `dev`. `main` is prod — agents NEVER
     push or merge to main; a human promotes dev → main.** Enforcement:
     agent sessions authenticate as the Claude machine account; server
     rules apply where the repo plan supports them, documentation
     everywhere else.
   - Close when done: `bd close <id> --reason "<done note>"`.
   ```

7. Commit the opt-in ON THE `dev` BRANCH (switch first: `git checkout dev` —
   committing this to main would violate the policy you just documented):
   `git add .beads/issues.jsonl .beads/.gitignore CLAUDE.md`
   then commit with message `chore: init beads-orc issue tracking`.
   (If `br init` created other tracked files under .beads/, add those too —
   never add `*.db`.)
