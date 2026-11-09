#!/bin/zsh
# Builds eWheel.app and packages it as a .dmg.
#   ./Scripts/build.sh          → dist/eWheel.dmg
#   ./Scripts/build.sh test     → also runs the conversion self-test first
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.2.0}"   # bump this for each release
NAME="eWheel"
EXE="eWheel"
BUNDLE_ID="com.echoro.ewheel"
DIST="dist"
APP="$DIST/$NAME.app"
DMG="$DIST/$NAME.dmg"   # fixed name, so "latest" download links always work

echo "▸ Compiling (release)"
swift build -c release --arch arm64
BIN=".build/arm64-apple-macosx/release/$EXE"
[[ -f "$BIN" ]] || BIN=".build/release/$EXE"

if [[ "${1:-}" == "test" ]]; then
  echo "▸ Self-test"
  TESTDIR=$(mktemp -d)
  "$BIN" --selftest "$TESTDIR"
  rm -rf "$TESTDIR"
fi

echo "▸ Assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"

echo "▸ Icon"
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift Scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  [[ $s != 512 ]] && sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Free and open source under the MIT licence.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "▸ Packaging $DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
