#!/bin/zsh
# Cut a Barktor release: build, sign, package a drag-install DMG with its SHA-256
# sidecar, and publish a GitHub release whose notes are the CHANGELOG section
# for the version in Resources/Info.plist.
#
# This is the no-Apple-Developer-ID path: the app is signed with the local
# self-signed identity (default "Barktor Local Dev") and NOT notarized, so a
# first install needs right-click > Open. In-app updates are frictionless:
# the updater verifies the .sha256 sidecar (mandatory - it refuses to install
# without one) and strips quarantine after its codesign gate. Signing with
# the SAME identity every release is what keeps TCC permissions alive across
# updates; if you change identities, every user re-grants permissions once.
# For the notarized path use `make dmg` instead (needs DEV_ID + NOTARY_PROFILE).
#
# Usage: scripts/release.sh [--dry-run]
#   --dry-run  build and package, but skip tag + GitHub release
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

SIGN_ID=${SIGN_ID:-"Barktor Local Dev"}
# Pin gh to origin's repo: with an upstream remote configured, gh otherwise
# resolves ambiguously and can try to publish the release on the fork parent.
REPO_SLUG=$(git remote get-url origin | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')
APP=dist/Barktor.app
DMG=dist/Barktor.dmg
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ---------------------------------------------------------------- preflight
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty - commit or stash first" >&2; exit 1
fi
if ! grep -q "^## \[$VERSION\]" CHANGELOG.md; then
  echo "error: CHANGELOG.md has no '## [$VERSION]' section" >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists" >&2; exit 1
fi
if ! $DRY_RUN && ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated" >&2; exit 1
fi
if ! security find-identity -p codesigning -v | grep -q "$SIGN_ID"; then
  echo "error: signing identity '$SIGN_ID' not found in keychain" >&2; exit 1
fi

# ------------------------------------------------------------------- build
# CLT-only machines have no Xcode toolchain: build without FoundationModels
# macros (same branch `make test` takes). With Xcode present, build plain.
if [[ -d "${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" ]]; then
  swift build -c release --arch arm64
else
  env -u DEVELOPER_DIR swift build -c release --arch arm64 -Xswiftc -DNO_APPLE_FM
fi

# ---------------------------------------------------------------- assemble
# Mirrors the Makefile `app` target, signed with the local identity instead
# of Developer ID (no hardened runtime: library validation would reject the
# self-signed llama.framework).
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/arm64-apple-macosx/release/Barktor "$APP/Contents/MacOS/Barktor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/barktor_menubar_glyph.pdf "$APP/Contents/Resources/barktor_menubar_glyph.pdf"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"
cp -Rp .build/arm64-apple-macosx/release/llama.framework "$APP/Contents/Frameworks/llama.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Barktor" 2>/dev/null || true
find "$APP" -name "*.cstemp" -delete

codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign "$SIGN_ID" --entitlements Resources/Barktor.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# --------------------------------------------------------------------- dmg
# Same drag-install layout as the Makefile `dmg` target (pre-baked .DS_Store,
# background, volume icon), minus notarization/stapling.
STAGE=dist/dmg-stage MNT=dist/dmg-mnt RW=dist/Barktor-rw.dmg
rm -rf "$DMG" "$RW" "$STAGE" "$MNT"
mkdir -p "$STAGE/.background"
cp -Rp "$APP" "$STAGE/"
cp Resources/dmg-launch-window.tiff "$STAGE/.background/background.tiff"
cp Resources/dmg-DS_Store "$STAGE/.DS_Store"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Barktor" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
mkdir -p "$MNT"
hdiutil attach "$RW" -nobrowse -noverify -noautoopen -mountpoint "$MNT" >/dev/null
SetFile -a C "$MNT" 2>/dev/null || true  # custom volume icon; cosmetic if SetFile is missing
hdiutil detach "$MNT" >/dev/null
rmdir "$MNT"
hdiutil convert "$RW" -format ULFO -o "$DMG" >/dev/null
rm -rf "$RW" "$STAGE"

# Sidecar the in-app updater REQUIRES: it refuses to install a DMG without a
# verified SHA-256. Format matches `shasum -a 256` so it can be checked by hand.
shasum -a 256 "$DMG" | awk '{ printf "%s  Barktor.dmg\n", $1 }' > "$DMG.sha256"

# ------------------------------------------------------------------- notes
# Extract this version's CHANGELOG section (from its heading to the next one).
NOTES=dist/release-notes-$VERSION.md
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { on=1; next }
  on && /^## \[/ { exit }
  on { print }
' CHANGELOG.md > "$NOTES"

echo "Packaged $DMG ($(du -h "$DMG" | cut -f1)) + sidecar; notes in $NOTES"
if $DRY_RUN; then
  echo "dry run: skipping tag + GitHub release for $TAG"; exit 0
fi

# ----------------------------------------------------------------- publish
git tag -a "$TAG" -m "Barktor $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" \
  --repo "$REPO_SLUG" \
  --title "Barktor $VERSION" \
  --notes-file "$NOTES" \
  --latest
echo "Released $TAG"
