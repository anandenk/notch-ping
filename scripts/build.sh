#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$TASK_ROOT/dist/Notch Ping.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/NotchPing" "$APP_DIR/Contents/MacOS/NotchPing"
cp "$BIN_DIR/notch-relay" "$APP_DIR/Contents/MacOS/notch-relay"
cp "$TASK_ROOT/ThirdParty/Lucide/LICENSE" "$APP_DIR/Contents/Resources/Lucide-LICENSE.txt"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>NotchPing</string>
    <key>CFBundleIdentifier</key><string>local.notch-ping.app</string>
    <key>CFBundleName</key><string>Notch Ping</string>
    <key>CFBundleDisplayName</key><string>Notch Ping</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR/Contents/MacOS/notch-relay"
codesign --force --sign - "$APP_DIR"
printf '\nBuilt: %s\n' "$APP_DIR"
