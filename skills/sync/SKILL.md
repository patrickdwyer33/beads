---
name: sync
description: Use when the user asks to sync a beads ledger now, preview what a sync would do, or debug ledger sync — automated sync runs at every session end since v0.2.0.
---

# Ledger sync (automated — this skill is for force-runs and debugging)

Since v0.2.0 a SessionEnd hook syncs EVERY beads-inited repo's
`.beads/issues.jsonl` to `origin/dev` automatically: flush DB → last-write-
wins merge vs origin's ledger (never drops an origin bead) → push a
`.beads/`-only commit via git plumbing → and, ONLY if the merge pulled in
foreign content, reconcile the local DB with a three-way
`br sync --merge --force`.

Manual operations:

1. Force a sync now (all beads repos, or name one):

   ```bash
   sh "$CLAUDE_PLUGIN_ROOT/hooks/beads-sync.sh" 2>/dev/null || sh ~/dev/beads/hooks/beads-sync.sh
   sh "$CLAUDE_PLUGIN_ROOT/hooks/beads-sync.sh" taher-core 2>/dev/null || sh ~/dev/beads/hooks/beads-sync.sh taher-core
   ```

2. Preview without changing anything: add `--dry-run`.

3. Debug a quiet SessionEnd run: `tail -20 ~/.claude/beads-orc-sync.log`
   (PUSH/IMPORT/SKIP/RETRY/ABORT/FAIL lines, one per repo per run).

Notes:
- The push is a ledger-data commit on `dev`. NEVER push main.
- The local `dev` BRANCH ref is not moved by the sync (it pushes a plumbing
  commit to origin). To bring a checked-out dev current:
  `git pull --ff-only origin dev`. If the pull refuses because
  `.beads/issues.jsonl` is locally modified, that's the flushed copy of what
  the sync already pushed — confirm with
  `git fetch origin dev && git diff origin/dev -- .beads/issues.jsonl`
  (expect empty) and discard it: `git checkout -- .beads/issues.jsonl`.
- A repo is skipped (logged) when it has no `origin/dev` — run beads-orc:init
  fully (it pushes dev) to make a repo syncable.
