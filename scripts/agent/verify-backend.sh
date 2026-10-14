#!/bin/bash
# V-BE of docs/DESIGN-stellar-parity.md §12.3 for one multichain-stellar work package, as CI runs it
# (.github/workflows/backend.yml): the type check of every entry point, the Deno unit tests, the API contract's checks
# (each fixture against _shared/contract.ts, and the phone's copies of the fixtures) and the SQL tests on the package's
# own Postgres port (55NN). It stops at the first failure.
#
#   scripts/agent/verify-backend.sh <S> <NN>     NN: the package's two digits (WP-NN also works)
#
# Each command writes to its own log in a temporary directory; a failure prints the log's last lines.
set -euo pipefail

say() { printf 'verify-backend: %s\n' "$*"; }
die() {
  printf 'verify-backend: %s\n' "$*" >&2
  exit 2
}

NN="${2:-}"
NN="${NN#WP-}"
if [ $# -ne 2 ] || [[ ! "$NN" =~ ^[0-9]{2}$ ]]; then
  printf 'usage: %s <S> <NN>   (NN: the package number, e.g. 02)\n' "$0" >&2
  exit 2
fi
S="$(cd "$1" 2>/dev/null && pwd)" || die "no directory $1"
C=backend/supabase/functions/deno.json
[ -f "$S/$C" ] || die "$S isn't a multichain-stellar checkout (no $C)"
DENO="$(command -v deno || echo /opt/homebrew/bin/deno)"
[ -x "$DENO" ] || die "deno isn't installed"

TMP="${TMPDIR:-/tmp}"
LOGS="$(mktemp -d "${TMP%/}/verify-backend-$NN.XXXXXX")"
N=0

# Runs one command in S, its output in a numbered log. Prints one line when it passes; on a failure the log's tail,
# then exits 1.
step() { # label command...
  local label="$1" log start status=0 last
  shift
  N=$((N + 1))
  log="$LOGS/$(printf '%02d' "$N")-$(printf '%s' "$label" | tr -c 'A-Za-z0-9.\n-' '-').log"
  start=$SECONDS
  (cd "$S" && NO_COLOR=1 "$@") >"$log" 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    last="$(grep -v '^[[:space:]]*$' "$log" | tail -1 | cut -c1-90 || true)"
    printf 'V-BE  ok    %-24s %4ss  %s\n' "$label" $((SECONDS - start)) "$last"
    return 0
  fi
  printf 'V-BE  FAIL  %-24s %4ss  exit %s\n' "$label" $((SECONDS - start)) "$status"
  say "last lines of $log:"
  tail -40 "$log" | sed 's/^/    /'
  exit 1
}

say "S = $S"
say "logs in $LOGS"

# The globs expand in S, as the commands in §12.3 do after `cd $S`.
cd "$S"
step "deno check" "$DENO" check --config "$C" backend/supabase/functions/lite/index.ts \
  backend/supabase/functions/lite-indexer/index.ts backend/supabase/functions/_shared/contract.ts \
  backend/scripts/*.ts backend/scripts/local/*.ts backend/tests/e2e/lite_e2e.ts backend/tests/e2e/phases/*.ts \
  backend/tests/vectors/gen-vectors.ts
step "deno test" "$DENO" test -A --config "$C" backend/tests/unit/
step "deno test (fixtures)" "$DENO" test --allow-read --allow-run --config "$C" backend/tests/fixtures/
step "fixtures sync.sh --check" backend/tests/fixtures/sync.sh --check
step "schema-test.sh 55$NN" backend/scripts/schema-test.sh "55$NN"

say "ok: V-BE passed (Postgres port 55$NN)"
