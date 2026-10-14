#!/usr/bin/env bash
# Cohort-2 redeploy of the Moments stack on Monad mainnet with the $2,000 graduation FDV baked into the factory's
# constructor policy (threshold 771.428571 USDC; split, min price, allocation cap, expiry share, royalty and the
# platform/treasury beneficiaries unchanged), then retire the cohort-1 stack. Run it from your own terminal. It signs
# with a Ledger or a Foundry keystore account and never reads a plaintext key.
#
#   cd /Users/jerry/Hackathon-moments/contracts && ./script/moments/redeploy-cohort2.sh
#
#   DRY_RUN=1      simulate only (no key needed, nothing sent)
#   YES=1          skip the confirmation prompts
#   LEDGER=1       sign on a Ledger
#   ACCOUNT=name   sign with a Foundry keystore account (cast wallet import <name> --interactive)
#
# What it does, in order, stopping at the first failure:
#   0. pre-flight: chain 143, the signer is the cohort-1 governance wallet, enough MON, cohort-1 record kept
#   1. simulate the deployment (addresses + gas), ask, then deploy for real (8 transactions)
#   2. set the NFT metadata base on the new factory
#   3. pause publishing on the cohort-1 factory (its Moments stay on-chain; they leave the app once it is re-pointed)
#   4. verify every new contract on Sourcify (no key)
#   5. print the new addresses + deploy block and run the invariant monitor against them
# Rehearsed end to end on an anvil fork on 2026-09-22
# (see DyorHQ/internal: ios-app/docs/moments-mainnet-runbook.md §1b).
set -euo pipefail

# RETIRED (security audit 2026-09-26). Cohort 2 is itself retired (publishing paused 2026-09-23), and this script would
# deploy a new stack whose treasury is 0x5282… — the wallet whose key leaked — and then overwrite
# deployments/moments-143.json, which now records the live cohort 3. The live stack was deployed by
# script/relaunch/relaunch-new-wallets.sh. The rest of the file is kept for the record only.
echo "redeploy-cohort2.sh is retired: it would deploy a Moments stack paying the leaked treasury 0x5282… and overwrite the cohort-3 record." >&2
exit 1

cd "$(dirname "$0")/../.."   # contracts/

FORGE=~/.foundry/bin/forge; CAST=~/.foundry/bin/cast
RPC=monad                                                  # foundry.toml alias → https://rpc.monad.xyz
EXPECTED_DEPLOYER=0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10   # cohort-1 deployer + governance
OLD_FACTORY=0x64698c7702d85F87f43a6dFF7D495CDD2327C020
PLATFORM=0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48
TREASURY=0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045
THRESHOLD_USDC=771428571                                   # $2,000 FDV at the default 10% creator allocation
BASE=https://dyorhq.fun/moments/
DEP=deployments/moments-143.json
LOG="deployments/redeploy-cohort2-$(date +%Y%m%d-%H%M%S).log"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }
confirm() { [ "${YES:-0}" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "stopped"; }

# ---------------------------------------------------------------- signer (never printed)
SIGN=()
if [ "${DRY_RUN:-0}" = 1 ]; then
  ADDR=$EXPECTED_DEPLOYER
elif [ "${LEDGER:-0}" = 1 ]; then
  SIGN=(--ledger); ADDR=$EXPECTED_DEPLOYER
else
  [ -n "${ACCOUNT:-}" ] || die "set LEDGER=1 or ACCOUNT=<Foundry keystore account>: this script never reads a plaintext key"
  ADDR=$($CAST wallet address --account "$ACCOUNT") || die "cannot read the keystore account $ACCOUNT"
  SIGN=(--account "$ACCOUNT")
fi
echo "signer: $ADDR"
if [ "$ADDR" != "$EXPECTED_DEPLOYER" ] && [ "${ALLOW_OTHER_DEPLOYER:-0}" != 1 ]; then
  die "the signer is not the cohort-1 governance wallet $EXPECTED_DEPLOYER (set ALLOW_OTHER_DEPLOYER=1 to deploy from a different wallet — it would then own the new stack)"
fi

# ---------------------------------------------------------------- 0. pre-flight (read-only)
say "0. pre-flight"
CHAIN=$($CAST chain-id --rpc-url $RPC); [ "$CHAIN" = 143 ] || die "rpc '$RPC' is chain $CHAIN, not Monad mainnet (143)"
BAL=$($CAST balance "$ADDR" --rpc-url $RPC --ether); echo "balance: $BAL MON (deploy ≈ 4.9 MON at 200 gwei)"
python3 -c "import sys; sys.exit(0 if float('$BAL') >= 8 else 1)" || die "fund $ADDR with at least 8 MON first"
echo "old factory governance: $($CAST call $OLD_FACTORY 'governance()(address)' --rpc-url $RPC)   publishingPaused: $($CAST call $OLD_FACTORY 'publishingPaused()(bool)' --rpc-url $RPC)"
[ -f deployments/moments-143-cohort1.json ] || cp "$DEP" deployments/moments-143-cohort1.json
CUR=$(python3 -c "import json;print(json.load(open('$DEP'))['thresholdUsdc'])")
if [ "$CUR" = "$THRESHOLD_USDC" ]; then
  echo "note: $DEP already records a $THRESHOLD_USDC-unit threshold — a cohort-2 stack may already be deployed ($(python3 -c "import json;print(json.load(open('$DEP'))['factory'])"))"
  confirm "Deploy ANOTHER stack anyway?"
fi

# ---------------------------------------------------------------- 1. simulate, then deploy
say "1. simulation (no transactions)"
THRESHOLD_USDC=$THRESHOLD_USDC PLATFORM=$PLATFORM TREASURY=$TREASURY \
  $FORGE script script/moments/Deploy.s.sol:DeployMoments --rpc-url $RPC --non-interactive --code-size-limit 200000 --sender "$ADDR" 2>&1 \
  | grep -E 'factory|collect |vesting|graduation|locker|hook  |buyback|governance|Estimated|Error' | tee -a "$LOG"
cp deployments/moments-143-cohort1.json "$DEP"   # the simulation writes the JSON too; keep the live record until the real run
[ "${DRY_RUN:-0}" = 1 ] && { say "DRY_RUN=1 — stopping before any transaction"; exit 0; }
confirm "Deploy the cohort-2 stack on Monad mainnet from $ADDR now?"
say "1. deploying (8 transactions)"
THRESHOLD_USDC=$THRESHOLD_USDC PLATFORM=$PLATFORM TREASURY=$TREASURY \
  $FORGE script script/moments/Deploy.s.sol:DeployMoments --rpc-url $RPC --broadcast --non-interactive --code-size-limit 200000 --sender "$ADDR" "${SIGN[@]}" 2>&1 \
  | grep -vE 'private-key|PRIVATE_KEY' | tee -a "$LOG"
grep -q 'ONCHAIN EXECUTION COMPLETE' "$LOG" || die "the deployment did not complete — read $LOG; nothing else was changed"
NEW_FACTORY=$(python3 -c "import json;print(json.load(open('$DEP'))['factory'])")
[ "$($CAST code "$NEW_FACTORY" --rpc-url $RPC)" != "0x" ] || die "no code at the new factory $NEW_FACTORY"
echo "new factory: $NEW_FACTORY   policy: $($CAST call "$NEW_FACTORY" 'policy()((uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,address,address))' --rpc-url $RPC)"

# ---------------------------------------------------------------- 2. metadata base on the new factory
say "2. external base URI on the new factory"
BASE=$BASE $FORGE script script/moments/PolicyOps.s.sol:PolicyOps --rpc-url $RPC --broadcast --non-interactive --sender "$ADDR" "${SIGN[@]}" --sig "setBase()" 2>&1 \
  | grep -vE 'private-key|PRIVATE_KEY' | grep -E 'externalBaseURI|Error|ONCHAIN' | tee -a "$LOG"

# ---------------------------------------------------------------- 3. retire the cohort-1 factory
say "3. pausing publishing on the cohort-1 factory $OLD_FACTORY"
if [ "$($CAST call $OLD_FACTORY 'governance()(address)' --rpc-url $RPC)" = "$ADDR" ]; then
  $CAST send $OLD_FACTORY 'setPublishingPaused(bool)' true --rpc-url $RPC "${SIGN[@]}" --json 2>&1 | grep -vE 'private-key|PRIVATE_KEY' \
    | python3 -c "import json,sys; r=json.load(sys.stdin); print('paused:', r.get('status'), r.get('transactionHash'))" | tee -a "$LOG"
else
  echo "skipped: $ADDR is not the old factory's governance" | tee -a "$LOG"
fi

# ---------------------------------------------------------------- 4. verify
say "4. Sourcify verification (no key)"
./script/moments/verify-moments-143.sh 2>&1 | grep -E '^==|verified|already|failed|Error' | tee -a "$LOG" || true

# ---------------------------------------------------------------- 5. summary + invariants
say "5. new deployment"
python3 - "$DEP" <<'EOF' | tee -a "$LOG"
import json, sys
dep = json.load(open(sys.argv[1]))
run = json.load(open("broadcast/Deploy.s.sol/143/run-latest.json"))
block = next((int(r["blockNumber"], 16) for r in run.get("receipts", []) if (r.get("contractAddress") or "").lower() == dep["factory"].lower()), None)
for k in ["factory", "collect", "vesting", "graduation", "locker", "hook", "buyback"]:
    print(f"  {k:<11} {dep[k]}")
print(f"  deployBlock {block}   thresholdUsdc {dep['thresholdUsdc']}   governance {dep['governance']}")
print("Next: tell Claude to wire these into the app (MomentsAddresses.monadMainnet + deployBlock), sync the web app, and rebuild.")
EOF
( cd .. && node scripts/moments-status.mjs 2>&1 | tail -6 ) | tee -a "$LOG" || true
say "done — log: $LOG"
