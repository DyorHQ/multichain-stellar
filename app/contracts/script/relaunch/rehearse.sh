#!/usr/bin/env bash
# Fork rehearsal of relaunch-new-wallets.sh: runs the REAL script against an anvil fork of Monad mainnet, signing as
# governance with --unlocked (no key anywhere), in four passes — dry run, a run stopped at the Moments confirmation,
# the resumed run, and a no-op re-run — then the relaunch fork tests of both stacks against the result. Every file the
# runs write (deployment records, broadcast/ and cache/ dirs) is snapshotted first and restored on exit.
#   cd /Users/jerry/Hackathon/contracts && ./script/relaunch/rehearse.sh
set -euo pipefail

# RETIRED with relaunch-new-wallets.sh (security audit 2026-09-26): it rehearses a relaunch that is done, with a script
# that now refuses to run. script/deploy-v2.sh has its own FORK=1 rehearsal mode. Kept for the record only.
echo "rehearse.sh is retired together with relaunch-new-wallets.sh; rehearse v2 with FORK=1 script/deploy-v2.sh." >&2
exit 1

LP_DIR=$(cd "$(dirname "$0")/../.." && pwd)
MOM_DIR=${MOMENTS_DIR:-/Users/jerry/Hackathon-moments/contracts}
FORGE=~/.foundry/bin/forge; CAST=~/.foundry/bin/cast; ANVIL=~/.foundry/bin/anvil
PORT=${PORT:-8545}; RPC=http://127.0.0.1:$PORT
UPSTREAM=${UPSTREAM:-https://rpc1.monad.xyz}
OUT=${OUT:-$(mktemp -d)}
GOV=0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10
SNAP=$(mktemp -d)
SCRIPT="$LP_DIR/script/relaunch/relaunch-new-wallets.sh"
ANVIL_PID=

say() { printf '\n\033[1m## %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mREHEARSAL FAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- snapshot everything the runs write
snap() {
  local d key sub
  for d in "$LP_DIR" "$MOM_DIR"; do
    key=$(basename "$(dirname "$d")")
    for sub in deployments broadcast cache; do
      if [ -d "$d/$sub" ]; then mkdir -p "$SNAP/$key/$sub"; rsync -a "$d/$sub/" "$SNAP/$key/$sub/"; else touch "$SNAP/$key.$sub.absent"; fi
    done
  done
}
restore() {
  local d key sub
  for d in "$LP_DIR" "$MOM_DIR"; do
    key=$(basename "$(dirname "$d")")
    for sub in deployments broadcast cache; do
      if [ -f "$SNAP/$key.$sub.absent" ]; then rm -rf "${d:?}/$sub"; elif [ -d "$SNAP/$key/$sub" ]; then rsync -a --delete "$SNAP/$key/$sub/" "$d/$sub/"; fi
    done
  done
}
cleanup() {
  local rc=$?
  cp "$LP_DIR"/deployments/relaunch-*.log "$OUT/" 2>/dev/null || true
  restore
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true
  echo "records restored: launchpad $(python3 -c "import json;print(json.load(open('$LP_DIR/deployments/143.json'))['factory'])"), moments $(python3 -c "import json;print(json.load(open('$MOM_DIR/deployments/moments-143.json'))['factory'])")"
  echo "logs: $OUT"
  rm -rf "$SNAP"
  exit $rc
}
snap
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP   # bash 3.2 skips the EXIT trap on a bare SIGINT

say "anvil fork of $UPSTREAM on :$PORT"
lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && fail "port $PORT is busy"
"$ANVIL" --fork-url "$UPSTREAM" --chain-id 143 --port "$PORT" --code-size-limit 200000 --no-rate-limit --retries 8 --fork-retry-backoff 1500 --silent > "$OUT/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do "$CAST" chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$("$CAST" chain-id --rpc-url "$RPC")" = 143 ] || fail "anvil did not come up"
echo "fork block $("$CAST" block-number --rpc-url "$RPC")"
"$CAST" rpc anvil_impersonateAccount "$GOV" --rpc-url "$RPC" >/dev/null
BAL0=$("$CAST" balance "$GOV" --rpc-url "$RPC")
echo "governance balance (real, untouched): $("$CAST" from-wei "$BAL0") MON"

record() { python3 -c "import json;print(json.load(open('$1'))['factory'])"; }
LP0=$(record "$LP_DIR/deployments/143.json"); MOM0=$(record "$MOM_DIR/deployments/moments-143.json")

say "pass 0 — LEDGER=1 against the fork: a real-signing run must refuse a local RPC"
set +e
LEDGER=1 YES=1 RPC=$RPC "$SCRIPT" > "$OUT/pass0-guard.txt" 2>&1
rc=$?
set -e
[ "$rc" != 0 ] && grep -q 'refusing to sign for real against a local RPC' "$OUT/pass0-guard.txt" || { tail -10 "$OUT/pass0-guard.txt"; fail "the local-RPC guard did not stop a real-signing run"; }
echo "refused: $(grep -o 'refusing to sign for real against a local RPC' "$OUT/pass0-guard.txt")"

say "pass 1 — DRY_RUN=1 (must send nothing and leave the records alone)"
DRY_RUN=1 RPC=$RPC "$SCRIPT" > "$OUT/pass1-dry.txt" 2>&1 || { tail -30 "$OUT/pass1-dry.txt"; fail "dry run failed"; }
grep -E 'would send|would deploy|prices:|PASS|FAIL|DRY_RUN' "$OUT/pass1-dry.txt"
[ "$(record "$LP_DIR/deployments/143.json")" = "$LP0" ] && [ "$(record "$MOM_DIR/deployments/moments-143.json")" = "$MOM0" ] || fail "the dry run changed a record"
[ "$("$CAST" balance "$GOV" --rpc-url "$RPC")" = "$BAL0" ] || fail "the dry run spent gas"

say "pass 2 — FORK=1, answering y (plan), y (launchpad), n (Moments): must stop after the launchpad is live"
set +e
printf 'y\ny\nn\n' | FORK=1 RPC=$RPC "$SCRIPT" > "$OUT/pass2-stopped.txt" 2>&1
rc=$?
set -e
grep -E 'sent:|already|live|stopped|!!|harvest' "$OUT/pass2-stopped.txt" | head -40
[ "$rc" != 0 ] || fail "pass 2 should have stopped at the Moments confirmation"
grep -q 'stopped — nothing further was sent' "$OUT/pass2-stopped.txt" || fail "pass 2 stopped for another reason (see $OUT/pass2-stopped.txt)"
[ "$(record "$LP_DIR/deployments/143.json")" != "$LP0" ] || fail "pass 2 did not deploy the launchpad"
[ "$(record "$MOM_DIR/deployments/moments-143.json")" = "$MOM0" ] || fail "pass 2 touched the Moments record"

say "pass 3 — FORK=1 YES=1: must resume (launchpad skipped) and finish Moments + read-back"
FORK=1 YES=1 RPC=$RPC "$SCRIPT" > "$OUT/pass3-resume.txt" 2>&1 || { tail -40 "$OUT/pass3-resume.txt"; fail "pass 3 failed"; }
grep -E 'already deployed|sent:|PASS|FAIL|ok |!!|deployBlock|transactions sent' "$OUT/pass3-resume.txt"
grep -q 'launchpad: done' "$OUT/pass3-resume.txt" || fail "pass 3 did not see the launchpad as done"

say "pass 4 — FORK=1 YES=1 again: must be a no-op"
FORK=1 YES=1 RPC=$RPC "$SCRIPT" > "$OUT/pass4-noop.txt" 2>&1 || { tail -40 "$OUT/pass4-noop.txt"; fail "pass 4 failed"; }
grep -q 'transactions sent by this run (besides the two deploys): 0' "$OUT/pass4-noop.txt" || fail "pass 4 sent transactions"
grep -qE 'deploying' "$OUT/pass4-noop.txt" && fail "pass 4 deployed again"
grep -c PASS "$OUT/pass4-noop.txt" | xargs echo "read-back PASS lines:"

BAL1=$("$CAST" balance "$GOV" --rpc-url "$RPC")
echo "governance spent $(python3 -c "print(($BAL0 - $BAL1) / 1e18)") MON on the fork (Monad bills the gas limit; the fork bills gas used — expect mainnet to cost a little more)"

MON_E8=$(grep -m1 -oE 'MON_USD_E8=[0-9]+' "$OUT/pass2-stopped.txt" | cut -d= -f2)
ABIL_E8=$(grep -m1 -oE 'ABIL_USD_E8=[0-9]+' "$OUT/pass2-stopped.txt" | cut -d= -f2)

say "launchpad relaunch tests against the fork (prices $MON_E8 / $ABIL_E8)"
( cd "$LP_DIR" && RELAUNCH_RPC=$RPC EXPECT_MON_USD_E8=$MON_E8 EXPECT_ABIL_USD_E8=$ABIL_E8 "$FORGE" test --code-size-limit 100000000 --match-path test/audit/Z_Relaunch.t.sol -vv 2>&1 ) | tee "$OUT/lp-tests.txt" | grep -E '^\[(PASS|FAIL)|Suite result|Error|revert' || true
grep -q 'Suite result: ok' "$OUT/lp-tests.txt" || fail "launchpad relaunch tests failed"

say "Moments relaunch tests against the fork"
( cd "$MOM_DIR" && RELAUNCH_RPC=$RPC "$FORGE" test --code-size-limit 100000000 --match-path test/moments/fork/Relaunch.t.sol -vv 2>&1 ) | tee "$OUT/mom-tests.txt" | grep -E '^\[(PASS|FAIL)|Suite result|Error|revert' || true
grep -q 'Suite result: ok' "$OUT/mom-tests.txt" || fail "Moments relaunch tests failed"

say "REHEARSAL PASSED"
