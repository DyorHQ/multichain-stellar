#!/bin/bash
# V-APP, V-STR and V-DYORKIT of docs/DESIGN-stellar-parity.md §12.3, in that order, for one work package that changes
# the app copy. It stops at the first failure.
#
#   scripts/agent/verify-app.sh <S> <WP-xx> [--clean]
#
# S is the package's worktree of this repository (scripts/agent/worktree.sh) and A=S/app its app copy. Every build
# uses one derived data folder, A/ios/DerivedData-<WP-xx>, for the internal project and the App Store project alike,
# and runs under the `xcode` lock (scripts/agent/lock.sh), taken once before the first build and given back after the
# last one (DyorKit's swift test): it waits for the lock for up to LOCK_WAIT seconds (default 7200). --clean deletes
# the derived data folder and DyorKit's .build when the run ends, if this run made them; otherwise delete them yourself
# when the package is done (README). Each command writes to its own log in a temporary directory; a failure prints the
# log's errors and its last lines. `swift test` and the internal build rewrite app/ios/DyorKit/Package.resolved, which
# must never change (invariant I2): it is restored from git on every exit, failures and Ctrl-C included.
set -euo pipefail

say() { printf 'verify-app: %s\n' "$*"; }
die() {
  printf 'verify-app: %s\n' "$*" >&2
  exit 2
}
usage() {
  printf 'usage: %s <S> <WP-xx> [--clean]\n' "$0" >&2
  exit 2
}

CLEAN=
if [ $# -eq 3 ] && [ "$3" = --clean ]; then CLEAN=1; elif [ $# -ne 2 ]; then usage; fi
[[ "$2" =~ ^WP-[A-Z0-9][A-Za-z0-9]{1,3}(-[a-z0-9]+)?$ ]] || usage
S="$(cd "$1" 2>/dev/null && pwd)" || die "no directory $1"
WP="$2"
A="$S/app"
IOS="$A/ios"
LOCK="$(cd "$(dirname "$0")" && pwd)/lock.sh"
[ -f "$IOS/Internal/generate.py" ] || die "$S has no app copy (no app/ios/Internal/generate.py)"
[ -f "$S/ios/Packages/StellarKit/Package.swift" ] || die "$S isn't a multichain-stellar checkout (no ios/Packages/StellarKit)"
[ -f "$IOS/project.local.yml" ] || die "$IOS/project.local.yml is missing: scripts/agent/worktree.sh writes it"
DD="DerivedData-$WP"
made_dd=
[ -e "$IOS/$DD" ] || made_dd=1
made_build=
[ -e "$IOS/DyorKit/.build" ] || made_build=1

HELD=
release_xcode() {
  [ -n "$HELD" ] || return 0
  "$LOCK" release xcode "$WP" >/dev/null || printf 'verify-app: could not release the xcode lock\n' >&2
  HELD=
}
restore() {
  git -C "$S" checkout -- app/ios/DyorKit/Package.resolved 2>/dev/null ||
    printf 'verify-app: could not restore app/ios/DyorKit/Package.resolved in %s\n' "$S" >&2
}
finish() {
  release_xcode
  restore
  if [ -n "$CLEAN" ] && [ -n "$made_dd$made_build" ]; then
    [ -z "$made_dd" ] || rm -rf "${IOS:?}/$DD"
    [ -z "$made_build" ] || rm -rf "${IOS:?}/DyorKit/.build"
    say "--clean: removed what this run built under $IOS"
  fi
}
trap finish EXIT
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

# The xcode lock, tied to this script's process: if the run is killed, the next acquire reclaims it. A lock this
# package already holds (taken by hand before the run) is used and left held.
take_xcode() {
  local out
  say "taking the xcode lock (waiting up to ${LOCK_WAIT:-7200} s for it)"
  out="$(LOCK_PID=$$ LOCK_WAIT="${LOCK_WAIT:-7200}" "$LOCK" acquire xcode "$WP")" || {
    printf '%s\n' "$out" >&2
    die "the xcode lock is busy"
  }
  printf '%s\n' "$out" | sed 's/^lock: /verify-app: /'
  case "$out" in *"acquired by"*) HELD=1 ;; esac
}

say "S = $S"
say "A = $A"
say "logs in $LOGS"

XCB_SIM=(-destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD")
APP="$DD/Build/Products/Release-iphonesimulator/DyorHQ.app"

take_xcode

# V-APP
step V-APP "generate.py (internal project)" "$IOS" python3 -I Internal/generate.py --spec project.local.yml --lite "$S/ios/Packages"
for c in Debug Release; do
  step V-APP "internal $c build" "$IOS" xcodebuild -project DyorHQInternal.xcodeproj -scheme DyorHQ -configuration "$c" \
    "${XCB_SIM[@]}" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
done
step V-APP "xcodegen (App Store project)" "$IOS" xcodegen generate --spec project.local.yml
# Both projects build DyorHQ.app into the same products folder: the internal Release build's app is removed first, so
# that nothing of the internal build is left in the app the check looks into.
rm -rf "${IOS:?}/$APP"
step V-APP "App Store Release build" "$IOS" xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -configuration Release \
  "${XCB_SIM[@]}" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
step V-APP "check-build23.py --app" "$IOS" python3 -I Internal/check-build23.py --app "$APP"
step V-APP "check-copies.py" "$IOS" python3 -I Internal/check-copies.py

# V-STR
step V-STR "check-lite-strings.py --enforce" "$IOS" python3 -I Internal/check-lite-strings.py --derived "$DD" --enforce
step V-STR "check-strings.py --enforce" "$A" python3 -I scripts/dev/check-strings.py --enforce

# V-DYORKIT
step V-DYORKIT "swift test" "$IOS/DyorKit" swift test
release_xcode
restore
step V-DYORKIT "Package.resolved unchanged" "$S" git diff --exit-code --stat -- app/ios/DyorKit/Package.resolved

say "ok: V-APP, V-STR and V-DYORKIT passed for $WP"
