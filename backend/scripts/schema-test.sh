#!/bin/bash
# The migrations and the SQL tests on a throwaway Postgres 16, as CI runs them (.github/workflows/backend.yml), on a
# port of your choice so that several work packages can run it at once:
#   - a new cluster (Homebrew's postgresql@16, keg-only) in a temporary directory, listening on 127.0.0.1:<port> only
#     (no Unix socket), trust auth;
#   - database `lite` with the roles CI creates (anon, authenticated) and lite_api, then every
#     backend/supabase/migrations/*.sql in filename order (2 and 3 skip themselves: no pg_cron, pg_net or storage);
#   - every backend/tests/sql/*.sql in filename order, each on its own copy of that database, so one test's leftovers
#     never reach the next;
#   - then the cluster stops and its directory is deleted, on success, failure or Ctrl-C alike.
#
#   backend/scripts/schema-test.sh <port>     e.g. 55NN for package WP-NN (docs/DESIGN-stellar-parity.md §12.3)
#
# Exit status: 0 when every migration and test ran without error, 1 otherwise, 2 for a usage error. It reads no secret:
# the cluster is local and empty, and every command starts from `env -i`, so PG* variables in your shell never apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="/opt/homebrew/opt/postgresql@16/bin"
PORT="${1:-}"
# backend/scripts/local-stack.sh's default ports: those belong to whoever holds the stack lock.
STACK_PORTS=" 8000 8001 54329 "

CLEAN_ENV=(HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  TMPDIR="${TMPDIR:-/tmp}")

say() { printf 'schema-test: %s\n' "$*"; }
die() {
  printf 'schema-test: %s\n' "$*" >&2
  exit 1
}
clean() { env -i "${CLEAN_ENV[@]}" "$@"; }
listener() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1 || true; }

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  printf 'usage: %s <port>   (1024-65535, e.g. 55NN for package WP-NN)\n' "$0" >&2
  exit 2
fi
case "$STACK_PORTS" in *" $PORT "*) die "port $PORT is the default local stack's; pick another, e.g. 55NN" ;; esac
[ -x "$PGBIN/postgres" ] || die "no Postgres 16 at $PGBIN (brew install postgresql@16)"
other="$(listener "$PORT")"
[ -z "$other" ] || die "port $PORT is taken by PID $other"

TMP="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP%/}/schema-test.XXXXXX")"
PGDATA="$WORK/pg"

# Stops the cluster (fast, then immediate, then the postmaster's PID) and deletes its directory.
cleanup() {
  local pid
  if [ -f "$PGDATA/postmaster.pid" ]; then
    clean "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w -t 20 stop >/dev/null 2>&1 ||
      clean "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate -w -t 10 stop >/dev/null 2>&1 || true
    pid="$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

psql_on() { # database psql-args...
  local db="$1"
  shift
  clean "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U postgres -d "$db" "$@"
}

# Runs one file, indenting its notices and errors as "<file>:<line>: …"; "… does not exist, skipping" (drop … if
# exists) is noise here.
run_file() { # database file
  psql_on "$1" -f "$2" 2>&1 | sed -e '/does not exist, skipping/d' -e 's|^psql:.*/\([^/]*:[0-9]*:\)|\1|' -e 's/^/    /'
}

say "Postgres 16 on 127.0.0.1:$PORT in $WORK"
# --no-sync: a throwaway cluster needs no flush to disk, which takes initdb tens of seconds.
clean "$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust -E UTF8 --locale=en_US.UTF-8 --no-sync --no-instructions \
  >"$WORK/initdb.log" 2>&1 ||
  { tail -20 "$WORK/initdb.log" >&2; die "initdb failed"; }
{
  printf '\n# backend/scripts/schema-test.sh: TCP on the loopback address only, no Unix socket; a throwaway cluster\n'
  printf "listen_addresses = '127.0.0.1'\nport = %s\nunix_socket_directories = ''\n" "$PORT"
  printf 'fsync = off\nsynchronous_commit = off\nfull_page_writes = off\n'
} >>"$PGDATA/postgresql.conf"
clean "$PGBIN/pg_ctl" -D "$PGDATA" -l "$WORK/postgres.log" -w -t 30 start >/dev/null ||
  { tail -20 "$WORK/postgres.log" >&2; die "Postgres didn't start"; }

clean "$PGBIN/createdb" -h 127.0.0.1 -p "$PORT" -U postgres -E UTF8 lite
# anon and authenticated as CI creates them. lite_api with the attributes migration 20261013000004 gives it, so that
# migration's guard finds it and the result is the same as on the hosted project.
say "roles anon, authenticated (nologin, as CI creates them) and lite_api"
psql_on lite -c "do \$\$ begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'lite_api') then
      create role lite_api login noinherit nocreatedb nocreaterole nobypassrls connection limit 20;
    end if;
  end \$\$;"

migrations=0
for f in "$ROOT"/backend/supabase/migrations/*.sql; do
  [ -f "$f" ] || continue
  say "migration $(basename "$f")"
  run_file lite "$f" || die "migration $(basename "$f") failed"
  migrations=$((migrations + 1))
done
[ "$migrations" -gt 0 ] || die "no migrations under backend/supabase/migrations"

tests=0
for f in "$ROOT"/backend/tests/sql/*.sql; do
  [ -f "$f" ] || continue
  tests=$((tests + 1))
  clean "$PGBIN/createdb" -h 127.0.0.1 -p "$PORT" -U postgres -T lite "test_$tests"
  say "test $(basename "$f")"
  run_file "test_$tests" "$f" || die "test $(basename "$f") failed"
done
[ "$tests" -gt 0 ] || die "no tests under backend/tests/sql"

cleanup
trap - EXIT
[ ! -e "$WORK" ] || die "could not remove $WORK"
say "ok: $migrations migrations, $tests SQL test file(s); the cluster is stopped and removed"
