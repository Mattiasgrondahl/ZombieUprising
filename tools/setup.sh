#!/usr/bin/env bash
# Vendors pinned Roblox CLI tooling for Linux/x86_64 into tools/bin.
# Everything here is reproducible and offline-friendly after first run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/tools/bin"
WORK="$ROOT/tools/.work"

ROJO_VERSION="7.4.0"
RBXMK_VERSION="0.9.1"
LUAU_VERSION="0.745"

mkdir -p "$BIN" "$WORK"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need curl
need unzip

fetch() { # url, out
  echo "  -> $1"
  curl -fsSL --retry 3 -o "$2" "$1"
}

install_rojo() {
  if [[ -x "$BIN/rojo" ]]; then echo "rojo: already installed"; return; fi
  echo "Installing rojo $ROJO_VERSION"
  fetch "https://github.com/rojo-rbx/rojo/releases/download/v${ROJO_VERSION}/rojo-${ROJO_VERSION}-linux-x86_64.zip" "$WORK/rojo.zip"
  unzip -oq "$WORK/rojo.zip" -d "$WORK"
  install -m 0755 "$WORK/rojo" "$BIN/rojo"
}

install_rbxmk() {
  if [[ -x "$BIN/rbxmk" ]]; then echo "rbxmk: already installed"; return; fi
  echo "Installing rbxmk $RBXMK_VERSION"
  fetch "https://github.com/Anaminus/rbxmk/releases/download/v${RBXMK_VERSION}/rbxmk-v${RBXMK_VERSION}-linux-amd64.zip" "$WORK/rbxmk.zip"
  unzip -oq "$WORK/rbxmk.zip" -d "$WORK"
  install -m 0755 "$WORK/rbxmk" "$BIN/rbxmk"
}

install_luau() {
  if [[ -x "$BIN/luau-analyze" && -x "$BIN/luau-compile" ]]; then echo "luau: already installed"; return; fi
  echo "Installing luau $LUAU_VERSION"
  fetch "https://github.com/luau-lang/luau/releases/download/${LUAU_VERSION}/luau-ubuntu.zip" "$WORK/luau.zip"
  unzip -oq "$WORK/luau.zip" -d "$WORK"
  # Upstream zip may or may not include the REPL binary; the analyzers always ship.
  for b in luau luau-analyze luau-compile luau-ast; do
    [[ -f "$WORK/$b" ]] && install -m 0755 "$WORK/$b" "$BIN/$b" || true
  done
}

install_rojo
install_rbxmk
install_luau

echo
echo "Installed into $BIN:"
ls -1 "$BIN"
echo
echo "Next: make lint && make build"
