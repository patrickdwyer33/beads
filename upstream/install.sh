#!/bin/sh
# install.sh — lay down the Claude Code dev toolchain (bd + hooks + the settings
# hooks block) on a Mac so every dev machine shares one coordinated setup.
# Idempotent: safe to re-run after `git pull`. Touches ONLY the toolchain — never
# the per-machine state under ~/.claude (sessions, history, caches, beads DBs).
#
#   workstation/install.sh            # install / update
#   workstation/install.sh --dry-run  # print what would change, touch nothing
#
# Source of truth: this dir (devops/workstation). Bootstrap a new machine with:
#   git -C ~/dev/devops pull && ~/dev/devops/workstation/install.sh
#
# NOTE: `br` (the beads binary) is a per-machine install, NOT shipped here (10MB
# compiled arm64). If it's missing this prints where to get it.

set -u
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
HOOKS="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

install_file() { # src dst
  src=$1; dst=$2
  if [ "$DRY" = 1 ]; then
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then note "unchanged  $dst"
    else note "would write $dst"; fi
    return
  fi
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then note "unchanged  $dst"; return; fi
  mkdir -p "$(dirname "$dst")" || return 1
  cp "$src" "$dst" && chmod +x "$dst" && note "installed  $dst"
}

mode=""; [ "$DRY" = 1 ] && mode="DRY-RUN — "
say "CC dev toolchain installer — ${mode}source: $HERE"

# 1) bd + the hook scripts
install_file "$HERE/bin/bd" "$BIN/bd"
for f in "$HERE"/hooks/*.sh; do
  [ -e "$f" ] || continue            # POSIX glob doesn't null out on no-match
  install_file "$f" "$HOOKS/$(basename "$f")"
done

# 2) settings.json — set ONLY the .hooks key from the canonical block, leaving
#    permissions / theme / every other key untouched. Backup taken (and the file
#    written) ONLY when the result actually differs, so re-runs are true no-ops.
HOOKS_JSON="$HERE/settings.hooks.json"
if ! command -v jq >/dev/null 2>&1; then
  say "WARN: jq not found — skipped settings.json hooks merge."
  note "Install jq (brew install jq) and re-run, or merge $HOOKS_JSON's .hooks into $SETTINGS by hand."
elif [ "$DRY" = 1 ]; then
  note "would set .hooks in $SETTINGS from settings.hooks.json"
else
  tmp=$(mktemp) || { say "ERROR: mktemp failed"; exit 1; }
  trap 'rm -f "$tmp"' EXIT
  if [ -f "$SETTINGS" ]; then
    merge='.hooks = $h[0].hooks'
    base="$SETTINGS"
  else
    merge='{hooks: $h[0].hooks}'
    base="/dev/null"; mkdir -p "$(dirname "$SETTINGS")"
  fi
  # Build the candidate, then refuse to write anything that isn't valid JSON with
  # a non-null .hooks (guards a malformed existing file or a shape change in the
  # canonical block from silently disabling all hooks).
  if jq --slurpfile h "$HOOKS_JSON" "$merge" "$base" > "$tmp" 2>/dev/null \
     && jq -e '(.hooks != null) and (.hooks | length > 0)' "$tmp" >/dev/null 2>&1; then
    if [ -f "$SETTINGS" ] && cmp -s "$tmp" "$SETTINGS"; then
      note ".hooks already current in $SETTINGS"
    else
      [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-workstation-$(date +%s)"
      mv "$tmp" "$SETTINGS" && note "wrote .hooks in $SETTINGS (backup kept if pre-existing)"
      trap - EXIT
    fi
  else
    say "ERROR: jq merge produced invalid/empty .hooks — $SETTINGS left unchanged."
  fi
fi

# 3) br presence check (per-machine binary)
if command -v br >/dev/null 2>&1; then
  note "br present: $(command -v br)"
else
  say "WARN: br (beads) not on PATH — bd wraps it and will fail without it."
  note "Install the br binary into $BIN (see https://github.com/Dicklesworthstone/beads_rust releases) and ensure $BIN is on PATH."
fi

# 4) PATH sanity for bd
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "WARN: $BIN is not on your PATH — add it in your shell profile so bd/br resolve." ;;
esac

say "done."
