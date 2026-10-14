#!/bin/bash
# Brings the String Catalogs up to date with the code, as Xcode's editor does after a build, for agents and CI. The app's
# ios/DyorHQ/Resources/Localizable.xcstrings and DyorKit's Sources/DyorKit/Resources/Localizable.xcstrings gain every
# string the compiler extracted from a build (SWIFT_EMIT_LOC_STRINGS writes them to .stringsdata files), and strings no
# longer in the code are marked stale. xcodebuild never updates a catalog by itself. InfoPlist.xcstrings is not synced:
# its keys are the Info.plist's (project.yml). Prints counts only, never string contents.
#
#   scripts/dev/strings-sync.sh                          # build for the simulator into a scratch folder, sync, delete it
#   scripts/dev/strings-sync.sh --derived-data <path>    # sync from a build that already ran in <path>
#   scripts/dev/strings-sync.sh --check                  # exit 1 when a catalog was out of date (CI, once L2 lands)
#   scripts/dev/strings-sync.sh -- <xcodebuild settings> # extra settings for the build, e.g. INFOPLIST_FILE=…
#
# The build needs ios/DyorHQ.xcodeproj (run `xcodegen generate` in ios/ first). Afterwards run
# scripts/dev/check-strings.py.
set -euo pipefail
set +x

ROOT=$(git rev-parse --show-toplevel)
DERIVED=; CHECK=; EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --derived-data) DERIVED=${2:?--derived-data needs a path}; shift 2 ;;
    --check) CHECK=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "strings-sync: unknown argument: $1" >&2; exit 2 ;;
  esac
done

APP_CATALOG="$ROOT/ios/DyorHQ/Resources/Localizable.xcstrings"
KIT_CATALOG="$ROOT/ios/DyorKit/Sources/DyorKit/Resources/Localizable.xcstrings"
for catalog in "$APP_CATALOG" "$KIT_CATALOG"; do
  [ -f "$catalog" ] || { echo "strings-sync: missing catalog: $catalog" >&2; exit 2; }
done

if [ -z "$DERIVED" ]; then
  PROJECT="$ROOT/ios/DyorHQ.xcodeproj"
  [ -d "$PROJECT" ] || { echo "strings-sync: no $PROJECT; run 'xcodegen generate' in ios/ first" >&2; exit 2; }
  DERIVED=$(mktemp -d "${TMPDIR:-/tmp}/strings-sync.XXXXXX")
  trap 'rm -rf "$DERIVED"' EXIT
  echo "strings-sync: building DyorHQ (Debug, simulator) into a scratch folder…"
  xcodebuild -project "$PROJECT" -scheme DyorHQ -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES ${EXTRA[@]+"${EXTRA[@]}"} build -quiet
fi

INTERMEDIATES="$DERIVED/Build/Intermediates.noindex"
[ -d "$INTERMEDIATES" ] || { echo "strings-sync: no build in $DERIVED" >&2; exit 2; }

# One target's .stringsdata files: the app's under DyorHQ.build, DyorKit's under DyorKit.build (each architecture
# extracts the same strings; the sync takes them all).
stringsdata() {
  find "$INTERMEDIATES" -type f -name '*.stringsdata' -path "*/$1.build/Objects-normal/*" | sort
}

checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
keys() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$1"; }

CHANGED=0
sync_catalog() {
  local catalog=$1 target=$2 files=()
  while IFS= read -r file; do files+=("$file"); done < <(stringsdata "$target")
  if [ ${#files[@]} -eq 0 ]; then
    echo "strings-sync: no .stringsdata for $target in $DERIVED (was SWIFT_EMIT_LOC_STRINGS on?)" >&2
    exit 2
  fi
  local before after args=()
  before=$(checksum "$catalog")
  for file in "${files[@]}"; do args+=(--stringsdata "$file"); done
  xcrun xcstringstool sync "$catalog" "${args[@]}"
  after=$(checksum "$catalog")
  if [ "$before" != "$after" ]; then CHANGED=1; state="updated"; else state="up to date"; fi
  echo "strings-sync: ${catalog#"$ROOT/"}: $(keys "$catalog") keys from ${#files[@]} files, $state"
}

sync_catalog "$APP_CATALOG" DyorHQ
sync_catalog "$KIT_CATALOG" DyorKit

if [ -n "$CHECK" ] && [ "$CHANGED" = 1 ]; then
  echo "strings-sync: a catalog was out of date with the code; commit the synced catalogs" >&2
  exit 1
fi
