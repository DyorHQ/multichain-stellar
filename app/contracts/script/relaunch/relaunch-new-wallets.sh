#!/usr/bin/env bash
# Full relaunch of the DyorHQ Launchpad AND Moments with the rotated wallets (2026-09-23).
#
# The treasury key 0x5282… leaked on 2026-09-17 and the wallets were rotated to treasury 0x5aDb… and fees 0x15ED…,
# but every live contract still paid the old ones. This script, run once from the owner's terminal:
#
#   0. pre-flight (read-only): chain 143, the signer is the governance wallet, enough MON, the source is the audited
#      source the live stacks were built from, every old contract is still owned by governance, and live MON/aBIL
#      prices from two independent sources that agree within 2%
#   1. stops the bleeding on the OLD launchpad stacks: protocol fees of the three old factories → new treasury,
#      Monday LP fees of the three old fee vaults → new fees wallet (existing launches keep trading; their fees now
#      reach the new wallets)
#   2. deploys the NEW launchpad (treasury 0x5aDb…, fees 0x15ED…, 5 MON launch fee, $2,000 → $20,000 FDV at the
#      live prices), simulating first and asking before it sends anything
#   3. closes the three old factories to new launches (whitelist on, launch config 0 off)
#   4. deploys Moments cohort 3 (platform 0x15ED…, treasury 0x5aDb…, $2,000-FDV threshold), simulating first
#   5. sets the NFT metadata base on it and pauses publishing on the cohort-2 factory (cohort 1 is already paused)
#   6. verifies every new contract on Sourcify (no key involved)
#   7. reads everything back from the chain — including a byte-for-byte check that the new contracts run the same
#      code as the stacks they replace — and prints the new addresses + deploy blocks
#
# Every step checks the chain first and skips what is already done, so an interrupted run is simply run again.
# Rehearsed end to end on an anvil fork of Monad mainnet (script/relaunch/rehearse.sh).
#
#   cd /Users/jerry/Hackathon/contracts && ./script/relaunch/relaunch-new-wallets.sh
#
#   DRY_RUN=1   pre-flight + prices + both deploy simulations, and the list of transactions it WOULD send; sends nothing
#   LEDGER=1    sign on a Ledger
#   ACCOUNT=n   sign with the Foundry keystore account n (cast wallet import n --interactive)
#   YES=1       no confirmation prompts
#   FORK=1      rehearsal against a local anvil fork (RPC=http://127.0.0.1:8545); signs with --unlocked as governance
#
# A real run signs with a Ledger or a keystore account; the script never reads a plaintext key.
set -euo pipefail

# RETIRED (security audit 2026-09-26, SEC-1). The relaunch it performed is done (2026-09-23), its source pin
# (LP_SOURCE_COMMIT) no longer matches contracts/src, which now holds the undeployed v2 fixes, and by default it passed a
# raw private key to forge/cast on the command line, which mainnet signing must never do again. The v2 deployment runs
# through script/deploy-v2.sh (Ledger or keystore only). The rest of the file is kept for the record only.
echo "relaunch-new-wallets.sh is retired: the relaunch is done; deploy v2 with script/deploy-v2.sh (--ledger or --account only)." >&2
exit 1

umask 077
# forge/cast honour FOUNDRY_* (compiler config → different bytecode), ETH_* (gas, sender, keystore, rpc), CAST_*
# (CAST_ASYNC returns before the receipt) and DAPP_* — none may leak in from the owner's shell.
for v in $(env | grep -oE '^(FOUNDRY|DAPP|ETH|CAST)_[A-Za-z0-9_]*=' || true); do unset "${v%=}"; done
unset CHAIN 2>/dev/null || true

LP_DIR=$(cd "$(dirname "$0")/../.." && pwd)                       # launchpad contracts/ (this repo)
MOM_DIR=${MOMENTS_DIR:-/Users/jerry/Hackathon-moments/contracts}  # Moments contracts/ (moments/v1 worktree)
FORGE=~/.foundry/bin/forge
CAST=~/.foundry/bin/cast
RPC=${RPC:-https://rpc.monad.xyz}
REFERENCE_RPC=https://rpc1.monad.xyz   # an independent mainnet endpoint the signing RPC must agree with

# ---------------------------------------------------------------- the roles (public addresses only)
GOV=0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10            # governance: owns every factory/vault, signs this run
NEW_TREASURY=0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371   # protocol fees (launchpad) + Moments treasury
NEW_FEES=0x15ED3bb488231213b141A2f78b62358D52235Cd7       # Monday LP fees (launchpad) + Moments platform share
LEAKED_TREASURY=0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045
OLD_FEES=0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48

OLD_FACTORIES=(0x10F34A174d9C393a90aFf94BDED7E1Db185446D7 0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4 0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea)
# 0xC154 first: it owns the only graduated old Monday position, whose unharvested LP fees anyone can push to the
# CURRENT recipient — so it is repointed before anything else and then harvested to the new fees wallet.
OLD_VAULTS=(0xC154C85e8a2A73B99676C31dcE8627D67A9F376A 0x42a1C1c1d6BC2544d3f478E4d42F5b5ec75888De 0x97B80811036306838e48C409543F7C50bb6e494B)
HARVEST=(0xC154C85e8a2A73B99676C31dcE8627D67A9F376A:0x72484c6c9f2a41dd9f34c61584bcd2b72eeef325)   # vault:pool (ad3d's graduated WMON pool)
COHORT0=0x47D989a54232D3bCdB7A7760D10E596647D986BA   # Moments v1 (never used, paused)
COHORT1=0x64698c7702d85F87f43a6dFF7D495CDD2327C020
COHORT2=0xc12B6b6948185cef75F861c5327702c30CB8a581

# ---------------------------------------------------------------- the economics (unchanged from the live stacks)
LAUNCH_FEE_WEI=5000000000000000000   # 5 MON
PROTOCOL_FEE_SHARE_BPS=5000
MAX_CREATOR_TAX_BPS=1000
LAUNCH_FDV_USD=2000                  # graduation at $20,000 (sqrt(10)-1 multiple, fixed in Deploy.s.sol)
THRESHOLD_USDC=771428571             # Moments: $2,000 FDV at the default 10% creator allocation
BASE=https://dyorhq.fun/moments/
MIN_BALANCE_MON=15                   # 53M gas of deploys: ≈ 5.5 MON at 103 gwei, ≈ 10.7 MON at 202 gwei; admin txs < 0.5 MON

# Source the live stacks were built from: the new contracts must be byte-identical to them (checked again in step 7).
LP_SOURCE_COMMIT=94e0fb1             # launchpad audit fixes — 0x10F3… was deployed from it on 2026-09-16
MOM_SOURCE_COMMIT=3db2294            # Moments cohort 2 — 0xc12B… was deployed from it on 2026-09-22

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LP_DIR/deployments/relaunch-$STAMP.log"
LP_REC="$LP_DIR/deployments/143.json"
LP_RETIRED_REC="$LP_DIR/deployments/143-retired-0x10F3.json"
MOM_REC="$MOM_DIR/deployments/moments-143.json"
MOM_RETIRED_REC="$MOM_DIR/deployments/moments-143-cohort2.json"
TMP=$(mktemp -d)
RESTORE_LP=0; RESTORE_MOM=0
cleanup() {
  # A simulation rewrites the record files; if anything interrupts one, put the live record back.
  [ "$RESTORE_LP" = 1 ] && [ -f "$TMP/143.json" ] && cp "$TMP/143.json" "$LP_REC"
  [ "$RESTORE_MOM" = 1 ] && [ -f "$TMP/moments-143.json" ] && cp "$TMP/moments-143.json" "$MOM_REC"
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP   # bash 3.2 skips the EXIT trap on a bare SIGINT

# ---------------------------------------------------------------- helpers
bold() { printf '\n\033[1m== %s\033[0m\n' "$*" | tee -a "$LOG"; }
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
die() { printf '\n\033[31m!! %s\033[0m\n' "$*" | tee -a "$LOG" >&2; exit 1; }
confirm() { [ "${YES:-0}" = 1 ] && return 0; local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || die "stopped — nothing further was sent"; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
eq() { [ "$(lc "$1")" = "$(lc "$2")" ]; }
first() { awk '{print $1}'; }
call() { $CAST call "$@" --rpc-url "$RPC" 2>/dev/null; }
codelen() { local c; c=$($CAST code "$1" --rpc-url "$RPC"); echo $(( (${#c} - 2) / 2 )); }
jget() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }
is_old_factory() { local f; for f in "${OLD_FACTORIES[@]}"; do eq "$1" "$f" && return 0; done; return 1; }
# Scrubs the key (with and without 0x) from every line of tool output before it reaches the screen or the log.
scrub() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "${PK:-}" ]; then line=${line//$PK/[redacted]}; line=${line//${PK#0x}/[redacted]}; fi
    printf '%s\n' "$line"
  done
}

# rcpt <field> — a field of the JSON receipt that `cast send --json` prints (after any warnings).
rcpt() { python3 -c "import json,sys; raw=sys.stdin.read(); print(json.loads(raw[raw.index('{'):]).get(sys.argv[1]))" "$1" 2>/dev/null || echo "?"; }

# send <label> <to> <signature> [args...] — one admin transaction, receipt status checked. DRY_RUN only lists it.
SENT=0
send() {
  local label=$1; shift
  if [ "$MODE" = dry ]; then say "   would send: $label"; return 0; fi
  local out status hash
  out=$($CAST send "$@" --rpc-url "$RPC" ${CAST_SIGN[@]+"${CAST_SIGN[@]}"} --json 2>&1 | scrub) || { printf '%s\n' "$out" | tail -5 | tee -a "$LOG"; die "$label: transaction failed"; }
  status=$(printf '%s' "$out" | rcpt status); hash=$(printf '%s' "$out" | rcpt transactionHash)
  [ "$status" = 0x1 ] || [ "$status" = 1 ] || { printf '%s\n' "$out" | tail -5 | tee -a "$LOG"; die "$label: status $status (tx $hash)"; }
  SENT=$((SENT + 1))
  say "   sent: $label   tx $hash"
}

# ---------------------------------------------------------------- signer (never printed)
mkdir -p "$LP_DIR/deployments"
: > "$LOG"
MODE=key
FORGE_SIGN=(); CAST_SIGN=()
if [ "${DRY_RUN:-0}" = 1 ]; then
  MODE=dry; ADDR=$GOV
elif [ "${FORK:-0}" = 1 ]; then
  case "$RPC" in http://127.0.0.1:*|http://localhost:*) ;; *) die "FORK=1 needs RPC=http://127.0.0.1:<port> (a local anvil fork), got $RPC" ;; esac
  MODE=fork; ADDR=$GOV; FORGE_SIGN=(--unlocked); CAST_SIGN=(--unlocked --from "$GOV")
elif [ "${LEDGER:-0}" = 1 ]; then
  MODE=ledger; ADDR=$GOV; FORGE_SIGN=(--ledger); CAST_SIGN=(--ledger --from "$GOV")
else
  [ -n "${ACCOUNT:-}" ] || die "set LEDGER=1 or ACCOUNT=<Foundry keystore account>: this script never reads a plaintext key"
  ADDR=$($CAST wallet address --account "$ACCOUNT") || die "cannot read the keystore account $ACCOUNT"
  FORGE_SIGN=(--account "$ACCOUNT"); CAST_SIGN=(--account "$ACCOUNT")
fi
say "mode: $MODE   signer: $ADDR   rpc: $RPC   log: $LOG"
eq "$ADDR" "$GOV" || die "the signer $ADDR is not the governance wallet $GOV — it owns every contract this run touches"

# ---------------------------------------------------------------- 0. pre-flight (read-only)
bold "0. pre-flight"
CHAIN=$($CAST chain-id --rpc-url "$RPC") || die "cannot reach $RPC"
[ "$CHAIN" = 143 ] || die "$RPC is chain $CHAIN, not Monad mainnet (143)"
if [ "$MODE" = key ] || [ "$MODE" = ledger ]; then
  # A real signature must go to real mainnet: a local fork also reports chain 143.
  case "$RPC" in *127.0.0.1*|*localhost*|*0.0.0.0*) die "refusing to sign for real against a local RPC ($RPC) — unset RPC or use FORK=1" ;; esac
  B=$(( $($CAST block-number --rpc-url "$RPC") - 20 ))
  H1=$($CAST block "$B" --field hash --rpc-url "$RPC"); H2=$($CAST block "$B" --field hash --rpc-url "$REFERENCE_RPC")
  [ -n "$H1" ] && [ "$H1" = "$H2" ] || die "$RPC and $REFERENCE_RPC disagree on block $B — not Monad mainnet, or a lagging node; retry"
  say "rpc: block $B hash matches $REFERENCE_RPC (mainnet)"
fi
BAL=$($CAST balance "$GOV" --rpc-url "$RPC" --ether)
say "governance balance: $BAL MON (need ≥ $MIN_BALANCE_MON)"
[ "$MODE" = dry ] || python3 -c "import sys; sys.exit(0 if float('$BAL') >= $MIN_BALANCE_MON else 1)" || die "fund $GOV with at least $MIN_BALANCE_MON MON first"

# The source must be exactly what the live stacks were built from (and the dependencies untouched).
git -C "$LP_DIR" diff --quiet "$LP_SOURCE_COMMIT" -- src script/Deploy.s.sol foundry.toml remappings.txt lib \
  || die "launchpad source differs from the audited commit $LP_SOURCE_COMMIT (git -C $LP_DIR diff $LP_SOURCE_COMMIT -- src)"
[ -z "$(git -C "$LP_DIR" status --porcelain -- src script/Deploy.s.sol foundry.toml remappings.txt)" ] || die "uncommitted launchpad source changes"
git -C "$MOM_DIR" diff --quiet "$MOM_SOURCE_COMMIT" -- src/moments script/moments/Deploy.s.sol foundry.toml remappings.txt lib \
  || die "Moments source differs from the cohort-2 commit $MOM_SOURCE_COMMIT"
[ -z "$(git -C "$MOM_DIR" status --porcelain -- src script/moments/Deploy.s.sol foundry.toml remappings.txt)" ] || die "uncommitted Moments source changes"
for d in "$LP_DIR" "$MOM_DIR"; do
  git -C "$d" submodule status --recursive lib | grep -q '^[+-U]' && die "a library submodule in $d is at the wrong commit or missing (git submodule status --recursive lib)"
  [ -z "$(git -C "$d" submodule foreach --quiet --recursive 'git status --porcelain --untracked-files=no')" ] || die "a library submodule in $d has local edits"
done
say "source: launchpad = $LP_SOURCE_COMMIT, Moments = $MOM_SOURCE_COMMIT, libraries pinned"

for f in "${OLD_FACTORIES[@]}"; do eq "$(call "$f" 'owner()(address)')" "$GOV" || die "old factory $f is not owned by governance"; done
for v in "${OLD_VAULTS[@]}"; do eq "$(call "$v" 'owner()(address)')" "$GOV" || die "old fee vault $v is not owned by governance"; done
for m in "$COHORT0" "$COHORT1" "$COHORT2"; do eq "$(call "$m" 'governance()(address)')" "$GOV" || die "Moments factory $m is not governed by governance"; done
for w in "$NEW_TREASURY" "$NEW_FEES"; do [ "$(codelen "$w")" = 0 ] || die "$w has code — the new wallets must be plain EOAs"; done
say "ownership: governance owns all 3 old factories, 3 old vaults and the 3 old Moments factories; new wallets are EOAs"

# Where each stack stands (so a re-run resumes instead of redeploying).
lp_ready() {  # <factory> — the new launchpad is fully configured
  local f=$1
  is_old_factory "$f" && return 1
  [ "$(codelen "$f")" -gt 0 ] || return 1
  [ "$(call "$f" 'whitelistEnabled()(bool)')" = false ] || return 1
  eq "$(call "$f" 'owner()(address)')" "$GOV" && eq "$(call "$f" 'protocolFeeRecipient()(address)')" "$NEW_TREASURY" \
    && [ "$(call "$f" 'launchFee()(uint256)' | first)" = "$LAUNCH_FEE_WEI" ] && [ "$(call "$f" 'launchConfigCount()(uint256)' | first)" = 1 ] \
    && [ "$(call "$f" 'mondayExecutor()(address)')" != 0x0000000000000000000000000000000000000000 ] \
    && [ "$(call "$f" 'approvedPairTokens(address)(bool)' 0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f)" = true ] \
    && [ "$(call "$f" 'pairMondayOnly(address)(bool)' 0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f)" = true ]
}
mom_ready() {  # <factory> — cohort 3 is deployed and wired
  local f=$1
  { eq "$f" "$COHORT0" || eq "$f" "$COHORT1" || eq "$f" "$COHORT2"; } && return 1
  [ "$(codelen "$f")" -gt 0 ] || return 1
  local pol; pol=$(call "$f" 'policy()(uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,address,address)' | tr '\n' ' ')
  eq "$(call "$f" 'governance()(address)')" "$GOV" && [ "$(call "$f" 'modulesSet()(bool)')" = true ] \
    && [ "$(echo "$pol" | awk '{print $1}')" = "$THRESHOLD_USDC" ] \
    && eq "$(echo "$pol" | awk '{print $(NF-1)}')" "$NEW_FEES" && eq "$(echo "$pol" | awk '{print $NF}')" "$NEW_TREASURY"
}
# never_sent <address>: no code on two independent endpoints AND no governance nonce below the current one creates it.
never_sent() {
  local a=$1 n k
  [ "$(codelen "$a")" = 0 ] || return 1
  [ "$($CAST code "$a" --rpc-url "$REFERENCE_RPC")" = 0x ] || return 1
  n=$($CAST nonce "$GOV" --rpc-url "$RPC")
  for ((k = n > 80 ? n - 80 : 0; k < n; k++)); do eq "$($CAST compute-address "$GOV" --nonce "$k" | awk '{print $NF}')" "$a" && return 1; done
  return 0
}
LP_CUR=$(jget "$LP_REC" factory)
if is_old_factory "$LP_CUR"; then LP_STATE=pending
elif lp_ready "$LP_CUR"; then LP_STATE=done
elif never_sent "$LP_CUR" && [ -f "$LP_RETIRED_REC" ]; then
  say "deployments/143.json names $LP_CUR, which was never sent (an interrupted simulation) — restoring the 0x10F3 record"
  cp "$LP_RETIRED_REC" "$LP_REC"; LP_CUR=$(jget "$LP_REC" factory); LP_STATE=pending
else die "deployments/143.json names $LP_CUR, which was sent but is not a complete relaunch — the launchpad broadcast was interrupted. Do NOT redeploy: finish it with forge's --resume (the exact command is in the log of the interrupted run, $LP_DIR/deployments/relaunch-*.log), then run this script again"
fi
MOM_CUR=$(jget "$MOM_REC" factory)
if eq "$MOM_CUR" "$COHORT2"; then MOM_STATE=pending
elif mom_ready "$MOM_CUR"; then MOM_STATE=done
elif never_sent "$MOM_CUR" && [ -f "$MOM_RETIRED_REC" ]; then
  say "deployments/moments-143.json names $MOM_CUR, which was never sent (an interrupted simulation) — restoring the cohort-2 record"
  cp "$MOM_RETIRED_REC" "$MOM_REC"; MOM_CUR=$(jget "$MOM_REC" factory); MOM_STATE=pending
else die "deployments/moments-143.json names $MOM_CUR, which was sent but is not a complete cohort 3 — the Moments broadcast was interrupted. Do NOT redeploy: finish it with forge's --resume (the exact command is in the log of the interrupted run), then run this script again"
fi
say "launchpad: $LP_STATE (record: $LP_CUR)   moments: $MOM_STATE (record: $MOM_CUR)"

if [ "$LP_STATE" = pending ]; then
  say "live prices (two sources each; the on-chain one is used):"
  PRICES=$(python3 "$LP_DIR/script/relaunch/prices.py" "$RPC" 2> >(tee -a "$LOG" >&2)) || die "prices unavailable or disagreeing — nothing was sent"
  MON_USD_E8=$(echo "$PRICES" | tail -1 | sed -E 's/.*MON_USD_E8=([0-9]+).*/\1/')
  ABIL_USD_E8=$(echo "$PRICES" | tail -1 | sed -E 's/.*ABIL_USD_E8=([0-9]+).*/\1/')
  [[ "$MON_USD_E8" =~ ^[0-9]+$ && "$ABIL_USD_E8" =~ ^[0-9]+$ ]] || die "could not parse prices: $PRICES"
  say "prices: MON_USD_E8=$MON_USD_E8 ABIL_USD_E8=$ABIL_USD_E8"
  python3 - "$MON_USD_E8" "$ABIL_USD_E8" "$LAUNCH_FDV_USD" <<'EOF' | tee -a "$LOG"
import sys
mon, abil, fdv = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
for sym, dec, p in (("MON", 18, mon), ("aBIL", 18, abil), ("USDC", 6, 10**8), ("AUSD", 6, 10**8)):
    phantom = fdv * 10**dec * 10**8 // p
    thr = phantom * 216_227_766 // 10**8
    print(f"  {sym:<4} @ ${p/1e8:<12.8g} opens at {phantom/10**dec:>14,.4f} {sym} virtual (${fdv:,} FDV), graduates after {thr/10**dec:>14,.4f} {sym} raised ($20,000 FDV)")
EOF
fi

bold "plan"
say "  1. old launchpads: Monday LP fees of ${OLD_VAULTS[*]} → $NEW_FEES"
say "                     protocol fees of ${OLD_FACTORIES[*]} → $NEW_TREASURY"
say "                     then harvest the old graduated Monday position's accrued LP fees to $NEW_FEES"
say "  2. new launchpad:  $([ "$LP_STATE" = done ] && echo "already deployed ($LP_CUR) — skipped" || echo "deploy (owner $GOV, treasury $NEW_TREASURY, fees $NEW_FEES, launch fee 5 MON, share 50%)")"
say "  3. old launchpads: closed to new launches (whitelist on, config 0 off) — existing launches keep trading"
say "  4. Moments:        $([ "$MOM_STATE" = done ] && echo "cohort 3 already deployed ($MOM_CUR) — skipped" || echo "deploy cohort 3 (platform $NEW_FEES, treasury $NEW_TREASURY, threshold $THRESHOLD_USDC)")"
say "  5. Moments:        base URI $BASE on cohort 3; pause publishing on cohort 2 $COHORT2"
say "  6. Sourcify verification   7. read-back of everything"
[ "$MODE" = dry ] || confirm "Proceed? (step 2 and step 4 each simulate first and ask again before deploying)"

# ---------------------------------------------------------------- 1. repoint the old launchpads' fees
bold "1. old launchpads → new wallets"
for v in "${OLD_VAULTS[@]}"; do
  cur=$(call "$v" 'lpFeeRecipient()(address)')
  if eq "$cur" "$NEW_FEES"; then say "   $v LP fees already → new fees wallet"
  else send "setLpFeeRecipient($NEW_FEES) on $v (was $cur)" "$v" 'setLpFeeRecipient(address)' "$NEW_FEES"; fi
done
for f in "${OLD_FACTORIES[@]}"; do
  cur=$(call "$f" 'protocolFeeRecipient()(address)'); share=$(call "$f" 'protocolFeeShareBps()(uint16)' | first)
  [ "$share" = "$PROTOCOL_FEE_SHARE_BPS" ] || die "old factory $f has share $share bps, expected $PROTOCOL_FEE_SHARE_BPS — stopping rather than guessing"
  if eq "$cur" "$NEW_TREASURY"; then say "   $f protocol fees already → new treasury"
  else send "setFeePolicy($NEW_TREASURY, $share) on $f (was $cur)" "$f" 'setFeePolicy(address,uint16)' "$NEW_TREASURY" "$share"; fi
done
# Harvest what the old Monday positions have accrued, now that it can only land on the new fees wallet.
for hv in "${HARVEST[@]}"; do
  v=${hv%%:*}; pool=${hv##*:}
  owed=$($CAST call "$v" 'collectFees(address)(uint128,uint128)' "$pool" --from "$GOV" --rpc-url "$RPC" 2>/dev/null | first | tr '\n' ' ')
  if [ "$owed" = "0 0 " ] || [ -z "$owed" ]; then say "   $v has nothing to harvest in $pool"; continue; fi
  if [ "$MODE" != dry ] && ! eq "$(call "$v" 'lpFeeRecipient()(address)')" "$NEW_FEES"; then die "refusing to harvest $v: its recipient is not the new fees wallet"; fi
  send "collectFees($pool) on $v → $NEW_FEES (owed: $owed)" "$v" 'collectFees(address)' "$pool"
done

# ---------------------------------------------------------------- 2. the new launchpad
bold "2. new launchpad"
lp_env=(POOL_MANAGER=0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e PROTOCOL_FEE_RECIPIENT=$NEW_TREASURY FEES=$NEW_FEES
  LAUNCH_FEE_WEI=$LAUNCH_FEE_WEI PROTOCOL_FEE_SHARE_BPS=$PROTOCOL_FEE_SHARE_BPS MAX_CREATOR_TAX_BPS=$MAX_CREATOR_TAX_BPS
  SUPPLY=1000000000000000000000000000 CURVE_FEE_BPS=100 POOL_FEE_BPS=100 TICK_SPACING=60 LAUNCH_FDV_USD=$LAUNCH_FDV_USD
  MONDAY_FACTORY=0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21 WMON=0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A
  USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603 AUSD=0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a
  ABIL=0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f MON_USD_E8=${MON_USD_E8:-0} ABIL_USD_E8=${ABIL_USD_E8:-0})
if [ "$LP_STATE" = done ]; then
  say "   already deployed: $LP_CUR"
else
  [ -f "$LP_RETIRED_REC" ] || cp "$LP_REC" "$LP_RETIRED_REC"
  cp "$LP_REC" "$TMP/143.json"; RESTORE_LP=1
  say "   simulating (no transactions)…"
  sim_rc=0
  ( cd "$LP_DIR" && env "${lp_env[@]}" $FORGE script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --non-interactive --code-size-limit 200000 --sender "$GOV" 2>&1 ) \
    | scrub > "$TMP/lpsim.out" || sim_rc=$?
  grep -E '^  (factory|hook|v4Executor|mondayExecutor|router) |Estimated|Error|error|revert' "$TMP/lpsim.out" | tee -a "$LOG" || true
  SIM_FACTORY=$(jget "$LP_REC" factory 2>/dev/null || echo none)
  cp "$TMP/143.json" "$LP_REC"; RESTORE_LP=0   # the simulation writes the record too; keep the live one until the real run
  [ "$sim_rc" = 0 ] || { tail -25 "$TMP/lpsim.out" | tee -a "$LOG"; die "the launchpad simulation failed (exit $sim_rc) — nothing was deployed"; }
  say "   deploy env (public values; reuse them verbatim for a forge --resume): ${lp_env[*]}"
  { is_old_factory "$SIM_FACTORY" || [ "$SIM_FACTORY" = none ]; } && die "the launchpad simulation did not produce a new factory — see $LOG"
  if [ "$MODE" = dry ]; then say "   DRY_RUN: would deploy the launchpad (indicative address $SIM_FACTORY — the real run lands later in the governance nonce sequence and prints the final one before asking)"
  else
    confirm "Deploy the new launchpad (factory $SIM_FACTORY) from $GOV now?"
    say "   deploying (18 transactions)…"
    ( cd "$LP_DIR" && env "${lp_env[@]}" $FORGE script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast --slow --non-interactive --code-size-limit 200000 --sender "$GOV" ${FORGE_SIGN[@]+"${FORGE_SIGN[@]}"} 2>&1 ) \
      | scrub | tee "$TMP/lp.out" | tee -a "$LOG" | grep -E 'factory|hook|Executor|router|ONCHAIN|Error|error' || true
    grep -q 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL' "$TMP/lp.out" || die "the launchpad broadcast did not complete. Do NOT redeploy. Finish it: cd $LP_DIR && env <the deploy env printed above> ~/.foundry/bin/forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast --resume --slow --non-interactive --code-size-limit 200000 --sender $GOV --private-key \$PRIVATE_KEY (or --ledger) — then run this script again"
    LP_CUR=$(jget "$LP_REC" factory)
    eq "$LP_CUR" "$SIM_FACTORY" || say "   note: landed at $LP_CUR (the simulation predicted $SIM_FACTORY — the governance nonce moved in between)"
    lp_ready "$LP_CUR" || die "the new factory $LP_CUR does not read back as fully configured — stopping before touching the old factories"
    say "   new launchpad live: factory $LP_CUR"
  fi
fi

# ---------------------------------------------------------------- 3. close the old launchpads to new launches
bold "3. old launchpads → closed to new launches"
if [ "$MODE" != dry ] && ! lp_ready "$(jget "$LP_REC" factory)"; then die "no live new launchpad — refusing to close the old ones"; fi
for f in "${OLD_FACTORIES[@]}"; do
  if [ "$(call "$f" 'whitelistEnabled()(bool)')" = true ]; then say "   $f whitelist already on"
  else send "setWhitelistEnabled(true) on $f" "$f" 'setWhitelistEnabled(bool)' true; fi
  en=$(call "$f" 'getLaunchConfig(uint256)((uint256,uint16,uint16,int24,uint16[],bool))' 0 | sed -E 's/.*, (true|false)\)$/\1/')
  if [ "$en" = false ]; then say "   $f launch config 0 already off"
  else send "setLaunchConfigEnabled(0, false) on $f" "$f" 'setLaunchConfigEnabled(uint256,bool)' 0 false; fi
done

# ---------------------------------------------------------------- 4. Moments cohort 3
bold "4. Moments cohort 3"
mom_env=(POOL_MANAGER=0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
  PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3 GOVERNANCE=$GOV PLATFORM=$NEW_FEES TREASURY=$NEW_TREASURY
  THRESHOLD_USDC=$THRESHOLD_USDC MIN_PRICE_USDC=100000 CREATOR_BPS=2000 PLATFORM_BPS=500 RESERVE_BPS=7500
  MAX_CREATOR_ALLOC_BPS=1000 EXPIRY_CREATOR_BPS=7000 ROYALTY_BPS=500)
if [ "$MOM_STATE" = done ]; then
  say "   already deployed: $MOM_CUR"
else
  [ -f "$MOM_RETIRED_REC" ] || cp "$MOM_REC" "$MOM_RETIRED_REC"
  cp "$MOM_REC" "$TMP/moments-143.json"; RESTORE_MOM=1
  say "   simulating (no transactions)…"
  sim_rc=0
  ( cd "$MOM_DIR" && env "${mom_env[@]}" $FORGE script script/moments/Deploy.s.sol:DeployMoments --rpc-url "$RPC" --non-interactive --code-size-limit 200000 --sender "$GOV" 2>&1 ) \
    | scrub > "$TMP/momsim.out" || sim_rc=$?
  grep -E '^  (factory|collect|vesting|graduation|locker|hook|buyback) |Estimated|Error|error|revert' "$TMP/momsim.out" | tee -a "$LOG" || true
  SIM_MOM=$(jget "$MOM_REC" factory 2>/dev/null || echo none)
  cp "$TMP/moments-143.json" "$MOM_REC"; RESTORE_MOM=0
  [ "$sim_rc" = 0 ] || { tail -25 "$TMP/momsim.out" | tee -a "$LOG"; die "the Moments simulation failed (exit $sim_rc) — nothing was deployed"; }
  say "   deploy env (public values; reuse them verbatim for a forge --resume): ${mom_env[*]}"
  { eq "$SIM_MOM" "$COHORT2" || [ "$SIM_MOM" = none ]; } && die "the Moments simulation did not produce a new factory — see $LOG"
  if [ "$MODE" = dry ]; then say "   DRY_RUN: would deploy Moments cohort 3 (indicative address $SIM_MOM — the real run prints the final one before asking)"
  else
    confirm "Deploy Moments cohort 3 (factory $SIM_MOM) from $GOV now?"
    say "   deploying (8 transactions)…"
    ( cd "$MOM_DIR" && env "${mom_env[@]}" $FORGE script script/moments/Deploy.s.sol:DeployMoments --rpc-url "$RPC" --broadcast --slow --non-interactive --code-size-limit 200000 --sender "$GOV" ${FORGE_SIGN[@]+"${FORGE_SIGN[@]}"} 2>&1 ) \
      | scrub | tee "$TMP/mom.out" | tee -a "$LOG" | grep -E 'factory|collect|vesting|graduation|locker|hook|buyback|ONCHAIN|Error|error' || true
    grep -q 'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL' "$TMP/mom.out" || die "the Moments broadcast did not complete. Do NOT redeploy. Finish it: cd $MOM_DIR && env <the deploy env printed above> ~/.foundry/bin/forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url $RPC --broadcast --resume --slow --non-interactive --code-size-limit 200000 --sender $GOV --private-key \$PRIVATE_KEY (or --ledger) — then run this script again"
    MOM_CUR=$(jget "$MOM_REC" factory)
    mom_ready "$MOM_CUR" || die "the cohort-3 factory $MOM_CUR does not read back as wired with the new wallets"
    say "   Moments cohort 3 live: factory $MOM_CUR"
  fi
fi

# ---------------------------------------------------------------- 5. metadata base + retire cohort 2
bold "5. Moments metadata base + retire cohort 2"
if [ "$MODE" = dry ] && [ "$MOM_STATE" = pending ]; then
  say "   would send: setExternalBaseURI($BASE) on the new cohort-3 factory"
else
  MOM_CUR=$(jget "$MOM_REC" factory)
  if [ "$(call "$MOM_CUR" 'externalBaseURI()(string)')" = "\"$BASE\"" ]; then say "   base URI already set on $MOM_CUR"
  else send "setExternalBaseURI($BASE) on $MOM_CUR" "$MOM_CUR" 'setExternalBaseURI(string)' "$BASE"; fi
fi
if [ "$MODE" != dry ] && ! mom_ready "$(jget "$MOM_REC" factory)"; then die "no live cohort 3 — refusing to pause cohort 2"; fi
for m in "$COHORT2" "$COHORT1" "$COHORT0"; do
  if [ "$(call "$m" 'publishingPaused()(bool)')" = true ]; then say "   $m publishing already paused"
  else send "setPublishingPaused(true) on $m" "$m" 'setPublishingPaused(bool)' true; fi
done

if [ "$MODE" = dry ]; then bold "DRY_RUN complete — nothing was sent. Run without DRY_RUN=1 to execute."; exit 0; fi

# ---------------------------------------------------------------- 6. Sourcify
bold "6. Sourcify verification (no key)"
if [ "$MODE" = fork ]; then say "   skipped on a fork"
else
  ( cd "$LP_DIR" && ./script/verify-143.sh 2>&1 ) | grep -E '^==|verified|already|failed|!!' | tee -a "$LOG" || true
  ( cd "$MOM_DIR" && ./script/moments/verify-moments-143.sh 2>&1 ) | grep -E '^==|verified|already|failed|!!' | tee -a "$LOG" || true
fi

# ---------------------------------------------------------------- 7. read-back
bold "7. read-back from the chain"
FAIL=0
check() { local label=$1; shift; if "$@"; then say "   PASS  $label"; else say "   FAIL  $label"; FAIL=$((FAIL + 1)); fi; }
LP=$(jget "$LP_REC" factory); VAULT=$(jget "$LP_REC" feeVault); MF=$(jget "$MOM_REC" factory)
new_lp_open() { [ "$(call "$LP" 'whitelistEnabled()(bool)')" = false ]; }
new_vault_ok() { eq "$(call "$VAULT" 'lpFeeRecipient()(address)')" "$NEW_FEES" && eq "$(call "$VAULT" 'owner()(address)')" "$GOV"; }
old_factory_ok() {
  eq "$(call "$1" 'protocolFeeRecipient()(address)')" "$NEW_TREASURY" && [ "$(call "$1" 'whitelistEnabled()(bool)')" = true ] \
    && call "$1" 'getLaunchConfig(uint256)((uint256,uint16,uint16,int24,uint16[],bool))' 0 | grep -q 'false)$'
}
old_vault_ok() { eq "$(call "$1" 'lpFeeRecipient()(address)')" "$NEW_FEES"; }
new_lp_economics() {
  [ "$(call "$LP" 'protocolFeeShareBps()(uint16)')" = "$PROTOCOL_FEE_SHARE_BPS" ] && [ "$(call "$LP" 'maxCreatorTaxBps()(uint16)')" = "$MAX_CREATOR_TAX_BPS" ] || return 1
  [ "$(call "$LP" 'getLaunchConfig(uint256)((uint256,uint16,uint16,int24,uint16[],bool))' 0)" = "(1000000000000000000000000000 [1e27], 100, 100, 60, [9800, 2500, 300, 30], true)" ] || return 1
  [ "$(call "$LP" 'launchConfigCount()(uint256)' | first)" = 1 ] || return 1
  local rows="" t
  for t in 0x0000000000000000000000000000000000000000 0x754704Bc059F8C67012fEd69BC8A327a5aafb603 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a 0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f; do
    rows="$rows$t $(call "$LP" 'pairTokenEconomics(address)(uint256,uint256,uint8,bool)' "$t" | first | tr '\n' ' ')$(call "$LP" 'pairMondayOnly(address)(bool)' "$t");"
  done
  python3 - "$rows" "${MON_USD_E8:-0}" "${ABIL_USD_E8:-0}" "$LAUNCH_FDV_USD" <<'PY'
import sys
rows = [r.split() for r in sys.argv[1].split(";") if r.strip()]
mon, abil, fdv = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
# address -> (decimals, USD price * 1e8 or 0 when this run did not fetch it, Monday-only)
expect = {"0x0000000000000000000000000000000000000000": (18, mon, False), "0x754704bc059f8c67012fed69bc8a327a5aafb603": (6, 10**8, False),
          "0x00000000efe302beaa2b3e6e1b18d08d69a9012a": (6, 10**8, False), "0x4fc5b9f8933597d3ecf84d0611687e1dc8dd576f": (18, abil, True)}
ok = len(rows) == 4
for addr, phantom, threshold, dec, approved, monday in rows:
    d, price, monday_only = expect[addr.lower()]
    phantom, threshold = int(phantom), int(threshold)
    good = approved == "true" and int(dec) == d and threshold == phantom * 216_227_766 // 10**8 and (monday == "true") == monday_only
    if price:
        good = good and phantom == fdv * 10**d * 10**8 // price
    if not good:
        print(f"     !! pair {addr}: phantom {phantom} threshold {threshold} decimals {dec} approved {approved} mondayOnly {monday}")
    ok = ok and good
sys.exit(0 if ok else 1)
PY
}
mom_policy_exact() {
  [ "$(call "$MF" 'policy()(uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,address,address)' | first | tr '\n' ' ' | tr 'A-F' 'a-f')" \
    = "$(lc "$THRESHOLD_USDC 100000 2000 500 7500 1000 7000 500 $NEW_FEES $NEW_TREASURY ")" ]
}
mom_open_with_base() { [ "$(call "$MF" 'publishingPaused()(bool)')" = false ] && [ "$(call "$MF" 'externalBaseURI()(string)')" = "\"$BASE\"" ]; }
old_cohorts_paused() { local m; for m in "$COHORT0" "$COHORT1" "$COHORT2"; do [ "$(call "$m" 'publishingPaused()(bool)')" = true ] || return 1; done; }
check "new launchpad $LP: owned by governance, fees → $NEW_TREASURY, 5 MON, aBIL Monday-only" lp_ready "$LP"
check "new launchpad economics: 50% share, 10% creator-tax cap, launch config, all 4 pairs at \$2,000 → \$20,000 FDV" new_lp_economics
check "new launchpad open to every creator" new_lp_open
check "new Monday fee vault $VAULT pays $NEW_FEES, owned by governance" new_vault_ok
for f in "${OLD_FACTORIES[@]}"; do check "old factory $f: fees → new treasury, closed to new launches" old_factory_ok "$f"; done
for v in "${OLD_VAULTS[@]}"; do check "old vault $v: LP fees → new fees wallet" old_vault_ok "$v"; done
check "Moments cohort 3 $MF: governance, platform $NEW_FEES, treasury $NEW_TREASURY, threshold $THRESHOLD_USDC" mom_ready "$MF"
check "Moments cohort 3 full policy (threshold, \$0.10 min price, 20/5/75 split, 10% alloc cap, 70% expiry, 5% royalty, wallets)" mom_policy_exact
check "Moments cohort 3 open, base URI $BASE" mom_open_with_base
check "old Moments factories (v1, cohorts 1 and 2) paused" old_cohorts_paused
say "   same code as the stacks they replace (every byte, after swapping each stack's own addresses):"
if python3 "$LP_DIR/script/relaunch/parity.py" "$RPC" "$LP_RETIRED_REC" "$LP_REC" factory escrow holderFeeSharing locker hook graduationExecutor mondayExecutor launchAndBuyRouter launchDeployer feeVault 2>&1 | tee -a "$LOG" \
  && python3 "$LP_DIR/script/relaunch/parity.py" "$RPC" "$MOM_RETIRED_REC" "$MOM_REC" factory collect vesting graduation locker hook buyback 2>&1 | tee -a "$LOG"; then
  say "   PASS  byte-identical code"
else say "   FAIL  code differs from the live stacks"; FAIL=$((FAIL + 1)); fi

bold "new addresses"
python3 - "$LP_REC" "$LP_DIR/broadcast/Deploy.s.sol/143/run-latest.json" "$MOM_REC" "$MOM_DIR/broadcast/Deploy.s.sol/143/run-latest.json" <<'EOF' | tee -a "$LOG"
import json, sys
def block(run, addr):
    try:
        r = json.load(open(run))
        return next((int(x["blockNumber"], 16) for x in r.get("receipts", []) if (x.get("contractAddress") or "").lower() == addr.lower()), None)
    except Exception:
        return None
lp = json.load(open(sys.argv[1])); mo = json.load(open(sys.argv[3]))
print("  launchpad (deployments/143.json):")
for k in ["factory", "launchAndBuyRouter", "escrow", "holderFeeSharing", "hook", "locker", "graduationExecutor", "mondayExecutor", "feeVault", "launchDeployer"]:
    print(f"    {k:<19} {lp[k]}")
print(f"    deployBlock         {block(sys.argv[2], lp['factory'])}")
print("  Moments cohort 3 (deployments/moments-143.json):")
for k in ["factory", "collect", "vesting", "graduation", "locker", "hook", "buyback"]:
    print(f"    {k:<19} {mo[k]}")
print(f"    deployBlock         {block(sys.argv[4], mo['factory'])}")
EOF
say "transactions sent by this run (besides the two deploys): $SENT"
[ "$FAIL" = 0 ] || die "$FAIL read-back check(s) failed — see above and $LOG"
say "note: the two oldest escrows (0x1253…, 0xeDC7…) credit rather than push — the new treasury claims its fees there with claim()."
bold "done — everything reads back correctly. Tell Claude: \"relaunch done\" so it wires the app to these addresses."
say "log: $LOG"
