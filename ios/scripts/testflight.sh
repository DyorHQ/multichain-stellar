#!/bin/zsh
# Archive DyorHQ for the App Store and upload the build to TestFlight from the command line.
#
# Needs: a paid Apple Developer Program membership, DEVELOPMENT_TEAM in DyorHQ/Config/Secrets.xcconfig, an app
# record for fun.dyorhq.app in App Store Connect, and either an App Store Connect API key (recommended, see below)
# or Xcode signed in to the account (Xcode → Settings → Accounts).
#
#   scripts/testflight.sh                 # archive + upload with the Xcode account
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/.private_keys/AuthKey_XXXX.p8 scripts/testflight.sh
#
# Create the API key at App Store Connect → Users and Access → Integrations → App Store Connect API (role: App
# Manager). The .p8 file downloads once; keep it outside the repo.
set -euo pipefail
set +x # never trace: the security gate below holds secret values in variables
cd "$(dirname "$0")/.."

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' DyorHQ/Config/Secrets.xcconfig | tr -d ' ')
if [[ -z "$TEAM" ]]; then echo "DEVELOPMENT_TEAM is not set in DyorHQ/Config/Secrets.xcconfig" >&2; exit 1; fi
if grep -q "127.0.0.1" DyorHQ/Config/Secrets.xcconfig; then echo "Secrets.xcconfig points at a local fork; restore the mainnet RPC first" >&2; exit 1; fi
# The v2 wiring gate, as in ci_scripts/ci_post_xcodebuild.sh: nothing ships while DyorKit's v2 addresses are PENDING or
# a retired Moments cohort is not final on chain (the archive's own build phase checks again).
python3 ../scripts/dev/check-launchpad-addresses.py --release || { echo "The release gate failed (above); nothing was built." >&2; exit 1; }
# Its Swift half and the strings gate, as in ci_scripts/ci_post_xcodebuild.sh: V2WiringTests refuses a pending v2 table,
# and the lanes' strings tests, which read the app's sources and String Catalogs, refuse a count whose English plural
# forms aren't in a catalog (a count of 1 would read "1 editions") where they would otherwise skip. They read this
# checkout only. swift test rewrites DyorKit/Package.resolved, so its pins are put back as they were.
RELEASE_TESTS='AppStringsTests|PerpsWalletStringsTests|MomentsStringsTests|DyorKitStringsTests|TradeStringsTests|ShippedLanguagesTests|V2WiringTests'
PINS=$(mktemp "${TMPDIR:-/tmp}/dyorkit-pins.XXXXXX")
cp DyorKit/Package.resolved "$PINS"
GATE=0
(cd DyorKit && DYORHQ_RELEASE_GATE=1 swift test --filter "$RELEASE_TESTS") || GATE=$?
cp "$PINS" DyorKit/Package.resolved && rm -f "$PINS"
(( GATE == 0 )) || { echo "The strings and v2 wiring tests failed under DYORHQ_RELEASE_GATE=1 (above); nothing was built." >&2; exit 1; }

# Bump the build number so every upload is unique — App Store Connect rejects a duplicate CFBundleVersion, which is
# the most common first-timer failure. Pin an exact number with BUILD=<n>; keep the current one with NO_BUMP=1.
VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
CURRENT_BUILD=$(sed -n 's/.*CFBundleVersion: "\(.*\)"/\1/p' project.yml)
if [[ -n "${BUILD:-}" ]]; then NEW_BUILD="$BUILD"
elif [[ -n "${NO_BUMP:-}" ]]; then NEW_BUILD="$CURRENT_BUILD"
else NEW_BUILD=$(( CURRENT_BUILD + 1 )); fi
if [[ "$NEW_BUILD" != "$CURRENT_BUILD" ]]; then
  sed -i '' "s/CFBundleVersion: \"$CURRENT_BUILD\"/CFBundleVersion: \"$NEW_BUILD\"/" project.yml
  echo "Build number: $CURRENT_BUILD → $NEW_BUILD (project.yml updated — commit it with the release)."
fi
BUILD="$NEW_BUILD"
echo "DyorHQ $VERSION ($BUILD) · team $TEAM"

xcodegen generate >/dev/null
ARCHIVE=build/DyorHQ-$VERSION-$BUILD.xcarchive
rm -rf "$ARCHIVE"
xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath DerivedDataDevice \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

# SECURITY GATE — nothing secret may ship. Everything in the app bundle is readable by anyone who has the IPA, so the
# archive is checked for (1) the value of every Secrets.xcconfig variable that is not a public identifier, (2) any
# keyed RPC-provider URL and (3) anywhere in the whole .xcarchive, every secret value from the repo's .env (every
# non-NEXT_PUBLIC_, non-address value) and Secrets.xcconfig plus private-key patterns, via scripts/dev/secret-scan.sh.
# A hit stops the release before anything is uploaded. Values are never printed.
APP="$ARCHIVE/Products/Applications/DyorHQ.app"
[[ -d "$APP" ]] || { echo "Archive has no app bundle at $APP" >&2; exit 1; }
PUBLIC_VARS=(DEVELOPMENT_TEAM DYOR_SLASH PRIVY_APP_ID PRIVY_CLIENT_ID PASSKEY_RP_ID PERPL_BUILDER_ID SOCIAL_LOGINS_ENABLED
  PASSKEYS_ENABLED LAUNCHPAD_FACTORY LAUNCH_ROUTER FEE_ESCROW HOLDER_FEE_SHARING MEME_HOOK AURORA_FEE_RECIPIENT
  MOMENTS_FACTORY MOMENTS_COLLECT MOMENTS_VESTING MOMENTS_GRADUATION MOMENTS_LOCKER MOMENTS_HOOK MOMENTS_BUYBACK
  MOMENTS_PLATFORM MOMENTS_TREASURY MOMENTS_DEPLOY_BLOCK)
LEAKS=()
while IFS= read -r line; do
  name=${line%%=*}; name=${name%%\[*}; name=${name//[[:space:]]/}
  (( ${PUBLIC_VARS[(Ie)$name]} )) && continue
  # xcconfig: drop NAME[conditions] =, strip a trailing // comment, trim, then expand $(DYOR_SLASH) (how URLs write
  # "//" in xcconfig).
  value=$(printf '%s' "$line" | sed -e 's/^[A-Za-z_][A-Za-z0-9_]*\(\[[^]]*\]\)*[[:space:]]*=//' -e 's:[[:space:]]//.*$::' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\$(DYOR_SLASH)/\//g')
  (( ${#value} >= 8 )) || continue
  # The value goes to grep through a pipe (-f), never on its command line, where `ps` would show it.
  if grep -rqF -f <(print -r -- "$value") "$APP"; then LEAKS+=("$name"); fi
done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])*[[:space:]]*=' DyorHQ/Config/Secrets.xcconfig)
if grep -rqE 'alchemy\.com/v2/[A-Za-z0-9_-]|infura\.io/v3/[0-9a-f]|quiknode\.pro/[0-9a-f]' "$APP"; then LEAKS+=("keyed RPC provider URL"); fi
# The scanner prints file:line and variable names only. The source overrides it honours for its own tests are unset
# so a stray variable in this shell cannot narrow the gate, and so are BASH_ENV / SHELLOPTS, which could trace the
# values it holds; a missing scanner or any scan error also refuses.
SCANNER=../scripts/dev/secret-scan.sh
if [[ ! -f "$SCANNER" ]]; then LEAKS+=("(secret-scan.sh missing — cannot check the .env values)")
elif ! env -u SECRET_SCAN_ENV -u SECRET_SCAN_XCCONFIG -u BASH_ENV -u SHELLOPTS /bin/bash "$SCANNER" --path "$ARCHIVE" >&2; then
  LEAKS+=(".env / Secrets.xcconfig values or key patterns listed above by secret-scan")
fi
if (( ${#LEAKS[@]} )); then
  echo "REFUSING TO UPLOAD — the archive contains secret values from: ${LEAKS[*]}" >&2
  echo "Keep secrets server-side (see the notes in project.yml). Nothing was uploaded." >&2
  exit 1
fi
echo "Security gate: no secrets found in the archive ✓"

OPTIONS=build/ExportOptions-$BUILD.plist
sed "s/TEAM_ID/$TEAM/" ExportOptions.plist > "$OPTIONS"
AUTH=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "build/export-$BUILD" \
  -allowProvisioningUpdates "${AUTH[@]}" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload"
echo "Uploaded. It appears under TestFlight in App Store Connect after processing (a few minutes); answer the export"
echo "compliance question there (standard encryption only) and add the build to a tester group."
echo "Next build: bump CFBundleVersion in project.yml before running this again."
