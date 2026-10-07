#!/bin/zsh
# Builds, notarizes and publishes an ImageSmith release. Installed copies pick it
# up through Sparkle (daily check, or Check for Updates… in the menu).
#
#   Scripts/release.sh 1.1.0 [--draft] [--skip-tests]
#
# 1. Checks: clean tree on main, in sync with origin, tests green (unless --skip-tests).
# 2. Builds the app with the version (build number = commit count).
# 3. Scripts/developer-id.sh signs it with Developer ID and uploads it to Apple's notary
#    service, using the Apple ID signed in to Xcode (Settings ▸ Accounts). No certificate
#    in the keychain, API key or app-specific password is needed.
# 4. Waits for notarization, exports the stapled app, and checks Gatekeeper accepts it.
# 5. Makes the update zip and a DMG for first installs, signs the zip with the Sparkle key
#    (login keychain, account "imagesmith"), adds the release to appcast.xml, publishes a
#    GitHub Release with both files, and pushes appcast.xml — which is what makes it live.
set -euo pipefail

VERSION="${1:?usage: Scripts/release.sh <version> [--draft] [--skip-tests]}"
shift
DRAFT=0; SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    *) echo "Unknown option $arg"; exit 2 ;;
  esac
done
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3"; exit 2; }

ROOT="${0:A:h:h}"
cd "$ROOT"
REPO=newtro/ImageSmith
TEAM=232A77467G
BUNDLE_ID=com.scottsmith.imagesmith
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OUT="$ROOT/.dist/release/$VERSION"
TAG="v$VERSION"

step() { print -P "%B==> $1%b" }

# 1. Checks
step "Checking the repository"
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash changes first."; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main isn't in sync with origin."; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG already exists."; exit 1; fi
if (( ! DRAFT )); then
  [[ "$(gh repo view $REPO --json visibility -q .visibility)" == PUBLIC ]] || {
    echo "$REPO is private, so installed copies can't download updates. Use --draft, or make it public."; exit 1; }
fi
if (( ! SKIP_TESTS )); then
  step "Running tests"
  swift test >/dev/null 2>&1 || { echo "Tests failed; run swift test to see why."; exit 1; }
fi
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle's tools are missing; run swift build once."; exit 1; }
BUILD_NUMBER="$(git rev-list --count HEAD)"

# 2. Build and archive
step "Building $VERSION ($BUILD_NUMBER)"
rm -rf "$OUT"; mkdir -p "$OUT"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" Scripts/build-app.sh >"$OUT/build.log" 2>&1 \
  || { tail -20 "$OUT/build.log"; exit 1; }
ARCHIVE="$OUT/ImageSmith.xcarchive"

# 3. Sign with Developer ID and upload to the notary service
step "Uploading to Apple for notarization"
Scripts/developer-id.sh "$ROOT/.dist/ImageSmith.app" "$OUT" upload

# 4. Wait for notarization (a first submission can take an hour or more; usually minutes).
step "Waiting for notarization"
for attempt in {1..180}; do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" \
       >"$OUT/notarize.log" 2>&1; then
    break
  fi
  grep -q "processing" "$OUT/notarize.log" || { tail -20 "$OUT/notarize.log"; echo "Notarization failed."; exit 1; }
  (( attempt % 5 == 0 )) && echo "   still processing ($(( attempt )) min)"
  sleep 60
done
APP="$OUT/notarized/ImageSmith.app"
[[ -d "$APP" ]] || { echo "Notarization didn't finish within 3 hours; rerun later."; exit 1; }
spctl -a -t exec "$APP" || { echo "Gatekeeper rejected the app."; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "The notarization ticket isn't stapled."; exit 1; }

# 5. Package, sign the update, publish
step "Packaging"
ZIP="$OUT/ImageSmith-$VERSION.zip"
DMG="$OUT/ImageSmith-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir -p "$OUT/dmg"; ditto "$APP" "$OUT/dmg/ImageSmith.app"; ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "ImageSmith $VERSION" -srcfolder "$OUT/dmg" -format UDZO "$DMG"

step "Signing the update and adding it to appcast.xml"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account imagesmith "$ZIP")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
python3 Scripts/appcast.py appcast.xml \
  --version "$VERSION" --build "$BUILD_NUMBER" --min-os "$MIN_OS" \
  --url "https://github.com/$REPO/releases/download/$TAG/ImageSmith-$VERSION.zip" \
  --signature "$SIGNATURE" --notes "https://github.com/$REPO/releases/tag/$TAG"

step "Publishing $TAG"
git tag -a "$TAG" -m "ImageSmith $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPO" --title "ImageSmith $VERSION" \
  --notes "Download ImageSmith-$VERSION.dmg for a first install. Installed copies update themselves." \
  $( (( DRAFT )) && echo --draft )
if (( ! DRAFT )); then
  git add appcast.xml
  git commit -qm "Release $VERSION

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  git push -q origin main
fi
# Leave only the zip and DMG: extra bundle copies with this bundle ID confuse
# LaunchServices and TCC about which ImageSmith holds the Screen Recording grant.
rm -rf "$ARCHIVE" "$OUT/upload" "$OUT/notarized" "$OUT/dmg" "$ROOT/.dist/ImageSmith.app"
step "Released ImageSmith $VERSION ($BUILD_NUMBER)$( (( DRAFT )) && echo ' as a draft; appcast.xml not published' )"
