# beads-orc

Claude Code plugin that orchestrates [beads](https://github.com/Dicklesworthstone/beads_rust)
(`br`) issue tracking across repos under `~/dev`. Adapted from the Dwyer Lab
toolchain (vendored pristine under `upstream/`).

## Model

- **Per-repo backlogs.** Each beads-inited repo has `.beads/beads.db` (live
  SQLite, gitignored, shared by every session on the machine) +
  `.beads/issues.jsonl` (git-tracked ledger). Opt in with the `beads-orc:init`
  skill. Repos live under `~/dev` directly or one group level down
  (`~/dev/<group>/<repo>`); group folders are never beads-inited; repo
  basenames stay unique across groups.
- **Convention:** a beads-inited repo's directory name == its bead id prefix.
  Ids are hash-suffixed (`taher-core-<slug>-<hash>`, e.g.
  `taher-core-project-scope-8cda`) — never sequential. `bd` routing depends
  only on the prefix.
- **Plugin releases:** this repo's `main` is the released plugin (the
  marketplace installs it); development happens on `dev` and lands on `main`
  only via PR.
- **Claim before you work:** `bd update <id> --claim` is atomic and shared
  machine-wide. Pick only from `bd ready`.
- **Branch policy (beads-inited repos):** feature worktree → review the
  diff with a fresh subagent → `dev` → a human promotes to `main` (prod).
  Agents never push or merge main. Enforcement: agent sessions run as a
  dedicated GitHub machine account (identity + audit); server rulesets
  apply on public/Pro repos (init skill sets them); documentation
  elsewhere. There is deliberately no command-parsing gate.
- **Automated ledger sync:** a SessionEnd hook syncs every beads-inited
  repo's ledger to `origin/dev` — LWW merge vs origin (never drops an
  origin bead), `.beads/`-only plumbing commit, and a three-way
  `br sync --merge --force` DB reconcile ONLY when the merge pulled in
  foreign content (skip-import guard). Log: `~/.claude/beads-orc-sync.log`.

## Layout

| Path | What |
|---|---|
| `.claude-plugin/plugin.json` | plugin manifest |
| `hooks/hooks.json` | additive hook registration (never touches user settings) |
| `hooks/*.sh` | digest, worktree link/create/remove, cmux label, ledger sync (SessionEnd) |
| `tests/` | sandboxed behavior suite for the sync (`sh tests/test-beads-sync.sh`) |
| `bin/bd` | dispatch wrapper around `br` (routing + session-distinct actor) |
| `scripts/install-br.sh` | pinned, checksum-verified `br` installer |
| `skills/` | setup, init, create, start, finish, status, sync |
| `upstream/` | pristine Dwyer Lab originals (reference for plans 2-3) |
