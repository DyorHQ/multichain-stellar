#!/bin/bash
# V-APP, V-STR and V-DYORKIT of docs/DESIGN-stellar-parity.md §12.3, in that order, for one netswitch work package. It
# stops at the first failure.
#
#   scripts/agent/verify-app.sh <A> <S> <WP-xx>
#
# A is the package's IOS-app worktree and S its multichain-stellar worktree (scripts/agent/worktree.sh). The builds use
# A/ios/DerivedData-<WP-xx> (internal project) and A/ios/DerivedData-<WP-xx>-as (App Store project). Each command
# writes to its own log in a temporary directory; a failure prints the log's errors and its last lines.
# `swift test` rewrites ios/DyorKit/Package.resolved, which must never change (invariant I2): it is restored from git
# on every exit, failures and Ctrl-C included.
set -euo pipefail

BASE=d387a64

say() { printf 'verify-app: %s\n' "$*"; }
die() {
  printf 'verify-app: %s\n' "$*" >&2
  exit 2
}

if [ $# -ne 3 ] || [[ ! "$3" =~ ^WP-[0-9]{2}(-[a-z0-9]+)?$ ]]; then
  printf 'usage: %s <A> <S> <WP-xx>\n' "$0" >&2
  exit 2
fi
A="$(cd "$1" 2>/dev/null && pwd)" || die "no directory $1"
S="$(cd "$2" 2>/dev/null && pwd)" || die "no directory $2"
WP="$3"
[ -f "$A/ios/Internal/generate.py" ] || die "$A isn't an IOS-app checkout of lite/network-switch (no ios/Internal/generate.py)"
[ -f "$S/ios/Packages/StellarKit/Package.swift" ] || die "$S isn't a multichain-stellar checkout (no ios/Packages/StellarKit)"
[ -f "$A/ios/project.local.yml" ] ||
  die "$A/ios/project.local.yml is missing: copy it from ~/Hackathon-b17/netswitch/ios (worktree.sh does)"

restore() {
  git -C "$A" checkout -- ios/DyorKit/Package.resolved 2>/dev/null ||
    printf 'verify-app: could not restore ios/DyorKit/Package.resolved in %s\n' "$A" >&2
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TMP="${TMPDIR:-/tmp}"
LOGS="$(mktemp -d "${TMP%/}/verify-app-$WP.XXXXXX")"
N=0

# Runs one command in <dir>, its output in a numbered log. Prints one line when it passes; on a failure the errors and
# the log's tail, then exits 1.
step() { # block label dir command...
  local block="$1" label="$2" dir="$3" log start status=0 last
  shift 3
  N=$((N + 1))
  log="$LOGS/$(printf '%02d' "$N")-$(printf '%s' "$label" | tr -c 'A-Za-z0-9.\n-' '-').log"
  start=$SECONDS
  (cd "$dir" && "$@") >"$log" 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    # XCTest's count when there is one (swift test ends with swift-testing's line), else the last line.
    last="$(grep -E 'Executed [0-9]+ tests?, with' "$log" | tail -1 || true)"
    [ -n "$last" ] || last="$(grep -v '^[[:space:]]*$' "$log" | tail -1 || true)"
    last="$(printf '%s' "$last" | sed 's/^[[:space:]]*//' | cut -c1-90)"
    printf '%-10s ok    %-34s %4ss  %s\n' "$block" "$label" $((SECONDS - start)) "$last"
    return 0
  fi
  printf '%-10s FAIL  %-34s %4ss  exit %s\n' "$block" "$label" $((SECONDS - start)) "$status"
  if grep -qE '(: (fatal )?error:|^error:)' "$log"; then
    say "errors:"
    grep -E '(: (fatal )?error:|^error:)' "$log" | sort -u | head -40 | sed 's/^/    /'
  fi
  say "last lines of $log:"
  tail -25 "$log" | sed 's/^/    /'
  exit 1
}

say "A = $A"
say "S = $S"
say "logs in $LOGS"

IOS="$A/ios"
XCB_SIM=(-destination 'generic/platform=iOS Simulator')

# V-APP
step V-APP "generate.py (internal project)" "$IOS" python3 -I Internal/generate.py --spec project.local.yml --lite "$S/ios/Packages"
for c in Debug Release; do
  step V-APP "internal $c build" "$IOS" xcodebuild -project DyorHQInternal.xcodeproj -scheme DyorHQ -configuration "$c" \
    "${XCB_SIM[@]}" -derivedDataPath "DerivedData-$WP" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
done
step V-APP "xcodegen (App Store project)" "$IOS" xcodegen generate --spec project.local.yml
step V-APP "App Store Release build" "$IOS" xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -configuration Release \
  "${XCB_SIM[@]}" -derivedDataPath "DerivedData-$WP-as" CODE_SIGNING_ALLOWED=NO build
step V-APP "check-build23.py --app" "$IOS" python3 -I Internal/check-build23.py --base "$BASE" \
  --app "DerivedData-$WP-as/Build/Products/Release-iphonesimulator/DyorHQ.app"
step V-APP "check-copies.py" "$IOS" python3 -I Internal/check-copies.py --base "$BASE"

# V-STR
step V-STR "check-lite-strings.py --enforce" "$IOS" python3 -I Internal/check-lite-strings.py --derived "DerivedData-$WP" \
  --base "$BASE" --enforce
step V-STR "check-strings.py --enforce" "$A" python3 -I scripts/dev/check-strings.py --enforce

# V-DYORKIT
step V-DYORKIT "swift test" "$IOS/DyorKit" swift test
restore
step V-DYORKIT "Package.resolved unchanged" "$A" git diff --exit-code --stat -- ios/DyorKit/Package.resolved

say "ok: V-APP, V-STR and V-DYORKIT passed for $WP"
