#!/bin/bash
# Turns on the tracked leak-guard hooks (.githooks/: pre-commit, pre-merge-commit, commit-msg, pre-push) for this clone and every
# worktree of it. Run it once per clone; the SessionStart hook in .claude/settings.json runs it for every Claude Code
# session. Safe to re-run.
#
#   scripts/dev/install-hooks.sh            # set up (or refresh) the hooks
#   scripts/dev/install-hooks.sh --check    # exit 0 when this worktree runs the leak guard, 1 when not; no changes
#   --force                                 # also replace another tool's hooks (kept as <hook>.bak) or core.hooksPath
#   --quiet                                 # print problems only
#
# Two set-ups, picked automatically:
#   core.hooksPath=.githooks — when every worktree of the clone has .githooks/ (a fresh clone, CI, a cloud session).
#     git then runs the checked-out branch's own .githooks/ directly, and stops running the hooks in <git common
#     dir>/hooks: when another tool has hooks there (Git LFS, a hook manager), this refuses to switch unless --force.
#   dispatchers — when some worktree checks out a branch from before .githooks/ existed (the main ~/Hackathon checkout
#     and its many worktrees): core.hooksPath would leave those worktrees with no hooks at all, because it applies to
#     the whole clone. Small dispatchers go into the shared hooks directory (<git common dir>/hooks) instead. Each runs
#     the worktree's .githooks/<hook> when its branch has one; otherwise the secret scan those branches always had
#     (their own scripts/dev/secret-scan.sh, else the copy stored next to the dispatchers).
# Either way this supersedes the hooks that `secret-scan.sh --install-hook` used to write (marked dyorhq-secret-scan):
# dispatchers replace them, and git stops reading that directory once core.hooksPath is set. Re-running after the old
# branches are gone switches to core.hooksPath.
set +x

QUIET=; FORCE=; CHECK=
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    --force) FORCE=1 ;;
    --check) CHECK=1 ;;
    *) sed -n '6,9p' "$0" | sed 's/^# //' >&2; exit 2 ;;
  esac
done
say() { [ -n "$QUIET" ] || echo "install-hooks: $*"; }
warn() { echo "install-hooks: $*" >&2; }
die() { warn "$*"; exit 2; }

HOOK_NAMES="pre-commit pre-merge-commit commit-msg pre-push"
# Every hook name git runs: a hook of another tool under one of these names stops running under core.hooksPath.
GIT_HOOKS="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg
  post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive post-receive post-update
  reference-transaction push-to-checkout pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman post-index-change
  p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit"
OURS='dyorhq-(leak-guard|secret-scan)' # markers of this guard's hooks, new and old
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOP=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
COMMON=$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir) || die "cannot find the git directory"
HOOKS_DIR="$COMMON/hooks"
CURRENT=$(git -C "$TOP" config --get core.hooksPath)

active() { # this worktree runs the leak guard
  if [ "$CURRENT" = .githooks ]; then [ -f "$TOP/.githooks/pre-commit" ]; return; fi
  [ -z "$CURRENT" ] && grep -qs 'dyorhq-leak-guard' "$HOOKS_DIR/pre-commit"
}
if [ -n "$CHECK" ]; then
  if active; then say "active ($([ "$CURRENT" = .githooks ] && echo core.hooksPath || echo dispatchers))."; exit 0; fi
  warn "the leak-guard hooks are NOT active in $TOP — run scripts/dev/install-hooks.sh."
  exit 1
fi

[ -f "$TOP/.githooks/pre-commit" ] || die "$TOP/.githooks/ is missing"
if [ -n "$CURRENT" ] && [ "$CURRENT" != .githooks ] && [ -z "$FORCE" ]; then
  die "core.hooksPath is already set to $CURRENT (another hook manager?) — left untouched. Re-run with --force to replace it."
fi

# Worktrees whose checked-out branch has no .githooks/ (a missing directory is a stale worktree entry: skipped).
LACKING=
while IFS= read -r line; do
  case "$line" in
    'worktree '*) wt=${line#worktree }; [ -d "$wt" ] && [ ! -f "$wt/.githooks/pre-commit" ] && LACKING="$LACKING $wt" ;;
  esac
done < <(git -C "$TOP" worktree list --porcelain)

# git skips a hook file that is not executable; a checkout on a filesystem without modes can lose the bit.
for h in $HOOK_NAMES; do [ -x "$TOP/.githooks/$h" ] || chmod 755 "$TOP/.githooks/$h" 2>/dev/null; done

if [ -z "$LACKING" ]; then
  if [ "$CURRENT" != .githooks ] && [ -z "$FORCE" ]; then
    FOREIGN=
    for h in $GIT_HOOKS; do
      [ -f "$HOOKS_DIR/$h" ] && [ -x "$HOOKS_DIR/$h" ] && ! grep -qE "$OURS" "$HOOKS_DIR/$h" && FOREIGN="$FOREIGN $h"
    done
    [ -z "$FOREIGN" ] || die "core.hooksPath=.githooks would switch off another tool's hooks in $HOOKS_DIR:$FOREIGN — left untouched. Call them from .githooks/ or re-run with --force."
  fi
  git -C "$TOP" config core.hooksPath .githooks || die "cannot set core.hooksPath"
  say "core.hooksPath=.githooks — every worktree of this clone runs its branch's .githooks/."
  exit 0
fi

# ---------- dispatchers in the shared hooks directory ----------
# git reads the shared hooks directory only while core.hooksPath is unset (a foreign value got here only with --force).
if [ -n "$CURRENT" ]; then git -C "$TOP" config --unset core.hooksPath || die "cannot unset core.hooksPath"; fi
mkdir -p "$HOOKS_DIR" || die "cannot create $HOOKS_DIR"
# The fallback scanner for branches that have none, with the wordlist it reads.
for f in secret-scan.sh bip39-english.txt; do
  cp "$SCRIPT_DIR/$f" "$HOOKS_DIR/$f.tmp.$$" && mv -f "$HOOKS_DIR/$f.tmp.$$" "$HOOKS_DIR/$f" || die "cannot copy $f into $HOOKS_DIR"
done
chmod 755 "$HOOKS_DIR/secret-scan.sh"
STATUS=0
for h in $HOOK_NAMES; do
  nofallback=
  case "$h" in
    pre-push) fallback=--pre-push ;;
    commit-msg) fallback=; nofallback='exit 0 # those branches never checked commit messages' ;;
    *) fallback=--staged ;;
  esac
  hook="$HOOKS_DIR/$h"
  if [ -e "$hook" ] && ! grep -qE "$OURS" "$hook"; then
    if [ -z "$FORCE" ]; then
      warn "$hook belongs to another tool — left untouched (re-run with --force to replace it; it is kept as $h.bak)."
      STATUS=1; continue
    fi
    cp -p "$hook" "$hook.bak" || die "cannot back up $hook"
  fi
  cat > "$hook.tmp.$$" <<EOF || die "cannot write $hook"
#!/bin/bash
# dyorhq-leak-guard dispatcher for $h (written by scripts/dev/install-hooks.sh; shared by every worktree).
# Runs the checked-out branch's tracked .githooks/$h. A branch from before .githooks/ existed gets the secret scan it
# always had: its own scripts/dev/secret-scan.sh, else the copy stored next to this dispatcher.
top=\$(git rev-parse --show-toplevel) || exit 1
[ -f "\$top/.githooks/$h" ] && exec /bin/bash "\$top/.githooks/$h" "\$@"
$nofallback
scanner="\$top/scripts/dev/secret-scan.sh"
[ -f "\$scanner" ] || scanner="$HOOKS_DIR/secret-scan.sh"
if [ ! -f "\$scanner" ]; then
  echo "$h: no leak guard found; refusing to continue unscanned." >&2
  exit 1
fi
# A traced or BASH_ENV-injected shell could print the values the scanner holds.
exec env -u BASH_ENV -u SHELLOPTS /bin/bash "\$scanner" $fallback "\$@"
EOF
  chmod 755 "$hook.tmp.$$" && mv -f "$hook.tmp.$$" "$hook" || die "cannot install $hook"
done
[ $STATUS = 0 ] && say "dispatchers in $HOOKS_DIR — worktrees on a branch with .githooks/ run it, the others keep their secret scan (worktrees without .githooks/:$LACKING)."
exit $STATUS
