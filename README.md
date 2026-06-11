# beads-orc

Claude Code plugin that orchestrates [beads](https://github.com/Dicklesworthstone/beads_rust)
(`br`) issue tracking across repos under `~/dev`. Adapted from the Dwyer Lab
toolchain (vendored pristine under `upstream/`).

## Model

- **Per-repo backlogs.** Each beads-inited repo has `.beads/beads.db` (live
  SQLite, gitignored, shared by every session on the machine) +
  `.beads/issues.jsonl` (git-tracked ledger). Opt in with the `beads-orc:init`
  skill.
- **Convention:** a beads-inited repo's directory name == its bead id prefix.
  Ids are hash-suffixed (`taher-core-<slug>-<hash>`, e.g.
  `taher-core-project-scope-8cda`) — never sequential. `bd` routing depends
  only on the prefix.
- **Plugin releases:** this repo's `main` is the released plugin (the
  marketplace installs it); development happens on `dev` and lands on `main`
  only via PR.
- **Claim before you work:** `bd update <id> --claim` is atomic and shared
  machine-wide. Pick only from `bd ready`.
- **Branch policy** (enforced by plan-2 review gate): feature worktree → `dev`
  (review-gated) → human promotes to `main` (prod). Agents never push `main`
  in beads-inited repos.

## Layout

| Path | What |
|---|---|
| `.claude-plugin/plugin.json` | plugin manifest |
| `hooks/hooks.json` | additive hook registration (never touches user settings) |
| `hooks/*.sh` | digest, worktree link/create/remove, cmux label |
| `bin/bd` | dispatch wrapper around `br` (routing + session-distinct actor) |
| `scripts/install-br.sh` | pinned, checksum-verified `br` installer |
| `skills/` | setup, init, create, start, finish, status, sync |
| `upstream/` | pristine Dwyer Lab originals (reference for plans 2-3) |
