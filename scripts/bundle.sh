#!/usr/bin/env bash
# Builds Kates and assembles a double-clickable Kates.app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/Kates.app"
BUNDLE_ID="com.kates.app"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG" --disable-sandbox
BIN="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/Kates"

echo "==> Rendering icon…"
swift scripts/make_icon.swift "$ROOT/icon_1024.png"

echo "==> Building AppIcon.icns…"
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  px="${spec% *}"; label="${spec#* }"
  sips -z "$px" "$px" "$ROOT/icon_1024.png" --out "$ICONSET/icon_${label}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns"

echo "==> Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kates"
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kates</string>
    <key>CFBundleDisplayName</key><string>Kates</string>
    <key>CFBundleExecutable</key><string>Kates</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Refresh icon cache for this bundle.
touch "$APP"
echo "==> Done: $APP"
