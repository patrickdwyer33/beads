#!/bin/sh
# setup.sh — one-command install of the Dwyer Lab Claude Code dev toolchain.
#
# Two parts:
#   1) br (the beads binary) — DOWNLOADED from the upstream GitHub release for
#      YOUR platform and checksum-verified. Pinned to the version the team runs
#      so everyone coordinates on the same beads. Not bundled in this zip.
#   2) the coordination layer — bd + hooks + the settings.json .hooks block,
#      via the canonical install.sh.
#
#   ./setup.sh            # install / update
#   ./setup.sh --dry-run  # preview only, touch nothing
#
# Prereqs: macOS or Linux, `jq` (brew install jq), `curl`, `tar`, and
# ~/.local/bin on your PATH.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Pinned so a coworker's br matches the rest of the team. Bump when the team does.
BR_VERSION="0.2.15"
REPO="Dicklesworthstone/beads_rust"

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# ── 1) br ───────────────────────────────────────────────────────────────────
install_br() {
  if command -v br >/dev/null 2>&1 && br --version 2>/dev/null | grep -q "$BR_VERSION"; then
    note "br $BR_VERSION already installed at $(command -v br)"; return 0
  fi

  # Map uname → the release asset naming (darwin/linux × arm64/amd64).
  os=$(uname -s); arch=$(uname -m)
  case "$os" in
    Darwin) plat=darwin ;;
    Linux)  plat=linux ;;
    *) say "ERROR: unsupported OS '$os' — install br manually from https://github.com/$REPO/releases"; return 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) cpu=arm64 ;;
    x86_64|amd64)  cpu=amd64 ;;
    *) say "ERROR: unsupported arch '$arch' — install br manually from https://github.com/$REPO/releases"; return 1 ;;
  esac

  asset="br-${BR_VERSION}-${plat}_${cpu}.tar.gz"
  base="https://github.com/$REPO/releases/download/v${BR_VERSION}"

  if [ "$DRY" = 1 ]; then note "would download $asset, verify sha256, install br → $BIN/br"; return 0; fi
  for tool in curl tar shasum; do
    command -v "$tool" >/dev/null 2>&1 || { say "ERROR: '$tool' is required to fetch br"; return 1; }
  done

  tmp=$(mktemp -d) || { say "ERROR: mktemp failed"; return 1; }
  note "downloading $asset"
  if ! curl -fsSL "$base/$asset" -o "$tmp/$asset" || ! curl -fsSL "$base/$asset.sha256" -o "$tmp/$asset.sha256"; then
    say "ERROR: download failed (network? wrong version?). Get it from https://github.com/$REPO/releases"; rm -rf "$tmp"; return 1
  fi

  got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
  want=$(awk '{print $1}' "$tmp/$asset.sha256")
  if [ -z "$want" ] || [ "$got" != "$want" ]; then
    say "ERROR: checksum mismatch for $asset — refusing to install."; note "want=$want"; note "got =$got"; rm -rf "$tmp"; return 1
  fi
  note "checksum ok"

  tar -xzf "$tmp/$asset" -C "$tmp" || { say "ERROR: extract failed"; rm -rf "$tmp"; return 1; }
  br_bin=$(find "$tmp" -type f -name br | head -1)
  if [ -z "$br_bin" ]; then say "ERROR: 'br' not found in $asset"; rm -rf "$tmp"; return 1; fi

  mkdir -p "$BIN"
  cp "$br_bin" "$BIN/br" && chmod +x "$BIN/br" && note "installed  $BIN/br ($BR_VERSION)"
  rm -rf "$tmp"
}

say "Dwyer Lab CC toolchain setup"
install_br || say "WARN: br install did not complete — bd wraps it and needs it. See message above."

# ── 2) coordination layer: bd, hooks, settings.json .hooks ──────────────────
sh "$HERE/install.sh" "$@"

printf '\nDone. Make sure %s is on your PATH, then RESTART your Claude Code session\n' "$BIN"
printf 'so the SessionStart hooks load. Verify with:  br --version  &&  bd --help\n'
