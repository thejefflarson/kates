#!/usr/bin/env bash
# Builds Kates and assembles a double-clickable Kates.app bundle, with the
# Sparkle framework embedded for auto-updates.
#
# Version can be overridden for releases:
#   MARKETING_VERSION=0.2.0 BUILD_NUMBER=3 ./scripts/bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/Kates.app"
BUNDLE_ID="com.kates.app"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SU_FEED_URL="https://raw.githubusercontent.com/thejefflarson/kates/main/appcast.xml"
SU_PUBLIC_ED_KEY="zBk/+O7F6ZvuCdEM7p7FQ3VHdkOFkRbJhMbZGRjqP3U="

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Kates"
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Embedding Sparkle.framework…"
SPARKLE_FW=$(find "$ROOT/.build/artifacts" \
    -path "*Sparkle.xcframework/macos-*/Sparkle.framework" -type d 2>/dev/null | head -1)
if [[ -z "$SPARKLE_FW" ]]; then
    echo "error: Sparkle.framework not found under .build/artifacts (build first)"
    exit 1
fi
# -R preserves the framework's internal symlinks (Versions/Current, etc.).
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
# The executable links @rpath/Sparkle.framework/…; point that rpath at the
# embedded copy. Skip if swift build already added it.
if ! otool -l "$APP/Contents/MacOS/Kates" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Kates"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kates</string>
    <key>CFBundleDisplayName</key><string>Kates</string>
    <key>CFBundleExecutable</key><string>Kates</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Code-sign last: modifying the binary (install_name_tool) and embedding the
# framework invalidates swift build's signature, and macOS SIGKILLs an
# invalidly-signed, framework-loading bundle. Ad-hoc by default so it runs
# locally; release.sh re-signs with a Developer ID for distribution.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Code signing (${IDENTITY})…"
if [[ "$IDENTITY" == "-" ]]; then
    # Ad-hoc: a single deep signature is enough to launch locally.
    codesign --force --deep --sign - "$APP"
else
    # Developer ID: --deep is unreliable for a framework with nested helpers
    # (Apple discourages it), and a distributable signature needs a secure
    # timestamp + the hardened runtime. Sparkle bundles an Autoupdate binary,
    # an Updater.app, and two XPC services, each of which is independent code —
    # sign them inside-out, deepest first, then the framework, then the app.
    SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    V="$FW/Versions/Current"
    "${SIGN[@]}" "$V/XPCServices/Downloader.xpc"
    "${SIGN[@]}" "$V/XPCServices/Installer.xpc"
    "${SIGN[@]}" "$V/Autoupdate"
    "${SIGN[@]}" "$V/Updater.app"
    "${SIGN[@]}" "$FW"
    "${SIGN[@]}" "$APP/Contents/MacOS/Kates"
    "${SIGN[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "    signature OK"

touch "$APP"
echo "==> Done: $APP ($MARKETING_VERSION build $BUILD_NUMBER)"
