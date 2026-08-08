#!/bin/bash
# Build YeelightLibra and bundle it into a .app with an Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="YeelightLibra"
swift build -c release
BIN=".build/release/$APP_NAME"
APP="$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>YeelightLibra</string>
    <key>CFBundleDisplayName</key>
    <string>Yeelight Libra</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.yeelightlibra</string>
    <key>CFBundleExecutable</key>
    <string>YeelightLibra</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Built $APP"
