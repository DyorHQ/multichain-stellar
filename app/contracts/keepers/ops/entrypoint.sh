#!/bin/bash
# Boot of the DyorHQ keepers machine on Fly.io (build 17 K4). It runs as root only to prepare, then hands over to the
# unprivileged `keeper` user (uid 10001) for good:
#  1. refuses to start without the state volume at /data: a second machine without the spend ledger and the cursors
#     could repeat sends;
#  2. mounts a private tmpfs at /run/dyor-keeper (0700, keeper) and writes the Fly secrets into it: for each signing
#     unit its keystore and password (KEEPER_<UNIT>_KEYSTORE_B64 and KEEPER_<UNIT>_PASSWORD_B64, base64), the webhook
#     (KEEPER_WEBHOOK_URL) and the healthchecks.io ping URLs (KEEPER_HC_<UNIT>_URL). Only shell builtins handle the
#     values, so none reaches a command line, the log or the disk;
#  3. derives each signer's public address as keeper (cast wallet address) and runs check-signers.mjs: the units use
#     different keys, none is a custody or protocol key or a Safe signer, each derives the address keeper-signers.json
#     pins, and each holds its minimum. It fails closed: a key may send only when the check printed "OK <unit>
#     <address>" for it. A forbidden key, or one the check did not clear (it failed, crashed or said nothing), is
#     removed (its unit runs dry runs with no signer); an unpinned one may run dry runs as its address but never sends;
#     either way a send flag at 1 makes the unit's runs fail loudly (healthchecks /fail) instead of sending;
#  4. only on the Machine KEEPER_MACHINE_ID names (FLY_MACHINE_ID) may a unit send: a second or replaced Machine runs
#     dry runs, and a send flag at 1 there fails its runs;
#  5. starts supercronic on ops/crontab as keeper, with an environment holding no secret and no capabilities. Given a
#     command instead (a local test: `docker run … IMAGE /app/contracts/keepers/ops/run-keeper.sh grad`), it runs that
#     command as keeper after the same preparation.
# Never add `set -x` to this file. KEEPER_APP_DIR, KEEPER_DATA_DIR and KEEPER_SECRETS_DIR exist for ops.test.mjs only;
# on the Machine they are unset.
set -euo pipefail
umask 077

APP_DIR=${KEEPER_APP_DIR:-/app}
OPS_DIR=$APP_DIR/contracts/keepers/ops
DATA_DIR=${KEEPER_DATA_DIR:-/data}
SECRETS_DIR=${KEEPER_SECRETS_DIR:-/run/dyor-keeper}
KEEPER_UID=10001
KEEPER_GID=10001
UNITS="grad sweeps buybacks"
HC_UNITS="grad sweeps buybacks governance"

say() { printf 'keepers: %s\n' "$*"; }
die() { printf 'keepers: FATAL: %s\n' "$*" >&2; exit 1; }
upper() { case "$1" in grad) echo GRAD ;; sweeps) echo SWEEPS ;; buybacks) echo BUYBACKS ;; governance) echo GOVERNANCE ;; esac; }
as_keeper() {
  setpriv --reuid="$KEEPER_UID" --regid="$KEEPER_GID" --init-groups --no-new-privs --inh-caps=-all --bounding-set=-all \
    env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/keeper TZ=UTC LANG=C.UTF-8 "$@"
}

[ "$(id -u)" = 0 ] || die "start as root: the entrypoint prepares /data and the secrets tmpfs, then runs everything as keeper"
KEEPER_NAME=$(getent passwd "$KEEPER_UID" | cut -d: -f1) || true
[ -n "$KEEPER_NAME" ] || die "no user with uid $KEEPER_UID in the image"

# ---- 1. the state volume
if ! mountpoint -q "$DATA_DIR"; then
  die "$DATA_DIR is not a mounted volume: refusing to run keepers without their state (one machine, one volume: see fly.toml)"
fi
chown "$KEEPER_UID:$KEEPER_GID" "$DATA_DIR"
chmod 0700 "$DATA_DIR"
find "$DATA_DIR" -mindepth 1 -maxdepth 1 ! -user "$KEEPER_UID" -exec chown "$KEEPER_UID:$KEEPER_GID" {} + 2>/dev/null || true

# ---- 2. the secrets tmpfs
any_secret=0
for name in $(compgen -e); do
  case "$name" in KEEPER_*_B64 | KEEPER_WEBHOOK_URL | KEEPER_HC_*_URL) any_secret=1 ;; esac
done
secrets_fs="none"
mkdir -p "$SECRETS_DIR"
if mount -t tmpfs -o "size=4m,mode=0700,uid=$KEEPER_UID,gid=$KEEPER_GID,nosuid,nodev,noexec" dyor-keeper-secrets "$SECRETS_DIR" 2>/dev/null; then
  secrets_fs="tmpfs (mounted)"
elif [ "$(stat -f -c %T /dev/shm 2>/dev/null || true)" = tmpfs ]; then
  # A container without CAP_SYS_ADMIN (a local docker run): /dev/shm is its tmpfs. /run/dyor-keeper points there (a
  # restarted container still has the link from its first boot).
  install -d -m 0700 -o "$KEEPER_UID" -g "$KEEPER_GID" /dev/shm/dyor-keeper
  if [ ! -L "$SECRETS_DIR" ]; then
    rmdir "$SECRETS_DIR" 2>/dev/null || die "$SECRETS_DIR exists and is not empty"
    ln -s /dev/shm/dyor-keeper "$SECRETS_DIR"
  fi
  [ "$(readlink "$SECRETS_DIR")" = /dev/shm/dyor-keeper ] || die "$SECRETS_DIR points somewhere else than /dev/shm/dyor-keeper"
  secrets_fs="tmpfs (/dev/shm)"
elif [ "$any_secret" = 1 ]; then
  die "no tmpfs for the secrets: refusing to write them to disk"
else
  chown "$KEEPER_UID:$KEEPER_GID" "$SECRETS_DIR"
  chmod 0700 "$SECRETS_DIR"
fi
# Every boot starts clean: no key, marker or URL of an earlier boot survives (a restarted container keeps /dev/shm).
find "$SECRETS_DIR/" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
say "secrets directory: $secrets_fs"

# Writes the variable named $1 into file $2 (owned by keeper, 0400). With $3 = b64 the value is base64 and is decoded.
put_secret() {
  local value="${!1-}"
  [ -n "$value" ] || return 1
  if [ "${3:-}" = b64 ]; then
    printf '%s' "$value" | base64 -d > "$2" 2>/dev/null || { rm -f "$2"; return 2; }
  else
    printf '%s\n' "$value" > "$2"
  fi
  chown "$KEEPER_UID:$KEEPER_GID" "$2"
  chmod 0400 "$2"
}
mark() { # unit reason: the key is never used; the unit runs dry runs with no signer, and fails if asked to send
  printf '%s\n' "$2" > "$SECRETS_DIR/$1.error"
  chown "$KEEPER_UID:$KEEPER_GID" "$SECRETS_DIR/$1.error"
  rm -f "$SECRETS_DIR/$1.keystore" "$SECRETS_DIR/$1.password" "$SECRETS_DIR/$1.address" "$SECRETS_DIR/$1.nosend"
  say "$1: NOT USABLE: $2"
}
nosend() { # unit reason: dry runs as the unit's address, never a send (until the next boot)
  printf '%s\n' "$2" > "$SECRETS_DIR/$1.nosend"
  chown "$KEEPER_UID:$KEEPER_GID" "$SECRETS_DIR/$1.nosend"
  say "$1: dry runs only: $2"
}

signers=()
for unit in $UNITS; do
  U=$(upper "$unit")
  ks_var="KEEPER_${U}_KEYSTORE_B64"
  pw_var="KEEPER_${U}_PASSWORD_B64"
  has_ks=0; has_pw=0
  [ -n "${!ks_var-}" ] && has_ks=1
  [ -n "${!pw_var-}" ] && has_pw=1
  if [ "$has_ks" = 0 ] && [ "$has_pw" = 0 ]; then
    say "$unit: no keystore (dry runs without a signer)"
    continue
  fi
  if [ "$has_ks" != "$has_pw" ]; then mark "$unit" "only one of $ks_var and $pw_var is set"; continue; fi
  rc=0; put_secret "$ks_var" "$SECRETS_DIR/$unit.keystore" b64 || rc=$?
  [ "$rc" = 0 ] || { mark "$unit" "$ks_var is not valid base64"; continue; }
  rc=0; put_secret "$pw_var" "$SECRETS_DIR/$unit.password" b64 || rc=$?
  [ "$rc" = 0 ] || { mark "$unit" "$pw_var is not valid base64"; continue; }
  first=$(head -c 1 "$SECRETS_DIR/$unit.keystore")
  [ "$first" = "{" ] || { mark "$unit" "$ks_var does not decode to a JSON keystore"; continue; }
  addr=$(as_keeper cast wallet address --keystore "$SECRETS_DIR/$unit.keystore" --password-file "$SECRETS_DIR/$unit.password" 2>/dev/null | tail -n 1) || addr=
  case "$addr" in
    0x[0-9a-fA-F]*) [ ${#addr} = 42 ] || addr= ;;
    *) addr= ;;
  esac
  [ -n "$addr" ] || { mark "$unit" "cast could not open the keystore with its password"; continue; }
  printf '%s\n' "$addr" > "$SECRETS_DIR/$unit.address"
  chown "$KEEPER_UID:$KEEPER_GID" "$SECRETS_DIR/$unit.address"
  chmod 0444 "$SECRETS_DIR/$unit.address"
  signers+=("$unit=$addr")
done

# ---- one Machine sends: the one KEEPER_MACHINE_ID names (a Fly secret, set once after the first deploy). Fly gives a
# second Machine (fly scale count, fly machine clone) its own empty volume, which the mount check above cannot tell
# from the first: it would send from the same keys with no spend ledger. Every Machine gets the same secrets, so the
# pin is checked against this Machine's own FLY_MACHINE_ID, and only then may a unit here send.
if [ -n "${KEEPER_MACHINE_ID-}" ] && [ -n "${FLY_MACHINE_ID-}" ] && [ "$KEEPER_MACHINE_ID" = "$FLY_MACHINE_ID" ]; then
  printf '%s\n' "$FLY_MACHINE_ID" > "$SECRETS_DIR/machine.ok"
  chown "$KEEPER_UID:$KEEPER_GID" "$SECRETS_DIR/machine.ok"
  chmod 0444 "$SECRETS_DIR/machine.ok"
  say "machine: $FLY_MACHINE_ID is the keeper Machine (KEEPER_MACHINE_ID): its units may send"
elif [ -n "${KEEPER_MACHINE_ID-}" ]; then
  say "machine: ${FLY_MACHINE_ID:-unknown} is NOT the keeper Machine $KEEPER_MACHINE_ID: no unit sends here (a second Machine must be destroyed; a replaced one needs KEEPER_MACHINE_ID updated)"
else
  say "machine: KEEPER_MACHINE_ID is not set: no unit sends until it names this Machine (${FLY_MACHINE_ID:-unknown})"
fi

if [ -n "${KEEPER_WEBHOOK_URL-}" ]; then
  put_secret KEEPER_WEBHOOK_URL "$SECRETS_DIR/webhook"
  say "webhook: set"
else
  say "webhook: NOT set (alerts go to the log only)"
fi
hc_set=
for unit in $HC_UNITS; do
  if put_secret "KEEPER_HC_$(upper "$unit")_URL" "$SECRETS_DIR/hc-$unit"; then hc_set="$hc_set $unit"; fi
done
say "healthchecks pings:${hc_set:- none}"

# ---- 3. the signers: distinct, never a custody or protocol key, pinned, funded
if [ ${#signers[@]} -gt 0 ]; then
  crc=0
  rpc_env=()
  [ -n "${KEEPER_RPC_URLS-}" ] && rpc_env=("KEEPER_RPC_URLS=$KEEPER_RPC_URLS")
  check=$(as_keeper ${rpc_env[@]+"${rpc_env[@]}"} node "$OPS_DIR/check-signers.mjs" "${signers[@]}" 2>&1) || crc=$?
  # Fail closed: a key is cleared only by its own "OK <unit> <address>" line for the address it derived. Silence (the
  # check did not run, crashed, or printed nothing for a unit) clears nothing.
  cleared=" "
  handled=" "
  while IFS= read -r line; do
    case "$line" in
      "OK "*)
        rest=${line#OK }; ok_unit=${rest%% *}; rest=${rest#"$ok_unit"}; rest=${rest# }; ok_addr=${rest%% *}
        cleared="$cleared$ok_unit=$ok_addr "
        say "signer check: $line" ;;
      "FORBIDDEN "*) rest=${line#FORBIDDEN }; mark "${rest%% *}" "${rest#* }"; handled="$handled${rest%% *} " ;;
      "UNPINNED "*) rest=${line#UNPINNED }; nosend "${rest%% *}" "${rest#* }"; handled="$handled${rest%% *} " ;;
      "") ;;
      *) say "signer check: $line" ;;
    esac
  done <<< "$check"
  for s in "${signers[@]}"; do
    unit=${s%%=*}
    case "$handled" in *" $unit "*) continue ;; esac
    if [ "$crc" != 0 ] && [ "$crc" != 1 ]; then
      mark "$unit" "the signer check could not run (exit $crc)"
    else
      case "$cleared" in
        *" $s "*) ;;
        *) mark "$unit" "the signer check did not clear this key (exit $crc, no OK line for ${s#*=})" ;;
      esac
    fi
  done
fi
for unit in $UNITS; do
  U=$(upper "$unit")
  flag_var="KEEPER_SEND_$U"
  flag="${!flag_var:-0}"
  case "$flag" in 0 | 1) ;; *) say "$unit: $flag_var must be 0 or 1: its runs will fail until that is fixed" ;; esac
  if [ -s "$SECRETS_DIR/$unit.address" ] && [ ! -e "$SECRETS_DIR/$unit.nosend" ] && [ -s "$SECRETS_DIR/machine.ok" ]; then
    say "$unit: signer $(cat "$SECRETS_DIR/$unit.address"), sends $([ "$flag" = 1 ] && echo ON || echo "off (dry run)")"
  elif [ "$flag" = 1 ]; then
    say "$unit: $flag_var=1 but the unit may not send (see above): its runs will fail until that is fixed"
  fi
done

# ---- 4. hand over to keeper, with no secret in the environment
keep=(PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/keeper TZ=UTC LANG=C.UTF-8 NODE_ENV=production
  KEEPER_SECRETS_DIR="$SECRETS_DIR" KEEPER_DATA_DIR="$DATA_DIR" KEEPER_APP_DIR="$APP_DIR")
for name in KEEPER_SEND_GRAD KEEPER_SEND_SWEEPS KEEPER_SEND_BUYBACKS KEEPER_TELEGRAM_CHAT_ID KEEPER_RPC_URLS FLY_APP_NAME FLY_MACHINE_ID FLY_REGION; do
  [ -n "${!name-}" ] && keep+=("$name=${!name}")
done
cd /home/keeper 2>/dev/null || cd /
if [ $# -gt 0 ]; then
  say "running $* as $KEEPER_NAME"
  exec setpriv --reuid="$KEEPER_UID" --regid="$KEEPER_GID" --init-groups --no-new-privs --inh-caps=-all --bounding-set=-all env -i "${keep[@]}" "$@"
fi
say "starting supercronic ($OPS_DIR/crontab) as $KEEPER_NAME"
exec setpriv --reuid="$KEEPER_UID" --regid="$KEEPER_GID" --init-groups --no-new-privs --inh-caps=-all --bounding-set=-all \
  env -i "${keep[@]}" supercronic -passthrough-logs "$OPS_DIR/crontab"
