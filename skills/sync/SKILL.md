---
name: sync
description: Use when the user asks to sync/commit a beads ledger, or before switching machines, until plan-2 automated sync lands.
---

# Manual ledger sync (interim — plan 2 automates this)

Per beads-inited repo with changes:

1. Flush the live DB to the ledger: `br sync --flush-only` (run in the repo).
2. `git status .beads/` — if issues.jsonl changed, commit ONLY it on the
   `dev` branch: `git add .beads/issues.jsonl && git commit -m "chore(beads): update ledger"`.
3. Push dev. NEVER push main.
4. After pulling someone else's ledger changes: `br sync --import-only`.
