#!/bin/bash
# Brings a newer public app into the app copy: `git subtree pull --prefix=app --squash` from a checkout of the public
# DyorHQ app (docs/DESIGN-stellar-parity.md §1, "Where the app code lives"), then the build-23 guard on the result.
#
#   scripts/app-subtree-pull.sh <public app checkout> <branch>     e.g. ~/Hackathon release/25
#
# Run it on a clean working tree of this repository (git subtree refuses otherwise). The pull writes two commits: the
# new snapshot, "Squashed 'app/' changes from <old>..<new>" (the public app's tree, which the guards then compare with),
# and the merge into app/. git's own output goes to a log; this prints only the conflicts, when there are any, and the
# guards' findings:
#   - app/ios/Internal/check-build23.py: the Stellar hooks are still only inside #if STELLAR_LITE, and nothing else of
#     the new snapshot changed;
#   - app/ios/Internal/check-copies.py: the Stellar copies whose Monad source changed upstream, to re-sync.
#
# Exit status: 0 when the pull merged and both guards pass, 1 on conflicts or a finding, 2 when it can't run.
set -euo pipefail

say() { printf 'app-subtree-pull: %s\n' "$*"; }
die() {
  printf 'app-subtree-pull: %s\n' "$*" >&2
  exit 2
}

if [ $# -ne 2 ]; then
  printf 'usage: %s <public app checkout> <branch>\n' "$0" >&2
  exit 2
fi
UPSTREAM="$(cd "$1" 2>/dev/null && pwd)" || die "no directory $1"
BRANCH="$2"
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
[ -d "$ROOT/app/ios/Internal" ] || die "$ROOT has no app copy (app/ios/Internal)"
git -C "$UPSTREAM" rev-parse --verify -q "refs/heads/$BRANCH^{commit}" >/dev/null ||
  die "$UPSTREAM has no branch $BRANCH"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] ||
  die "$ROOT has uncommitted changes: commit or stash them first"

TMP="${TMPDIR:-/tmp}"
LOG="$(mktemp "${TMP%/}/app-subtree-pull.XXXXXX")"
TIP="$(git -C "$UPSTREAM" rev-parse --short "refs/heads/$BRANCH")"
BEFORE="$(git -C "$ROOT" rev-parse HEAD)"

status=0
git -C "$ROOT" subtree pull --prefix=app --squash -m "App: pull the public app's $BRANCH ($TIP) into app/" \
  "$UPSTREAM" "$BRANCH" >"$LOG" 2>&1 || status=$?
if [ "$status" -ne 0 ]; then
  conflicts="$(git -C "$ROOT" diff --name-only --diff-filter=U)"
  if [ -n "$conflicts" ]; then
    say "conflicts (git's log: $LOG):"
    printf '%s\n' "$conflicts" | sed 's/^/    /'
    say "resolve them, keeping every #if STELLAR_LITE block, and commit; then run app/ios/Internal/check-build23.py"
    say "and app/ios/Internal/check-copies.py"
    exit 1
  fi
  say "git subtree pull failed (exit $status); its log, $LOG:"
  tail -20 "$LOG" | sed 's/^/    /'
  exit 2
fi
rm -f "$LOG"
if [ "$(git -C "$ROOT" rev-parse HEAD)" = "$BEFORE" ]; then
  say "app/ already has $BRANCH ($TIP): nothing to pull"
else
  say "merged $BRANCH ($TIP) into app/ at $(git -C "$ROOT" rev-parse --short HEAD)"
fi

failed=0
python3 -I "$ROOT/app/ios/Internal/check-build23.py" || failed=1
python3 -I "$ROOT/app/ios/Internal/check-copies.py" || failed=1
exit "$failed"
