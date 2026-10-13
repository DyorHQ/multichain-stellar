#!/bin/bash
# DyorHQ Lite's backend on this Mac, against Stellar TESTNET, with no hosted Supabase project involved:
#   - Postgres 16 (Homebrew, keg-only) listening on 127.0.0.1:54329 only (no Unix socket), data in .local-stack/pg,
#     trust auth; database `lite` with the migrations in order (2 and 3 skip themselves: no pg_cron, pg_net or
#     storage here) and backend/tests/sql/lite_schema_test.sql, once
#   - the `lite` API on 127.0.0.1:8000 and `lite-indexer` on 127.0.0.1:8001 (Deno; DENO_SERVE_ADDRESS sets the
#     address, since a bare Deno.serve() listens on 0.0.0.0:8000)
#   - a loop that POSTs to the indexer every 60 s, standing in for the pg_cron job (migration 2)
#
# Secrets reach the processes only through --env-file=.secrets/local-functions.env, which make-local-env.ts derives
# from .secrets/testnet-functions.env WITHOUT that file's hosted LITE_DB_URL. Every process starts from `env -i`, so
# nothing exported in your shell (LITE_DB_URL, SUPABASE_*, PG*) reaches it. This script holds no secret and prints
# none; `invite` writes the code to .secrets/local-invites.txt (mode 600) instead of printing it.
#
#   backend/scripts/local-stack.sh start            idempotent: initdb and migrations once, then whatever isn't running
#   backend/scripts/local-stack.sh stop             the loop, both functions, then Postgres
#   backend/scripts/local-stack.sh status           what runs, and GET /v1/config in one line
#   backend/scripts/local-stack.sh logs [lite|indexer|loop|postgres|all] [lines]
#   backend/scripts/local-stack.sh invite <label>   one single-use invite (14 days), appended to .secrets/local-invites.txt
#
# API base URL, for the app on the iOS Simulator (it shares the Mac's loopback) and for backend/tests/e2e/lite_e2e.ts:
#   http://127.0.0.1:8000/lite
# Not available locally: media uploads and Moment metadata, which need Supabase Storage. SUPABASE_URL is set to
# https://local.invalid (a reserved name that never resolves) and no service-role key exists, so those routes answer
# 503 storage_unavailable, and the e2e test's Moment URI (https://local.invalid/storage/v1/object/public/…) counts as
# "ours", as that test expects.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACK="$ROOT/.local-stack"
PGDATA="$STACK/pg"
LOGS="$STACK/logs"
PGBIN="/opt/homebrew/opt/postgresql@16/bin"
PGPORT=54329
API_PORT=8000
INDEXER_PORT=8001
API_URL="http://127.0.0.1:$API_PORT/lite"
LOCAL_DB_URL="postgresql://lite_api@127.0.0.1:$PGPORT/lite"
SECRETS="$ROOT/.secrets"
SOURCE_ENV="$SECRETS/testnet-functions.env"
LOCAL_ENV="$SECRETS/local-functions.env"
INVITES="$SECRETS/local-invites.txt"
DENO_CONFIG="$ROOT/backend/supabase/functions/deno.json"
DENO="$(command -v deno || echo /opt/homebrew/bin/deno)"
READY_MARK="local-stack: migrations and schema tests applied"

# The whole environment a child process gets, besides its --env-file and the variables named at its start.
CLEAN_ENV=(HOME="$HOME" PATH="$(dirname "$DENO"):/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  TMPDIR="${TMPDIR:-/tmp}" NO_COLOR=1)
if [ -n "${DENO_DIR:-}" ]; then CLEAN_ENV+=(DENO_DIR="$DENO_DIR"); fi

say() { printf '%s\n' "$*"; }
die() {
  printf 'local-stack: %s\n' "$*" >&2
  exit 1
}
clean() { env -i "${CLEAN_ENV[@]}" "$@"; }
psql_as() { # role database psql-args...
  local role="$1" db="$2"
  shift 2
  clean "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGPORT" -U "$role" -d "$db" "$@"
}
listener() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1 || true; }
pid_file() { printf '%s/%s.pid' "$STACK" "$1"; }

# What a component's command line contains: a PID file only counts while its process still runs that.
marker() {
  case "$1" in
    lite) printf 'functions/lite/index.ts' ;;
    indexer) printf 'functions/lite-indexer/index.ts' ;;
    loop) printf 'local/indexer-loop.ts' ;;
  esac
}

running_pid() { # name → prints the PID while that component runs
  local f pid
  f="$(pid_file "$1")"
  [ -f "$f" ] || return 1
  pid="$(cat "$f")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$(marker "$1")" || return 1
  printf '%s' "$pid"
}

# Starts a command detached from this shell (its own session, stdin /dev/null, output appended to its log) and records
# the PID. nohup, perl, env and deno each exec in place, so the recorded PID is the server's own.
spawn() { # name log command...
  local name="$1" log="$2"
  shift 2
  nohup /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec failed: $!\n"' -- "$@" >>"$log" 2>&1 </dev/null &
  printf '%s\n' "$!" >"$(pid_file "$name")"
}

wait_for() { # url expected-http-status seconds
  local i code
  for i in $(seq 1 "$3"); do
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null || true)"
    [ "$code" = "$2" ] && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------------------------------------ Postgres

pg_running() { clean "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }

db_ready() {
  [ "$(psql_as postgres postgres -tAc "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = 'lite'")" = "$READY_MARK" ]
}

init_pg() {
  [ -f "$PGDATA/PG_VERSION" ] && return 0
  say "postgres: initdb $PGDATA (UTF8, en_US.UTF-8, superuser postgres, trust auth)"
  clean "$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust -E UTF8 --locale=en_US.UTF-8 >>"$LOGS/initdb.log" 2>&1 ||
    die "initdb failed; see $LOGS/initdb.log"
  {
    printf '\n# backend/scripts/local-stack.sh: TCP on the loopback address only, no Unix socket\n'
    printf "listen_addresses = '127.0.0.1'\nport = %s\nunix_socket_directories = ''\n" "$PGPORT"
  } >>"$PGDATA/postgresql.conf"
}

start_pg() {
  local other
  if pg_running; then return 0; fi
  other="$(listener "$PGPORT")"
  [ -z "$other" ] || die "port $PGPORT is taken by PID $other, which isn't this stack's Postgres"
  clean "$PGBIN/pg_ctl" -D "$PGDATA" -l "$LOGS/postgres.log" -w -t 30 start >/dev/null ||
    die "Postgres didn't start; see $LOGS/postgres.log"
  say "postgres: running on 127.0.0.1:$PGPORT"
}

# Once: database `lite`, the roles CI creates, every migration in order, then the schema tests. Without the mark (a
# first start, or a setup that stopped half-way) the local database is rebuilt from scratch.
setup_db() {
  local f
  db_ready && return 0
  # "… does not exist, skipping" notices (dropdb --if-exists, drop policy if exists) are noise here.
  clean "$PGBIN/dropdb" -h 127.0.0.1 -p "$PGPORT" -U postgres --if-exists lite 2>&1 | sed '/does not exist, skipping/d'
  clean "$PGBIN/createdb" -h 127.0.0.1 -p "$PGPORT" -U postgres -E UTF8 lite
  say "postgres: database lite; roles anon and authenticated (nologin, as CI creates them)"
  psql_as postgres lite -c "do \$\$ begin
      if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
      if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
    end \$\$;"
  for f in "$ROOT"/backend/supabase/migrations/*.sql; do
    say "postgres: migration $(basename "$f")"
    psql_as postgres lite -f "$f" 2>&1 | sed -e '/does not exist, skipping/d' -e 's/^/    /'
  done
  say "postgres: backend/tests/sql/lite_schema_test.sql"
  psql_as postgres lite -f "$ROOT/backend/tests/sql/lite_schema_test.sql" 2>&1 | sed 's/^/    /'
  psql_as postgres postgres -c "comment on database lite is '$READY_MARK'"
}

# ------------------------------------------------------------------------------------------------ processes

make_env() {
  if [ -f "$LOCAL_ENV" ] && { [ ! -f "$SOURCE_ENV" ] || [ "$LOCAL_ENV" -nt "$SOURCE_ENV" ]; }; then
    chmod 600 "$LOCAL_ENV"
    return 0
  fi
  [ -f "$SOURCE_ENV" ] || die "missing $SOURCE_ENV (backend/scripts/new-testnet-secrets.ts creates it, docs/RUNBOOK-testnet.md §1)"
  clean "$DENO" run --no-config --allow-read="$SOURCE_ENV" --allow-write="$LOCAL_ENV" \
    "$ROOT/backend/scripts/local/make-local-env.ts"
  if running_pid lite >/dev/null || running_pid indexer >/dev/null || running_pid loop >/dev/null; then
    say "note: processes that were already running keep the old values; run stop, then start"
  fi
}

start_function() { # name port entry [NAME=value...]
  local name="$1" port="$2" entry="$3" pid other
  shift 3
  if pid="$(running_pid "$name")"; then
    say "$name: already running (PID $pid)"
    return 0
  fi
  other="$(listener "$port")"
  [ -z "$other" ] || die "port $port is taken by PID $other; free it first"
  spawn "$name" "$LOGS/$name.log" env -i "${CLEAN_ENV[@]}" DENO_SERVE_ADDRESS="tcp:127.0.0.1:$port" "$@" \
    "$DENO" run -A --frozen --env-file="$LOCAL_ENV" --config "$DENO_CONFIG" "$entry"
  say "$name: started on 127.0.0.1:$port"
}

stop_process() { # name
  local pid i
  if pid="$(running_pid "$1")"; then
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
    say "$1: stopped (PID $pid)"
  fi
  rm -f "$(pid_file "$1")"
}

# ------------------------------------------------------------------------------------------------ commands

cmd_start() {
  local pid
  [ -x "$PGBIN/postgres" ] || die "no Postgres 16 at $PGBIN"
  [ -x "$DENO" ] || die "deno isn't installed"
  mkdir -p "$LOGS"
  chmod 700 "$STACK"
  init_pg
  start_pg
  setup_db
  make_env
  start_function lite "$API_PORT" "$ROOT/backend/supabase/functions/lite/index.ts" SUPABASE_URL=https://local.invalid
  start_function indexer "$INDEXER_PORT" "$ROOT/backend/supabase/functions/lite-indexer/index.ts"
  wait_for "$API_URL/v1/config" 200 90 || die "the lite API doesn't answer GET /v1/config; see: $0 logs lite"
  # Without the cron secret the indexer answers 403, which shows it is up.
  wait_for "http://127.0.0.1:$INDEXER_PORT/" 403 90 || die "lite-indexer doesn't answer; see: $0 logs indexer"
  if pid="$(running_pid loop)"; then
    say "loop: already running (PID $pid)"
  else
    spawn loop "$LOGS/indexer-loop.log" env -i "${CLEAN_ENV[@]}" "$DENO" run --no-config \
      --allow-env=LITE_CRON_SECRET --allow-net="127.0.0.1:$INDEXER_PORT" --env-file="$LOCAL_ENV" \
      "$ROOT/backend/scripts/local/indexer-loop.ts"
    say "loop: started (POST to lite-indexer every 60 s)"
  fi
  say ""
  cmd_status
}

cmd_stop() {
  stop_process loop
  stop_process indexer
  stop_process lite
  if pg_running; then
    clean "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null
    say "postgres: stopped"
  fi
}

last_post() { # time and HTTP status of the running loop's latest POST (lines after its start banner)
  local line
  line="$(awk '/ indexer-loop: POST / { last = ""; next } $2 ~ /^([0-9][0-9][0-9]|error)$/ { last = $1 " → " $2 } END { print last }' \
    "$LOGS/indexer-loop.log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "$line"; else printf 'none yet'; fi
}

config_line() {
  local body
  if ! body="$(curl -fsS -m 5 "$API_URL/v1/config" 2>/dev/null)"; then
    say "config    GET $API_URL/v1/config didn't answer"
    return 0
  fi
  printf '%s' "$body" | clean "$DENO" eval --no-config '
    const c = JSON.parse(await new Response(Deno.stdin.readable).text());
    const pinned = new Set(Object.values(c.allowlist ?? {}).flat()).size;
    console.log(`config    network ${c.network}, ${pinned} pinned contracts, sponsor ${c.sponsor ? "set" : "NOT set"}`);'
}

cmd_status() {
  local pid counts
  if pg_running; then
    counts="$(psql_as lite_api lite -tAc "select format('%s testers, %s launches, %s moments, indexed to ledger %s',
      (select count(*) from lite.testers), (select count(*) from lite.launches), (select count(*) from lite.moments),
      coalesce((select ledger::text from lite.indexer_cursors where name = 'events'), 'none'))" 2>/dev/null || echo "schema not ready")"
    say "postgres  running  127.0.0.1:$PGPORT, db lite: $counts"
  else
    say "postgres  stopped"
  fi
  if pid="$(running_pid lite)"; then say "lite      running  PID $pid, $API_URL"; else say "lite      stopped"; fi
  if pid="$(running_pid indexer)"; then say "indexer   running  PID $pid, http://127.0.0.1:$INDEXER_PORT"; else say "indexer   stopped"; fi
  if pid="$(running_pid loop)"; then say "loop      running  PID $pid, last POST $(last_post)"; else say "loop      stopped"; fi
  config_line
}

cmd_logs() {
  local which="${1:-all}" lines="${2:-40}" f
  case "$which" in
    lite) f=lite.log ;;
    indexer) f=indexer.log ;;
    loop) f=indexer-loop.log ;;
    postgres) f=postgres.log ;;
    all)
      for which in lite indexer loop postgres; do
        say "== $which"
        cmd_logs "$which" "${2:-15}"
      done
      return 0
      ;;
    *) die "usage: logs [lite|indexer|loop|postgres|all] [lines]" ;;
  esac
  if [ -f "$LOGS/$f" ]; then tail -n "$lines" "$LOGS/$f"; else say "(no $LOGS/$f yet)"; fi
}

cmd_invite() {
  local label="${1:-}" code
  [ -n "$label" ] || die "usage: invite <label>, e.g. invite \"Jay simulator\""
  label="$(printf '%s' "$label" | tr -d '\000-\037' | cut -c1-80)"
  pg_running && db_ready || die "the local database isn't up; run: $0 start"
  # invite-tester.ts prints the code once: it goes into the file, never to the terminal.
  code="$(clean LITE_DB_URL="$LOCAL_DB_URL" "$DENO" run -A --frozen --config "$DENO_CONFIG" \
    "$ROOT/backend/scripts/invite-tester.ts" "$label" 1 14)" || die "invite-tester.ts failed; nothing written"
  [[ "$code" =~ ^DYOR-[A-Z2-9]{5}-[A-Z2-9]{5}$ ]] || die "invite-tester.ts printed something unexpected; nothing written"
  if [ ! -f "$INVITES" ]; then
    (
      umask 077
      printf '# Local-stack invites (backend/scripts/local-stack.sh invite): created UTC, label, code. Single use, 14 days.\n' >"$INVITES"
    )
  fi
  chmod 600 "$INVITES"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" "$code" >>"$INVITES"
  say "wrote 1 invite to $INVITES"
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  logs)
    shift
    cmd_logs "$@"
    ;;
  invite)
    shift
    cmd_invite "$@"
    ;;
  *)
    say "usage: $0 start | stop | status | logs [lite|indexer|loop|postgres|all] [lines] | invite <label>"
    exit 2
    ;;
esac
