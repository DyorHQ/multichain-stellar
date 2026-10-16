#!/bin/zsh
# Archive the internal DyorHQ app (DyorHQInternal.xcodeproj: the app with the Stellar network) and upload it to
# TestFlight for the INTERNAL group only. The export sets testFlightInternalTestingOnly, so App Store Connect never lets
# this build reach external testers or the App Store, whose builds come from scripts/testflight.sh (no Stellar code).
#
# Needs what scripts/testflight.sh needs (DEVELOPMENT_TEAM in DyorHQ/Config/Secrets.xcconfig, the fun.dyorhq.app record,
# an App Store Connect API key or Xcode signed in to the account), plus the build number App Store Connect expects next:
#
#   BUILD=<n> Internal/testflight-internal.sh                  # from app/ios, with the Xcode account
#   BUILD=<n> ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… Internal/testflight-internal.sh
#   BUILD=<n> NO_UPLOAD=1 Internal/testflight-internal.sh      # archive and check only
#
# The build number is set on the generated Internal/Info.plist for this archive only (project.yml stays build 24, as the
# App Store build-23 check requires) and put back afterwards. The archive's Lite API must be the hosted one.
set -euo pipefail
set +x # never trace: the security gate below holds secret values in variables
cd "$(dirname "$0")/.."

[[ -n "${BUILD:-}" && "$BUILD" == <-> ]] || { echo "Set BUILD=<n>: the next build number App Store Connect expects for fun.dyorhq.app" >&2; exit 1; }
[[ -f DyorHQ/Config/Secrets.xcconfig ]] || { echo "DyorHQ/Config/Secrets.xcconfig is missing in this checkout (copy the app's own, git-ignored)" >&2; exit 1; }
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' DyorHQ/Config/Secrets.xcconfig | tr -d ' ')
if [[ -z "$TEAM" ]]; then echo "DEVELOPMENT_TEAM is not set in DyorHQ/Config/Secrets.xcconfig" >&2; exit 1; fi
if grep -q "127.0.0.1" DyorHQ/Config/Secrets.xcconfig; then echo "Secrets.xcconfig points at a local fork; restore the mainnet RPC first" >&2; exit 1; fi
# The same release gates as scripts/testflight.sh: the Monad side of this app is the App Store app's.
python3 ../scripts/dev/check-launchpad-addresses.py --release || { echo "The release gate failed (above); nothing was built." >&2; exit 1; }
RELEASE_TESTS='AppStringsTests|PerpsWalletStringsTests|MomentsStringsTests|DyorKitStringsTests|TradeStringsTests|ShippedLanguagesTests|V2WiringTests'
PINS=$(mktemp "${TMPDIR:-/tmp}/dyorkit-pins.XXXXXX")
cp DyorKit/Package.resolved "$PINS"
GATE=0
(cd DyorKit && DYORHQ_RELEASE_GATE=1 swift test --filter "$RELEASE_TESTS") || GATE=$?
cp "$PINS" DyorKit/Package.resolved && rm -f "$PINS"
(( GATE == 0 )) || { echo "The strings and v2 wiring tests failed under DYORHQ_RELEASE_GATE=1 (above); nothing was built." >&2; exit 1; }

python3 -I Internal/generate.py >/dev/null
restore_plists() { git checkout -- Internal/Info.plist Internal/Info-Debug.plist DyorKit/Package.resolved 2>/dev/null || true; }
trap restore_plists EXIT
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Internal/Info.plist)
for plist in Internal/Info.plist Internal/Info-Debug.plist; do /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist"; done
echo "DyorHQ internal $VERSION ($BUILD) · team $TEAM"

ARCHIVE=build/DyorHQInternal-$VERSION-$BUILD.xcarchive
rm -rf "$ARCHIVE"
xcodebuild -project DyorHQInternal.xcodeproj -scheme DyorHQ -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath DerivedDataInternalDevice \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

APP="$ARCHIVE/Products/Applications/DyorHQ.app"
[[ -d "$APP" ]] || { echo "Archive has no app bundle at $APP" >&2; exit 1; }
# The internal app talks to the hosted Lite API, never a local stack, and carries the build number asked for.
API=$(/usr/libexec/PlistBuddy -c 'Print :LITE_API_URL' "$APP/Info.plist" 2>/dev/null || true)
[[ "$API" == https://*.supabase.co/functions/v1/lite ]] || { echo "The archive's LITE_API_URL is '$API', not the hosted Lite API; nothing was uploaded." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")" == "$BUILD" ]] || { echo "The archive's build number isn't $BUILD; nothing was uploaded." >&2; exit 1; }
echo "Lite API: $API ✓"

# SECURITY GATE, as in scripts/testflight.sh: nothing secret may ship. Values are never printed.
PUBLIC_VARS=(DEVELOPMENT_TEAM DYOR_SLASH PRIVY_APP_ID PRIVY_CLIENT_ID PASSKEY_RP_ID PERPL_BUILDER_ID SOCIAL_LOGINS_ENABLED
  PASSKEYS_ENABLED LAUNCHPAD_FACTORY LAUNCH_ROUTER FEE_ESCROW HOLDER_FEE_SHARING MEME_HOOK AURORA_FEE_RECIPIENT
  MOMENTS_FACTORY MOMENTS_COLLECT MOMENTS_VESTING MOMENTS_GRADUATION MOMENTS_LOCKER MOMENTS_HOOK MOMENTS_BUYBACK
  MOMENTS_PLATFORM MOMENTS_TREASURY MOMENTS_DEPLOY_BLOCK)
LEAKS=()
while IFS= read -r line; do
  name=${line%%=*}; name=${name%%\[*}; name=${name//[[:space:]]/}
  (( ${PUBLIC_VARS[(Ie)$name]} )) && continue
  value=$(printf '%s' "$line" | sed -e 's/^[A-Za-z_][A-Za-z0-9_]*\(\[[^]]*\]\)*[[:space:]]*=//' -e 's:[[:space:]]//.*$::' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\$(DYOR_SLASH)/\//g')
  (( ${#value} >= 8 )) || continue
  if grep -rqF -f <(print -r -- "$value") "$APP"; then LEAKS+=("$name"); fi
done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])*[[:space:]]*=' DyorHQ/Config/Secrets.xcconfig)
if grep -rqE 'alchemy\.com/v2/[A-Za-z0-9_-]|infura\.io/v3/[0-9a-f]|quiknode\.pro/[0-9a-f]' "$APP"; then LEAKS+=("keyed RPC provider URL"); fi
# Stellar secret seeds (S… StrKeys) never ship either.
if grep -rqE 'S[A-Z2-7]{55}' "$APP" --include='*.plist' --include='*.json' --include='*.strings'; then LEAKS+=("a Stellar secret-key-shaped string"); fi
SCANNER=../scripts/dev/secret-scan.sh
[[ -f "$SCANNER" ]] || SCANNER=$HOME/Hackathon/scripts/dev/secret-scan.sh
if [[ ! -f "$SCANNER" ]]; then LEAKS+=("(secret-scan.sh missing — cannot check the .env values)")
elif ! env -u SECRET_SCAN_ENV -u SECRET_SCAN_XCCONFIG -u BASH_ENV -u SHELLOPTS /bin/bash "$SCANNER" --path "$ARCHIVE" >&2; then
  LEAKS+=(".env / Secrets.xcconfig values or key patterns listed above by secret-scan")
fi
if (( ${#LEAKS[@]} )); then
  echo "REFUSING TO UPLOAD — the archive contains secret values from: ${LEAKS[*]}" >&2
  exit 1
fi
echo "Security gate: no secrets found in the archive ✓"
[[ -z "${NO_UPLOAD:-}" ]] || { echo "NO_UPLOAD set: archive at $ARCHIVE, not uploaded."; exit 0; }

OPTIONS=build/ExportOptions-internal-$BUILD.plist
sed "s/TEAM_ID/$TEAM/" ExportOptions.plist > "$OPTIONS"
/usr/libexec/PlistBuddy -c "Add :testFlightInternalTestingOnly bool true" "$OPTIONS"
AUTH=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "build/export-internal-$BUILD" \
  -allowProvisioningUpdates "${AUTH[@]}" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload"
echo "Uploaded for INTERNAL testing only. After processing (a few minutes) it appears under TestFlight in App Store"
echo "Connect: answer the export compliance question (standard encryption only) and add it to the internal group."
