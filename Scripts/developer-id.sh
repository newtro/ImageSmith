#!/bin/zsh
# Re-signs a built ImageSmith.app with Developer ID through Xcode's cloud-managed
# certificate (the Apple ID in Xcode ▸ Settings ▸ Accounts), so no certificate has
# to live in the keychain. Releases and local installs then share one signature,
# which keeps the Screen Recording grant across updates.
#
#   Scripts/developer-id.sh <ImageSmith.app> <work dir> [export|upload]
#
# export: signs only, leaving <work dir>/export/ImageSmith.app.
# upload: also sends it to Apple's notary service (Scripts/release.sh waits for it).
set -euo pipefail
APP="${1:?usage: developer-id.sh <app> <work dir> [export|upload]}"
WORK="${2:?usage: developer-id.sh <app> <work dir> [export|upload]}"
DEST="${3:-export}"
TEAM=232A77467G
INFO="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"; }

ARCHIVE="$WORK/ImageSmith.xcarchive"
rm -rf "$ARCHIVE" "$WORK/$DEST"
mkdir -p "$ARCHIVE/Products/Applications"
ditto "$APP" "$ARCHIVE/Products/Applications/ImageSmith.app"
cat >"$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
  <key>ApplicationPath</key><string>Applications/ImageSmith.app</string>
  <key>CFBundleIdentifier</key><string>$(plist CFBundleIdentifier)</string>
  <key>CFBundleShortVersionString</key><string>$(plist CFBundleShortVersionString)</string>
  <key>CFBundleVersion</key><string>$(plist CFBundleVersion)</string>
  <key>Architectures</key><array><string>arm64</string></array>
  <key>Team</key><string>$TEAM</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
<key>Name</key><string>ImageSmith</string>
<key>SchemeName</key><string>ImageSmith</string>
</dict></plist>
PLIST
cat >"$WORK/ExportOptions-$DEST.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>$DEST</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/$DEST" \
  -exportOptionsPlist "$WORK/ExportOptions-$DEST.plist" -allowProvisioningUpdates >"$WORK/$DEST.log" 2>&1 \
  || { tail -20 "$WORK/$DEST.log" >&2; exit 1; }
