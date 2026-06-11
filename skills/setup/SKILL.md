---
name: setup
description: Use when setting up beads-orc on a machine for the first time, or when br/bd are missing from PATH. Installs the pinned br binary and links bd.
---

# beads-orc machine setup

One-time per machine. Idempotent — safe to re-run.

1. Install the pinned `br` binary (downloaded from the upstream release,
   SHA256-verified):

   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/install-br.sh" 2>/dev/null \
     || ~/dev/beads/scripts/install-br.sh
   ```

2. Link `bd` into ~/.local/bin:

   ```bash
   mkdir -p ~/.local/bin && ln -sf ~/dev/beads/bin/bd ~/.local/bin/bd
   ```

3. Verify PATH: `command -v br && command -v bd`. If either is missing,
   `~/.local/bin` is not on PATH — tell the user to add
   `export PATH="$HOME/.local/bin:$PATH"` to their shell profile. Do NOT
   edit their profile without asking.

4. Verify versions: `br --version` (expect 0.2.15) and
   `bd --help >/dev/null && echo bd-ok`.
