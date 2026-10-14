#!/bin/bash
# Creates the keeper keys and loads the keepers' secrets into Fly (build 17 K4). The owner runs it on their Mac, logged
# in with flyctl, with Foundry's cast installed. Nothing secret is printed, put on a command line or kept on disk:
#  - each keystore is made by `cast wallet new` in a private temporary folder, behind cast's hidden password prompt
#    (paste the password generated for that key in the password manager);
#  - that password is asked once more, hidden, to write its file, and checked by opening the keystore with it;
#  - the Discord webhook, the healthchecks.io ping URLs and an optional restricted RPC URL (a provider key, used
#    before rpc3 and rpc4) are asked for hidden (Enter skips one);
#  - everything goes to `fly secrets import --stage` on stdin (never `fly secrets set NAME=VALUE`, which would put the
#    value in argv and the shell history), and the temporary folder is deleted on exit.
# It prints only the public addresses (to fund, and to pin in ops/keeper-signers.json through a reviewed commit: until
# a unit's address is pinned it runs dry runs only), the secret names, and the `fly secrets set` commands for the send
# flags, which hold no secret. The secrets reach the Machine at the next deploy (or `fly secrets deploy`); until the
# send flags are 1 every unit is a dry run.
#
#   contracts/keepers/ops/make-keeper-secrets.sh --app NAME [--keys grad,sweeps,buybacks|none] [--no-urls]
#   contracts/keepers/ops/make-keeper-secrets.sh --print-commands [--app NAME]
#
#   --keys   which keys to create (default: all three). Creating a key again replaces it (and sets its send flag
#            back to 0): move its funds out first, then pin the new address.
#   --no-urls  skip the webhook and healthchecks prompts (for example when replacing one key)
#   --print-commands  print the fly command templates, with placeholders, and stop: no cast, no fly, nothing created
# Never add `set -x`.
set -euo pipefail
umask 077

app=
keys="grad,sweeps,buybacks"
urls=1
print_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || { echo "secrets: --app needs a name" >&2; exit 64; }; app=$2; shift ;;
    --keys) [ $# -ge 2 ] || { echo "secrets: --keys needs a list" >&2; exit 64; }; keys=$2; shift ;;
    --no-urls) urls=0 ;;
    --print-commands) print_only=1 ;;
    -h | --help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "secrets: unknown option $1" >&2; exit 64 ;;
  esac
  shift
done

# The fly commands around the import, as templates. The send flags hold no secret, so `fly secrets set` is fine for
# them; every secret value goes through this script, on stdin, never on a command line.
templates() {
  local a=${1:-<APP>}
  cat <<TEMPLATES
# Secret values (keystores, passwords, webhook, ping URLs, a keyed RPC URL): only through this script, on stdin:
contracts/keepers/ops/make-keeper-secrets.sh --app $a                          # all three keys and the URLs
contracts/keepers/ops/make-keeper-secrets.sh --app $a --keys grad --no-urls    # replace one key
contracts/keepers/ops/make-keeper-secrets.sh --app $a --keys none              # replace the URLs (webhook, pings, RPC)
# Apply the staged secrets (restarts the Machine); list names and digests (never values):
fly secrets deploy --app $a
fly secrets list --app $a
# Once, before the first send flag: pin the one Machine that may send (deploy-fly.sh prints its id). A second Machine,
# or a replaced one, sends nothing until this names it:
fly secrets set KEEPER_MACHINE_ID=<MACHINE_ID> --app $a
# After the 7-day dry run, one unit at a time, a day apart (each restarts the Machine):
fly secrets set KEEPER_SEND_GRAD=1 --app $a
fly secrets set KEEPER_SEND_BUYBACKS=1 --app $a
fly secrets set KEEPER_SEND_SWEEPS=1 --app $a
# Stop one unit sending at once:
fly secrets set KEEPER_SEND_<GRAD|BUYBACKS|SWEEPS>=0 --app $a
TEMPLATES
}
if [ "$print_only" = 1 ]; then
  templates "$app"
  exit 0
fi
[ -n "$app" ] || { echo "secrets: usage: make-keeper-secrets.sh --app NAME [--keys grad,sweeps,buybacks|none] [--no-urls] | --print-commands [--app NAME]" >&2; exit 64; }
[ "$keys" = none ] && keys=
units=()
for u in $(printf '%s' "$keys" | tr ',' ' '); do
  case "$u" in grad | sweeps | buybacks) units+=("$u") ;; *) echo "secrets: unknown key $u (grad, sweeps, buybacks)" >&2; exit 64 ;; esac
done
[ ${#units[@]} -gt 0 ] || [ "$urls" = 1 ] || { echo "secrets: nothing to do" >&2; exit 64; }

CAST=${CAST_BIN:-}
if [ -z "$CAST" ]; then
  if command -v cast >/dev/null 2>&1; then CAST=cast; else CAST="$HOME/.foundry/bin/cast"; fi
fi
FLY=${FLY_BIN:-fly}
[ ${#units[@]} -eq 0 ] || "$CAST" --version >/dev/null 2>&1 || { echo "secrets: Foundry's cast is not installed (foundryup)" >&2; exit 2; }
command -v "$FLY" >/dev/null 2>&1 || { echo "secrets: flyctl (fly) is not installed" >&2; exit 2; }
"$FLY" auth whoami >/dev/null 2>&1 || { echo "secrets: not logged in to Fly: run fly auth login" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/dyor-keeper-secrets.XXXXXX")
chmod 0700 "$work"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
import="$work/import"
: > "$import"

upper() { case "$1" in grad) echo GRAD ;; sweeps) echo SWEEPS ;; buybacks) echo BUYBACKS ;; governance) echo GOVERNANCE ;; esac; }
b64() { base64 < "$1" | tr -d '\n'; }
hidden() { # prompt -> the answer in REPLY, never echoed
  REPLY=
  IFS= read -r -s -p "$1" REPLY || true
  printf '\n' >&2
}

addresses=()
for unit in "${units[@]}"; do
  U=$(upper "$unit")
  name="dyor-keeper-$unit"
  echo
  echo "== $name"
  echo "cast asks for the keystore password: paste the one generated for $name in the password manager."
  "$CAST" wallet new "$work" "$name" > /dev/null
  [ -s "$work/$name" ] || { echo "secrets: cast did not write the $name keystore" >&2; exit 1; }
  addr=
  for try in 1 2 3; do
    hidden "Paste the same password once more (hidden, to write its file): "
    printf '%s' "$REPLY" > "$work/$unit.password"
    REPLY=
    addr=$("$CAST" wallet address --keystore "$work/$name" --password-file "$work/$unit.password" 2>/dev/null | tail -n 1) || addr=
    case "$addr" in 0x[0-9a-fA-F]*) [ ${#addr} = 42 ] && break ;; esac
    addr=
    echo "That password does not open the keystore (try $try of 3)." >&2
  done
  [ -n "$addr" ] || { echo "secrets: the password did not match: nothing was imported" >&2; exit 1; }
  printf 'KEEPER_%s_KEYSTORE_B64=%s\n' "$U" "$(b64 "$work/$name")" >> "$import"
  printf 'KEEPER_%s_PASSWORD_B64=%s\n' "$U" "$(b64 "$work/$unit.password")" >> "$import"
  printf 'KEEPER_SEND_%s=0\n' "$U" >> "$import"
  addresses+=("$name $addr")
done

if [ "$urls" = 1 ]; then
  echo
  echo "== alerts and the dead-man alarm (Enter skips one)"
  hidden "Discord channel webhook URL (hidden): "
  case "$REPLY" in
    "") ;;
    https://*) printf 'KEEPER_WEBHOOK_URL=%s\n' "$REPLY" >> "$import" ;;
    *) echo "secrets: the webhook must be an https URL" >&2; exit 1 ;;
  esac
  for unit in grad sweeps buybacks governance; do
    hidden "healthchecks.io ping URL for the $unit check (hidden): "
    case "$REPLY" in
      "") ;;
      https://*) printf 'KEEPER_HC_%s_URL=%s\n' "$(upper "$unit")" "$REPLY" >> "$import" ;;
      *) echo "secrets: a ping URL must be https" >&2; exit 1 ;;
    esac
  done
  # A restricted provider key's URL goes first; the public rpc3 and rpc4 stay as fallbacks. The keepers read the list
  # from their environment, never a command line.
  hidden "Restricted RPC URL, with its key (hidden; Enter keeps rpc3 then rpc4): "
  case "$REPLY" in
    "") ;;
    *[[:space:]]*) echo "secrets: the RPC URL must be one https URL, without spaces" >&2; exit 1 ;;
    https://*) printf 'KEEPER_RPC_URLS=%s https://rpc3.monad.xyz https://rpc4.monad.xyz\n' "$REPLY" >> "$import" ;;
    *) echo "secrets: the RPC URL must be https" >&2; exit 1 ;;
  esac
  REPLY=
fi

count=$(grep -c '=' "$import" || true)
[ "$count" -gt 0 ] || { echo "secrets: nothing to import" >&2; exit 1; }
echo
echo "Importing $count secret(s) into the Fly app $app (staged: they reach the Machine at the next deploy)."
"$FLY" secrets import --app "$app" --stage < "$import" > /dev/null
echo "Imported. Their names: $(sed 's/=.*//' "$import" | tr '\n' ' ')"
if [ ${#addresses[@]} -gt 0 ]; then
  echo
  echo "Public addresses: fund them (grad 30, buybacks 10, sweeps 5 MON), and send them to engineering to pin in"
  echo "contracts/keepers/ops/keeper-signers.json (a reviewed commit; until then a unit runs dry runs only) and to"
  echo "record in custody-addresses.md:"
  for a in "${addresses[@]}"; do echo "  $a"; done
fi
echo "The temporary folder with the keystores is deleted now; Fly holds the only copy of each key."
echo
echo "Next (templates; no secret value ever goes on a command line):"
templates "$app"
