#!/usr/bin/env bash
# Run every forge/cast command that can sign on Monad through this wrapper (security audit 2026-09-26, SEC-1):
#
#   script/mainnet.sh forge script script/Deploy.s.sol:Deploy --rpc-url monad --broadcast --ledger
#   script/mainnet.sh cast send <to> 'sig()' --rpc-url https://rpc1.monad.xyz --account owner
#
# It works out the chain of the RPC the command uses (--rpc-url / -r / --fork-url / -f, else ETH_RPC_URL, else the
# foundry.toml alias "monad" for a bare `forge script`) with `cast chain-id`. On Monad mainnet (143) it refuses raw
# keys: --private-key(s), --mnemonic(s) and their passphrases/indexes, --interactive(s) (which prompt for a raw key),
# and PRIVATE_KEY / TREASURY_KEY / OWNER_KEY / DEPLOYER_PRIVATE_KEY / ETH_PRIVATE_KEY in the environment. Sign with
# --ledger or --account <keystore> instead. ALLOW_RAW_KEY_143=1 overrides, on purpose only. An RPC whose chain cannot
# be read is treated as mainnet (fail closed). Otherwise the command runs unchanged; nothing is printed or logged.
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: script/mainnet.sh forge|cast <args...>" >&2; exit 2; }
case "$1" in forge | cast) ;; *) echo "mainnet.sh only wraps forge and cast (got: $1)" >&2; exit 2 ;; esac

CAST=${CAST:-$(command -v cast || echo ~/.foundry/bin/cast)}
TOOL=$1
shift

rpc=
raw_flag=
prev=
for a in "$@"; do
  case "$prev" in --rpc-url | -r | --fork-url | -f) rpc=$a ;; esac
  case "$a" in
    --rpc-url=* | --fork-url=*) rpc=${a#*=} ;;
    --private-key | --private-key=* | --private-keys | --private-keys=*) raw_flag=$a ;;
    --mnemonic | --mnemonic=* | --mnemonics | --mnemonics=*) raw_flag=$a ;;
    --mnemonic-passphrase* | --mnemonic-index*) raw_flag=$a ;;
    --interactive | --interactives | --interactives=* | -i) raw_flag=$a ;;
  esac
  prev=$a
done
raw_flag=${raw_flag%%=*} # the flag name only, never its value
[ -n "$rpc" ] || rpc=${ETH_RPC_URL:-}
[ -n "$rpc" ] || { [ "$TOOL" = forge ] && [ "${1:-}" = script ] && rpc=monad; } || true

if [ -n "$rpc" ]; then
  chain=$("$CAST" chain-id --rpc-url "$rpc" 2>/dev/null || echo unknown)
else
  chain=none # nothing to sign against (a local simulation)
fi

if [ "$chain" = 143 ] || [ "$chain" = unknown ]; then
  if [ "${ALLOW_RAW_KEY_143:-0}" != 1 ]; then
    where="Monad mainnet (chain 143)"
    [ "$chain" = unknown ] && where="an RPC whose chain could not be read (treated as Monad mainnet)"
    if [ -n "$raw_flag" ]; then
      echo "refused: $raw_flag on $where. Sign with --ledger or --account <keystore> (ALLOW_RAW_KEY_143=1 overrides)." >&2
      exit 3
    fi
    for v in PRIVATE_KEY TREASURY_KEY OWNER_KEY DEPLOYER_PRIVATE_KEY ETH_PRIVATE_KEY; do
      if [ -n "${!v:-}" ]; then
        echo "refused: $v is set in the environment while targeting $where. Unset it and sign with --ledger or --account <keystore> (ALLOW_RAW_KEY_143=1 overrides)." >&2
        exit 3
      fi
    done
  fi
fi

exec "$TOOL" "$@"
