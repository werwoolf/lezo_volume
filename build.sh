#!/bin/bash
# Збирає VolumeControl.app із VolumeControl.swift.
# Запуск:  chmod +x build.sh && ./build.sh
set -e

APP="VolumeControl"
BUNDLE="$APP.app"
SRC="VolumeControl.swift"

cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ Не знайдено swiftc. Встанови Xcode Command Line Tools:"
  echo "   xcode-select --install"
  exit 1
fi

echo "⚙️  Компіляція…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

swiftc -O "$SRC" -o "$BUNDLE/Contents/MacOS/$APP" \
  -framework Cocoa \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -framework Carbon

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>VolumeControl</string>
  <key>CFBundleDisplayName</key>     <string>VolumeControl</string>
  <key>CFBundleIdentifier</key>      <string>local.volumecontrol</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>VolumeControl</string>
  <key>LSUIElement</key>            <true/>
  <key>LSMinimumSystemVersion</key>  <string>12.0</string>
</dict>
</plist>
PLIST

echo "✅ Готово: $(pwd)/$BUNDLE"
echo "   Запусти:  open \"$BUNDLE\""
