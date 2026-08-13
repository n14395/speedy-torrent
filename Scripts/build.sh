#!/bin/zsh
# Assemble SpeedyTorrent.app from the SwiftPM release build.
# Usage: Scripts/bundle.sh [output-dir]   (default: ./dist)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/SpeedyTorrent.app"
VERSION="0.1.0"

cd "$ROOT"
# Prefer full Xcode; fall back to CLT with the 26.5 SDK pinned (see test.sh).
for xcode in /Applications/Xcode.app /Applications/Xcode-beta.app; do
  if [[ -d $xcode/Contents/Developer ]]; then
    export DEVELOPER_DIR=$xcode/Contents/Developer
    break
  fi
done
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build -c release --product SpeedyTorrentApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$(swift build -c release --show-bin-path)/SpeedyTorrentApp" "$APP/Contents/MacOS/SpeedyTorrent"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SpeedyTorrent</string>
    <key>CFBundleDisplayName</key>
    <string>SpeedyTorrent</string>
    <key>CFBundleIdentifier</key>
    <string>dev.nwf.SpeedyTorrent</string>
    <key>CFBundleExecutable</key>
    <string>SpeedyTorrent</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Magnet Link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>magnet</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>BitTorrent Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.bittorrent.torrent</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.bittorrent.torrent</string>
            <key>UTTypeDescription</key>
            <string>BitTorrent Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>torrent</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/x-bittorrent</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

# Package a distributable .dmg alongside the .app (set SKIP_DMG=1 to skip).
if [[ "${SKIP_DMG:-0}" != "1" ]]; then
  DMG="$OUT/SpeedyTorrent-$VERSION.dmg"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT

  # ditto preserves the code signature and resource attributes; the
  # /Applications symlink gives the familiar drag-to-install layout.
  ditto "$APP" "$STAGE/SpeedyTorrent.app"
  ln -s /Applications "$STAGE/Applications"

  rm -f "$DMG"
  hdiutil create \
    -volname "SpeedyTorrent $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

  rm -rf "$STAGE"
  trap - EXIT
  echo "Built $DMG"
  echo
  echo "Note: the app is ad-hoc signed (not notarized). On first launch after"
  echo "downloading, macOS Gatekeeper will block it — right-click the app and"
  echo "choose Open, or run: xattr -dr com.apple.quarantine /Applications/SpeedyTorrent.app"
fi
