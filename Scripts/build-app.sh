#!/bin/bash
# Builds ImageSmith.app from the Swift package, embeds Sparkle and signs it.
#   VERSION=1.2.0 Scripts/build-app.sh      # Scripts/release.sh sets VERSION
# CFBundleVersion is the commit count, which Sparkle compares between releases.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="ImageSmith"
BUNDLE_ID="com.scottsmith.imagesmith"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
FEED_URL="https://raw.githubusercontent.com/newtro/ImageSmith/main/appcast.xml"
SPARKLE_PUBLIC_KEY="xk7w/R/7FgOg8zem9yYBlGXnT/DKE0IbC2eub9tPwV4="
DIST="$ROOT/.dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --disable-sandbox
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

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
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
# Inside-out: Sparkle's helpers, the framework, then the app. Release builds
# are re-signed with Developer ID and notarized by Scripts/release.sh.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"; }
for xpc in "$SPARKLE"/XPCServices/*.xpc; do sign "$xpc"; done
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier "$BUNDLE_ID" "$APP"

echo "✓ Built $APP ($VERSION, build $BUILD_NUMBER)"
