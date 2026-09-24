#!/bin/zsh
# Builds "Account Switcher.app" as a universal (Apple Silicon + Intel) binary.
#
#   ./build.sh                 build and install into ~/Applications (ad-hoc signed)
#   OUT_DIR=dist ./build.sh    build into another folder
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh   sign for distribution
set -e
cd "$(dirname "$0")"

OUT_DIR="${OUT_DIR:-$HOME/Applications}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(cat VERSION)"
APP="$OUT_DIR/Account Switcher.app"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" main.swift Onboarding.swift -o "$BUILD/AccountSwitcher-$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD"/AccountSwitcher-* -output "$APP/Contents/MacOS/AccountSwitcher"
[[ -f assets/AppIcon.icns ]] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Account Switcher</string>
  <key>CFBundleDisplayName</key><string>Account Switcher</string>
  <key>CFBundleIdentifier</key><string>io.berk.account-switcher</string>
  <key>CFBundleExecutable</key><string>AccountSwitcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
P

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP" 2>/dev/null
else
  # Hardened runtime + secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION)"
