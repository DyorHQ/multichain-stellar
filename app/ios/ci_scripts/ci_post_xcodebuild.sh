#!/bin/zsh
# Xcode Cloud runs this after each xcodebuild action. For an archive it is the SECURITY GATE of scripts/testflight.sh:
# a cloud archive goes to TestFlight without ever running that script, so the same checks run here, and a non-zero
# exit fails the archive action before its TestFlight post-action can distribute the build. The values come from the
# Secrets.xcconfig that ci_post_clone.sh writes from the workflow's environment variables (a cloud clone has no .env).
# Checked anywhere in the .xcarchive and the App Store export: every non-public Secrets.xcconfig value, keyed
# RPC-provider URLs and private-key patterns (scripts/dev/secret-scan.sh, which prints names only, never values).
# Before that, the v2 wiring gate: an archive is refused while DyorKit's v2 launchpad or Moments addresses are still
# PENDING (scripts/dev/check-launchpad-addresses.py --release), so no build ships with Launch and Publish "not live yet",
# and while a retired Moments cohort is not final on chain (momentCount equal to its pin, every coin in the retired-coin
# table, cohorts 1 and 2 paused: read-only calls to a public Monad RPC). The DyorHQ target's install-only build phase
# runs the same check first; this is the second layer. Then its Swift half and the strings gate: DyorKit's
# V2WiringTests and the strings tests under DYORHQ_RELEASE_GATE=1, so no build ships with a count that reads "1 editions".
set -euo pipefail
set +x # never trace: the scanner holds secret values in variables
[[ ${CI_XCODEBUILD_ACTION:-} == archive ]] || exit 0
cd "$(dirname "$0")/.."

WIRING=../scripts/dev/check-launchpad-addresses.py
if [[ ! -f $WIRING ]] || ! command -v python3 >/dev/null; then
  echo "error: $WIRING (or python3) is missing, so the v2 contract wiring cannot be checked; refusing to ship." >&2
  exit 1
fi
if ! python3 "$WIRING" --release >&2; then
  echo "error: REFUSING TO SHIP — the v2 contract addresses or the retired Moments cohorts failed the release gate (above)." >&2
  exit 1
fi

# Its Swift half and the strings gate, as in scripts/testflight.sh: V2WiringTests refuses a pending v2 table, and the
# lanes' strings tests, which read the app's sources and String Catalogs, refuse a count whose English plural forms
# aren't in a catalog (a count of 1 would read "1 editions") where they would otherwise skip. They read this checkout
# only; swift test fetches DyorKit's pinned packages.
RELEASE_TESTS='AppStringsTests|PerpsWalletStringsTests|MomentsStringsTests|DyorKitStringsTests|TradeStringsTests|ShippedLanguagesTests|V2WiringTests'
if ! command -v swift >/dev/null; then
  echo "error: swift is missing, so the strings and v2 wiring tests cannot run; refusing to ship." >&2
  exit 1
fi
if ! (cd DyorKit && DYORHQ_RELEASE_GATE=1 swift test --filter "$RELEASE_TESTS" >&2); then
  echo "error: REFUSING TO SHIP — the strings or v2 wiring tests failed under DYORHQ_RELEASE_GATE=1 (above)." >&2
  exit 1
fi

ARCHIVE=${CI_ARCHIVE_PATH:-}
if [[ -z $ARCHIVE || ! -d $ARCHIVE ]]; then
  echo "error: CI_ARCHIVE_PATH does not name an archive, so it cannot be checked for secrets; refusing to ship it." >&2
  exit 1
fi
SCANNER=../scripts/dev/secret-scan.sh
[[ -f $SCANNER ]] || { echo "error: $SCANNER is missing; refusing to ship an unchecked archive." >&2; exit 1; }

LEAKS=()
if grep -rqE 'alchemy\.com/v2/[A-Za-z0-9_-]|infura\.io/v3/[0-9a-f]|quiknode\.pro/[0-9a-f]' "$ARCHIVE"; then LEAKS+=("keyed RPC provider URL"); fi
# The .ipa of the App Store export, when this action exported one, is unpacked and checked too.
for target in "$ARCHIVE" ${CI_APP_STORE_SIGNED_APP_PATH:-}; do
  [[ -e $target ]] || continue
  if ! env -u SECRET_SCAN_ENV -u SECRET_SCAN_XCCONFIG -u BASH_ENV -u SHELLOPTS /bin/bash "$SCANNER" --path "$target" >&2; then
    LEAKS+=("secret values or key patterns listed above by secret-scan (${target:t})")
  fi
done
if (( ${#LEAKS[@]} )); then
  echo "error: REFUSING TO SHIP — the archive contains: ${LEAKS[*]}" >&2
  echo "Keep secrets server-side (see the notes in project.yml); do not add secret values to the Xcode Cloud workflow." >&2
  exit 1
fi
echo "Security gate: no secrets found in the archive ✓"
