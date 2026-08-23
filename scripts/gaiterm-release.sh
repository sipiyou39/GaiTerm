#!/usr/bin/env bash
#
# Teddy CLI release & auto-update publisher.
#
#   ./scripts/gaiterm-release.sh 1.0.1 ["release notes"]
#
# Builds the app, stamps the version, signs it with Developer ID, notarizes and
# staples it, signs the archive with Sparkle's EdDSA key, writes appcast.xml,
# and publishes both artifacts as a GitHub Release.
#
# Requirements: zig, gh (authenticated), a Developer ID Application identity,
# a notarytool Keychain profile, and Sparkle's sign_update in DerivedData.
set -euo pipefail

VERSION="${1:?usage: gaiterm-release.sh <version> [notes]}"
NOTES="${2:-Teddy CLI $VERSION}"
APPCAST_NOTES="Teddy CLI $VERSION est disponible. Les notes detaillees s'afficheront au premier lancement apres installation."
REPO="sipiyou39/GaiTerm"
PUBLIC_REMOTE="${TEDDYCLI_PUBLIC_REMOTE:-gaiterm-public}"
NOTARY_PROFILE="${TEDDYCLI_NOTARY_PROFILE:-teddycli-notary}"
SIGN_ID="${TEDDYCLI_SIGN_ID:-Developer ID Application: younes boukobaa (JPC779B3N5)}"
EXPECTED_BUNDLE_ID="com.sipiyou.teddycli"
EXPECTED_PUBLIC_ED_KEY="XE4x4lbdwUmG/1EdTnS8u/uIbEnIVIlVA4jSo+dNdd0="
EXPECTED_TECHNICAL_NAME="TeddyCLI"
EXPECTED_DISPLAY_NAME="Teddy CLI"
TAG="v$VERSION"
BUILD="$(date +%Y%m%d%H%M)"           # monotonic build number for Sparkle
ZIP="TeddyCLI-$VERSION.zip"
URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/macos/build/ReleaseLocal/Teddy CLI.app"
ENTITLEMENTS="$ROOT/macos/GhosttyReleaseLocal.entitlements"
OUT="$ROOT/build/release"

cd "$ROOT"

CURRENT_BRANCH="$(git branch --show-current)"
[ "$CURRENT_BRANCH" = "main" ] || {
  echo "✗ releases must be published from main (current: $CURRENT_BRANCH)"
  exit 1
}

# Documentation instructions may be locally customized, but every product file
# in the archive must come from the pushed commit.
if ! git diff --quiet -- . \
  ':(exclude)AGENTS.md' \
  ':(exclude)macos/AGENTS.md'; then
  echo "✗ uncommitted product changes remain; commit and push them before releasing"
  exit 1
fi
if ! git diff --cached --quiet; then
  echo "✗ staged changes remain; commit and push them before releasing"
  exit 1
fi
UNTRACKED_PRODUCT_FILES="$(git ls-files --others --exclude-standard -- . \
  ':(exclude)AGENTS.md' \
  ':(exclude)macos/AGENTS.md')"
[ -z "$UNTRACKED_PRODUCT_FILES" ] || {
  echo "✗ untracked product files remain; commit them before releasing"
  echo "$UNTRACKED_PRODUCT_FILES"
  exit 1
}

REMOTE_URL="$(git remote get-url "$PUBLIC_REMOTE" 2>/dev/null || true)"
[ -n "$REMOTE_URL" ] || {
  echo "✗ public remote '$PUBLIC_REMOTE' is not configured"
  exit 1
}
case "$REMOTE_URL" in
  https://github.com/sipiyou39/GaiTerm.git|git@github.com:sipiyou39/GaiTerm.git) ;;
  *)
    echo "✗ '$PUBLIC_REMOTE' points to an unexpected repository: $REMOTE_URL"
    exit 1
    ;;
esac

git fetch "$PUBLIC_REMOTE" main --quiet
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse "$PUBLIC_REMOTE/main")"
[ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] || {
  echo "✗ local main is not identical to $PUBLIC_REMOTE/main"
  exit 1
}

SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -ipath "*artifacts/sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "✗ sign_update not found (open the project in Xcode once)"; exit 1; }

echo "▸ Building Teddy CLI…"
zig build -Doptimize=ReleaseFast -Dversion-string="$VERSION" >/dev/null
[ -d "$APP" ] || { echo "✗ build product missing: $APP"; exit 1; }

echo "▸ Stamping version $VERSION (build $BUILD)…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

read_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null
}

require_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(read_plist_value "$key")" || {
    echo "✗ missing required Info.plist key: $key"
    exit 1
  }
  if [ "$actual" != "$expected" ]; then
    echo "✗ invalid $key: expected '$expected', got '$actual'"
    exit 1
  fi
}

require_plist_value "CFBundleIdentifier" "$EXPECTED_BUNDLE_ID"
require_plist_value "SUPublicEDKey" "$EXPECTED_PUBLIC_ED_KEY"
require_plist_value "CFBundleName" "$EXPECTED_TECHNICAL_NAME"
require_plist_value "CFBundleDisplayName" "$EXPECTED_DISPLAY_NAME"
require_plist_value "LSHasLocalizedDisplayName" "true"

LOCALIZED_INFO_PLIST="$APP/Contents/Resources/en.lproj/InfoPlist.strings"
[ -f "$LOCALIZED_INFO_PLIST" ] || {
  echo "✗ missing localized product identity: $LOCALIZED_INFO_PLIST"
  exit 1
}
for key in CFBundleName CFBundleDisplayName; do
  actual="$(/usr/bin/plutil -extract "$key" raw -o - "$LOCALIZED_INFO_PLIST" 2>/dev/null)" || {
    echo "✗ missing localized $key"
    exit 1
  }
  if [ "$actual" != "$EXPECTED_DISPLAY_NAME" ]; then
    echo "✗ invalid localized $key: expected '$EXPECTED_DISPLAY_NAME', got '$actual'"
    exit 1
  fi
done

# Sign last because stamping Info.plist invalidates the build-time signature.
echo "▸ Signing with '$SIGN_ID'…"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP" || {
  echo "✗ codesign failed with required identity '$SIGN_ID'; release aborted"
  exit 1
}
codesign --verify --deep --strict --verbose=2 "$APP" || {
  echo "✗ signed bundle verification failed"
  exit 1
}
SIGN_DETAILS="$(codesign -dvv "$APP" 2>&1)"
grep -Fqx "Authority=$SIGN_ID" <<<"$SIGN_DETAILS" || {
  echo "✗ bundle was not signed by required identity '$SIGN_ID'"
  exit 1
}
grep -Eq '^CodeDirectory .* flags=.*runtime' <<<"$SIGN_DETAILS" || {
  echo "✗ hardened runtime is missing from the signed bundle"
  exit 1
}

echo "▸ Preparing notarization archive…"
mkdir -p "$OUT"
rm -f "$OUT/$ZIP"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP"

echo "▸ Notarizing with Keychain profile '$NOTARY_PROFILE'…"
xcrun notarytool submit "$OUT/$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" --wait || {
  echo "✗ notarization failed; configure the profile with notarytool store-credentials"
  exit 1
}

echo "▸ Stapling notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# The ticket is stapled to the app, so recreate the distributable archive.
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
    <title>Teddy CLI</title>
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
    --repo "$REPO" --title "Teddy CLI $VERSION" --notes "$NOTES"
fi

echo "✓ Released $VERSION → https://github.com/$REPO/releases/tag/$TAG"
echo "  Teddy CLI installations will see it via 'Check for Updates'."
