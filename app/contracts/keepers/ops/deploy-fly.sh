#!/bin/bash
# Deploys a keepers bundle (ops/bundle.sh) to Fly.io (build 17 K4). Run by the owner, from their Mac, logged in with
# flyctl. It checks the bundle before anything else: made from a reviewed commit, every file matching its SHA256
# manifest, and no file the manifest does not list. The image is built from the bundle alone (the Dockerfile's test
# stage runs the keeper tests), tagged with the commit, and rolled onto the app's single Machine.
#
#   contracts/keepers/ops/deploy-fly.sh BUNDLE_DIR [--app NAME] [--remote-builder] [--check-only] [--yes]
#
#   --app NAME         the Fly app (default: the app in the bundle's fly.toml, dyorhq-keepers)
#   --remote-builder   build on Fly's remote builder instead of the local Docker daemon (the default is local)
#   --check-only       verify the bundle and print the fly command, then stop (no Fly call)
#   --yes              do not ask for the commit to be typed back
#
# It refuses to deploy onto an app with more than one Machine, and afterwards checks that the app has exactly one
# Machine and no IP address. Never add `set -x`.
set -euo pipefail

bundle=
app=
builder=--local-only
check_only=0
assume_yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || { echo "deploy: --app needs a name" >&2; exit 64; }; app=$2; shift ;;
    --remote-builder) builder=--remote-only ;;
    --check-only) check_only=1 ;;
    --yes) assume_yes=1 ;;
    -h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "deploy: unknown option $1" >&2; exit 64 ;;
    *) bundle=$1 ;;
  esac
  shift
done
[ -n "$bundle" ] || { echo "deploy: usage: deploy-fly.sh BUNDLE_DIR [--app NAME] [--remote-builder] [--check-only] [--yes]" >&2; exit 64; }
[ -d "$bundle" ] || { echo "deploy: $bundle is not a directory (unpack the tarball first)" >&2; exit 2; }
bundle=$(cd "$bundle" && pwd)

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
fail() { echo "deploy: REFUSED: $*" >&2; exit 1; }

# ---- the bundle
for f in BUNDLE_COMMIT BUNDLE_REVIEWED BUNDLE_MANIFEST.sha256 contracts/keepers/ops/fly.toml contracts/keepers/ops/Dockerfile; do
  [ -f "$bundle/$f" ] || fail "$f is missing: not a bundle from ops/bundle.sh"
done
IFS= read -r sha < "$bundle/BUNDLE_COMMIT"
IFS= read -r reviewed < "$bundle/BUNDLE_REVIEWED"
case "$sha" in *[!0-9a-f]* | "") fail "BUNDLE_COMMIT is not a commit id" ;; esac
[ ${#sha} = 40 ] || fail "BUNDLE_COMMIT is not a full commit id"
case "$reviewed" in "reviewed: on origin/main"*) ;; *) fail "the bundle was not made from a reviewed commit ($reviewed)" ;; esac
# Run from a checkout that knows the commit, the claim is checked against git too (git fetch origin first).
if git rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
  git merge-base --is-ancestor "$sha" origin/main 2>/dev/null || fail "commit ${sha:0:12} is not on origin/main in this checkout"
else
  echo "deploy: note: this checkout does not know commit ${sha:0:12}; trusting the bundle's own record" >&2
fi
(cd "$bundle" && sha256 -c BUNDLE_MANIFEST.sha256 >/dev/null 2>&1) || {
  (cd "$bundle" && sha256 -c BUNDLE_MANIFEST.sha256 2>/dev/null | grep -v ': OK$' | head -5) >&2 || true
  fail "files differ from the bundle's manifest"
}
listed=$(sed 's/^[0-9a-f]\{64\}  //' "$bundle/BUNDLE_MANIFEST.sha256" | LC_ALL=C sort)
present=$(cd "$bundle" && find . -type f ! -name BUNDLE_MANIFEST.sha256 | sed 's|^\./||' | LC_ALL=C sort)
[ "$listed" = "$present" ] || fail "the bundle holds files its manifest does not list (or lacks listed ones)"
short=${sha:0:12}
[ -n "$app" ] || app=$(sed -n 's/^app = "\(.*\)"$/\1/p' "$bundle/contracts/keepers/ops/fly.toml" | head -n 1)
[ -n "$app" ] || fail "no app name: pass --app"

cmd=(fly deploy "$bundle"
  --config "$bundle/contracts/keepers/ops/fly.toml"
  --dockerfile "$bundle/contracts/keepers/ops/Dockerfile"
  --app "$app"
  "$builder"
  --image-label "keepers-$short"
  --ha=false
  --no-public-ips
  --strategy rolling
  --yes)
echo "deploy: bundle $short ($reviewed), $(wc -l < "$bundle/BUNDLE_MANIFEST.sha256" | tr -d ' ') files, manifest OK"
echo "deploy: app $app, builder ${builder#--}"
echo "deploy: ${cmd[*]}"
if [ "$check_only" = 1 ]; then
  echo "deploy: --check-only: nothing was deployed"
  exit 0
fi

command -v fly >/dev/null 2>&1 || fail "flyctl (fly) is not installed"
fly auth whoami >/dev/null 2>&1 || fail "not logged in to Fly: run fly auth login"
count_machines() { fly machine list --app "$app" --quiet 2>/dev/null | grep -c -E '^[0-9a-f]{8,}$' || true; }
before=$(count_machines)
[ "${before:-0}" -le 1 ] || fail "the app already has $before Machines: two keepers would send from the same keys. Destroy the extra ones first (fly machine list --app $app)"
if [ "$assume_yes" = 0 ]; then
  printf 'Deploy commit %s to the Fly app %s? Type the first 12 characters of the commit to go on: ' "$short" "$app"
  IFS= read -r answer
  [ "$answer" = "$short" ] || fail "not confirmed"
fi

"${cmd[@]}"

# ---- after the deploy: one Machine, no address
machines=$(count_machines)
ips=$(fly ips list --app "$app" --json 2>/dev/null | tr -d ' \n\t')
status=0
if [ "$machines" != 1 ]; then
  echo "deploy: WARNING: the app has $machines Machines, not 1: two keepers would send from the same keys. Stop the extra ones now (fly machine destroy <id> --app $app)." >&2
  status=1
fi
case "$ips" in "" | "[]" | "null") ;; *)
  echo "deploy: WARNING: the app has IP addresses; the keepers need none (fly ips list --app $app, then fly ips release <ip> --app $app)." >&2
  status=1 ;;
esac
ids=$(fly machine list --app "$app" --quiet 2>/dev/null | grep -E '^[0-9a-f]{8,}$' || true)
if [ "$machines" = 1 ]; then
  echo "deploy: the keeper Machine is $ids. Only the Machine KEEPER_MACHINE_ID names may send; on the first deploy (or after replacing the Machine) pin it once: fly secrets set KEEPER_MACHINE_ID=$ids --app $app"
fi
echo "deploy: done: commit $short on $app ($machines Machine). Watch it: fly logs --app $app"
exit "$status"
