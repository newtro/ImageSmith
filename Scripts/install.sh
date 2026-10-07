#!/bin/bash
# Builds and installs ImageSmith into /Applications, restarting it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/build-app.sh" release

# Sign like a release so the Screen Recording grant carries over between local
# installs and Sparkle updates. Offline, the 'ImageSmith Dev' signature stays.
WORK="$ROOT/.dist/devid"
LOG="$ROOT/.dist/developer-id.log"
if "$ROOT/Scripts/developer-id.sh" "$ROOT/.dist/ImageSmith.app" "$WORK" export >"$LOG" 2>&1; then
  echo "▸ Signed with Developer ID"
  rm -rf "$ROOT/.dist/ImageSmith.app"
  mv "$WORK/export/ImageSmith.app" "$ROOT/.dist/ImageSmith.app"
else
  echo "▸ Developer ID signing failed (offline, or Xcode signed out?); keeping the local signature."
  echo "  Details: $LOG"
  echo "  macOS will ask for Screen Recording again when you next switch signatures."
fi
rm -rf "$WORK"

echo "▸ Installing to /Applications…"
pkill -x ImageSmith 2>/dev/null || true
sleep 0.5
rm -rf /Applications/ImageSmith.app
cp -R "$ROOT/.dist/ImageSmith.app" /Applications/

# Only one copy of the bundle may be registered, or TCC matches the wrong one.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$ROOT/.dist/ImageSmith.app" 2>/dev/null || true
rm -rf "$ROOT/.dist/ImageSmith.app"
"$LSREG" -f /Applications/ImageSmith.app

# Only an ad-hoc build changes the code hash on every rebuild; Developer ID and
# 'ImageSmith Dev' signatures keep the grant valid.
if codesign -dvv /Applications/ImageSmith.app 2>&1 | grep -q "Signature=adhoc"; then
  echo "▸ Clearing the stale Screen Recording grant (ad-hoc build changed the code hash)…"
  tccutil reset ScreenCapture com.scottsmith.imagesmith >/dev/null 2>&1 || true
fi

open /Applications/ImageSmith.app
echo "✓ ImageSmith is running. Look for the camera icon in the menu bar."
