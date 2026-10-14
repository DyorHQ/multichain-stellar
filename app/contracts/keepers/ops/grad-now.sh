#!/bin/bash
# The manual one-shot graduation (build 17 plan 2.9 step 17): until the grad unit sends on its own, the owner finishes
# a stuck launch or Moment with this, on the keepers machine, from their Mac:
#
#   fly ssh console --app dyorhq-keepers -C "/app/contracts/keepers/ops/grad-now.sh"          # dry run: what it would send
#   fly ssh console --app dyorhq-keepers -C "/app/contracts/keepers/ops/grad-now.sh --send"   # sends, with the grad key
#
# It runs the grad unit (moments-graduation, launchpad-graduation) once, now, as the keeper user: the same simulations,
# receipt checks, spend cap, state file and alerts as a scheduled run, after waiting for a scheduled grad run to end.
# With --send it sends even while KEEPER_SEND_GRAD is 0; each send prints "sent … tx 0x… succeeded" or raises a
# critical alert. It pings no healthchecks.io check. Never add `set -x`.
set -u

send=
case "${1:-}" in
  "") ;;
  --send) send=--send ;;
  *) echo "grad-now: usage: grad-now.sh [--send]" >&2; exit 64 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
if [ "$(id -u)" = 0 ]; then
  # An ssh session's environment carries the Fly secrets: the run gets a clean one, as the keeper user.
  keep=(PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/keeper TZ=UTC LANG=C.UTF-8 NODE_ENV=production
    KEEPER_SECRETS_DIR=/run/dyor-keeper KEEPER_DATA_DIR=/data KEEPER_APP_DIR=/app)
  for name in KEEPER_TELEGRAM_CHAT_ID KEEPER_RPC_URLS; do
    [ -n "${!name-}" ] && keep+=("$name=${!name}")
  done
  exec setpriv --reuid=10001 --regid=10001 --init-groups --no-new-privs --inh-caps=-all --bounding-set=-all \
    env -i "${keep[@]}" "$here/run-keeper.sh" grad --manual $send
fi
exec "$here/run-keeper.sh" grad --manual $send
