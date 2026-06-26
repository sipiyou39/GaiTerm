#!/usr/bin/env bash
#
# GaiTerm release & auto-update publisher.
#
#   ./scripts/gaiterm-release.sh 1.0.1 ["release notes"]
#
# Builds the app, stamps the version, zips it, signs it with your Sparkle
# EdDSA key (from your Keychain), writes appcast.xml, and publishes both as a
# GitHub Release. Friends running an older GaiTerm then see the update in-app.
#
# Requirements: zig, gh (authenticated), Sparkle's sign_update (already on disk
# via Xcode's DerivedData).
set -euo pipefail

VERSION="${1:?usage: gaiterm-release.sh <version> [notes]}"
NOTES="${2:-GaiTerm $VERSION}"
APPCAST_NOTES="GaiTerm $VERSION est disponible. Les notes detaillees s'afficheront au premier lancement apres installation."
REPO="sipiyou39/GaiTerm"
# Stable self-signed code-signing identity. Gives every build the same code
# identity so macOS keeps a user's granted permissions (Full Disk Access, folder
# access) across updates instead of re-prompting. Created once in the login
# keychain; see GAITERM.md. Falls back to ad-hoc if it's missing on this machine.
SIGN_ID="GaiTerm Self-Signed"
TAG="v$VERSION"
BUILD="$(date +%Y%m%d%H%M)"           # monotonic build number for Sparkle
ZIP="GaiTerm-$VERSION.zip"
URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/macos/build/ReleaseLocal/GaiTerm.app"
OUT="$ROOT/build/release"

cd "$ROOT"

SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -ipath "*artifacts/sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "✗ sign_update not found (open the project in Xcode once)"; exit 1; }

echo "▸ Building GaiTerm…"
zig build -Doptimize=ReleaseFast >/dev/null
[ -d "$APP" ] || { echo "✗ build product missing: $APP"; exit 1; }

echo "▸ Stamping version $VERSION (build $BUILD)…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Sign last (after the Info.plist edits, which invalidate any prior signature).
# A stable identity is what lets a recipient grant Full Disk Access once and keep
# it across updates. Without the cert on this machine, fall back to ad-hoc.
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "▸ Signing with '$SIGN_ID'…"
  codesign --force --deep --sign "$SIGN_ID" "$APP" || { echo "✗ codesign failed"; exit 1; }
else
  echo "▸ '$SIGN_ID' not found — signing ad-hoc (permissions won't persist across updates)…"
  codesign --force --deep --sign - "$APP" || { echo "✗ codesign failed"; exit 1; }
fi

echo "▸ Zipping…"
mkdir -p "$OUT"
rm -f "$OUT/$ZIP"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP"
LENGTH="$(stat -f%z "$OUT/$ZIP")"

echo "▸ Signing (EdDSA)…"
# sign_update prints: sparkle:edSignature="…" length="…"
SIG_OUT="$("$SIGN_UPDATE" "$OUT/$ZIP")"
ED_SIG="$(echo "$SIG_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] || { echo "✗ failed to read signature from: $SIG_OUT"; exit 1; }

echo "▸ Writing appcast.xml…"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>GaiTerm</title>
    <item>
      <title>$VERSION</title>
      <description><![CDATA[$APPCAST_NOTES]]></description>
      <pubDate>$(date -R 2>/dev/null || date)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.1</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream"
                 sparkle:edSignature="$ED_SIG" length="$LENGTH" />
    </item>
  </channel>
</rss>
XML

echo "> Publishing GitHub release ${TAG}"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$OUT/$ZIP" "$OUT/appcast.xml" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$OUT/$ZIP" "$OUT/appcast.xml" \
    --repo "$REPO" --title "GaiTerm $VERSION" --notes "$NOTES"
fi

echo "✓ Released $VERSION → https://github.com/$REPO/releases/tag/$TAG"
echo "  Friends on an older build will see it via 'Check for Updates'."
