#!/bin/bash
# Builds ImageSmith.app from the Swift package and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="ImageSmith"
BUNDLE_ID="com.scottsmith.imagesmith"
VERSION="1.0.0"
DIST="$ROOT/.dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --disable-sandbox
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "▸ Rendering icon…"
  swift "$ROOT/Scripts/make-icon.swift" /tmp/$APP_NAME.iconset >/dev/null
  iconutil -c icns /tmp/$APP_NAME.iconset -o "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>ImageSmith</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key><array><string>imagesmith</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# A stable identity (see Scripts/create-signing-identity.sh) keeps the Screen
# Recording grant alive across rebuilds; ad-hoc signing does not.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ImageSmith Dev"; then
  IDENTITY="ImageSmith Dev"
  echo "▸ Signing with '$IDENTITY'…"
else
  echo "▸ Signing (ad-hoc) — macOS will ask for Screen Recording again after this build."
  echo "  Run Scripts/create-signing-identity.sh once to stop that happening."
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>/dev/null

echo "✓ Built $APP"
