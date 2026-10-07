#!/bin/bash
# Builds MacGameHub.app (release) into ./build and optionally copies it to /Applications.
#   ./scripts/build-app.sh            → build/MacGameHub.app
#   ./scripts/build-app.sh --install  → also copies to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="MacGameHub"
BUNDLE_ID="id.vickyir.macgamehub"
VERSION="0.1.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift tidak ditemukan. Pasang Xcode atau jalankan: xcode-select --install" >&2
  exit 1
fi

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

echo "==> Menyusun $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Borrow the GPTK icon for the app if the engine is already installed.
ICON_SRC="$HOME/Library/Application Support/MacGameHub/Engines/Game Porting Toolkit.app/Contents/Resources/gptk.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

echo "==> Ad-hoc codesign"
codesign --force --deep -s - "$APP"

if [ "${1:-}" = "--install" ]; then
  echo "==> Menyalin ke /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "Selesai: /Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
else
  echo "Selesai: $APP"
  open "$APP"
fi
