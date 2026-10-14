#!/bin/bash
# The placeholder scan of docs/DESIGN-stellar-parity.md §9: text that stands in for real data must not reach the new
# app code or the backend. It greps the tracked files (new files count once staged with `git add`) of
#   A, the IOS-app worktree:            ios/DyorHQ/Lite, ios/Internal
#   S, the multichain-stellar worktree: backend, ios/Packages
# for each pattern below, and fails on any hit that the allow list doesn't name.
#
#   scripts/agent/scan-placeholders.sh [--allow FILE] <A> <S>     FILE defaults to scripts/agent/scan-allow.txt
#
# Patterns are fixed strings, matched case-sensitively anywhere in a line. An allow-list line reads
#   <path glob> <pattern> # reason
# The path is relative to its repository (the scanned folders of A and S don't overlap) and `*` matches across
# folders. The pattern is one of PATTERNS, written exactly. The reason is required.
#
# Exit status: 0 when no hit is left over, 1 when some are, 2 for a usage or allow-list error.
set -euo pipefail

PATTERNS=('"TOKEN"' 'example.invalid' 'USDC: 1' 'BUSDC: 1' 'Paid by DyorHQ' 'pays the Stellar network fees'
  'Reserves paid by DyorHQ' '10,000 test' '10000 test' 'Lorem')
APP_PATHS=(ios/DyorHQ/Lite ios/Internal)
LITE_PATHS=(backend ios/Packages)

say() { printf 'scan-placeholders: %s\n' "$*"; }
die() {
  printf 'scan-placeholders: %s\n' "$*" >&2
  exit 2
}
usage() {
  sed -n '8p' "$0" | sed 's/^# //' >&2
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
[ $# -eq 2 ] || usage
A="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "$1 is not a git checkout"
S="$(git -C "$2" rev-parse --show-toplevel 2>/dev/null)" || die "$2 is not a git checkout"
[ -d "$A/ios/DyorHQ" ] || die "$A doesn't look like IOS-app (no ios/DyorHQ)"
[ -d "$S/backend" ] && [ -d "$S/ios/Packages" ] || die "$S doesn't look like multichain-stellar (no backend, ios/Packages)"
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
scan() { # label repo paths...
  local label="$1" repo="$2" pattern out status hit path rest number text
  shift 2
  for pattern in "${PATTERNS[@]}"; do
    status=0
    out="$(git -C "$repo" grep -n -I -F -e "$pattern" -- "$@")" || status=$?
    [ "$status" -le 1 ] || die "git grep failed in $repo"
    [ -n "$out" ] || continue
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
    done <<<"$out"
  done
}

say "A = $A (${APP_PATHS[*]}); S = $S (${LITE_PATHS[*]})"
scan A "$A" "${APP_PATHS[@]}"
scan S "$S" "${LITE_PATHS[@]}"
# By repository, file and line.
[ -z "$REPORT" ] || printf '%s' "$REPORT" | sort -t: -k1,1 -k2,2n

unused=""
for ((i = 0; i < ${#ALLOW_GLOB[@]}; i++)); do
  [ -n "${ALLOW_USED[i]}" ] || unused="$unused ${ALLOW_LINE[i]}"
done
[ -z "$unused" ] || say "allow-list lines that matched nothing:$unused"
say "$HITS placeholder hit(s), $ALLOWED allowed by $(basename "$ALLOW")"
[ "$HITS" -eq 0 ]
