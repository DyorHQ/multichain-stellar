#!/bin/bash
# Copies the API fixtures (backend/tests/fixtures/api/*.json, one per response: today's payloads as <name>.legacy.json)
# to the phone's tests, which decode every one of them (StellarKit LiteClientTests.testDecodesApiFixtures). The copies
# are committed, so `swift test` needs no backend checkout; run this after changing a fixture and commit both.
#
#   backend/tests/fixtures/sync.sh           # copy (and drop copies whose fixture is gone)
#   backend/tests/fixtures/sync.sh --check   # exit 1 when the copies differ from the fixtures
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
from="$here/api"
to="$repo/ios/Packages/StellarKit/Tests/LiteClientTests/Fixtures"

case "${1:-}" in
  "") check=0 ;;
  --check) check=1 ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

if [ "$check" = 1 ]; then
  if diff -r "$from" "$to" >/dev/null 2>&1; then
    echo "fixtures: the phone's copies match"
    exit 0
  fi
  echo "fixtures: the phone's copies differ; run backend/tests/fixtures/sync.sh" >&2
  diff -rq "$from" "$to" >&2 || true
  exit 1
fi

mkdir -p "$to"
for old in "$to"/*.json; do
  [ -e "$old" ] || continue
  [ -e "$from/$(basename "$old")" ] || rm "$old"
done
cp "$from"/*.json "$to"/
echo "fixtures: copied $(find "$from" -name '*.json' | wc -l | tr -d ' ') to ${to#"$repo"/}"
