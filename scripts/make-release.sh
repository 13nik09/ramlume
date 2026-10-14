#!/bin/bash
# Builds RamLume for release and packages it for GitHub Releases.
#
#   scripts/make-release.sh
#       Universal build, ad-hoc signed and NOT notarized. Other people's Macs will ask them to
#       confirm the first launch (see "Installation" in README.md).
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=ramlume \
#     scripts/make-release.sh
#       Signs with your Developer ID (hardened runtime, secure timestamp), notarizes with
#       notarytool, staples the ticket, and checks the result with Gatekeeper.
#       Set up the notary profile once with `xcrun notarytool store-credentials` (docs/building.md).
#
# Output: dist/RamLume-<version>-macOS.zip and a .sha256 file next to it.
set -euo pipefail

cd "$(dirname "$0")/.."
DERIVED=build/Release
APP="$DERIVED/Build/Products/Release/RamLume.app"
BIN="$APP/Contents/MacOS/RamLume"
LOG=build/release-build.log

fail() { echo "error: $*" >&2; exit 1; }

mkdir -p build dist

echo "==> Building universal Release"
# Coverage instrumentation is switched off explicitly: a scheme-level coverage setting would
# otherwise instrument Release builds too, and an instrumented app writes .profraw files.
if ! xcodebuild -project RamLume.xcodeproj -scheme RamLume -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    ONLY_ACTIVE_ARCH=NO CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO \
    clean build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20 >&2 || true
  fail "build failed; see $LOG"
fi
grep -E " warning:" "$LOG" | grep -v -i appintents | sort -u || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
echo "    RamLume $VERSION ($BUILD), $BUNDLE_ID"

echo "==> Checking the build"
ARCHS=$(lipo -archs "$BIN")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "not a universal binary (found: $ARCHS)"
if nm -m "$BIN" | grep -q "llvm_profile"; then fail "the binary contains coverage instrumentation"; fi
if strings "$BIN" | grep -qE "RAMLUME-DEBUG|HOVERLAB|UISTRESS"; then fail "the binary contains debug-only code"; fi
"$BIN" --dump-metrics >/dev/null || fail "the built app's metrics report failed"
echo "    universal ($ARCHS), no instrumentation or debug code, metrics report runs"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with \"$SIGN_IDENTITY\""
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP" || fail "code signature verification failed"

ZIP="dist/RamLume-$VERSION-macOS.zip"
rm -f "$ZIP" "$ZIP.sha256"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || fail "NOTARY_PROFILE needs SIGN_IDENTITY (a Developer ID Application identity)"
  echo "==> Notarizing (this usually takes a few minutes)"
  ditto -c -k --keepParent "$APP" "$ZIP"
  OUTPUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$OUTPUT"
  echo "$OUTPUT" | grep -q "status: Accepted" \
    || fail "notarization wasn't accepted; see the log with: xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -vv "$APP"
  rm -f "$ZIP"
  STATUS="Developer ID signed and notarized"
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
  STATUS="Developer ID signed, NOT notarized"
else
  STATUS="ad-hoc signed, NOT notarized"
fi

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" >"$(basename "$ZIP").sha256")
echo "    $ZIP ($STATUS)"
echo "    SHA-256: $(cut -d ' ' -f 1 "$ZIP.sha256")"
