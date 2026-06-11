---
name: start
description: Use when beginning work on a bead — claims it atomically and steps into an isolated worktree.
---

# Start a bead

1. Pick ONLY from `bd ready` (open, unblocked, unclaimed) — or
   use the id the user gave. Never pick from 🔒 in-flight.
2. CLAIM FIRST, before any other work: `bd update <id> --claim`
   (atomic: sets assignee + status=in_progress, hides it from other sessions).
3. Read the full bead: `bd show <id>` — note description, deps, parent epic.
4. Enter an isolated worktree IN THIS SESSION (never tell the user to open a
   new terminal). EnterWorktree/ExitWorktree are deferred tools: first
   `ToolSearch(query: "select:EnterWorktree,ExitWorktree")`, then
   `EnterWorktree(name: "<repo>/<short-slug>")` from ~/dev, or
   `EnterWorktree(name: "<short-slug>")` from inside the repo.
5. Do the work on that branch. Branch policy: this branch will be pushed to
   `dev` (review-gated) when done — `main` is prod; NEVER push main.
6. If you stop without finishing, say so and leave the claim in place (or
   release with `bd update <id> --status open` if abandoning).
