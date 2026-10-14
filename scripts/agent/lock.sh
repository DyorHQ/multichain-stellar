#!/bin/bash
# Locks that work packages take before using a shared resource (docs/DESIGN-stellar-parity.md §13.4):
#   sim    the agent simulator (every `xcodebuild test` and simulator run)
#   stack  the default local stack (backend/scripts/local-stack.sh without PORT_BASE: ports 8000, 8001 and 54329)
#
#   scripts/agent/lock.sh acquire <sim|stack> <WP-xx>   0: held by WP-xx now (or already); 1: another owner holds it
#   scripts/agent/lock.sh release <sim|stack> <WP-xx>   0: released (or not held); 1: another owner holds it
#   scripts/agent/lock.sh status [sim|stack]            who holds what
#
# A lock is the directory ~/Hackathon-b17/wt/.locks/<name> (mkdir is atomic) with three files: `owner` (the package),
# `pid` (the process the lock lives with, and that process's start time) and `since`. That process is the one that
# started the calling shell, such as the Claude Code session or the terminal window, so the lock outlives the command
# that took it and stays held between an agent's commands. Once that process has exited the lock is stale, and the next
# acquire takes it over. LOCK_PID=<pid> ties the lock to another process instead, and LOCK_WAIT=<seconds> makes acquire
# retry every 5 seconds for that long before it gives up.
#
# A lock directory without a pid file was taken by hand (mkdir to take it, rmdir to give it back): it is never taken
# over, and only its holder removes it.
set -euo pipefail

LOCKS="${AGENT_LOCKS:-$HOME/Hackathon-b17/wt/.locks}"

say() { printf 'lock: %s\n' "$*"; }
die() {
  printf 'lock: %s\n' "$*" >&2
  exit 2
}
usage() {
  sed -n '6,8p' "$0" | sed 's/^# //' >&2
  exit 2
}

# A process's start time. ps writes it in the caller's locale and time zone, so both are pinned: a lock taken from a
# terminal with LANG or TZ set must read the same from an agent without them, or it would look stale and be taken over.
started() { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' || true; }

# The process that started the calling shell: up the parents from the caller, past every shell, `env` and `timeout`.
holder() {
  local pid="$PPID" parent name
  while :; do
    name="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    name="${name##*/}"
    name="${name#-}"
    case "$name" in
      sh | bash | zsh | dash | ksh | fish | env | timeout) ;;
      *) break ;;
    esac
    parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    # A shell launchd started directly: tie the lock to that shell, not to launchd, which never exits.
    if [ -z "$parent" ] || [ "$parent" -le 1 ]; then break; fi
    pid="$parent"
  done
  printf '%s' "$pid"
}

# Exit 0 while the process recorded in <dir>/pid still runs; a reused PID has another start time.
alive() { # dir
  local pid start
  pid="$(sed -n 1p "$1/pid" 2>/dev/null || true)"
  start="$(sed -n 2p "$1/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [ -n "$start" ] && [ "$(started "$pid")" = "$start" ]
}

describe() { # dir
  local owner pid since
  if [ ! -f "$1/pid" ]; then
    if [ -f "$1/owner" ]; then
      printf 'held by %s, taken by hand (no pid file: never taken over)' "$(head -1 "$1/owner" | cut -c1-60)"
    else
      printf 'held without an owner file (taken by hand, or being taken right now)'
    fi
    return 0
  fi
  owner="$(cat "$1/owner" 2>/dev/null || true)"
  pid="$(sed -n 1p "$1/pid" 2>/dev/null || true)"
  since="$(cat "$1/since" 2>/dev/null || true)"
  if alive "$1"; then
    printf 'held by %s since %s (PID %s)' "$owner" "$since" "$pid"
  else
    printf 'stale: held by %s since %s, PID %s has exited' "$owner" "$since" "$pid"
  fi
}

# Takes <dir> when it is free; writes the owner files. Exit 1 when it exists.
take() { # dir
  local pid
  mkdir "$1" 2>/dev/null || return 1
  pid="${LOCK_PID:-$(holder)}"
  if ! { printf '%s\n' "$OWNER" >"$1/owner" && date -u +%Y-%m-%dT%H:%M:%SZ >"$1/since" &&
    printf '%s\n%s\n' "$pid" "$(started "$pid")" >"$1/pid"; }; then
    rm -f "$1/owner" "$1/pid" "$1/since"
    rmdir "$1" 2>/dev/null || true
    die "could not write the owner files in $1"
  fi
}

# Removes a stale lock. A short-lived <dir>.reclaim directory makes this one critical section: two acquires that both
# saw the same stale lock can't both remove it, and neither can remove the lock the other has just taken.
reclaim() { # dir pid-file-as-seen
  local guard="$1.reclaim" seen="$2"
  if ! mkdir "$guard" 2>/dev/null; then
    # A reclaim older than a minute crashed half-way: drop its guard, and let the next acquire retry.
    if [ -n "$(find "$guard" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$guard" 2>/dev/null || true; fi
    return 1
  fi
  # Only the stale lock that was seen: never one released and taken again since, or one being taken right now.
  if [ -n "$seen" ] && [ "$(cat "$1/pid" 2>/dev/null || true)" = "$seen" ] && ! alive "$1"; then
    rm -f "$1/owner" "$1/pid" "$1/since"
    rmdir "$1" 2>/dev/null || true
  fi
  rmdir "$guard"
}

acquire() {
  local dir="$LOCKS/$NAME" deadline=$((SECONDS + ${LOCK_WAIT:-0})) seen
  mkdir -p "$LOCKS"
  while :; do
    if take "$dir"; then
      say "$NAME acquired by $OWNER"
      return 0
    fi
    if [ -f "$dir/pid" ]; then
      if alive "$dir" && [ "$(cat "$dir/owner" 2>/dev/null || true)" = "$OWNER" ]; then
        say "$NAME is already held by $OWNER"
        return 0
      fi
      if ! alive "$dir"; then
        seen="$(cat "$dir/pid" 2>/dev/null || true)"
        say "$NAME: taking over a stale lock ($(describe "$dir"))"
        reclaim "$dir" "$seen" || true
        if take "$dir"; then
          say "$NAME acquired by $OWNER"
          return 0
        fi
      fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      say "$NAME is busy: $(describe "$dir")"
      return 1
    fi
    sleep 5
  done
}

release() {
  local dir="$LOCKS/$NAME" owner
  if [ ! -d "$dir" ]; then
    say "$NAME is not held"
    return 0
  fi
  if [ ! -f "$dir/pid" ]; then
    say "$NAME was taken by hand (no pid file); only its holder removes it"
    return 1
  fi
  owner="$(cat "$dir/owner")"
  if [ "$owner" != "$OWNER" ]; then
    say "$NAME is held by $owner, not $OWNER: not released"
    return 1
  fi
  rm -f "$dir/owner" "$dir/pid" "$dir/since"
  rmdir "$dir" 2>/dev/null || { say "$dir holds other files: left in place"; return 1; }
  say "$NAME released by $OWNER"
}

status() {
  local name
  for name in "$@"; do
    if [ -d "$LOCKS/$name" ]; then say "$name: $(describe "$LOCKS/$name")"; else say "$name: free"; fi
  done
}

valid_name() { case "$1" in sim | stack) return 0 ;; *) return 1 ;; esac }

case "${1:-}" in
  acquire | release)
    [ $# -eq 3 ] || usage
    NAME="$2"
    OWNER="$3"
    valid_name "$NAME" || die "unknown lock '$NAME': sim or stack"
    [[ "$OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$ ]] || die "owner must be a package id such as WP-21"
    [[ "${LOCK_WAIT:-0}" =~ ^[0-9]+$ ]] || die "LOCK_WAIT must be a number of seconds"
    if [ -n "${LOCK_PID:-}" ]; then
      [[ "$LOCK_PID" =~ ^[0-9]+$ ]] || die "LOCK_PID must be a process id"
      [ -n "$(started "$LOCK_PID")" ] || die "LOCK_PID $LOCK_PID isn't running"
    fi
    "$1"
    ;;
  status)
    if [ $# -eq 2 ]; then
      valid_name "$2" || die "unknown lock '$2': sim or stack"
      status "$2"
    else
      status sim stack
    fi
    ;;
  *) usage ;;
esac
