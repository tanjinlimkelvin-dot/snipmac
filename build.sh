#!/bin/zsh
# Build SnipMac.app and install it into /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SnipMac.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework Cocoa -framework ScreenCaptureKit -framework Carbon -framework ServiceManagement -framework Vision \
  Sources/main.swift -o "$APP/Contents/MacOS/SnipMac"

swift make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.jinlim.snipmac</string>
  <key>CFBundleName</key><string>SnipMac</string>
  <key>CFBundleDisplayName</key><string>SnipMac</string>
  <key>CFBundleExecutable</key><string>SnipMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>SnipMac needs screen recording access to take screenshots.</string>
</dict>
</plist>
PLIST

# Sign with the stable local certificate so Screen Recording permission survives rebuilds
IDENTITY=$(security find-identity -p codesigning | awk '/"SnipMac Local Signing"/ {print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" --identifier com.jinlim.snipmac "$APP"

pkill -x SnipMac 2>/dev/null || true
rm -rf /Applications/SnipMac.app
cp -R "$APP" /Applications/
echo "Installed /Applications/SnipMac.app"
