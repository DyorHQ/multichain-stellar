#!/bin/bash
# Forbidden-path guard. Fails when a path that must never be in this repository is tracked, staged or pushed: env
# files, key and signing material, build products, local AI-session settings, and internal documents (audit reports,
# security reviews, runbooks, handoffs), which belong in the private DyorHQ/internal repository. Also enforces the
# repository's pinned files and push URLs (.leakguard "@pin" and "@push-url" lines). Prints paths and the matching
# pattern only, never file contents.
#
#   scripts/dev/forbidden-paths.sh                    # every tracked path (CI)
#   scripts/dev/forbidden-paths.sh --staged           # paths a commit would add, change or delete (pre-commit hook)
#   scripts/dev/forbidden-paths.sh --pre-push R URL   # commits being pushed to remote R, refs on stdin (pre-push hook)
#   scripts/dev/forbidden-paths.sh --history [REV…]   # commits `git log REV…` lists (default: --all), e.g. A..B in CI
#   scripts/dev/forbidden-paths.sh --check PATH…      # the given paths (no git needed with --config)
#   --config FILE                                     # patterns from FILE instead of .leakguard (repeatable)
#   --repo DIR                                        # run in another repository
#
# Patterns: the built-in secret-material list below, then the repository's .leakguard (see its header). One glob per
# line; "!glob" exempts paths that a deny glob matched. A glob without "/" matches the file name at any depth, a glob
# with "/" matches the whole path from the repository root, and a leading "/" anchors a file name at the root; "*"
# also matches "/", matching ignores case, and one "{a,b,…}" group expands to one glob per alternative. A path is
# forbidden when a deny glob matches it and no "!" glob does. Built-in matches (secret material) can only be exempted
# by a "!" line without wildcards, e.g. "!certs/public-test.pem".
# Directives: "@only GLOB" — an allowlist: when a .leakguard has @only lines, every path must match one of them too
# (a "!" line does not override it); "@pin PATH SHA256" — the file must exist with exactly that content and no commit
# may delete it; "@push-url GLOB" — pushes go only to a remote whose URL (host/path, lower case, without credentials or
# ".git") matches one of these globs. Other "@" lines are read by scripts/dev/secret-scan.sh and the workflow.
#
# Which .leakguard counts: with --config, the given files. Otherwise the committed version AND the pending one, and a
# path is forbidden when either forbids it: HEAD's and the index's (--staged), HEAD's and the working tree's (tracked,
# --history, --check), the pushed commit's and the remote branch's (--pre-push). A change to .leakguard can tighten
# the check at once, but loosens it only from the next commit on, so no commit can exempt itself.
# Exit status: 0 clean, 1 forbidden paths, 2 usage or setup error. Runs on macOS /bin/bash 3.2.
set +x
export LC_ALL=C

# Secret material, forbidden in every repository whatever its .leakguard says: env files and their copies (".env copy",
# .env-prod, prod.env.bak), Cloudflare .dev.vars, the iOS Secrets.xcconfig and its copies, keys and certificates (also
# renamed, e.g. deployer.key.txt), geth/foundry keystores, signed builds and local Claude settings.
BUILTIN_DENY=(
  '.env*' '*.env' '*.env.*' '.dev.vars*' 'Secrets*.xcconfig*'
  '*.p8' '*.p8.*' '*.p12' '*.pfx' '*.pem' '*.pem.*' '*.key' '*.key.*' '*.mobileprovision' '*.provisionprofile'
  '*.keystore' '*.jks' '*.kdbx' 'UTC--*' '*keystore/*' '*keystores/*'
  id_rsa id_dsa id_ecdsa id_ed25519 '.claude/settings.local.json' '*/.claude/settings.local.json' '.claude/*.local.*'
  '*.xcarchive/*' '*.ipa'
)
# Templates with placeholder values (their contents are still scanned by secret-scan.sh).
BUILTIN_ALLOW=(
  '.env.example' '.env.sample' '.env.template' '.env.*.example' '.env.*.sample' '.env.*.template'
  '*.env.example' '*.env.sample' '*.env.template' '.dev.vars.example' '.dev.vars.sample' '.dev.vars.template'
  'Secrets.example.xcconfig'
)

usage() { sed -n '8,14p' "$0" | sed 's/^# //' >&2; exit 2; }
die() { echo "forbidden-paths: $*" >&2; exit 2; }

MODE=tracked; CONFIGS=(); REPO=; ARGS=(); REMOTE=; URL=
while [ $# -gt 0 ]; do
  case "$1" in
    --tracked) MODE=tracked ;;
    --staged) MODE=staged ;;
    --pre-push) MODE=push; REMOTE=${2:-}; URL=${3:-${2:-}}; break ;; # git passes the remote and its URL; refs on stdin
    --history) MODE=history; shift; ARGS=("$@"); break ;;
    --check) MODE=check; shift; ARGS=("$@"); break ;;
    --config) [ $# -ge 2 ] || usage; [ -f "$2" ] || die "no such config file: $2"
      CONFIGS[${#CONFIGS[@]}]="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;; # absolute: the scan cds
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[ "$MODE" = history ] && [ ${#ARGS[@]} -eq 0 ] && ARGS=(--all)

TOP=
if [ "$MODE" != check ] || [ ${#CONFIGS[@]} -eq 0 ]; then
  TOP=$(git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  cd "$TOP" || die "cannot enter $TOP"
fi

# ---------- .leakguard versions ("slots"): a path is forbidden when any slot forbids it ----------
NSLOT=0; SLOT_TEXT=(); SLOT_LABEL=()
DENY_G=(); DENY_S=(); ALLOW_G=(); ALLOW_S=(); ONLY_G=(); ONLY_S=(); PIN_P=(); PIN_H=(); URL_G=(); URL_S=()
reset_config() {
  NSLOT=0; SLOT_TEXT=(); SLOT_LABEL=(); DENY_G=(); DENY_S=(); ALLOW_G=(); ALLOW_S=(); ONLY_G=(); ONLY_S=()
  PIN_P=(); PIN_H=(); URL_G=(); URL_S=()
}
add_glob() { # deny|allow|only|url glob — one {a,b,…} group expands to one glob per alternative
  local pre rest alts post a IFS
  case "$2" in
    *'{'*'}'*)
      pre=${2%%\{*}; rest=${2#*\{}; alts=${rest%%\}*}; post=${rest#*\}}
      IFS=,; set -f
      for a in $alts; do add_glob "$1" "$pre$a$post"; done
      set +f ;;
    *)
      case "$1" in
        deny) DENY_G[${#DENY_G[@]}]=$2; DENY_S[${#DENY_S[@]}]=$NSLOT ;;
        allow) ALLOW_G[${#ALLOW_G[@]}]=$2; ALLOW_S[${#ALLOW_S[@]}]=$NSLOT ;;
        only) ONLY_G[${#ONLY_G[@]}]=$2; ONLY_S[${#ONLY_S[@]}]=$NSLOT ;;
        url) URL_G[${#URL_G[@]}]=$2; URL_S[${#URL_S[@]}]=$NSLOT ;;
      esac ;;
  esac
}
add_slot() { # text label — one version of .leakguard (an identical one already loaded is skipped)
  local i=0 line p h x
  while [ $i -lt $NSLOT ]; do [ "${SLOT_TEXT[$i]}" = "$1" ] && return 0; i=$((i + 1)); done
  SLOT_TEXT[$NSLOT]=$1; SLOT_LABEL[$NSLOT]=$2
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) ;;
      @pin[[:space:]]*)
        read -r p h x <<< "${line#@pin}"
        [[ -n $p && $h =~ ^[0-9a-fA-F]{64}$ && -z $x ]] || die "$2: malformed line: @pin PATH SHA256"
        PIN_P[${#PIN_P[@]}]=$p; PIN_H[${#PIN_H[@]}]=$(printf '%s' "$h" | tr A-F a-f) ;;
      @only[[:space:]]*)
        read -r p x <<< "${line#@only}"
        [ -n "$p" ] && [ -z "$x" ] || die "$2: malformed line: @only GLOB"
        add_glob only "$p" ;;
      @push-url[[:space:]]*)
        read -r p x <<< "${line#@push-url}"
        [ -n "$p" ] && [ -z "$x" ] || die "$2: malformed line: @push-url GLOB"
        add_glob url "$p" ;;
      '@'*) ;; # read by scripts/dev/secret-scan.sh (@public, @internal, @allow) and the workflow (@history-base)
      '!'*) add_glob allow "${line#!}" ;;
      *) add_glob deny "$line" ;;
    esac
  done <<< "$1"
  NSLOT=$((NSLOT + 1))
}
add_file() { [ -f "$1" ] && add_slot "$(cat "$1")" "$2"; return 0; } # file label
add_rev() { # rev label — "" is the index
  local t
  t=$(git show "$1:.leakguard" 2>/dev/null) && add_slot "$t" "$2"
  return 0
}
load_configs() { # the --config files, or the default versions for this mode
  local f
  if [ ${#CONFIGS[@]} -gt 0 ]; then
    for f in "${CONFIGS[@]}"; do add_file "$f" "$f"; done
    return 0
  fi
  case "$MODE" in
    push) return 0 ;; # per pushed ref, in check_pushed
    staged) add_rev HEAD "HEAD:.leakguard"; add_rev "" "the staged .leakguard" ;;
    tracked|history|check) add_rev HEAD "HEAD:.leakguard"; add_file "$TOP/.leakguard" ".leakguard" ;;
  esac
  [ $NSLOT -gt 0 ] || echo "forbidden-paths: warning — no .leakguard found; only the built-in secret-file list is checked." >&2
  return 0
}

shopt -s nocasematch
matches() { # path glob
  case "$2" in
    /*) [[ $1 == ${2#/} ]] ;;
    */*) [[ $1 == $2 ]] ;;
    *) [[ ${1##*/} == $2 ]] ;;
  esac
}
exact_glob() { case "$1" in *[*?[]*) return 1 ;; esac; return 0; }
check_path() { # path [label] — prints a finding when the path is forbidden
  local g i j s ok
  for g in "${BUILTIN_DENY[@]}"; do
    matches "$1" "$g" || continue
    for i in "${BUILTIN_ALLOW[@]}"; do matches "$1" "$i" && return 0; done
    # Secret material: only an exact "!" line in every .leakguard version exempts it.
    [ $NSLOT -gt 0 ] || { echo "${2:-$1}: forbidden path (matches \"$g\")"; return 0; }
    s=0
    while [ $s -lt $NSLOT ]; do
      ok=; j=0
      while [ $j -lt ${#ALLOW_G[@]} ]; do
        if [ "${ALLOW_S[$j]}" = $s ] && exact_glob "${ALLOW_G[$j]}" && matches "$1" "${ALLOW_G[$j]}"; then ok=1; break; fi
        j=$((j + 1))
      done
      [ -n "$ok" ] || { echo "${2:-$1}: forbidden path (matches \"$g\")"; return 0; }
      s=$((s + 1))
    done
    return 0
  done
  # @only: in a .leakguard that has these lines, the path must match one of them.
  s=0
  while [ $s -lt $NSLOT ]; do
    ok=-; j=0
    while [ $j -lt ${#ONLY_G[@]} ]; do
      if [ "${ONLY_S[$j]}" = $s ]; then
        ok=
        matches "$1" "${ONLY_G[$j]}" && { ok=1; break; }
      fi
      j=$((j + 1))
    done
    [ -z "$ok" ] && { echo "${2:-$1}: forbidden path (not in the .leakguard @only list)"; return 0; }
    s=$((s + 1))
  done
  i=0
  while [ $i -lt ${#DENY_G[@]} ]; do
    if matches "$1" "${DENY_G[$i]}"; then
      s=${DENY_S[$i]}; ok=; j=0
      while [ $j -lt ${#ALLOW_G[@]} ]; do
        if [ "${ALLOW_S[$j]}" = "$s" ] && matches "$1" "${ALLOW_G[$j]}"; then ok=1; break; fi
        j=$((j + 1))
      done
      [ -n "$ok" ] || { echo "${2:-$1}: forbidden path (matches \"${DENY_G[$i]}\")"; return 0; }
    fi
    i=$((i + 1))
  done
  return 0
}

# ---------- pinned files ----------
sha256() { # stdin — prints the hex digest
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else openssl dgst -sha256 -r | cut -d' ' -f1; fi
}
is_pinned() { local p; for p in "${PIN_P[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }
check_pins() { # every pinned file must be in the index with its pinned content
  local p seen=/
  for p in "${PIN_P[@]}"; do
    case "$seen" in *"/$p/"*) continue ;; esac
    seen="$seen$p/"
    check_pin "$p" "$p" ":$p"
  done
}
check_pin() { # label path object — the object (":path" or "sha:path") must hold every content pinned for the path
  local i=0 h=
  while [ $i -lt ${#PIN_P[@]} ]; do
    if [ "${PIN_P[$i]}" = "$2" ]; then
      if ! git cat-file -e "$3" 2>/dev/null; then echo "$1: pinned file is missing (.leakguard @pin)"; return 0; fi
      [ -n "$h" ] || h=$(git cat-file blob "$3" | sha256)
      [ "$h" = "${PIN_H[$i]}" ] || { echo "$1: pinned file changed (its sha256 is not the one .leakguard @pin allows)"; return 0; }
    fi
    i=$((i + 1))
  done
}
check_change() { # status path label object — one added, changed or deleted path
  case "$1" in
    D) is_pinned "$2" && echo "$3: deletes a pinned file (.leakguard @pin)" ;;
    *) check_path "$2" "$3"; is_pinned "$2" && check_pin "$3" "$2" "$4" ;;
  esac
  return 0
}

# ---------- push URLs ----------
norm_url() { # URL — host/path in lower case, without scheme, credentials, trailing "/" or ".git"
  local u=$1 auth rest scp=
  case "$u" in *://*) u=${u#*://} ;; *) scp=1 ;; esac
  auth=${u%%/*}; rest=${u#"$auth"}
  auth=${auth##*@}
  if [ -n "$scp" ]; then case "$auth" in *:*) rest="/${auth#*:}$rest"; auth=${auth%%:*} ;; esac; fi
  u=$auth$rest; u=${u%/}; u=${u%.git}
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}
check_url() { # URL — every .leakguard version with @push-url lines must allow it
  local u s i ok
  u=$(norm_url "$1")
  s=0
  while [ $s -lt $NSLOT ]; do
    ok=-; i=0
    while [ $i -lt ${#URL_G[@]} ]; do
      if [ "${URL_S[$i]}" = $s ]; then
        [ "$ok" = - ] && ok=
        [[ $u == ${URL_G[$i]} ]] && { ok=1; break; }
      fi
      i=$((i + 1))
    done
    [ -z "$ok" ] && { echo "push to $u: not a remote this repository may push to (.leakguard @push-url)"; return 0; }
    s=$((s + 1))
  done
  return 0
}

# ---------- commits ----------
commit_changes() { # sha — status and path of each change (a merge: against its first parent), NUL-separated
  if git rev-parse -q --verify "$1^" >/dev/null; then git diff-tree -r --no-renames --name-status -z "$1^" "$1"
  else git diff-tree -r --root --no-renames --no-commit-id --name-status -z "$1"; fi
}
check_commits() { # git rev-list arguments
  local c st p
  for c in $(git rev-list "$@"); do
    while IFS= read -r -d '' st && IFS= read -r -d '' p; do check_change "$st" "$p" "${c:0:7}:$p" "$c:$p"; done \
      < <(commit_changes "$c")
  done
}
remote_base() { # remote — the remote's default branch as fetched here, if any
  local r
  git config --get "remote.$1.url" >/dev/null 2>&1 || return 0
  r=$(git symbolic-ref -q "refs/remotes/$1/HEAD" 2>/dev/null)
  [ -n "$r" ] || for r in "refs/remotes/$1/main" "refs/remotes/$1/master" ""; do
    git rev-parse -q --verify "$r" >/dev/null 2>&1 && break
  done
  [ -n "$r" ] && git rev-parse -q --verify "$r^{commit}"
  return 0
}
# Commits the remote does not have yet: everything not on one of ITS remote-tracking refs (other remotes do not count:
# a commit on a private remote is not yet on this one), nor on the ref being updated.
check_pushed() {
  local refs lref lsha rref rsha base
  refs=$(cat)
  while read -r lref lsha rref rsha; do
    case "$lsha" in *[!0]*) ;; *) continue ;; esac # a deleted ref pushes no commits
    git rev-parse -q --verify "$lsha^{commit}" >/dev/null || die "cannot read the pushed commit for $lref"
    base=
    case "$rsha" in *[!0]*) git rev-parse -q --verify "$rsha^{commit}" >/dev/null && base=$rsha ;; esac
    [ -n "$base" ] || base=$(remote_base "$REMOTE")
    if [ ${#CONFIGS[@]} -eq 0 ]; then
      reset_config
      add_rev "$lsha" "the pushed .leakguard"
      [ -n "$base" ] && add_rev "$base" "the remote's .leakguard"
      [ $NSLOT -gt 0 ] || echo "forbidden-paths: warning — no .leakguard in $lref; only the built-in list is checked." >&2
    fi
    check_url "$URL"
    set -- "$lsha" --not
    git config --get "remote.$REMOTE.url" >/dev/null 2>&1 && set -- "$@" --remotes="$REMOTE/*"
    [ -n "$base" ] && [ "$base" = "$rsha" ] && set -- "$@" "$rsha"
    check_commits "$@"
  done <<< "$refs"
}

load_configs
case "$MODE" in
  tracked)
    WHAT="tracked paths"
    OUT=$(git ls-files -z | while IFS= read -r -d '' p; do check_path "$p"; done; check_pins) ;;
  staged)
    WHAT="staged changes"
    OUT=$(git diff --cached --no-renames --name-status -z | while IFS= read -r -d '' st && IFS= read -r -d '' p; do
      check_change "$st" "$p" "$p" ":$p"; done) ;;
  push)
    [ -n "$URL" ] || die "--pre-push needs the remote's name and URL (git passes them to the hook)"
    WHAT="commits being pushed"
    OUT=$(check_pushed) || exit 2 ;;
  history)
    git rev-list -n 1 "${ARGS[@]}" >/dev/null 2>&1 || die "git log cannot read the revisions: ${ARGS[*]}"
    WHAT="commits of git log ${ARGS[*]}"
    OUT=$(check_commits "${ARGS[@]}") ;;
  check)
    WHAT="the given paths"
    OUT=$(for p in "${ARGS[@]}"; do check_path "$p"; done) ;;
esac

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  echo "forbidden-paths: $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') finding(s) in $WHAT." >&2
  echo "  Secrets stay in git-ignored files or a secret store; internal documents go to the private DyorHQ/internal" >&2
  echo "  repository. Unstage with: git rm --cached <path>. A path that is truly fine gets a \"!\" line in .leakguard," >&2
  echo "  committed on its own first (a commit cannot exempt itself)." >&2
  exit 1
fi
echo "forbidden-paths: clean — $WHAT (${#BUILTIN_DENY[@]} built-in + ${#DENY_G[@]} .leakguard patterns, $NSLOT .leakguard version(s))." >&2
exit 0
