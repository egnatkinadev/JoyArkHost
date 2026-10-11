#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
swift build "$@" --configuration release --product RoomPlayHost
TASK_BIN="$(swift build "$@" --configuration release --show-bin-path)"
TASK_APP="$TASK_ROOT/build/JoyArk Host.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN/RoomPlayHost" "$TASK_APP/Contents/MacOS/RoomPlayHost"
# Remove local compiler/debug paths from the assembled release executable.
strip -S "$TASK_APP/Contents/MacOS/RoomPlayHost"
TASK_ICONS="$TASK_ROOT/build/JoyArk.iconset"
mkdir -p "$TASK_ICONS"
for TASK_SIZE in 16 32 128 256 512; do
    sips -z "$TASK_SIZE" "$TASK_SIZE" "$TASK_ROOT/docs/icon.png" --out "$TASK_ICONS/icon_${TASK_SIZE}x${TASK_SIZE}.png" >/dev/null
    TASK_RETINA=$((TASK_SIZE * 2))
    sips -z "$TASK_RETINA" "$TASK_RETINA" "$TASK_ROOT/docs/icon.png" --out "$TASK_ICONS/icon_${TASK_SIZE}x${TASK_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$TASK_ICONS" -o "$TASK_APP/Contents/Resources/JoyArk.icns"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.roomplay.host</string>
    <key>CFBundleName</key><string>JoyArk Host</string>
    <key>CFBundleDisplayName</key><string>JoyArk Host</string>
    <key>CFBundleExecutable</key><string>RoomPlayHost</string>
    <key>CFBundleIconFile</key><string>JoyArk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>JoyArk Host accepts an encrypted connection from your iPhone on the same local network to stream your selected display and receive game controls.</string>
    <key>NSBonjourServices</key><array><string>_roomplay._tcp</string><string>_roomplay-pair._tcp</string></array>
    <key>NSAudioCaptureUsageDescription</key><string>Share the sound of games running on this Mac with your connected iPhone.</string>
</dict>
</plist>
PLIST
plutil -lint "$TASK_APP/Contents/Info.plist"
codesign --force --deep --sign - "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
printf 'Built: %s\n' "$TASK_APP"
