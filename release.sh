#!/bin/zsh
# Builds the distributable files into dist/:
#   AccountSwitcher.zip          used by the one-line terminal installer
#   AccountSwitcher-<ver>.dmg    drag-to-Applications disk image
#
# Signing uses the first "Developer ID Application" identity in your keychain (override with
# SIGN_IDENTITY). Notarization runs when NOTARY_PROFILE names a profile created once with:
#   xcrun notarytool store-credentials <profile> --apple-id <you@…> --team-id <TEAMID>
# Without it the files are signed but not notarized, and macOS warns on first open.
set -e
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
DIST="$PWD/dist"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN_IDENTITY" ]] || { echo "No Developer ID Application identity found. Set SIGN_IDENTITY."; exit 1; }

notarize() {
  [[ -n "$NOTARY_PROFILE" ]] || return 0
  echo "Notarizing $(basename "$1")…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

rm -rf "$DIST" && mkdir -p "$DIST"
echo "Signing as: $SIGN_IDENTITY"
OUT_DIR="$DIST" SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh
APP="$DIST/Account Switcher.app"
codesign --verify --strict --deep "$APP"

# Zip for the terminal installer. Notarize it, then staple the ticket to the app itself.
ZIP="$DIST/AccountSwitcher.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "$NOTARY_PROFILE" ]]; then
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi

# Disk image with an Applications shortcut to drag onto.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/AccountSwitcher-$VERSION.dmg"
hdiutil create -volname "Account Switcher" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
if [[ -n "$NOTARY_PROFILE" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

echo
[[ -n "$NOTARY_PROFILE" ]] && echo "Signed and notarized:" || echo "Signed, NOT notarized (set NOTARY_PROFILE):"
ls -lh "$ZIP" "$DMG" | awk '{print "  " $5 "  " $NF}'
