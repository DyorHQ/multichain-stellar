#!/usr/bin/env bash
# Deploys the v2 contracts (DyorHQ/internal: ios-app/contracts/CHANGELOG-v2.md) on Monad mainnet: a new Launchpad stack and a new Moments cohort.
# Security audit 2026-09-26: it signs only on a Ledger (LEDGER=1) or with an encrypted Foundry keystore (ACCOUNT=name),
# never with a raw key (SEC-1); every money role and price is explicit (LP-7); and it never writes a live deployment
# record (RO-7): the new records land in deployments/pending-*.json and are promoted by hand after verification.
# The previous launchpad (0x6B1C…) and Moments cohort 3 (0x0FD4…) stay as they are on chain; the app retires them
# (owner decision 2026-09-28).
#
#   cd contracts
#   GOV=0x… OWNER=<Safe> GOVERNANCE=<Safe> TREASURY=0x… FEES=0x… GUARDIAN=0x… LAUNCH_FEE_WEI=… THRESHOLD_USDC=… \
#     EXTERNAL_BASE_URI=https://dyorhq.fun/moments/c4/ ACCOUNT=<keystore> script/deploy-v2.sh
#
#   GOV            the signer (a fresh single-use keystore or a hardware wallet), which hands the new stacks to:
#   OWNER          launchpad owner to hand over to (a Safe; it must call acceptOwnership())              [required]
#   GOVERNANCE     Moments governance to hand over to (a Safe; it must call acceptGovernance())          [required]
#                  (DRY_RUN/FORK default both to GOV; a live run refuses GOV unless NO_HANDOVER=1)
#   TREASURY       launchpad protocol fees + Moments treasury (expiry share)                             [required]
#   FEES           Monday LP fees (launchpad) + Moments platform share                                   [required]
#   GUARDIAN       Moments guardian: can cancel a pending policy and pause publishing (a different key)  [required]
#   LAUNCH_FEE_WEI launch fee in wei (the live stack charges 5 MON = 5000000000000000000)                  [required]
#   THRESHOLD_USDC Moments graduation threshold in USDC units (cohort 3: 771428571)                        [required]
#   EXTERNAL_BASE_URI  the new Moments' link base: exactly https://dyorhq.fun/moments/c4/, the only one build 16
#                  publishes under (the bare …/moments/ is cohort 3's, …/c1/ and …/c2/ cohorts 1 and 2's) [required]
#   LEDGER=1 | ACCOUNT=<keystore name>   how to sign (exactly one)
#   DRY_RUN=1      pre-flight, live prices and both simulations; sends nothing (no signer needed)
#   FORK=1         rehearsal on a local anvil fork (RPC=http://127.0.0.1:<port>, started with --auto-impersonate and
#                  --disable-code-size-limit, since LaunchpadFactory is above Ethereum's 24 KB limit; fund GOV first:
#                  cast rpc anvil_setBalance $GOV 0x3635C9ADC5DEA00000 --rpc-url $RPC);
#                  signs with --unlocked as GOV; every file the run writes is restored on exit
#   RPC            the RPC it deploys through [default https://rpc3.monad.xyz]; chain 143 is also checked on rpc1
#   ONLY=launchpad | moments   deploy one stack only
#   YES=1          no confirmation prompts
#   MIN_BALANCE_MON  the MON GOV must hold [default 15]
#   ALLOW_SCRIPT_OVERRIDES=1   let the Deploy scripts read their other knobs from this environment (see step 0)
#   NO_HANDOVER=1  a live run whose OWNER / GOVERNANCE is GOV itself (the stacks stay with GOV): on purpose only
#
# Steps, stopping at the first failure:
#   0. pre-flight. It refuses: a contracts/.env (forge and cast load it); a raw key or ALLOW_RAW_KEY_143 in the
#      environment; any other variable the Deploy scripts read (POOL_MANAGER, USDC, MIN_PRICE_USDC, …: the names come
#      from their sources) set in this environment, unless ALLOW_SCRIPT_OVERRIDES=1; an EXTERNAL_BASE_URI other than
#      https://dyorhq.fun/moments/c4/; an OWNER or GOVERNANCE set but empty, or on a LEDGER/ACCOUNT run unset or GOV
#      (unless NO_HANDOVER=1); roles that are not distinct; an OWNER or GOVERNANCE other than GOV that is not a Safe
#      (code, a threshold of at least 2, and none of GOV, GUARDIAN, TREASURY or FEES among its owners); an RPC that is
#      not chain 143; a full run (ONLY unset) signed by LEDGER/ACCOUNT from a GOV whose nonce is not 0 (printing the
#      ONLY=moments run when the launchpad in deployments/pending-143.json has finished); an ONLY=moments LEDGER/ACCOUNT
#      run from a GOV whose nonce is not 0 while that launchpad has not finished, or once the Moments factory in
#      deployments/pending-moments-143.json has code; a balance under MIN_BALANCE_MON.
#   1. live MON/aBIL prices from two sources (script/relaunch/prices.py)
#   2. launchpad: simulate, confirm, broadcast (the modules are sealed in the same run)
#   3. Moments: simulate, confirm, broadcast
#   4. the follow-ups: the Safe accepts both handovers in one batch, Sourcify, then the records are promoted and the
#      app and keepers wired in one change.
# A broadcast that stops midway (an error, or Ctrl-C) is finished with forge's --resume, never by running this script
# again (it reads no arguments, so a rerun deploys a whole new stack): it then prints the exact commands, with this run's
# values. Once the launchpad stack has landed, any exit before the Moments broadcast prints the ONLY=moments run that
# follows it.
set -euo pipefail
umask 077
# forge/cast honour FOUNDRY_* (compiler config), ETH_* (sender, keystore, rpc), CAST_* and DAPP_*: none may leak in.
for v in $(env | grep -oE '^(FOUNDRY|DAPP|ETH|CAST)_[A-Za-z0-9_]*=' || true); do unset "${v%=}"; done

cd "$(dirname "$0")/.." # contracts/
CONTRACTS=$(pwd -P)
FORGE=~/.foundry/bin/forge
CAST=~/.foundry/bin/cast
DEFAULT_RPC=https://rpc3.monad.xyz
RPC=${RPC:-$DEFAULT_RPC}
REFERENCE_RPC=https://rpc1.monad.xyz
MIN_BALANCE_MON=${MIN_BALANCE_MON:-15}
LAUNCHPAD_TARGET=script/Deploy.s.sol:Deploy
MOMENTS_TARGET=script/moments/Deploy.s.sol:DeployMoments
SNAP=$(mktemp -d)
cp -R deployments "$SNAP/deployments"
for d in broadcast cache; do if [ -d "$d" ]; then cp -R "$d" "$SNAP/$d"; fi; done
cleanup() {
  # The launchpad stack landed and the Moments broadcast never began (its simulation failed, its prompt was declined, the
  # run was stopped): the one way on is ONLY=moments, whatever made this run exit.
  if [ "${LAUNCHPAD_DONE:-}" = 1 ] && [ "${BEGUN:-}" != "$MOMENTS_TARGET" ] && [ -z "${ONLY:-}" ]; then moments_next || true; fi
  # FORK rehearsals leave nothing behind (records, broadcast logs, script caches); a real run keeps its
  # pending-*.json records and broadcast logs.
  if [ "${FORK:-0}" = 1 ]; then
    rm -rf deployments && cp -R "$SNAP/deployments" deployments
    for d in broadcast cache; do
      rm -rf "$d"
      if [ -d "$SNAP/$d" ]; then cp -R "$SNAP/$d" "$d"; fi
    done
  fi
  rm -rf "$SNAP"
}
trap cleanup EXIT
# Ctrl-C reaches forge and this script together. While forge broadcasts, the signal is held until forge returns, so the
# commands that finish its broadcast are still printed; at any other time it stops the run (and cleanup still runs).
IN_FLIGHT=
INTERRUPTED=0
on_signal() { if [ -n "$IN_FLIGHT" ]; then INTERRUPTED=$1; else exit "$1"; fi; }
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

say() { printf '%s\n' "$*"; }
bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m!! %s\033[0m\n' "$1" >&2; exit "${2:-1}"; } # <message> [exit code]
confirm() { [ "${YES:-0}" = 1 ] && return 0; local a; read -r -p "$1 [y/N] " a || a=; [ "$a" = y ] || [ "$a" = Y ] || die "stopped: nothing further was sent"; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
need() { [ -n "${!1:-}" ] || die "$1 must be set (see the header of this script)"; }
isaddr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$2 is not an address: $1"; }
env_names() { local a out=; for a in "$@"; do out="$out ${a%%=*}"; done; printf '%s' "${out# }"; }

# The RPC as a printed command may show it: a public Monad RPC or a local fork verbatim. Any other URL may carry a key,
# so it stays "$RPC", to be set in the shell that runs the command.
rpc_word() {
  case "$RPC" in
    https://rpc.monad.xyz | https://rpc[0-9].monad.xyz | http://127.0.0.1:* | http://localhost:*) printf '%s' "$RPC" ;;
    *) printf '%s' '"$RPC"' ;;
  esac
}

# The variables a Deploy script reads, from its source and MainnetGuard's: vm.env*("X") and _addr/_uint("X").
script_knobs() { grep -hoE '(vm\.env[A-Za-z]*|_addr|_uint)\("[A-Z][A-Z0-9_]*"' "$@" | sed -E 's/.*\("//; s/"$//' | sort -u; }

# Adds to STRAY every variable the stack's script reads, other than the ones this script passes it, that is set here.
# The scripts fall back to their defaults only when such a knob is unset, so a stray one (say MIN_PRICE_USDC) would
# silently change the deploy. Only names are collected, never values.
STRAY=
stray_knobs() { # <stack> <names this script passes it> <its sources...>
  local stack=$1 passes=$2 knobs v
  shift 2
  knobs=" $(script_knobs "$@" | tr '\n' ' ' || true) "
  for v in $passes; do
    case "$knobs" in *" $v "*) ;; *) die "the $stack script does not read $v (or its knobs could not be read from $*): check this script against it" ;; esac
  done
  for v in $knobs; do
    case " $passes $STRAY " in *" $v "*) continue ;; esac
    if [ -n "${!v+set}" ]; then STRAY="${STRAY:+$STRAY }$v"; fi
  done
}

# OWNER and GOVERNANCE, when they are not GOV, receive the new stacks: each must be a Safe (code, getThreshold() of at
# least 2) that none of this deploy's keys or money roles signs for. A fork of mainnet has the Safe too.
check_safe() { # <role> <address>
  local role=$1 safe=$2 code threshold raw o x count=0
  code=$($CAST code "$safe" --rpc-url "$RPC") || die "$role $safe: its code could not be read"
  [ -n "$code" ] && [ "$code" != 0x ] || die "$role $safe has no code: the stacks go to the owner's Safe, never to a plain address"
  threshold=$($CAST call "$safe" 'getThreshold()(uint256)' --rpc-url "$RPC" 2>/dev/null) || die "$role $safe: getThreshold() could not be read; it is not a Safe"
  raw=$($CAST call "$safe" 'getOwners()(address[])' --rpc-url "$RPC" 2>/dev/null) || die "$role $safe: getOwners() could not be read; it is not a Safe"
  threshold=${threshold%% *}
  [[ "$threshold" =~ ^[0-9]+$ ]] && [ "$threshold" -ge 2 ] || die "$role $safe has a threshold of $threshold: the Safe that owns a stack needs at least 2 signatures"
  for o in $(printf '%s' "$raw" | tr -d '[]' | tr ',' ' ' | tr 'A-F' 'a-f'); do
    [[ "$o" =~ ^0x[0-9a-f]{40}$ ]] || die "$role $safe: getOwners() did not return a list of addresses"
    count=$((count + 1))
    for x in GOV GUARDIAN TREASURY FEES; do
      [ "$o" != "$(lc "${!x}")" ] || die "$role $safe has $x ${!x} among its owners: none of this deploy's keys or money roles may sign for it"
    done
  done
  [ "$count" -ge "$threshold" ] || die "$role $safe: $count owners for a threshold of $threshold"
  say "$role $safe: a Safe, threshold $threshold of $count owners (none of them GOV, GUARDIAN, TREASURY or FEES)"
}

# A record's factory (nothing when the file is missing).
record_factory() { if [ -f "$1" ]; then python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["factory"])' "$1"; fi; }

# Whether a launchpad stack has finished. --slow sends each transaction once the one before it is mined, so the last
# one proves the rest: sealModules(), then transferOwnership(OWNER) (a handover the Safe has accepted since counts too).
# The factory having code proves only the first.
read_chain() { $CAST call "$1" "$2" --rpc-url "$RPC" 2>/dev/null; }
launchpad_finished() { # <factory>
  local owner pending
  [ "$(read_chain "$1" 'modulesSealed()(bool)')" = true ] || return 1
  owner=$(read_chain "$1" 'owner()(address)') || return 1
  [ "$(lc "$owner")" != "$(lc "$OWNER")" ] || return 0
  pending=$(read_chain "$1" 'pendingOwner()(address)') || return 1
  [ "$(lc "$owner")" = "$(lc "$GOV")" ] && [ "$(lc "$pending")" = "$(lc "$OWNER")" ]
}

# How many transactions the simulation just planned, from forge's newest dry-run log (both Deploy scripts log to
# broadcast/Deploy.s.sol/143/); nothing when it cannot be read.
planned_txs() { python3 -c 'import glob, json; logs = sorted(glob.glob("broadcast/Deploy.s.sol/143/dry-run/run-[0-9]*.json")); print(len(json.load(open(logs[-1]))["transactions"]))' 2>/dev/null || true; }

# Whether the Moments stack of an earlier run is on chain: its record names a factory with code. Unreadable refuses.
moments_sent() {
  local f code
  f=$(record_factory deployments/pending-moments-143.json 2>/dev/null) || return 1
  [ -n "$f" ] || return 1
  code=$($CAST code "$f" --rpc-url "$RPC" 2>/dev/null) || die "cannot read the code at $f (deployments/pending-moments-143.json)"
  [ -n "$code" ] && [ "$code" != 0x ]
}

# The ONLY=moments run that follows this run's launchpad stack, value for value.
only_moments_command() {
  local signer="LEDGER=1" extra=
  case "$MODE" in account) signer="ACCOUNT=$(printf '%q' "$ACCOUNT")" ;; fork) signer="FORK=1" ;; esac
  [ "$RPC" = "$DEFAULT_RPC" ] || extra=" RPC=$(rpc_word)"
  [ "${NO_HANDOVER:-0}" != 1 ] || extra="$extra NO_HANDOVER=1"
  say "  cd $(printf '%q' "$CONTRACTS") && ONLY=moments $signer GOV=$GOV OWNER=$OWNER GOVERNANCE=$GOVERNANCE \\"
  say "    TREASURY=$TREASURY FEES=$FEES GUARDIAN=$GUARDIAN LAUNCH_FEE_WEI=$LAUNCH_FEE_WEI THRESHOLD_USDC=$THRESHOLD_USDC \\"
  say "    EXTERNAL_BASE_URI=$(printf '%q' "$EXTERNAL_BASE_URI")$extra script/deploy-v2.sh"
}

# Printed on exit once the launchpad stack has landed and the Moments broadcast never began (see cleanup).
moments_next() {
  bold "The launchpad stack is on chain; the Moments stack was not sent"
  say "Do NOT run the full command again: it would deploy a second launchpad (a LEDGER/ACCOUNT run refuses GOV's nonce"
  say "now). Send nothing else from GOV $GOV."
  say "Deploy the Moments stack alone, in a clean shell (add MIN_BALANCE_MON=8 if GOV now holds under $MIN_BALANCE_MON MON; the"
  say "Moments stack costs about 3):"
  only_moments_command
  if [ -n "$STRAY" ]; then say "(this run also read $STRAY from the environment: set each again, to the same value)"; fi
  if [ "$(rpc_word)" != "$RPC" ]; then say "(set RPC to the RPC this run used: it is not printed, since it may carry a key)"; fi
}

# ---------------------------------------------------------------- 0. pre-flight
bold "0. pre-flight"
# forge and cast load contracts/.env into their own environment, past every check below. Its existence is tested,
# never its content.
if [ -e .env ] || [ -L .env ]; then
  die "contracts/.env exists, and forge and cast would load it: move it out of contracts/ for the deploy"
fi
for v in PRIVATE_KEY TREASURY_KEY OWNER_KEY DEPLOYER_PRIVATE_KEY ETH_PRIVATE_KEY; do
  [ -z "${!v:-}" ] || die "$v is set: unset it. This script signs only with LEDGER=1 or ACCOUNT=<keystore> (SEC-1)."
done
[ -z "${ALLOW_RAW_KEY_143+set}" ] || die "ALLOW_RAW_KEY_143 is set: unset it. This script never signs with a raw key, so the scripts' raw-key refusal stays on (SEC-1)."
for v in GOV TREASURY FEES GUARDIAN LAUNCH_FEE_WEI THRESHOLD_USDC EXTERNAL_BASE_URI; do need "$v"; done
case "${ONLY:-}" in "" | launchpad | moments) ;; *) die "ONLY must be launchpad or moments (unset: both), got: $ONLY" ;; esac
RPC_SHOWN=$(rpc_word)
[ "$RPC_SHOWN" = "$RPC" ] || RPC_SHOWN="a custom one (not printed: it may carry a key)"
SIGN=()
if [ "${DRY_RUN:-0}" = 1 ]; then
  MODE=dry
elif [ "${FORK:-0}" = 1 ]; then
  case "$RPC" in http://127.0.0.1:* | http://localhost:*) ;; *) die "FORK=1 needs RPC=http://127.0.0.1:<port> (a local anvil fork), got $RPC_SHOWN" ;; esac
  MODE=fork
  SIGN=(--unlocked)
elif [ "${LEDGER:-0}" = 1 ] && [ -z "${ACCOUNT:-}" ]; then
  MODE=ledger
  SIGN=(--ledger)
elif [ -n "${ACCOUNT:-}" ] && [ "${LEDGER:-0}" != 1 ]; then
  MODE=account
  SIGN=(--account "$ACCOUNT")
else
  die "choose exactly one signer: LEDGER=1 or ACCOUNT=<keystore name> (or DRY_RUN=1 / FORK=1)"
fi
say "mode: $MODE   signer: $GOV   rpc: $RPC_SHOWN"
# An empty OWNER or GOVERNANCE (OWNER=$SAFE in a shell where SAFE is not set) is a mistake, never a request for GOV. A
# live run names both and hands the stacks to the owner's Safe, not to GOV (a single-use deployer, retired after the
# deploy), unless NO_HANDOVER=1.
for v in OWNER GOVERNANCE; do
  [ -z "${!v+set}" ] || [ -n "${!v}" ] || die "$v is set but empty ($v=\$SAFE in a shell where SAFE is not set?): set it to the owner's Safe"
  if [ "$MODE" = ledger ] || [ "$MODE" = account ]; then
    need "$v"
    [ "$(lc "${!v}")" != "$(lc "$GOV")" ] || [ "${NO_HANDOVER:-0}" = 1 ] || die "$v is GOV: a live run hands the stacks to the owner's Safe, never leaves them with the single-use deployer (NO_HANDOVER=1 does, on purpose only)"
  fi
done
OWNER=${OWNER:-$GOV}
GOVERNANCE=${GOVERNANCE:-$GOV}
for v in GOV OWNER GOVERNANCE TREASURY FEES GUARDIAN; do isaddr "${!v}" "$v"; done
[[ "$LAUNCH_FEE_WEI" =~ ^[0-9]+$ && "$THRESHOLD_USDC" =~ ^[0-9]+$ ]] || die "LAUNCH_FEE_WEI and THRESHOLD_USDC must be integers"
# A Moment NFT's link is this base plus its id, and the app reads the cohort from the c<N>/ segment: every factory
# needs its own. It cannot be changed without governance, and a v2 Moment published under the wrong base keeps it.
# Build 16 publishes on v2 only under …/c4/ (MomentsAddresses.expectedExternalBaseURI): any other base blocks it.
V2_EXTERNAL_BASE_URI=https://dyorhq.fun/moments/c4/
[ "$EXTERNAL_BASE_URI" = "$V2_EXTERNAL_BASE_URI" ] || die "EXTERNAL_BASE_URI must be exactly $V2_EXTERNAL_BASE_URI, the only link base build 16 publishes under, got: $EXTERNAL_BASE_URI"
roles=$(printf '%s\n' "$(lc "$GOV")" "$(lc "$TREASURY")" "$(lc "$FEES")" "$(lc "$GUARDIAN")")
[ "$(printf '%s\n' "$roles" | sort -u | wc -l | tr -d ' ')" = 4 ] || die "GOV, TREASURY, FEES and GUARDIAN must be four different addresses"
for r in "$OWNER" "$GOVERNANCE"; do
  for x in "$TREASURY" "$FEES" "$GUARDIAN"; do [ "$(lc "$r")" != "$(lc "$x")" ] || die "OWNER/GOVERNANCE must not be a money role or the guardian"; done
done

# What each stack's forge run is given (run_script checks it gets exactly these): nothing else may reach the scripts.
LAUNCHPAD_PASSES="PROTOCOL_FEE_RECIPIENT FEES OWNER LAUNCH_FEE_WEI MON_USD_E8 ABIL_USD_E8"
MOMENTS_PASSES="GOVERNANCE GUARDIAN PLATFORM TREASURY THRESHOLD_USDC EXTERNAL_BASE_URI"
[ "${ONLY:-}" = moments ] || stray_knobs launchpad "$LAUNCHPAD_PASSES" script/Deploy.s.sol script/lib/MainnetGuard.sol
[ "${ONLY:-}" = launchpad ] || stray_knobs Moments "$MOMENTS_PASSES" script/moments/Deploy.s.sol script/lib/MainnetGuard.sol
if [ -n "$STRAY" ]; then
  [ "${ALLOW_SCRIPT_OVERRIDES:-0}" = 1 ] || die "set in this environment, and read by the Deploy scripts in place of their defaults: $STRAY. Unset them (use a clean shell), or set ALLOW_SCRIPT_OVERRIDES=1 if every one is intended."
  say "ALLOW_SCRIPT_OVERRIDES=1: the Deploy scripts read $STRAY from this environment"
fi

# cast's error names the URL it could not reach, so a custom RPC's error is not shown.
if [ "$RPC_SHOWN" = "$RPC" ]; then
  CHAIN=$($CAST chain-id --rpc-url "$RPC") || die "cannot reach the RPC"
else
  CHAIN=$($CAST chain-id --rpc-url "$RPC" 2>/dev/null) || die "cannot reach the RPC (cast's error is not shown: it names the URL)"
fi
[ "$CHAIN" = 143 ] || die "the RPC is chain $CHAIN, not Monad mainnet (143)"
if [ "$MODE" != fork ]; then
  REF=$($CAST chain-id --rpc-url "$REFERENCE_RPC") || die "cannot reach $REFERENCE_RPC"
  [ "$REF" = 143 ] || die "$REFERENCE_RPC is chain $REF"
fi
# A single-use deployer starts at nonce 0. Anything else means an earlier run, which is picked up where it stopped and
# never deployed again: a stopped broadcast is finished with --resume (step 2/3 prints how), and the Moments stack
# follows a finished launchpad with ONLY=moments. Moments sent while the launchpad is half done would move GOV's nonce,
# and the launchpad's --resume could then never finish it.
NONCE=$($CAST nonce "$GOV" --rpc-url "$RPC") || die "cannot read GOV's nonce"
[[ "$NONCE" =~ ^[0-9]+$ ]] || die "GOV's nonce reads $NONCE"
if [ "$NONCE" != 0 ] && [ "${ONLY:-}" != launchpad ]; then
  LP_BEFORE=$(record_factory deployments/pending-143.json 2>/dev/null) || LP_BEFORE=
  if moments_sent; then
    sent="GOV has nonce $NONCE, and the Moments stack in deployments/pending-moments-143.json is on chain: if its broadcast stopped midway, finish it with the --resume command it printed; if it finished, go on with step 4. No stack is deployed twice."
    case "$MODE" in ledger | account) die "$sent" ;; *) say "note: $sent" ;; esac
  elif [ -n "$LP_BEFORE" ] && launchpad_finished "$LP_BEFORE"; then
    if [ -n "${ONLY:-}" ]; then
      say "the launchpad stack in deployments/pending-143.json has finished: $LP_BEFORE"
    else
      case "$MODE" in
        ledger | account)
          bold "GOV has nonce $NONCE, and the launchpad stack in deployments/pending-143.json has finished: $LP_BEFORE"
          say "Deploy the Moments stack alone, in a clean shell (add MIN_BALANCE_MON=8 if GOV holds under $MIN_BALANCE_MON MON):"
          only_moments_command
          die "a full run would deploy a second launchpad: run the ONLY=moments command above" ;;
        *) say "note: GOV's nonce is $NONCE; a live full run refuses anything but 0" ;;
      esac
    fi
  elif [ -z "${ONLY:-}" ]; then
    case "$MODE" in
      ledger | account) die "GOV $GOV has nonce $NONCE: a full run needs a fresh, single-use deployer at nonce 0. If a broadcast of this script stopped midway, finish it with the --resume command it printed (then ONLY=moments, once the launchpad has finished); otherwise deploy from a new keystore." ;;
      *) say "note: GOV's nonce is $NONCE; a live full run refuses anything but 0" ;;
    esac
  else
    if [ -z "$LP_BEFORE" ]; then
      unfinished="GOV has nonce $NONCE, and there is no deployments/pending-143.json to show that its launchpad stack finished"
    else
      unfinished="GOV has nonce $NONCE, and the launchpad in deployments/pending-143.json ($LP_BEFORE) has not finished (it must read modulesSealed() true, then pendingOwner() or owner() OWNER)"
    fi
    case "$MODE" in
      ledger | account) die "$unfinished. Finish the launchpad first with the --resume command step 2 printed: Moments sent now would move GOV's nonce, and that --resume could never finish it." ;;
      *) say "note: $unfinished; a live ONLY=moments run refuses this" ;;
    esac
  fi
fi
BAL=$($CAST balance "$GOV" --rpc-url "$RPC" --ether | cut -d. -f1)
[ "$BAL" -ge "$MIN_BALANCE_MON" ] || [ "$MODE" = dry ] || die "$GOV holds $BAL MON; the two deployments need about $MIN_BALANCE_MON"
say "chain 143 · $GOV holds ~$BAL MON · nonce $NONCE"
for role in OWNER GOVERNANCE; do
  if [ "$(lc "${!role}")" = "$(lc "$GOV")" ]; then
    say "$role: GOV itself (no handover)"
  elif [ "$role" = GOVERNANCE ] && [ "$(lc "$GOVERNANCE")" = "$(lc "$OWNER")" ]; then
    say "GOVERNANCE: the same Safe as OWNER"
  else
    check_safe "$role" "${!role}"
  fi
done
case "${ONLY:-}" in launchpad) STACKS="launchpad only" ;; moments) STACKS="Moments only" ;; *) STACKS="launchpad, then Moments" ;; esac
say "stacks: $STACKS"
say "OWNER $OWNER · GOVERNANCE $GOVERNANCE · GUARDIAN $GUARDIAN"
say "TREASURY $TREASURY · FEES $FEES"
say "LAUNCH_FEE_WEI $LAUNCH_FEE_WEI · THRESHOLD_USDC $THRESHOLD_USDC"
say "EXTERNAL_BASE_URI $EXTERNAL_BASE_URI"

# ---------------------------------------------------------------- 1. prices
if [ "${ONLY:-}" != moments ]; then
  bold "1. live prices"
  PRICES=$(python3 script/relaunch/prices.py "$RPC") || die "prices unavailable, or the two sources disagree: nothing was sent"
  MON_USD_E8=$(printf '%s' "$PRICES" | tail -1 | sed -E 's/.*MON_USD_E8=([0-9]+).*/\1/')
  ABIL_USD_E8=$(printf '%s' "$PRICES" | tail -1 | sed -E 's/.*ABIL_USD_E8=([0-9]+).*/\1/')
  [[ "$MON_USD_E8" =~ ^[0-9]+$ && "$ABIL_USD_E8" =~ ^[0-9]+$ ]] || die "could not parse the prices"
  say "MON_USD_E8=$MON_USD_E8 ABIL_USD_E8=$ABIL_USD_E8 (Deploy.s.sol also refuses prices outside its sanity band)"
fi

# After a broadcast that stopped midway: the commands that finish it. forge's --resume sends the rest of the run from
# its log in broadcast/, without simulating again, and needs GOV's nonce where the run left it. The env is this run's,
# value for value, and the command is the one that stopped plus --resume, through script/mainnet.sh. A broadcast that
# sent nothing has no log of its own, and a Moments --resume would then replay the launchpad's finished log (same
# broadcast/Deploy.s.sol/143/ path) and report success, so the nonce and the stack's last transaction decide.
resume_help() { # <label> <target> <nonce when the broadcast began> <transactions planned> <env...>
  local label=$1 target=$2 start=$3 planned=$4 a line now record factory sign= again="the same command" chain
  shift 4
  bold "$label stopped midway: finish it, do not start over"
  if [ "$MODE" = fork ]; then
    say "A fork rehearsal cannot be resumed (broadcast/ is restored on exit): restart anvil and rehearse again."
    return 0
  fi
  for a in "${SIGN[@]}"; do sign="$sign $(printf '%q' "$a")"; done
  now=$($CAST nonce "$GOV" --rpc-url "$RPC" 2>/dev/null) || now="(unreadable)"
  record=deployments/pending-143.json
  [ "$target" = "$LAUNCHPAD_TARGET" ] || record=deployments/pending-moments-143.json
  factory=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["factory"])' "$record" 2>/dev/null) || factory="<the factory in $record>"
  [ "$target" = "$LAUNCHPAD_TARGET" ] || [ -n "${ONLY:-}" ] || again="the same command with ONLY=moments"
  say "- Do NOT run script/deploy-v2.sh again for this stack, with or without --resume: it reads no arguments, so it would deploy a whole new stack."
  say "- Send nothing else from GOV $GOV: --resume needs its nonce where this run left it."
  say "- Do not delete broadcast/: --resume reads this run's log there (both Deploy scripts log to broadcast/Deploy.s.sol/143/, and this run is the newest)."
  say ""
  say "GOV's nonce reads $now; it read $start when this broadcast began. If it still reads $start a minute from now, nothing"
  say "of this stack was sent (it stopped before its first transaction: a mistyped keystore password, say), and there is"
  say "nothing to resume: fix the cause and run $again. Otherwise finish it, in a clean shell:"
  line="  cd $(printf '%q' "$CONTRACTS") && env PATH=\"\$HOME/.foundry/bin:\$PATH\""
  for a in "$@"; do line="$line $(printf '%q' "$a")"; done
  say "$line \\"
  say "    script/mainnet.sh forge script $target --rpc-url $(rpc_word) --code-size-limit 200000 \\"
  say "    --sender $GOV --broadcast --slow --non-interactive$sign --resume"
  if [ -n "$STRAY" ]; then say "(this run also read $STRAY from the environment: keep each set to the same value)"; fi
  chain="--rpc-url $(rpc_word)"
  say "It has finished only when all of these read so (the factory having code proves only its first transaction):"
  if [ -n "$planned" ]; then say "  cast nonce $GOV $chain    # $((start + planned)): $planned transactions from $start"; fi
  if [ "$target" = "$LAUNCHPAD_TARGET" ]; then
    say "  cast call $factory 'modulesSealed()(bool)' $chain    # true"
    if [ "$(lc "$OWNER")" != "$(lc "$GOV")" ]; then
      say "  cast call $factory 'pendingOwner()(address)' $chain    # $OWNER"
    else
      say "  cast call $factory 'owner()(address)' $chain    # $GOV"
    fi
  else
    say "  cast call $factory 'modulesSet()(bool)' $chain    # true"
    if [ "$(lc "$GOVERNANCE")" != "$(lc "$GOV")" ]; then
      say "  cast call $factory 'pendingGovernance()(address)' $chain    # $GOVERNANCE"
    else
      say "  cast call $factory 'governance()(address)' $chain    # $GOV"
    fi
  fi
  if [ "$target" = "$LAUNCHPAD_TARGET" ] && [ -z "${ONLY:-}" ]; then
    say ""
    say "Only then, the Moments stack (ONLY=moments, which refuses while the launchpad has not finished; add MIN_BALANCE_MON=8"
    say "if GOV now holds under $MIN_BALANCE_MON MON, the Moments stack costs about 3):"
    only_moments_command
  fi
  if [ "$(rpc_word)" != "$RPC" ]; then say "(set RPC to the RPC this run used: it is not printed, since it may carry a key)"; fi
}

run_script() { # <label> <target> <names checked in step 0> <env...> -- simulate, confirm, broadcast
  local label=$1 target=$2 passes=$3 start planned
  shift 3
  [ "$(env_names "$@")" = "$passes" ] || die "$label: passes $(env_names "$@"), but step 0 checked $passes"
  bold "$label: simulation"
  env "$@" "$FORGE" script "$target" --rpc-url "$RPC" --code-size-limit 200000 --sender "$GOV" || die "$label: the simulation failed; nothing was sent"
  [ "$MODE" = dry ] && return 0
  planned=$(planned_txs)
  confirm "$label: broadcast these transactions as $GOV?"
  start=$($CAST nonce "$GOV" --rpc-url "$RPC") || die "$label: cannot read GOV's nonce; nothing was sent"
  [[ "$start" =~ ^[0-9]+$ ]] || die "$label: GOV's nonce reads $start; nothing was sent"
  BEGUN=$target
  bold "$label: broadcast"
  IN_FLIGHT=1
  if ! env "$@" "$FORGE" script "$target" --rpc-url "$RPC" --code-size-limit 200000 --sender "$GOV" --broadcast --slow --non-interactive "${SIGN[@]}"; then
    resume_help "$label" "$target" "$start" "$planned" "$@"
    IN_FLIGHT=
    [ "$INTERRUPTED" = 0 ] || die "$label: interrupted, and the broadcast did not complete. Do NOT start over: finish it as shown above." "$INTERRUPTED"
    die "$label: the broadcast did not complete. Do NOT start over: finish it as shown above."
  fi
  IN_FLIGHT=
  [ "$target" != "$LAUNCHPAD_TARGET" ] || LAUNCHPAD_DONE=1
  # A signal held while forge finished the broadcast: it is complete, and the run stops here.
  [ "$INTERRUPTED" = 0 ] || die "$label: the broadcast completed, then the run was interrupted" "$INTERRUPTED"
}

# ---------------------------------------------------------------- 2. launchpad
if [ "${ONLY:-}" != moments ]; then
  run_script "2. launchpad" "$LAUNCHPAD_TARGET" "$LAUNCHPAD_PASSES" \
    PROTOCOL_FEE_RECIPIENT="$TREASURY" FEES="$FEES" OWNER="$OWNER" LAUNCH_FEE_WEI="$LAUNCH_FEE_WEI" \
    MON_USD_E8="$MON_USD_E8" ABIL_USD_E8="$ABIL_USD_E8"
fi

# ---------------------------------------------------------------- 3. Moments
if [ "${ONLY:-}" != launchpad ]; then
  run_script "3. Moments" "$MOMENTS_TARGET" "$MOMENTS_PASSES" \
    GOVERNANCE="$GOVERNANCE" GUARDIAN="$GUARDIAN" PLATFORM="$FEES" TREASURY="$TREASURY" THRESHOLD_USDC="$THRESHOLD_USDC" \
    EXTERNAL_BASE_URI="$EXTERNAL_BASE_URI"
fi

# ---------------------------------------------------------------- the live records were not touched
# Only the tracked records: every run rewrites its git-ignored dryrun-*.json (each simulation) and pending-*.json.
for f in "$SNAP"/deployments/*.json; do
  case "$(basename "$f")" in dryrun-* | pending-*) continue ;; esac
  cmp -s "$f" "deployments/$(basename "$f")" || die "deployments/$(basename "$f") changed during the run: restore it from git before anything reads it"
done

bold "4. next"
if [ "$MODE" = dry ]; then
  case "${ONLY:-}" in
    launchpad) say "dry run: nothing was sent. Simulated record: deployments/dryrun-143.json" ;;
    moments) say "dry run: nothing was sent. Simulated record: deployments/dryrun-moments-143.json" ;;
    *) say "dry run: nothing was sent. Simulated records: deployments/dryrun-143.json, deployments/dryrun-moments-143.json"
       say "(the Moments simulation starts from GOV's current nonce, not after the launchpad's, so its addresses are not the live ones)" ;;
  esac
  exit 0
fi
# The records this run (or, after ONLY=, the other stack's run) wrote; a missing one is left out below.
LP=$(record_factory deployments/pending-143.json) || die "deployments/pending-143.json has no factory"
MF=$(record_factory deployments/pending-moments-143.json) || die "deployments/pending-moments-143.json has no factory"
if [ "$MODE" = fork ]; then
  say "fork rehearsal: the records, broadcast logs and caches are removed on exit, so read the fork now."
else
  say "records: deployments/pending-143.json, deployments/pending-moments-143.json (git-ignored, read by nothing yet):"
  say "copy them to DyorHQ/internal first."
fi
if [ -n "$LP" ]; then
  if [ "$(lc "$OWNER")" != "$(lc "$GOV")" ]; then want="pendingOwner() $OWNER"; else want="owner() $GOV"; fi
  say "- launchpad factory $LP must read $want and modulesSealed() true"
fi
if [ -n "$MF" ]; then
  if [ "$(lc "$GOVERNANCE")" != "$(lc "$GOV")" ]; then want="pendingGovernance() $GOVERNANCE"; else want="governance() $GOV"; fi
  say "- Moments factory $MF must read $want, guardian() $GUARDIAN and externalBaseURI() $EXTERNAL_BASE_URI"
fi
if { [ -n "$LP" ] && [ "$(lc "$OWNER")" != "$(lc "$GOV")" ]; } || { [ -n "$MF" ] && [ "$(lc "$GOVERNANCE")" != "$(lc "$GOV")" ]; }; then
  say "- the Safe accepts the handovers in one batch (Transaction Builder, custom data, value 0):"
  if [ -n "$LP" ] && [ "$(lc "$OWNER")" != "$(lc "$GOV")" ]; then say "    to $LP  data 0x79ba5097  acceptOwnership()   (OWNER $OWNER)"; fi
  if [ -n "$MF" ] && [ "$(lc "$GOVERNANCE")" != "$(lc "$GOV")" ]; then say "    to $MF  data 0x238efcbc  acceptGovernance()  (GOVERNANCE $GOVERNANCE)"; fi
  say "  then owner() / governance() must read the Safe; anything else abandons that deployment"
fi
say "- verify every new contract on Sourcify:"
[ -z "$LP" ] || say "    RECORD=deployments/pending-143.json script/verify-143.sh"
[ -z "$MF" ] || say "    RECORD=deployments/pending-moments-143.json script/moments/verify-moments-143.sh"
say "- then, in one change: promote the records (143.json -> 143-retired-0x6B1C.json and moments-143.json ->"
say "  moments-143-cohort3.json, each pending-*.json to the live name, deployBlock added to the Moments record by hand),"
say "  wire the app (LaunchpadAddresses / MomentsAddresses.monadMainnet) and the keepers (keepers/lib/deployments.mjs,"
say "  LIVE_EXTERNAL_BASE_URI in keepers/keeper.mjs), and pass scripts/dev/check-launchpad-addresses.py --release"
say "- the old launchpad 0x6B1C… and Moments cohort 3 0x0FD4… stay as they are on chain (owner decision 2026-09-28)"
