#!/bin/bash
# The placeholder scan of docs/DESIGN-stellar-parity.md §9: text that stands in for real data must not reach the new
# app code or the backend. It greps the files (tracked, and new ones not added yet; ignored ones aside) of S, a
# worktree of this repository, and its app copy A = S/app:
#   A: app/ios/DyorHQ/Lite, app/ios/Internal, and the #if STELLAR_LITE blocks of app/ios's other Swift files (the
#      network switch's hooks in the snapshot's files, §3.1)
#   S: backend, ios/Packages
# for each pattern below, and fails on any hit that the allow list doesn't name. It never reads a secret file.
#
#   scripts/agent/scan-placeholders.sh [--allow FILE] <S>        FILE defaults to scripts/agent/scan-allow.txt
#   scripts/agent/scan-placeholders.sh [--allow FILE] <A> <S>    the same, as §12.3's V-SCAN writes it (A must be S/app)
#
# Patterns are fixed strings, matched case-sensitively anywhere in a line. An allow-list line reads
#   <path glob> <pattern> # reason
# The path is relative to S (app/… for the app copy) and `*` matches across folders. The pattern is one of PATTERNS,
# written exactly. The reason is required.
#
# Exit status: 0 when no hit is left over, 1 when some are, 2 for a usage or allow-list error.
set -euo pipefail

# §9's list, then three for evidence that its table says this scan tests and that the list misses: the copy "DyorHQ
# pays the network fees and the reserve" (NetworkSheet) and the testnet faucet's 10,000 written in code (NetworkSheet,
# LiteHomeView).
PATTERNS=('"TOKEN"' 'example.invalid' 'USDC: 1' 'BUSDC: 1' 'Paid by DyorHQ' 'pays the Stellar network fees'
  'Reserves paid by DyorHQ' '10,000 test' '10000 test' 'Lorem'
  'pays the network fees' 'number(10_000)' '10_000.formatted')
APP_PATHS=(app/ios/DyorHQ/Lite app/ios/Internal)
LITE_PATHS=(backend ios/Packages)
# Every grep leaves these out, tracked or not.
NO_SECRETS=(':(exclude,glob)**/.env*' ':(exclude,glob)**/Secrets.xcconfig' ':(exclude,glob)**/.secrets'
  ':(exclude,glob)**/.secrets/**')

say() { printf 'scan-placeholders: %s\n' "$*"; }
die() {
  printf 'scan-placeholders: %s\n' "$*" >&2
  exit 2
}
usage() {
  sed -n '10,11p' "$0" | sed 's/^# //' >&2
  exit 2
}
trim() { # leading and trailing blanks
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

ALLOW="$(cd "$(dirname "$0")" && pwd)/scan-allow.txt"
if [ "${1:-}" = "--allow" ]; then
  [ $# -ge 2 ] || usage
  ALLOW="$2"
  shift 2
fi
[ $# -eq 1 ] || [ $# -eq 2 ] || usage
S="$(git -C "${!#}" rev-parse --show-toplevel 2>/dev/null)" || die "${!#} is not a git checkout"
[ -d "$S/app/ios/DyorHQ" ] || die "$S has no app copy (no app/ios/DyorHQ)"
[ -d "$S/backend" ] && [ -d "$S/ios/Packages" ] || die "$S doesn't look like multichain-stellar (no backend, ios/Packages)"
if [ $# -eq 2 ]; then
  [ "$(cd "$1" 2>/dev/null && pwd -P)" = "$(cd "$S/app" && pwd -P)" ] || die "A must be S's app copy, $S/app"
fi
[ -f "$ALLOW" ] || die "no allow list at $ALLOW"

# ------------------------------------------------------------------------------------------------ allow list

ALLOW_GLOB=()
ALLOW_PATTERN=()
ALLOW_LINE=()
ALLOW_USED=()
known_pattern() {
  local p
  for p in "${PATTERNS[@]}"; do [ "$p" = "$1" ] && return 0; done
  return 1
}
n=0
while IFS= read -r raw || [ -n "$raw" ]; do
  n=$((n + 1))
  line="$(trim "$raw")"
  case "$line" in "" | "#"*) continue ;; esac
  case "$line" in *"#"*) ;; *) die "$ALLOW:$n: no reason (write: <path glob> <pattern> # reason)" ;; esac
  rule="$(trim "${line%%#*}")"
  reason="$(trim "${line#*#}")"
  glob="${rule%%[[:space:]]*}"
  pattern="$(trim "${rule#"$glob"}")"
  [ -n "$reason" ] || die "$ALLOW:$n: the reason is empty"
  [ -n "$pattern" ] || die "$ALLOW:$n: no pattern after the path glob"
  known_pattern "$pattern" || die "$ALLOW:$n: '$pattern' isn't one of the scan's patterns"
  ALLOW_GLOB+=("$glob")
  ALLOW_PATTERN+=("$pattern")
  ALLOW_LINE+=("$n")
  ALLOW_USED+=("")
done <"$ALLOW"

# Exit 0 when an allow-list line covers <path> for <pattern>, and marks that line used.
allowed() { # path pattern
  local i
  for ((i = 0; i < ${#ALLOW_GLOB[@]}; i++)); do
    # Unquoted on the right: a glob, whose * also matches "/".
    if [ "${ALLOW_PATTERN[i]}" = "$2" ] && [[ "$1" == ${ALLOW_GLOB[i]} ]]; then
      ALLOW_USED[i]=1
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------------------------------------------ scan

HITS=0
ALLOWED=0
REPORT=""
# Counts <pattern>'s hits, given as git grep prints them (path:line:text); reports those the allow list doesn't name.
record() { # label pattern hits
  local label="$1" pattern="$2" hit path rest number text
  [ -n "$3" ] || return 0
  while IFS= read -r hit; do
    path="${hit%%:*}"
    rest="${hit#*:}"
    number="${rest%%:*}"
    text="$(trim "${rest#*:}")"
    if allowed "$path" "$pattern"; then
      ALLOWED=$((ALLOWED + 1))
      continue
    fi
    HITS=$((HITS + 1))
    REPORT="$REPORT$(printf '%s %s:%s  [%s]  %s' "$label" "$path" "$number" "$pattern" "${text:0:100}")"$'\n'
  done <<<"$3"
}

# git grep over <repo>'s working tree: tracked files, and untracked ones that aren't ignored.
grep_repo() { # repo grep-arguments...
  local repo="$1" status=0
  shift
  git -C "$repo" grep -I --untracked "$@" || status=$?
  [ "$status" -le 1 ] || die "git grep failed in $repo"
}

scan() { # label repo paths...
  local label="$1" repo="$2" pattern out
  shift 2
  for pattern in "${PATTERNS[@]}"; do
    out="$(grep_repo "$repo" -n -F -e "$pattern" -- "$@" "${NO_SECRETS[@]}")"
    record "$label" "$pattern" "$out"
  done
}

# Each #if keeps a frame: lite says its open branch only compiles with STELLAR_LITE, and neg that the #if tested
# !STELLAR_LITE, which makes its #elseif and #else branches the Lite ones. A line inside any Lite frame is printed as
# git grep prints a hit.
LITE_LINES='
function lite_cond(s) { gsub(/![[:space:]]*STELLAR_LITE/, "", s); return s ~ /STELLAR_LITE/ }
/^[[:space:]]*#if[[:space:]]/ { d++; lite[d] = lite_cond($0); neg[d] = $0 ~ /![[:space:]]*STELLAR_LITE/; next }
/^[[:space:]]*#elseif[[:space:]]/ { if (d) lite[d] = neg[d] || lite_cond($0); next }
/^[[:space:]]*#else([[:space:]]|$)/ { if (d) lite[d] = neg[d]; next }
/^[[:space:]]*#endif/ { if (d) d--; next }
{ for (i = 1; i <= d; i++) if (lite[i]) { print ENVIRON["SCAN_PATH"] ":" NR ":" $0; next } }
'

# The app's Swift files outside APP_PATHS hold the snapshot's code, and the network switch's hooks inside
# #if STELLAR_LITE (§3.1): only those blocks are scanned.
scan_blocks() { # label repo
  local label="$1" repo="$2" files path lines="" pattern
  files="$(grep_repo "$repo" -l -F -e STELLAR_LITE -- 'app/ios/*.swift' ':(exclude)app/ios/DyorHQ/Lite' \
    ':(exclude)app/ios/Internal' "${NO_SECRETS[@]}")"
  [ -n "$files" ] || return 0
  while IFS= read -r path; do
    lines="$lines$(SCAN_PATH="$path" awk "$LITE_LINES" "$repo/$path")"$'\n'
  done <<<"$files"
  for pattern in "${PATTERNS[@]}"; do
    # The pattern in a line's text, not in its path:line: prefix.
    record "$label" "$pattern" "$(printf '%s' "$lines" |
      PATTERN="$pattern" awk '{ t = $0; sub(/^[^:]*:[^:]*:/, "", t) } index(t, ENVIRON["PATTERN"])')"
  done
}

say "S = $S: ${APP_PATHS[*]} and #if STELLAR_LITE blocks elsewhere in app/ios; ${LITE_PATHS[*]}"
scan A "$S" "${APP_PATHS[@]}"
scan_blocks A "$S"
scan S "$S" "${LITE_PATHS[@]}"
# By repository, file and line, the same order in every locale.
[ -z "$REPORT" ] || printf '%s' "$REPORT" | LC_ALL=C sort -t: -k1,1 -k2,2n

unused=""
for ((i = 0; i < ${#ALLOW_GLOB[@]}; i++)); do
  [ -n "${ALLOW_USED[i]}" ] || unused="$unused ${ALLOW_LINE[i]}"
done
[ -z "$unused" ] || say "allow-list lines that matched nothing:$unused"
say "$HITS placeholder hit(s), $ALLOWED allowed by $(basename "$ALLOW")"
[ "$HITS" -eq 0 ]
