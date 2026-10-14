#!/bin/bash
# A work package's two worktrees, side by side (docs/DESIGN-stellar-parity.md §13.4):
#   ~/Hackathon-b17/wt/WP-xx/IOS-app             branch stellar/WP-xx from lite/network-switch (~/Hackathon-b17/netswitch)
#   ~/Hackathon-b17/wt/WP-xx/multichain-stellar  branch stellar/WP-xx from this repository's main
# Side by side, ios/Internal/generate.py's default --lite (../../multichain-stellar/ios/Packages) finds the packages.
#
#   scripts/agent/worktree.sh WP-xx     then run the line it prints last: export A=… S=…
#
# It also copies the untracked ios/project.local.yml from the netswitch checkout into A, keeps /.secrets out of git
# here (.git/info/exclude), and links S/.secrets to the main checkout's .secrets so that local-stack.sh can start. It
# never opens anything under .secrets. It refuses when either directory or either branch already exists, and removes
# what it made when a later step fails.
set -euo pipefail

B17="$HOME/Hackathon-b17"
WT="$B17/wt"
NETSWITCH="$B17/netswitch"
APP_BASE=lite/network-switch
LITE_BASE=main

say() { printf 'worktree: %s\n' "$*"; }
die() {
  printf 'worktree: %s\n' "$*" >&2
  exit 1
}

WP="${1:-}"
if [ $# -ne 1 ] || [[ ! "$WP" =~ ^WP-[0-9]{2}(-[a-z0-9]+)?$ ]]; then
  printf 'usage: %s WP-xx   (e.g. WP-21, or WP-21-fix)\n' "$0" >&2
  exit 2
fi
BRANCH="stellar/$WP"
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
# The main checkout: the one whose .git is this repository's common directory.
MAIN="$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")"
A="$WT/$WP/IOS-app"
S="$WT/$WP/multichain-stellar"

git -C "$NETSWITCH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "no IOS-app checkout at $NETSWITCH"
git -C "$NETSWITCH" rev-parse --verify -q "refs/heads/$APP_BASE" >/dev/null || die "no branch $APP_BASE in $NETSWITCH"
git -C "$ROOT" rev-parse --verify -q "refs/heads/$LITE_BASE" >/dev/null || die "no branch $LITE_BASE in $ROOT"
for d in "$A" "$S"; do
  [ ! -e "$d" ] || die "$d already exists; nothing changed"
done
if git -C "$NETSWITCH" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null; then
  die "IOS-app already has a branch $BRANCH; nothing changed"
fi
if git -C "$ROOT" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null; then
  die "multichain-stellar already has a branch $BRANCH; nothing changed"
fi

# On a failure from here on, remove the worktrees and branches this run made (both are new, at their base commits).
made_app=
made_lite=
done_ok=
undo() {
  [ -z "$done_ok" ] || return 0
  if [ -n "$made_lite" ]; then
    git -C "$ROOT" worktree remove --force "$S" 2>/dev/null || true
    git -C "$ROOT" branch -q -D "$BRANCH" 2>/dev/null || true
  fi
  if [ -n "$made_app" ]; then
    git -C "$NETSWITCH" worktree remove --force "$A" 2>/dev/null || true
    git -C "$NETSWITCH" branch -q -D "$BRANCH" 2>/dev/null || true
  fi
  rmdir "$WT/$WP" 2>/dev/null || true
  [ -z "$made_app$made_lite" ] || say "removed the worktrees and branches this run made"
}
trap undo EXIT

mkdir -p "$WT/$WP"
git -C "$NETSWITCH" worktree add -q -b "$BRANCH" "$A" "$APP_BASE"
made_app=1
say "A: $A on $BRANCH from $APP_BASE ($(git -C "$A" rev-parse --short HEAD))"
git -C "$ROOT" worktree add -q -b "$BRANCH" "$S" "$LITE_BASE"
made_lite=1
say "S: $S on $BRANCH from $LITE_BASE ($(git -C "$S" rev-parse --short HEAD))"

# The internal project's local spec is untracked: it comes from the netswitch checkout, never from git.
if [ -f "$NETSWITCH/ios/project.local.yml" ]; then
  cp -p "$NETSWITCH/ios/project.local.yml" "$A/ios/project.local.yml"
  say "A: copied ios/project.local.yml"
else
  say "note: $NETSWITCH/ios/project.local.yml is missing; generate.py --spec project.local.yml needs it"
fi

# .gitignore's `.secrets/` matches a directory, not a link to one; info/exclude is shared by every worktree.
exclude="$(git -C "$S" rev-parse --path-format=absolute --git-path info/exclude)"
mkdir -p "$(dirname "$exclude")"
grep -qxF '/.secrets' "$exclude" 2>/dev/null || printf '/.secrets\n' >>"$exclude"
if [ -d "$MAIN/.secrets" ]; then
  ln -s "$MAIN/.secrets" "$S/.secrets"
  say "S: .secrets links to $MAIN/.secrets (excluded from git)"
else
  say "note: $MAIN has no .secrets; local-stack.sh needs one (docs/RUNBOOK-testnet.md §1)"
fi

if [ -x "$A/scripts/dev/install-hooks.sh" ] && ! "$A/scripts/dev/install-hooks.sh" --check --quiet; then
  say "note: the leak-guard hooks are not active in A; run scripts/dev/install-hooks.sh there before committing"
fi

done_ok=1
printf 'export A=%q S=%q\n' "$A" "$S"
