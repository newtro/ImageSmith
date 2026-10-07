#!/bin/zsh
# Builds, notarizes and publishes an ImageSmith release. Installed copies pick it
# up through Sparkle (daily check, or Check for Updates… in the menu).
#
#   Scripts/release.sh 1.1.0 [--draft] [--skip-tests]
#
# 1. Checks: clean tree on main, in sync with origin, tests green (unless --skip-tests).
#    The release is pinned to that commit and built from a separate worktree, so edits
#    made in this checkout while it runs can't ship.
# 2. Builds the app with the version (build number = commit count, which must exceed
#    every build already in appcast.xml).
# 3. Scripts/developer-id.sh signs it with Developer ID and uploads it to Apple's notary
#    service, using the Apple ID signed in to Xcode (Settings ▸ Accounts). No certificate
#    in the keychain, API key or app-specific password is needed.
# 4. Waits for notarization, exports the stapled app, and checks Gatekeeper accepts it.
# 5. Makes the update zip and a DMG for first installs, signs the zip with the Sparkle key
#    (login keychain, account "imagesmith"), publishes a GitHub Release tagged at the
#    pinned commit, then commits appcast.xml alone and pushes it — which makes it live.
#    --draft publishes a draft release and leaves the feed untouched.
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
OUT="$ROOT/.dist/release/$VERSION"
SRC="$OUT/src"
TAG="v$VERSION"

step() { print -P "%B==> $1%b" }
cleanup() {
  # Leave only the zip and DMG: extra bundle copies with this bundle ID confuse
  # LaunchServices and TCC about which ImageSmith holds the Screen Recording grant.
  rm -rf "$OUT/ImageSmith.xcarchive" "$OUT/upload" "$OUT/notarized" "$OUT/dmg"
  [[ -d "$SRC" ]] && git -C "$ROOT" worktree remove --force "$SRC" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Checks
step "Checking the repository"
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash changes first."; exit 1; }
git fetch -q origin
SHA="$(git rev-parse HEAD)"
[[ "$SHA" == "$(git rev-parse origin/main)" ]] || { echo "main isn't in sync with origin."; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "$TAG" >/dev/null; then
  echo "$TAG already exists."; exit 1
fi
if (( ! DRAFT )); then
  [[ "$(gh repo view $REPO --json visibility -q .visibility)" == PUBLIC ]] || {
    echo "$REPO is private, so installed copies can't download updates. Use --draft, or make it public."; exit 1; }
fi
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle's tools are missing; run swift build once."; exit 1; }
BUILD_NUMBER="$(git rev-list --count "$SHA")"
python3 Scripts/appcast.py appcast.xml --check-build "$BUILD_NUMBER"

rm -rf "$OUT"; mkdir -p "$OUT"
git worktree prune
git worktree add -q --detach "$SRC" "$SHA"
if (( ! SKIP_TESTS )); then
  step "Running tests"
  (cd "$SRC" && swift test >"$OUT/test.log" 2>&1) || { tail -20 "$OUT/test.log"; echo "Tests failed."; exit 1; }
fi

# 2. Build
step "Building $VERSION ($BUILD_NUMBER) from ${SHA:0:7}"
(cd "$SRC" && VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" Scripts/build-app.sh >"$OUT/build.log" 2>&1) \
  || { tail -20 "$OUT/build.log"; exit 1; }

# 3. Sign with Developer ID and upload to the notary service
step "Uploading to Apple for notarization"
"$SRC/Scripts/developer-id.sh" "$SRC/.dist/ImageSmith.app" "$OUT" upload
ARCHIVE="$OUT/ImageSmith.xcarchive"

# 4. Wait for notarization (a first submission can take an hour or more; usually minutes).
#    Xcode fails the export while Apple is still processing; only a rejection stops early.
step "Waiting for notarization"
for attempt in {1..180}; do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" \
       >"$OUT/notarize.log" 2>&1; then
    break
  fi
  if grep -qiE "invalid|rejected|not (be )?notarized" "$OUT/notarize.log"; then
    tail -20 "$OUT/notarize.log"; echo "Notarization failed."; exit 1
  fi
  (( attempt % 5 == 0 )) && echo "   still processing ($attempt min)"
  sleep 60
done
APP="$OUT/notarized/ImageSmith.app"
[[ -d "$APP" ]] || { tail -20 "$OUT/notarize.log"; echo "Notarization didn't finish within 3 hours."; exit 1; }
spctl -a -t exec "$APP" || { echo "Gatekeeper rejected the app."; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "The notarization ticket isn't stapled."; exit 1; }

# 5. Package, sign the update, publish
step "Packaging"
ZIP="$OUT/ImageSmith-$VERSION.zip"
DMG="$OUT/ImageSmith-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir -p "$OUT/dmg"; ditto "$APP" "$OUT/dmg/ImageSmith.app"; ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "ImageSmith $VERSION" -srcfolder "$OUT/dmg" -format UDZO "$DMG"

step "Signing the update"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account imagesmith "$ZIP")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
# A draft's download URL isn't public yet, so its entry never touches the live feed.
FEED="appcast.xml"; (( DRAFT )) && { cp appcast.xml "$OUT/appcast.xml"; FEED="$OUT/appcast.xml"; }
python3 Scripts/appcast.py "$FEED" \
  --version "$VERSION" --build "$BUILD_NUMBER" --min-os "$MIN_OS" \
  --url "https://github.com/$REPO/releases/download/$TAG/ImageSmith-$VERSION.zip" \
  --signature "$SIGNATURE" --notes "https://github.com/$REPO/releases/tag/$TAG"
(( DRAFT )) || trap 'git -C "$ROOT" checkout -- appcast.xml; cleanup' EXIT

step "Publishing $TAG"
# gh creates the tag at the pinned commit, so nothing is tagged if the upload fails.
gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPO" --target "$SHA" --title "ImageSmith $VERSION" \
  --notes "Download ImageSmith-$VERSION.dmg for a first install. Installed copies update themselves." \
  $( (( DRAFT )) && echo --draft )
git fetch -q origin --tags
if (( DRAFT )); then
  step "Released ImageSmith $VERSION ($BUILD_NUMBER) as a draft; the feed entry is in $FEED"
  exit 0
fi
[[ "$(git rev-parse HEAD)" == "$SHA" ]] || {
  echo "main moved during the release; the GitHub release is out but the feed isn't."
  echo "Add the entry yourself:"; git diff appcast.xml; exit 1; }
git commit -q -m "Release $VERSION

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- appcast.xml
git push -q origin HEAD:main
trap cleanup EXIT
step "Released ImageSmith $VERSION ($BUILD_NUMBER)"
