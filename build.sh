#!/bin/zsh
# Builds Tynda.app next to this script. Needs only the Xcode Command Line Tools (clang).
set -euo pipefail
cd "$(dirname "$0")"
APP=Tynda.app
VERSION="$(cat VERSION)"   # the one place the version lives
rm -rf Tynda.app   # start clean, so nothing from an older build rides along
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=14.0 \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework AVFoundation -framework ServiceManagement -framework QuartzCore \
  Sources/main.m -o "$APP/Contents/MacOS/Tynda"
cp dictate_server.py Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tynda</string>
  <key>CFBundleIdentifier</key><string>app.tynda.mac</string>
  <key>CFBundleExecutable</key><string>Tynda</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Tynda listens to your voice to type what you say.</string>
</dict>
</plist>
EOF
# Ad-hoc signature: enough to run on this Mac. macOS treats every rebuild as a new app,
# so permissions have to be granted again after each build.
codesign --force --sign - --identifier app.tynda.mac "$APP"
echo "Built $PWD/$APP"
