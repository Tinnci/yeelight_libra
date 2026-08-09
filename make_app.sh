#!/bin/bash
# Build YeelightLibra and bundle it into a .app with an Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="YeelightLibra"
swift build -c release
BIN=".build/release/$APP_NAME"
APP="$APP_NAME.app"
ICON_SOURCE="Assets/AppIcon.png"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Missing app icon source: $ICON_SOURCE" >&2
    exit 1
fi

iconset_root="$(mktemp -d /tmp/yeelight-libra-iconset.XXXXXX)"
iconset_dir="$iconset_root/AppIcon.iconset"
mkdir -p "$iconset_dir"
trap 'rm -rf "$iconset_root"' EXIT

for icon_size in 16 32 128 256 512; do
    double_size=$((icon_size * 2))
    sips -z "$icon_size" "$icon_size" "$ICON_SOURCE" \
        --out "$iconset_dir/icon_"$icon_size"x"$icon_size".png" >/dev/null
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" \
        --out "$iconset_dir/icon_"$icon_size"x"$icon_size"@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
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
