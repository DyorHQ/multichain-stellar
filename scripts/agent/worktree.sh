#!/bin/bash
# A work package's worktree of this repository (docs/DESIGN-stellar-parity.md §13.4):
#   ~/Hackathon-b17/wt/WP-xx/multichain-stellar   branch stellar/WP-xx from --base (default: main)
# The app copy is its app/ (A = $S/app), so the app and package changes of one package land on one branch, and
# app/ios/Internal/generate.py's default --lite (../../ios/Packages) finds the packages.
#
#   scripts/agent/worktree.sh WP-xx [--base <branch>]     then run the line it prints last: export S=… A=…
#
# --base is the branch to start from: the current integration branch (integrate/m0, …) when there is one, else main.
# It also writes the untracked app/ios/project.local.yml, the internal project's local spec: a copy of the netswitch
# checkout's, or, when that is missing, the same include of project.yml with Secrets.example.xcconfig for both
# configurations. It keeps /.secrets and that spec out of git (.git/info/exclude), and links S/.secrets to the main
# checkout's .secrets so that local-stack.sh can start. It never opens anything under .secrets, nor Secrets.xcconfig.
# It refuses when the directory or the branch already exists, and removes what it made when a later step fails.
set -euo pipefail

B17="$HOME/Hackathon-b17"
WT="$B17/wt"
LOCAL_SPEC="$B17/netswitch/ios/project.local.yml"
SPEC=app/ios/project.local.yml

say() { printf 'worktree: %s\n' "$*"; }
die() {
  printf 'worktree: %s\n' "$*" >&2
  exit 1
}
usage() {
  printf 'usage: %s WP-xx [--base <branch>]   (e.g. WP-21, WP-02b or WP-21-fix; --base defaults to main)\n' "$0" >&2
  exit 2
}

WP=
BASE=main
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || usage
      BASE="$2"
      shift 2
      ;;
    --base=*)
      BASE="${1#--base=}"
      shift
      ;;
    -*) usage ;;
    *)
      [ -z "$WP" ] || usage
      WP="$1"
      shift
      ;;
  esac
done
[[ "$WP" =~ ^WP-[A-Z0-9][A-Za-z0-9]{1,3}(-[a-z0-9]+)?$ ]] || usage
BRANCH="stellar/$WP"
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
# The main checkout: the one whose .git is this repository's common directory.
MAIN="$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")"
S="$WT/$WP/multichain-stellar"

git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null || die "no branch or commit $BASE in $ROOT"
[ ! -e "$S" ] || die "$S already exists; nothing changed"
if git -C "$ROOT" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null; then
  die "this repository already has a branch $BRANCH; nothing changed"
fi

# On a failure from here on, remove the worktree and branch this run made (both new, at the base commit).
made=
done_ok=
undo() {
  [ -z "$done_ok" ] || return 0
  if [ -n "$made" ]; then
    git -C "$ROOT" worktree remove --force "$S" 2>/dev/null || true
    git -C "$ROOT" branch -q -D "$BRANCH" 2>/dev/null || true
    say "removed the worktree and branch this run made"
  fi
  rmdir "$WT/$WP" 2>/dev/null || true
}
trap undo EXIT

mkdir -p "$WT/$WP"
git -C "$ROOT" worktree add -q -b "$BRANCH" "$S" "$BASE"
made=1
say "S: $S on $BRANCH from $BASE ($(git -C "$S" rev-parse --short HEAD))"
[ -f "$S/app/ios/Internal/generate.py" ] || die "$BASE has no app copy (app/ios/Internal/generate.py)"

# The local spec and .secrets stay out of git: .gitignore's `.secrets/` matches a directory, not a link to one, and
# info/exclude is shared by every worktree.
exclude="$(git -C "$S" rev-parse --path-format=absolute --git-path info/exclude)"
mkdir -p "$(dirname "$exclude")"
for pattern in /.secrets "/$SPEC"; do
  grep -qxF -e "$pattern" -e "${pattern#/}" "$exclude" 2>/dev/null || printf '%s\n' "$pattern" >>"$exclude"
done

# The internal project's local spec is untracked: from the netswitch checkout, or written here, never from git.
if [ -f "$LOCAL_SPEC" ]; then
  cp -p "$LOCAL_SPEC" "$S/$SPEC"
  say "A: copied $SPEC from $LOCAL_SPEC"
else
  cat >"$S/$SPEC" <<'YAML'
# Local only (excluded in .git/info/exclude, never committed): generates this worktree's project without the
# git-ignored Secrets.xcconfig, using the tracked example instead (every value empty: no Privy sign-in, passkeys off,
# the public Monad RPC). project.yml itself is unchanged.  xcodegen generate --spec project.local.yml
include:
  - path: project.yml
    relativePaths: true
configFiles:
  Debug: DyorHQ/Config/Secrets.example.xcconfig
  Release: DyorHQ/Config/Secrets.example.xcconfig
YAML
  say "A: wrote $SPEC (Secrets.example.xcconfig for Debug and Release)"
fi

if [ -d "$MAIN/.secrets" ]; then
  ln -s "$MAIN/.secrets" "$S/.secrets"
  say "S: .secrets links to $MAIN/.secrets (excluded from git)"
else
  say "note: $MAIN has no .secrets; local-stack.sh needs one (docs/RUNBOOK-testnet.md §1)"
fi

done_ok=1
printf 'export S=%q A=%q\n' "$S" "$S/app"
