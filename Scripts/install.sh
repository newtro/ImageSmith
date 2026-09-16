#!/bin/bash
# Builds and installs ImageSmith into /Applications, restarting it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/build-app.sh" release

echo "▸ Installing to /Applications…"
pkill -x ImageSmith 2>/dev/null || true
sleep 0.5
rm -rf /Applications/ImageSmith.app
cp -R "$ROOT/.dist/ImageSmith.app" /Applications/

# Only one copy of the bundle may be registered, or TCC matches the wrong one.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$ROOT/.dist/ImageSmith.app" 2>/dev/null || true
rm -rf "$ROOT/.dist"
"$LSREG" -f /Applications/ImageSmith.app

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "ImageSmith Dev"; then
  echo "▸ Clearing the stale Screen Recording grant (ad-hoc build changed the code hash)…"
  tccutil reset ScreenCapture com.scottsmith.imagesmith >/dev/null 2>&1 || true
fi

open /Applications/ImageSmith.app
echo "✓ ImageSmith is running. Look for the camera icon in the menu bar."
