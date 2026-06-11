---
name: status
description: Use when the user asks what's on the backlog, what's in flight, or what to work on next across beads-orc repos.
---

# Backlog status

For each beads-inited repo under ~/dev (dirs containing .beads/):

- Ready next: `bd ready` (run per repo, from the repo dir or with --db).
- In flight with assignees: `br --db <repo>/.beads/beads.db coordination status`
- One bead in depth: `bd show <id>` (add --json for machine-readable).

Summarize: ▸ ready (safe to claim) vs 🔒 in-flight (claimed — do not pick),
per repo. Flag stale in-flight claims (old age, assignee branch gone) to the
user rather than reclaiming silently.
