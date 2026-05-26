#!/usr/bin/env bash
# Tools/scan_leak.sh — Task 12 (app.md §9 no-durable-plaintext, §11). The manual
# counterpart to the E2E's automated scratch-dir scan: after the GUI app has been
# force-killed mid-window (see E2E.md), sweep the real on-disk locations a
# standard-account leak could land in and assert a known plaintext SENTINEL is
# absent everywhere durable.
#
# Use a THROWAWAY sentinel during the test launch (type it into the notes, e.g.
# "LEAKPROBE-7f3a"), NOT your real admin/Canopy password — so this scan can search
# for it in cleartext without itself writing your real secret anywhere.
#
# Usage:  Tools/scan_leak.sh <SENTINEL>
#
# Exit 0 = sentinel not found in any durable location (PASS). Exit 1 = found
# (FAIL — a durable plaintext leak) or the sentinel was empty.

set -uo pipefail
SENTINEL="${1:-}"
if [ -z "$SENTINEL" ]; then
  echo "usage: Tools/scan_leak.sh <SENTINEL>" >&2
  exit 1
fi

APP_SUPPORT="$HOME/Library/Application Support/EncryptedVault"
BUNDLE_ID="app.encryptedvault"

# Durable locations a standard account can write, where decrypted notes could
# accidentally land (state restoration, autosave, caches, temp, crash reports).
LOCATIONS=(
  "$APP_SUPPORT"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  "$HOME/Library/Containers/$BUNDLE_ID"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME/Library/Application Support/CrashReporter"
  "$HOME/Library/Logs/DiagnosticReports"
  "${TMPDIR:-/tmp}"
)

echo "== Scanning for plaintext sentinel: '$SENTINEL' =="
found=0
for loc in "${LOCATIONS[@]}"; do
  [ -e "$loc" ] || { echo "  -- absent: $loc"; continue; }
  # -r recursive, -l list matching files, -a treat binary as text (sealed blobs
  # are binary; we want to catch plaintext that slipped into any of them).
  hits="$(grep -rla "$SENTINEL" "$loc" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "  !! LEAK in: $loc"
    echo "$hits" | sed 's/^/       /'
    found=1
  else
    echo "  ok: $loc"
  fi
done

# The vault blobs themselves MUST be sealed (sentinel must not appear in them).
if [ -d "$APP_SUPPORT" ]; then
  for f in "$APP_SUPPORT/vault.dat" "$APP_SUPPORT/vault.dat.bak"; do
    [ -f "$f" ] || continue
    if grep -qa "$SENTINEL" "$f" 2>/dev/null; then
      echo "  !! SENTINEL IN SEALED BLOB (should be impossible): $f"
      found=1
    fi
    mode="$(stat -f '%Lp' "$f" 2>/dev/null || echo '???')"
    [ "$mode" = "600" ] || echo "  WARN: $f mode is $mode (expected 600)"
  done
fi

echo
if [ "$found" -eq 0 ]; then
  echo "PASS — no durable plaintext sentinel found."
  exit 0
else
  echo "FAIL — durable plaintext leak detected (see above)."
  exit 1
fi
