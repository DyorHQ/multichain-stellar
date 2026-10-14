#!/bin/bash
# One keeper unit on the Fly.io machine (build 17 K4), started by supercronic (ops/crontab) as the `keeper` user.
#
#   run-keeper.sh <grad|sweeps|buybacks|governance>     the scheduled run
#   run-keeper.sh <grad|sweeps|buybacks> --manual [--send]
#                                                       an owner's one-shot from `fly ssh console` (grad-now.sh): waits
#                                                       for a scheduled run of the unit to end, pings nothing, and with
#                                                       --send sends even while the unit's flag is off
#
# Every scheduled run is a dry run unless the unit's own flag is exactly 1 (KEEPER_SEND_GRAD, KEEPER_SEND_SWEEPS,
# KEEPER_SEND_BUYBACKS: Fly secrets, unset = 0), entrypoint.sh left it a usable keystore that derives the address
# keeper-signers.json pins, and this is the Machine KEEPER_MACHINE_ID names, so the 7-day dry run and the staged
# enables (grad, then buybacks, then sweeps) are secret flips. Governance never sends. A flag that asks to send when
# the unit may not still runs the dry run, then fails. No unit ever passes --only-live: the retired stacks keep their
# holders.
#
# healthchecks.io: /start before the run; the plain ping after keeper exit 0 (nothing for a human) or 2 (alerts, which
# the keeper already posted); /fail after 1 or anything else. The ping URL reaches curl on stdin (-K -), never argv,
# and curl's output and errors are discarded, so no log line carries it. Never add `set -x` to this file.
set -u -o pipefail
umask 077

unit=${1:-}
shift || true
manual=0
manual_send=0
while [ $# -gt 0 ]; do
  case "$1" in
    --manual) manual=1 ;;
    --send) manual_send=1 ;;
    *) echo "run-keeper: unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
[ "$manual_send" = 0 ] || [ "$manual" = 1 ] || { echo "run-keeper: --send is only for --manual runs; scheduled runs follow the unit's flag" >&2; exit 64; }

APP_DIR=${KEEPER_APP_DIR:-/app}
DATA_DIR=${KEEPER_DATA_DIR:-/data}
SECRETS_DIR=${KEEPER_SECRETS_DIR:-/run/dyor-keeper}
NODE_BIN=${KEEPER_NODE:-node}
KEEPER_MJS=${KEEPER_MJS:-$APP_DIR/contracts/keepers/keeper.mjs}
# The RPC list in fallback order: KEEPER_RPC_URLS (space-separated; a Fly secret, with a restricted provider key's URL
# first when there is one), else rpc3 (Ankr) then rpc4 (Infura); rpc1 rate-limits a full run. The keeper reads it from
# its environment, never its command line: `ps` shows a process's arguments to anyone on the Machine for the whole run.
export KEEPER_RPC_URLS="${KEEPER_RPC_URLS:-https://rpc3.monad.xyz https://rpc4.monad.xyz}"

# The unit table (build 17 plan, decision 14; keepers report 3.3 and 3.4). The funding is 30 / 10 / 5 MON for
# grad / buybacks / sweeps; --min-balance warns (every 12 h) below 10 / 3 / 1; --max-spend-per-day holds sends above
# 20 / 10 / 3 MON (the same numbers as keeper-signers.json; ops.test.mjs keeps them equal). A signing unit's
# --max-runtime is 240 s: below the grad cadence and inside fly.toml's kill_timeout, and a send never outlasts it, so a
# deploy lets a run finish. The key-less governance scan gets 600 s for a catch-up (a deploy that stops it costs only
# that run's progress: its cursor is saved at the end of a run, so the next run scans those blocks again and misses
# none). The log cursors start where the plan says (governance after the 13 reviewed v2 setup events; later runs
# resume from the cursor in the state file).
flag=
min_balance=
cap=
extra=()
case "$unit" in
  grad) jobs=(moments-graduation launchpad-graduation); flag=KEEPER_SEND_GRAD; min_balance=10; cap=20; runtime=240; extra=(--logs-cursor) ;;
  buybacks) jobs=(buybacks); flag=KEEPER_SEND_BUYBACKS; min_balance=3; cap=10; runtime=240 ;;
  sweeps) jobs=(sweeps); flag=KEEPER_SEND_SWEEPS; min_balance=1; cap=3; runtime=240 ;;
  governance) jobs=(governance); runtime=600; extra=(--logs-cursor --logs-from 108860011) ;;
  *) echo "run-keeper: usage: run-keeper.sh <grad|sweeps|buybacks|governance> [--manual [--send]]" >&2; exit 64 ;;
esac
if [ "$manual" = 1 ] && [ -z "$flag" ]; then
  echo "run-keeper: $unit never sends; --manual is for the signing units" >&2
  exit 64
fi

log() { printf '[%s] %s\n' "$unit" "$*"; }

# ---- healthchecks.io (scheduled runs only)
hc_url=
if [ "$manual" = 0 ] && [ -s "$SECRETS_DIR/hc-$unit" ]; then
  IFS= read -r hc_url < "$SECRETS_DIR/hc-$unit" || true
  case "$hc_url" in
    https://*) case "$hc_url" in *[\"\\\ ]*) hc_url= ; log "healthchecks URL for $unit is malformed: not pinging" ;; esac ;;
    *) hc_url= ; log "healthchecks URL for $unit is not https: not pinging" ;;
  esac
fi
hc() {
  [ -n "$hc_url" ] || return 0
  local rc=0
  printf 'url = "%s%s"\n' "$hc_url" "$1" | curl -fsS -m 10 --retry 3 --retry-max-time 40 -o /dev/null -K - >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || log "healthchecks ping ${1:-success} failed (curl exit $rc)"
}

# ---- one run of a unit at a time (supercronic never overlaps a job either; this also covers the manual one-shot)
mkdir -p "$DATA_DIR" 2>/dev/null || true
command -v flock >/dev/null 2>&1 || { log "flock is not installed: not running"; exit 1; }
if ! exec 9>>"$DATA_DIR/.lock-$unit"; then
  log "cannot open the lock file in $DATA_DIR: not running"
  exit 1
fi
if [ "$manual" = 1 ]; then
  flock -w 600 9 || { log "a scheduled $unit run still holds the lock after 10 minutes: try again"; exit 1; }
else
  flock -n 9 || { log "the previous $unit run is still going: this run is skipped"; exit 0; }
fi

# ---- what this run may do
problem=
want_send=0
if [ -n "$flag" ]; then
  flag_value=${!flag:-0}
  case "$flag_value" in
    1) want_send=1 ;;
    0 | "") ;;
    *) problem="$flag must be 0 or 1" ;;
  esac
fi
[ "$manual_send" = 1 ] && want_send=1
if [ "$manual" = 1 ] && [ "$manual_send" = 0 ]; then want_send=0; fi

keystore="$SECRETS_DIR/$unit.keystore"
password="$SECRETS_DIR/$unit.password"
address=
signer_error=
no_send=
if [ -n "$flag" ]; then
  if [ -s "$SECRETS_DIR/$unit.error" ]; then
    IFS= read -r signer_error < "$SECRETS_DIR/$unit.error" || true
  elif [ -s "$keystore" ] && [ -s "$password" ] && [ -s "$SECRETS_DIR/$unit.address" ]; then
    IFS= read -r address < "$SECRETS_DIR/$unit.address" || true
    case "$address" in 0x[0-9a-fA-F]*) [ ${#address} = 42 ] || { address= ; signer_error="its address file is malformed"; } ;; *) address= ; signer_error="its address file is malformed" ;; esac
    # A key that may run dry runs as its address but never send (not pinned in keeper-signers.json).
    if [ -n "$address" ] && [ -e "$SECRETS_DIR/$unit.nosend" ]; then
      IFS= read -r no_send < "$SECRETS_DIR/$unit.nosend" || true
      no_send=${no_send:-it may not send}
    fi
  fi
fi

args=("$NODE_BIN" "$KEEPER_MJS" "${jobs[@]}" --state-file "$DATA_DIR/state-$unit.json" --max-runtime "$runtime")
if [ ${#extra[@]} -gt 0 ]; then args+=("${extra[@]}"); fi
[ -n "$min_balance" ] && args+=(--min-balance "$min_balance")
[ -n "$cap" ] && args+=(--max-spend-per-day "$cap")
if [ -s "$SECRETS_DIR/webhook" ]; then
  args+=(--webhook-file "$SECRETS_DIR/webhook")
else
  log "no webhook: alerts go to this log only"
fi

# Only the Machine KEEPER_MACHINE_ID names sends (entrypoint.sh writes this marker at boot): a second Machine has its
# own empty volume, so its spend ledger, backoffs and nonces would not be this one's.
if [ -n "$address" ] && [ -z "$no_send" ] && [ ! -s "$SECRETS_DIR/machine.ok" ]; then
  no_send="this is not the keeper Machine KEEPER_MACHINE_ID names (${FLY_MACHINE_ID:-unknown})"
fi

mode="dry run"
if [ "$want_send" = 1 ]; then
  if [ -n "$address" ] && [ -z "$no_send" ]; then
    args+=(--send --keystore "$keystore" --password-file "$password" --sim-from "$address")
    mode="SEND from $address"
  elif [ -n "$address" ]; then
    args+=(--sim-from "$address")
    mode="dry run as $address"
    problem="${problem:+$problem; }sending is on but the $unit key may not send ($no_send): ran dry"
  else
    problem="${problem:+$problem; }sending is on but the $unit keystore is not usable (${signer_error:-no keystore, password or address in $SECRETS_DIR}): ran dry"
  fi
elif [ -n "$address" ]; then
  args+=(--sim-from "$address")
  mode="dry run as $address"
elif [ -n "$flag" ]; then
  mode="dry run (no signer${signer_error:+: $signer_error})"
fi

cd "${HOME:-/}" 2>/dev/null || cd /
log "start: ${jobs[*]} · $mode · max ${runtime}s"
hc /start
"${args[@]}" 2>&1 | while IFS= read -r line; do printf '[%s] %s\n' "$unit" "$line"; done
code=${PIPESTATUS[0]}

if [ -z "$problem" ] && { [ "$code" = 0 ] || [ "$code" = 2 ]; }; then
  log "end: keeper exit $code ($([ "$code" = 0 ] && echo "nothing for a human" || echo "alerts raised and posted"))"
  hc ""
  exit 0
fi
[ -n "$problem" ] && log "FAILED: $problem"
log "end: keeper exit $code: this run FAILED"
hc /fail
exit 1
