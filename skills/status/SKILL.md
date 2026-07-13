---
name: status
description: Use when the user asks what's on the backlog, what's in flight, or what to work on next — current repo by default, all beads-inited repos when outside one.
---

# Backlog status

Scope rule: if the cwd is inside a beads-inited repo (`git rev-parse
--show-toplevel` succeeds and `<toplevel>/.beads` exists — a worktree counts,
its `.beads` redirect is still a `.beads`), report THAT repo only. Otherwise
(e.g. `~/dev`, or a repo that isn't beads-inited), report every beads-inited
repo under ~/dev (dirs containing `.beads/`, directly under ~/dev or one
group level down) and say which scope you used.
The user can always name a repo or say "all" to override.

Per repo in scope:

- Ready next: `bd ready` (from the repo dir, or `br --db <repo>/.beads/beads.db ready`).
- In flight with assignees: `br --db <repo>/.beads/beads.db coordination status`
- One bead in depth: `bd show <id>` (add --json for machine-readable).

Summarize: ▸ ready (safe to claim) vs 🔒 in-flight (claimed — do not pick).
Flag stale in-flight claims (old age, assignee branch gone) to the user
rather than reclaiming silently.
