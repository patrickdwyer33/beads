#!/bin/sh
# install-br.sh — install the pinned beads binary (br) into ~/.local/bin,
# downloaded from the upstream GitHub release and SHA256-verified.
#   ./install-br.sh            # install / update
#   ./install-br.sh --dry-run  # preview only
set -u
BIN="$HOME/.local/bin"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

BR_VERSION="0.2.15"   # bump deliberately; re-run after editing
REPO="Dicklesworthstone/beads_rust"

# Pinned, known-good tarball hashes — trust-on-first-pin, updated together with
# BR_VERSION (Step 2 pins them). The co-located .sha256 alone proves nothing: an
# attacker who swaps the release asset swaps it too. Empty value = check skipped.
EXPECTED_SHA256_DARWIN_ARM64="4e32133f1eca2828be15e0fa84d3db456d5af6fd64cffab7385ed449b12b889c"
EXPECTED_SHA256_LINUX_AMD64=""

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

if command -v br >/dev/null 2>&1 && br --version 2>/dev/null | grep -q "$BR_VERSION"; then
  note "br $BR_VERSION already installed at $(command -v br)"; exit 0
fi

os=$(uname -s); arch=$(uname -m)
case "$os" in
  Darwin) plat=darwin ;;
  Linux)  plat=linux ;;
  *) say "ERROR: unsupported OS '$os'"; exit 1 ;;
esac
case "$arch" in
  arm64|aarch64) cpu=arm64 ;;
  x86_64|amd64)  cpu=amd64 ;;
  *) say "ERROR: unsupported arch '$arch'"; exit 1 ;;
esac

asset="br-${BR_VERSION}-${plat}_${cpu}.tar.gz"
base="https://github.com/$REPO/releases/download/v${BR_VERSION}"

if [ "$DRY" = 1 ]; then note "would download $asset, verify sha256, install br → $BIN/br"; exit 0; fi
for tool in curl tar shasum; do
  command -v "$tool" >/dev/null 2>&1 || { say "ERROR: '$tool' is required"; exit 1; }
done

tmp=$(mktemp -d) || exit 1
note "downloading $asset"
if ! curl -fsSL "$base/$asset" -o "$tmp/$asset" || ! curl -fsSL "$base/$asset.sha256" -o "$tmp/$asset.sha256"; then
  say "ERROR: download failed. Get it manually from https://github.com/$REPO/releases"; rm -rf "$tmp"; exit 1
fi
got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
want=$(awk '{print $1}' "$tmp/$asset.sha256")
if [ -z "$want" ] || [ "$got" != "$want" ]; then
  say "ERROR: checksum mismatch — refusing to install."; rm -rf "$tmp"; exit 1
fi
note "checksum ok"

case "${plat}_${cpu}" in
  darwin_arm64) pinned="$EXPECTED_SHA256_DARWIN_ARM64" ;;
  linux_amd64)  pinned="$EXPECTED_SHA256_LINUX_AMD64" ;;
  *)            pinned="" ;;
esac
if [ -n "$pinned" ] && [ "$got" != "$pinned" ]; then
  say "ERROR: tarball does not match the hash PINNED in this script — refusing to install."
  note "pinned=$pinned"; note "got   =$got"; rm -rf "$tmp"; exit 1
fi

tar -xzf "$tmp/$asset" -C "$tmp" || { say "ERROR: extract failed"; rm -rf "$tmp"; exit 1; }
br_bin=$(find "$tmp" -type f -name br | head -1)
[ -n "$br_bin" ] || { say "ERROR: 'br' not found in $asset"; rm -rf "$tmp"; exit 1; }
mkdir -p "$BIN"
cp "$br_bin" "$BIN/br" && chmod +x "$BIN/br" && note "installed  $BIN/br ($BR_VERSION)" \
  || { say "ERROR: install to $BIN failed"; rm -rf "$tmp"; exit 1; }
rm -rf "$tmp"
