#!/usr/bin/env bash
# release.sh — build, sign, (optionally notarize), and publish a Kates release,
# updating the Sparkle appcast.
#
# Usage:
#   ./scripts/release.sh v0.2.0
#
# Signing & notarization (optional but recommended for a Gatekeeper-friendly
# download). If a "Developer ID Application" certificate is in your keychain it
# is used automatically; otherwise the build is ad-hoc signed (users must
# right-click → Open). To notarize, set up a keychain profile once:
#   xcrun notarytool store-credentials "KatesNotarization" \
#     --apple-id "you@example.com" --team-id "ABCDE12345" \
#     --password "app-specific-password"
# then run with NOTARY_PROFILE=KatesNotarization.
#
# Update signing always uses Sparkle's Ed25519 key from your login keychain
# (created once with Sparkle's generate_keys; public half is in Info.plist).
set -euo pipefail

VERSION="${1:?Usage: $0 <version tag>  e.g. $0 v0.2.0}"
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must match vMAJOR.MINOR.PATCH (got: $VERSION)"
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="thejefflarson/kates"
APP="$ROOT/Kates.app"
SHORT_VERSION="${VERSION#v}"

# ── Preconditions ─────────────────────────────────────────────────────────────

for cmd in swift git gh ditto codesign; do
    command -v "$cmd" &>/dev/null || { echo "error: $cmd not found"; exit 1; }
done

BRANCH=$(git symbolic-ref --short HEAD)
[[ "$BRANCH" == "main" ]] || { echo "error: release from main (on: $BRANCH)"; exit 1; }
git status --porcelain | grep -q . && { echo "error: working tree is dirty"; exit 1; }
git tag --list | grep -qxF "$VERSION" && { echo "error: tag $VERSION exists"; exit 1; }

git fetch origin main --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
    echo "error: local main is not in sync with origin/main"; exit 1; }

SIGN_UPDATE=$(find "$ROOT/.build/artifacts" -path "*Sparkle/bin/sign_update" 2>/dev/null | head -1)
[[ -n "$SIGN_UPDATE" ]] || { echo "error: sign_update not found — run 'swift build' first"; exit 1; }

# Monotonic build number for Sparkle version comparison: count of prior tags + 1.
BUILD_NUMBER=$(( $(git tag --list 'v*' | wc -l | tr -d ' ') + 1 ))

# ── Signing identity ──────────────────────────────────────────────────────────

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="Developer ID Application"
else
    IDENTITY="-"
    echo "warning: no Developer ID certificate found — building ad-hoc signed."
    echo "         The downloaded app will be Gatekeeper-blocked (right-click → Open)."
fi

# ── Test, build, sign ─────────────────────────────────────────────────────────

echo "→ running tests"
swift test --quiet --disable-sandbox

echo "→ building Kates.app $SHORT_VERSION (build $BUILD_NUMBER)"
MARKETING_VERSION="$SHORT_VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    CODESIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/bundle.sh" release

# ── Package ───────────────────────────────────────────────────────────────────

WORK=$(mktemp -d /tmp/kates-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/Kates-$VERSION.zip"
echo "→ zipping app"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── Notarize (optional) ───────────────────────────────────────────────────────

if [[ "$IDENTITY" != "-" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "→ notarizing (~2 min)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "→ stapling"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
else
    echo "→ skipping notarization (set NOTARY_PROFILE and use a Developer ID to enable)"
fi

# ── Sign the update for Sparkle ───────────────────────────────────────────────

echo "→ signing update"
SIG_OUTPUT=$("$SIGN_UPDATE" "$ZIP")
ED_SIG=$(printf '%s' "$SIG_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
[[ ${#ED_SIG} -ge 80 ]] || { echo "error: sign_update produced no/invalid signature"; exit 1; }
LENGTH=$(stat -f%z "$ZIP")
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$(basename "$ZIP")"
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

# ── Append to appcast ─────────────────────────────────────────────────────────

echo "→ updating appcast.xml"
python3 - "$ROOT/appcast.xml" "$SHORT_VERSION" "$BUILD_NUMBER" "$DOWNLOAD_URL" \
          "$ED_SIG" "$LENGTH" "$PUB_DATE" "$MIN_OS" <<'PY'
import sys, xml.etree.ElementTree as ET
appcast, version, build, url, sig, length, pub_date, min_os = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for p, u in ns.items(): ET.register_namespace(p, u)
tree = ET.parse(appcast); channel = tree.getroot().find("channel")
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Kates {version}"
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, f"{{{ns['sparkle']}}}version").text = build
ET.SubElement(item, f"{{{ns['sparkle']}}}shortVersionString").text = version
if min_os:
    ET.SubElement(item, f"{{{ns['sparkle']}}}minimumSystemVersion").text = min_os
ET.SubElement(item, "enclosure", {
    "url": url, f"{{{ns['sparkle']}}}edSignature": sig,
    "length": length, "type": "application/octet-stream"})
ET.indent(tree, space="  ")
tree.write(appcast, xml_declaration=True, encoding="utf-8")
PY

git add appcast.xml
git commit -q -m "appcast: add $VERSION"

# ── Tag, push, publish ────────────────────────────────────────────────────────

echo "→ tagging and pushing"
git tag "$VERSION"
git push --atomic origin main "$VERSION"

echo "→ creating GitHub release"
gh release create "$VERSION" "$ZIP" --repo "$REPO" --title "Kates $VERSION" --generate-notes

echo "→ verifying $DOWNLOAD_URL"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -L "$DOWNLOAD_URL" || echo 000)
[[ "$CODE" == "200" ]] || { echo "error: enclosure URL returned HTTP $CODE (publish the release)"; exit 1; }

echo "done — Kates $VERSION released"
