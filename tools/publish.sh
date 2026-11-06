#!/usr/bin/env bash
# Publishes (or updates) the experience on Roblox, fully headlessly.
#
# Auth: a ROBLOSECURITY-style cookie supplied either via the ROBLOSECURITY
# environment variable or a .cookies file (gitignored). The cookie is never
# echoed and never written to logs.
#
# First run CREATES a new place asset and prints its id; save that id in
# ROBLOX_PLACE_ID (or .placeid) so later runs update the same experience.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="$ROOT/tools/bin"
RBXMK="$BIN/rbxmk"
PLACE="${1:-build/ZombieUprising.rbxlx}"
COOKIES_FILE="$ROOT/.cookies"
PLACE_ID_FILE="$ROOT/.placeid"

if [[ ! -f "$PLACE" ]]; then
  echo "place file not found: $PLACE (run 'make build' first)" >&2
  exit 1
fi

# ---- Resolve cookie -------------------------------------------------
TMPCOOKIES=""
cleanup() { [[ -n "$TMPCOOKIES" && -f "$TMPCOOKIES" ]] && rm -f "$TMPCOOKIES"; }
trap cleanup EXIT

COOKIE_ARGS=()
if [[ -n "${ROBLOSECURITY:-}" ]]; then
  TMPCOOKIES="$(mktemp)"
  chmod 600 "$TMPCOOKIES"
  printf 'Set-Cookie: .ROBLOSECURITY=%s\n' "$ROBLOSECURITY" > "$TMPCOOKIES"
  COOKIE_ARGS=(--cookies-file "$TMPCOOKIES")
elif [[ -f "$COOKIES_FILE" ]]; then
  COOKIE_ARGS=(--cookies-file "$COOKIES_FILE")
else
  cat >&2 <<'EOM'
No Roblox credentials found.

Provide one of:
  1. export ROBLOSECURITY="<cookie>"     then re-run
  2. put the cookie in .cookies          in Set-Cookie header form:
       echo 'Set-Cookie: .ROBLOSECURITY=xxxx' > .cookies

How to obtain the cookie:
  Log into roblox.com in a browser, open devtools -> Application/Storage ->
  Cookies -> copy the value of .ROBLOSECURITY.

Security notes:
  - This is a full-account session credential. Treat it like a password.
  - .cookies is gitignored; never commit it.
  - Revoke it by logging out of all Roblox sessions after use.
EOM
  exit 2
fi

# ---- Upload ---------------------------------------------------------
PLACE_ID=""
if [[ -n "${ROBLOX_PLACE_ID:-}" ]]; then
  PLACE_ID="$ROBLOX_PLACE_ID"
elif [[ -f "$PLACE_ID_FILE" ]]; then
  PLACE_ID="$(tr -d '[:space:]' < "$PLACE_ID_FILE")"
fi

echo "Publishing $PLACE ..."

if [[ -n "$PLACE_ID" ]]; then
  echo "Updating existing place $PLACE_ID"
  OUT=$("$RBXMK" upload-asset "${COOKIE_ARGS[@]}" --id "$PLACE_ID" --format rbxlx "$PLACE" 2>&1) || {
    echo "$OUT" >&2
    echo "upload failed" >&2
    exit 3
  }
  echo "$OUT"
  echo "Updated place $PLACE_ID"
else
  echo "Creating new place asset..."
  OUT=$("$RBXMK" upload-asset "${COOKIE_ARGS[@]}" --format rbxlx "$PLACE" 2>&1) || {
    echo "$OUT" >&2
    echo "upload failed" >&2
    exit 3
  }
  echo "$OUT"
  # Attempt to capture the returned asset id so future runs update in place.
  NEW_ID="$(echo "$OUT" | grep -oE '[0-9]{6,}' | head -n1 || true)"
  if [[ -n "$NEW_ID" ]]; then
    echo "$NEW_ID" > "$PLACE_ID_FILE"
    echo "Saved new place id $NEW_ID to .placeid — future runs will update it."
  fi
fi

echo "Done."
