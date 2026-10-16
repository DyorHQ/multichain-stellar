#!/bin/bash
# DyorHQ Lite's backend on this Mac, against Stellar TESTNET, with no hosted Supabase project involved
# (docs/DESIGN-stellar-parity.md §6.17, docs/RUNBOOK-testnet.md §8):
#   - Postgres 16 (Homebrew, keg-only) on 127.0.0.1 only (no Unix socket), trust auth; database `lite` with each
#     migration applied once, in filename order, and recorded in public.local_stack_migrations (2 and 3 skip
#     themselves: no pg_cron, pg_net or storage here); backend/tests/sql/lite_schema_test.sql, which rolls itself back,
#     checks the schema after every change
#   - the `lite` API and `lite-indexer` (Deno; DENO_SERVE_ADDRESS sets the address, since a bare Deno.serve() listens
#     on 0.0.0.0:8000). The API also serves the local stand-in for media storage (/v1/local-media/*, §6.9): uploads are
#     kept in the stack's media directory (LITE_LOCAL_STORAGE_DIR) and served under LITE_PUBLIC_BASE, the API's URL
#   - a loop that POSTs to the indexer every 60 s, standing in for the pg_cron job (migration 2)
#
# Ports and state. Without PORT_BASE, the default stack: API 8000, indexer 8001, Postgres 54329 (scripts/agent/lock.sh's
# `stack` lock guards them). With PORT_BASE=<n>, a stack of its own: API n, indexer n+1, Postgres n+2, and n+3 kept
# free for a storage stand-in (the API serves it today). Each stack keeps its Postgres data, logs, PID files, env file
# and media in a state directory of this checkout: .local-stack for the default stack, .local-stack/<n> for the
# others. So several worktrees, and several stacks in one worktree, run side by side.
#
# Secrets reach the processes only through the stack's env file (<state>/functions.env, mode 600), which
# make-local-env.ts derives from .secrets/testnet-functions.env WITHOUT that file's hosted LITE_DB_URL. Every process
# starts from `env -i`, so nothing exported in your shell (LITE_DB_URL, SUPABASE_*, PG*) reaches it. This script holds
# no secret and prints none. A stack with PORT_BASE only reads .secrets (every worktree's .secrets links to the same
# directory): its env file and its invites stay in its state directory. Without .secrets/testnet-functions.env, a stack
# that has started before starts again from its env file as it is, with the same options; a new stack, or other
# options, need the file back (docs/RUNBOOK-testnet.md §1).
#
#   local-stack.sh start [options]   idempotent: initdb once, the new migrations, then whatever isn't running
#     --no-loop                    no indexer loop, and LITE_KEEPER=off: a package's stack never races the shared
#                                  sponsor's or keeper's sequence number (LITE_KEEPER=off alone keeps the loop)
#     --deployment <name>          testnet (the default) or testnet-qa (needs deployments/testnet-qa.json or testnet-qa-v2.json)
#     --activation <mode>          friendbot (testnet's default) or sponsored, which rehearses mainnet's setup
#     --short-sessions             access tokens last 120 s and refresh tokens 600 s, so renewal QA runs in minutes
#     --invite-required            a first sign-in needs an invite, as on mainnet (LITE_INVITE_REQUIRED=1)
#   local-stack.sh stop              the loop, both functions, then Postgres
#   local-stack.sh status            what runs, the fee mode, the sponsor's and keeper's XLM, reference prices, watch groups
#   local-stack.sh migrate           the migrations this database hasn't had, and nothing else (starts Postgres if needed)
#   local-stack.sh e2e [phases...]   backend/tests/e2e/lite_e2e.ts against this stack, with its settings
#   local-stack.sh logs [lite|indexer|loop|postgres|all] [lines]
#   local-stack.sh invite <label>    one single-use invite (14 days), appended to a file, never printed:
#                                  .secrets/local-invites.txt (default stack) or <state>/invites.txt
#
# The API's base URL, for the app on the iOS Simulator (it shares the Mac's loopback) and for lite_e2e.ts:
# http://127.0.0.1:8000/lite on the default stack, http://127.0.0.1:<PORT_BASE>/lite on the others.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="/opt/homebrew/opt/postgresql@16/bin"
SECRETS="$ROOT/.secrets"
SOURCE_ENV="$SECRETS/testnet-functions.env"
DENO_CONFIG="$ROOT/backend/supabase/functions/deno.json"
DENO="$(command -v deno || echo /opt/homebrew/bin/deno)"
MIGRATIONS_TABLE="public.local_stack_migrations"
# What make-local-env.ts may read from its environment: the stack's settings, none of them a secret.
SETTING_NAMES="LITE_DB_URL,LITE_DEPLOYMENT,LITE_ACTIVATION,LITE_KEEPER,LITE_JWT_TTL_S,LITE_REFRESH_TTL_S,LITE_INVITE_REQUIRED,LITE_LOCAL_STORAGE_DIR,LITE_PUBLIC_BASE"

say() { printf '%s\n' "$*"; }
die() {
  printf 'local-stack: %s\n' "$*" >&2
  exit 1
}

PORT_BASE="${PORT_BASE:-}"
if [ -z "$PORT_BASE" ]; then
  STACK="$ROOT/.local-stack"
  API_PORT=8000
  INDEXER_PORT=8001
  PGPORT=54329
  INVITES="$SECRETS/local-invites.txt"
else
  [[ "$PORT_BASE" =~ ^[1-9][0-9]{3,4}$ ]] && [ "$PORT_BASE" -ge 1024 ] && [ "$PORT_BASE" -le 65532 ] ||
    die "PORT_BASE is a port from 1024 to 65532: the API's, with the indexer on +1, Postgres on +2 and +3 kept free"
  for port in "$PORT_BASE" $((PORT_BASE + 1)) $((PORT_BASE + 2)) $((PORT_BASE + 3)); do
    case "$port" in 8000 | 8001 | 54329) die "PORT_BASE=$PORT_BASE overlaps the default stack's ports; leave PORT_BASE unset for that one" ;; esac
  done
  STACK="$ROOT/.local-stack/$PORT_BASE"
  API_PORT="$PORT_BASE"
  INDEXER_PORT=$((PORT_BASE + 1))
  PGPORT=$((PORT_BASE + 2))
  INVITES="$STACK/invites.txt"
fi
PGDATA="$STACK/pg"
LOGS="$STACK/logs"
MEDIA="$STACK/media"
LOCAL_ENV="$STACK/functions.env"
SETTINGS="$STACK/settings"
# Where an older local-stack.sh kept the default stack's env file: its processes still count as the default stack's.
LEGACY_ENV="$SECRETS/local-functions.env"
API_URL="http://127.0.0.1:$API_PORT/lite"
LOCAL_DB_URL="postgresql://lite_api@127.0.0.1:$PGPORT/lite"

# The whole environment a child process gets, besides its --env-file and the variables named at its start.
CLEAN_ENV=(HOME="$HOME" PATH="$(dirname "$DENO"):/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  TMPDIR="${TMPDIR:-/tmp}" NO_COLOR=1)
if [ -n "${DENO_DIR:-}" ]; then CLEAN_ENV+=(DENO_DIR="$DENO_DIR"); fi

clean() { env -i "${CLEAN_ENV[@]}" "$@"; }
psql_as() { # role database psql-args...
  local role="$1" db="$2"
  shift 2
  clean "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGPORT" -U "$role" -d "$db" "$@"
}
listener() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1 || true; }
# psql's notices and errors as "<file>:<line>: …", indented; "… does not exist, skipping" (drop … if exists) is noise.
indent() { sed -e '/does not exist, skipping/d' -e 's|^psql:.*/\([^/]*:[0-9]*:\)|\1|' -e 's/^/    /'; }
pid_file() { printf '%s/%s.pid' "$STACK" "$1"; }
setting() { sed -n "s/^$1=//p" "$SETTINGS" 2>/dev/null | head -1; }

# What a component's command line runs.
marker() {
  case "$1" in
    lite) printf 'functions/lite/index.ts' ;;
    indexer) printf 'functions/lite-indexer/index.ts' ;;
    loop) printf 'local/indexer-loop.ts' ;;
  esac
}

# A PID file counts only while its process still runs that component with this stack's env file, so a stale PID file
# never points at another stack's process.
running_pid() { # name → prints the PID while that component runs
  local f pid line
  f="$(pid_file "$1")"
  [ -f "$f" ] || return 1
  pid="$(cat "$f")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  line="$(ps -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ "$line" == *"$(marker "$1")"* ]] || return 1
  [[ "$line" == *"--env-file=$LOCAL_ENV"* || (-z "$PORT_BASE" && "$line" == *"--env-file=$LEGACY_ENV"*) ]] || return 1
  printf '%s' "$pid"
}

any_running() { running_pid lite >/dev/null || running_pid indexer >/dev/null || running_pid loop >/dev/null; }

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

check_tools() {
  [ -x "$PGBIN/postgres" ] || die "no Postgres 16 at $PGBIN"
  [ -x "$DENO" ] || die "deno isn't installed"
  mkdir -p "$LOGS" "$MEDIA"
  chmod 700 "$STACK" "$MEDIA"
}

# ------------------------------------------------------------------------------------------------ Postgres

pg_running() { clean "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }

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

# Database `lite`, with the roles CI creates and the table that records which migrations it has had.
create_db() {
  # "… does not exist, skipping" notices (dropdb --if-exists, drop policy if exists) are noise here.
  clean "$PGBIN/dropdb" -h 127.0.0.1 -p "$PGPORT" -U postgres --if-exists --force lite 2>&1 | sed '/does not exist, skipping/d'
  clean "$PGBIN/createdb" -h 127.0.0.1 -p "$PGPORT" -U postgres -E UTF8 lite
  say "postgres: database lite; roles anon and authenticated (nologin, as CI creates them)"
  psql_as postgres lite -c "do \$\$ begin
      if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
      if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
    end \$\$;
    create table $MIGRATIONS_TABLE (name text primary key, applied_at timestamptz not null default now());
    revoke all on $MIGRATIONS_TABLE from public;"
}

# Each migration this database hasn't had, in filename order, in a transaction of its own together with its row in
# local_stack_migrations: one that fails leaves nothing behind and runs again next time. A database made before
# migrations were recorded (or half-made) is rebuilt once, and that deletes everything in it. The indexed rows come
# back from the chain; DyorHQ's own records don't: the transaction log and plans (Recent Activity, and the Portfolio
# figures drawn from it, start over), refresh tokens (every session ends), testers (testnet registers them again at
# their next sign-in) and invites (the codes in .secrets/local-invites.txt stop working).
migrate_db() {
  local f name done_names newest applied=0 total=0
  if [ "$(psql_as postgres postgres -tAc "select count(*) from pg_database where datname = 'lite'")" = 0 ]; then
    create_db
  elif [ "$(psql_as postgres lite -tAc "select to_regclass('$MIGRATIONS_TABLE') is not null")" != t ]; then
    say "postgres: database lite has no record of its migrations (an older local-stack.sh made it); rebuilding it once,"
    say "          which deletes its transaction history, plans, sessions, testers and invites"
    create_db
  fi
  done_names="$(psql_as postgres lite -tAc "select name from $MIGRATIONS_TABLE")"
  newest="$(psql_as postgres lite -tAc "select coalesce(max(name), '') from $MIGRATIONS_TABLE")"
  for f in "$ROOT"/backend/supabase/migrations/*.sql; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    total=$((total + 1))
    [[ "$name" =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]] || die "unexpected migration file name: $name"
    if printf '%s\n' "$done_names" | grep -qxF "$name"; then continue; fi
    if [[ "$name" < "$newest" ]]; then
      say "postgres: migration $name (out of order: this database has $newest already)"
    else
      say "postgres: migration $name"
    fi
    psql_as postgres lite -1 -f "$f" -c "insert into $MIGRATIONS_TABLE (name) values ('$name')" 2>&1 | indent ||
      die "migration $name failed; nothing of it was applied"
    applied=$((applied + 1))
  done
  if [ "$applied" -eq 0 ]; then
    say "postgres: migrations up to date ($total)"
    return 0
  fi
  say "postgres: backend/tests/sql/lite_schema_test.sql (rolled back)"
  psql_as postgres lite -f "$ROOT/backend/tests/sql/lite_schema_test.sql" 2>&1 | indent ||
    die "lite_schema_test.sql failed after the new migrations"
  say "postgres: $applied migration(s) applied, $total in all"
}

# ------------------------------------------------------------------------------------------------ processes

LOOP=on
KEEPER="${LITE_KEEPER:-on}"
DEPLOYMENT=testnet
ACTIVATION=
SHORT_SESSIONS=
INVITE_REQUIRED=

usage() {
  say "usage: [PORT_BASE=<port>] $0 start [--no-loop] [--deployment testnet|testnet-qa] [--activation friendbot|sponsored]"
  say "         [--short-sessions] [--invite-required]"
  say "       | stop | status | migrate | e2e [phases...] | logs [lite|indexer|loop|postgres|all] [lines] | invite <label>"
  exit 2
}

start_options() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-loop) LOOP=off KEEPER=off ;;
      --deployment)
        [ $# -ge 2 ] || usage
        DEPLOYMENT="$2"
        shift
        ;;
      --activation)
        [ $# -ge 2 ] || usage
        ACTIVATION="$2"
        shift
        ;;
      --short-sessions) SHORT_SESSIONS=1 ;;
      --invite-required) INVITE_REQUIRED=1 ;;
      *) usage ;;
    esac
    shift
  done
  case "$KEEPER" in on | off) ;; *) die "LITE_KEEPER is on or off" ;; esac
  case "$ACTIVATION" in "" | friendbot | sponsored) ;; *) die "--activation is friendbot or sponsored" ;; esac
  case "$DEPLOYMENT" in
    testnet) ;;
    testnet-qa)
      # testnet-qa is served where it was made: its v1 file (deploy-contracts.ts), its v2 file (deploy-contracts-v2.ts),
      # or both (deployments/index.ts reads each where it exists).
      [ -f "$ROOT/backend/supabase/functions/_shared/deployments/testnet-qa.json" ] ||
        [ -f "$ROOT/backend/supabase/functions/_shared/deployments/testnet-qa-v2.json" ] ||
        die "--deployment testnet-qa: no deployments/testnet-qa.json or testnet-qa-v2.json here (deploy-contracts.ts or deploy-contracts-v2.ts --deployment testnet-qa makes them)"
      ;;
    *) die "--deployment is testnet or testnet-qa: the local stack runs on testnet only" ;;
  esac
}

# This stack's settings, none of them a secret: what status reports, and what make_env compares.
write_settings() {
  printf '# backend/scripts/local-stack.sh: the settings this stack was started with (no secret)\n'
  printf 'loop=%s\nkeeper=%s\ndeployment=%s\nactivation=%s\nsessions=%s\ninvites=%s\n' "$LOOP" "$KEEPER" "$DEPLOYMENT" \
    "${ACTIVATION:-default}" "$([ -n "$SHORT_SESSIONS" ] && echo short || echo default)" \
    "$([ -n "$INVITE_REQUIRED" ] && echo required || echo default)"
}

# The stack's env file, from .secrets/testnet-functions.env and this start's settings. A running stack keeps the env
# its processes started with: other settings or secrets need a stop first. Without the source file, a stack that
# started before with the same settings keeps its env file as it is.
make_env() {
  local next="$LOCAL_ENV.next" vars
  write_settings >"$SETTINGS.next"
  if [ ! -f "$SOURCE_ENV" ]; then
    if [ -f "$LOCAL_ENV" ] && [ -f "$SETTINGS" ] && cmp -s "$SETTINGS.next" "$SETTINGS"; then
      rm -f "$SETTINGS.next"
      chmod 600 "$LOCAL_ENV"
      say "env: $LOCAL_ENV as it was ($SOURCE_ENV isn't here)"
      return 0
    fi
    rm -f "$SETTINGS.next"
    die "missing $SOURCE_ENV, which a new stack or other settings need: restore it from the password manager" \
      "(docs/RUNBOOK-testnet.md §1). Don't run new-testnet-secrets.ts for it: its new sponsor isn't the one the app pins"
  fi
  vars=(LITE_DB_URL="$LOCAL_DB_URL" LITE_DEPLOYMENT="$DEPLOYMENT" LITE_KEEPER="$KEEPER" LITE_LOCAL_STORAGE_DIR="$MEDIA"
    LITE_PUBLIC_BASE="$API_URL")
  if [ -n "$ACTIVATION" ]; then vars+=(LITE_ACTIVATION="$ACTIVATION"); fi
  if [ -n "$SHORT_SESSIONS" ]; then vars+=(LITE_JWT_TTL_S=120 LITE_REFRESH_TTL_S=600); fi
  if [ -n "$INVITE_REQUIRED" ]; then vars+=(LITE_INVITE_REQUIRED=1); fi
  if ! clean "${vars[@]}" "$DENO" run --no-config --allow-read="$SOURCE_ENV" --allow-write="$next" \
    --allow-env="$SETTING_NAMES" "$ROOT/backend/scripts/local/make-local-env.ts" --from "$SOURCE_ENV" --to "$next" >/dev/null; then
    rm -f "$next" "$SETTINGS.next"
    die "make-local-env.ts wrote nothing (see above)"
  fi
  if [ -f "$LOCAL_ENV" ] && cmp -s "$next" "$LOCAL_ENV" && [ -f "$SETTINGS" ] && cmp -s "$SETTINGS.next" "$SETTINGS"; then
    rm -f "$next" "$SETTINGS.next"
    return 0
  fi
  if any_running; then
    rm -f "$next" "$SETTINGS.next"
    die "this stack runs with other settings or secrets; run: $0 stop, then start with the ones you want"
  fi
  mv -f "$next" "$LOCAL_ENV"
  mv -f "$SETTINGS.next" "$SETTINGS"
  say "env: $LOCAL_ENV (mode 600), secrets from $SOURCE_ENV"
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
  start_options "$@"
  check_tools
  make_env
  init_pg
  start_pg
  migrate_db
  start_function lite "$API_PORT" "$ROOT/backend/supabase/functions/lite/index.ts" SUPABASE_URL=https://local.invalid
  start_function indexer "$INDEXER_PORT" "$ROOT/backend/supabase/functions/lite-indexer/index.ts"
  wait_for "$API_URL/v1/config" 200 90 || die "the lite API doesn't answer GET /v1/config; see: $0 logs lite"
  # Without the cron secret the indexer answers 403, which shows it is up.
  wait_for "http://127.0.0.1:$INDEXER_PORT/" 403 90 || die "lite-indexer doesn't answer; see: $0 logs indexer"
  if [ "$LOOP" = off ]; then
    say "loop: off (--no-loop; keeper jobs off too)"
  elif pid="$(running_pid loop)"; then
    say "loop: already running (PID $pid)"
  else
    spawn loop "$LOGS/indexer-loop.log" env -i "${CLEAN_ENV[@]}" "$DENO" run --no-config \
      --allow-env=LITE_CRON_SECRET --allow-net="127.0.0.1:$INDEXER_PORT" --env-file="$LOCAL_ENV" \
      "$ROOT/backend/scripts/local/indexer-loop.ts" "http://127.0.0.1:$INDEXER_PORT/lite-indexer"
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

cmd_migrate() {
  check_tools
  init_pg
  start_pg
  migrate_db
}

last_post() { # time and HTTP status of the running loop's latest POST (lines after its start banner)
  local line
  line="$(awk '/ indexer-loop: POST / { last = ""; next } $2 ~ /^([0-9][0-9][0-9]|error)$/ { last = $1 " → " $2 } END { print last }' \
    "$LOGS/indexer-loop.log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "$line"; else printf 'none yet'; fi
}

# The API's view of itself: network, deployment, contracts, sponsor, invites and the fee mode (GET /v1/config).
config_lines() {
  local body
  if ! body="$(curl -fsS -m 5 "$API_URL/v1/config" 2>/dev/null)"; then
    say "config    GET $API_URL/v1/config didn't answer"
    return 0
  fi
  printf '%s' "$body" | clean "$DENO" eval --no-config '
    const c = JSON.parse(await new Response(Deno.stdin.readable).text());
    const pinned = new Set(Object.values(c.allowlist ?? {}).flat()).size;
    const sponsor = c.sponsor ? `${c.sponsor.slice(0, 4)}…${c.sponsor.slice(-4)}` : "NOT set";
    const invites = c.inviteRequired ? "invites required" : "no invite needed";
    console.log(`config    network ${c.network}, deployment ${c.deployment?.id ?? "?"}, ${pinned} pinned contracts, sponsor ${sponsor}, ${invites}`);
    const f = c.fees ?? {};
    const cap = f.maxFee ? `, at most ${Number(f.maxFee) / 1e7} XLM a transaction` : "";
    console.log(`fees      payer ${f.payer ?? "?"}${cap}; activation ${c.activation}; starter swap ${f.starterSwap ? "offered" : "off"}`);' ||
    say "config    GET $API_URL/v1/config answered something else than the config"
}

# A query as lite_api, the role the functions use: prints its result, or on failure psql's error (its first line) and
# returns 1.
lite_api_query() { # sql
  local err out
  err="$(mktemp "$STACK/query.XXXXXX")"
  if out="$(psql_as lite_api lite -tAc "$1" 2>"$err")"; then
    rm -f "$err"
    printf '%s' "$out"
    return 0
  fi
  head -1 "$err" | sed -E 's/^.*(ERROR|FATAL): +//'
  rm -f "$err"
  return 1
}

# What the indexer recorded: the ops job's balances (migration 05), reference prices (06) and watch groups (07), each
# once its migration is applied.
indexer_lines() {
  local tables facts ops=null quotes=null groups=null members=null
  if ! tables="$(lite_api_query "select string_agg(t, ' ') from unnest(array['lite.job_runs', 'lite.ref_quotes',
    'lite.watch_groups', 'lite.watch_contracts']) as t where to_regclass(t) is not null")"; then
    say "indexer   lite_api can't read the indexer's tables${tables:+: $tables}"
    return 0
  fi
  case " $tables " in *" lite.job_runs "*)
    ops="(select json_build_object('age', extract(epoch from now() - started_at)::int, 'ok', ok, 'result', result)
      from lite.job_runs where job = 'ops' order by started_at desc limit 1)" ;;
  esac
  case " $tables " in *" lite.ref_quotes "*)
    quotes="(select json_agg(json_build_object('ref', ref, 'usd', usd, 'source', source,
      'age', extract(epoch from now() - quoted_at)::int) order by ref) from lite.ref_quotes)" ;;
  esac
  case " $tables " in *" lite.watch_groups "*) groups="(select count(*) from lite.watch_groups)" ;; esac
  case " $tables " in *" lite.watch_contracts "*) members="(select count(*) from lite.watch_contracts)" ;; esac
  if ! facts="$(lite_api_query "select json_build_object('tables', '$tables', 'ops', $ops, 'quotes', $quotes,
    'groups', $groups, 'members', $members, 'keeper', '$(setting keeper)')")"; then
    say "indexer   lite_api can't read the indexer's tables${facts:+: $facts}"
    return 0
  fi
  printf '%s' "$facts" | clean "$DENO" eval --no-config '
      const d = JSON.parse(await new Response(Deno.stdin.readable).text());
      const has = (t) => d.tables.split(" ").includes(t);
      const ago = (s) => (s < 120 ? `${s} s` : s < 7200 ? `${Math.round(s / 60)} min` : `${Math.round(s / 3600)} h`);
      // The ops job (lite-indexer/jobs/ops.ts) records each key'"'"'s balance: {sponsor: {xlm}, keeper: {xlm}}, or
      // sponsorXlm and keeperXlm. Only those figures are printed, never the rest of the row.
      const xlm = (r, role) => {
        const v = r?.[role]?.xlm ?? r?.[`${role}Xlm`] ?? null;
        return v === null || !Number.isFinite(Number(v)) ? null : Number(v).toLocaleString("en-US", { maximumFractionDigits: 2 });
      };
      const keeperJobs = d.keeper === "off" ? "keeper jobs off (LITE_KEEPER=off); " : "";
      if (!has("lite.job_runs")) console.log(`keepers   ${keeperJobs}no lite.job_runs yet (migration 05)`);
      else if (!d.ops) console.log(`keepers   ${keeperJobs}no ops run yet (the indexer reads the sponsor'"'"'s and keeper'"'"'s XLM every 10 minutes)`);
      else {
        const [s, k] = [xlm(d.ops.result, "sponsor"), xlm(d.ops.result, "keeper")];
        const when = `ops run ${ago(d.ops.age)} ago${d.ops.ok ? "" : ", failed"}`;
        console.log(`keepers   ${keeperJobs}${s || k ? `sponsor ${s ?? "?"} XLM, keeper ${k ?? "?"} XLM (${when})` : `no balances in the last ops run (${when})`}`);
      }
      if (!has("lite.ref_quotes")) console.log("prices    no lite.ref_quotes yet (migration 06)");
      else if (!d.quotes) console.log("prices    no reference quote yet");
      else console.log(`prices    ${d.quotes.map((q) => `${q.ref} ${Number(q.usd)} USD from ${q.source}, ${ago(q.age)} old`).join("; ")}`);
      if (!has("lite.watch_groups")) console.log("watch     no lite.watch_groups yet (migration 07)");
      else console.log(`watch     ${d.groups} group(s)${d.members === null ? "" : `, ${d.members} contract(s)`}`);' ||
    say "indexer   its tables didn't read back"
}

cmd_status() {
  local pid counts migrations
  if [ -z "$PORT_BASE" ]; then
    say "stack     default ports, state ${STACK#"$ROOT"/}"
  else
    say "stack     PORT_BASE $PORT_BASE (API $API_PORT, indexer $INDEXER_PORT, Postgres $PGPORT), state ${STACK#"$ROOT"/}"
  fi
  if pg_running; then
    counts="$(psql_as lite_api lite -tAc "select format('%s testers, %s launches, %s moments, indexed to ledger %s',
      (select count(*) from lite.testers), (select count(*) from lite.launches), (select count(*) from lite.moments),
      coalesce((select ledger::text from lite.indexer_cursors where name = 'events'), 'none'))" 2>/dev/null || echo "schema not ready")"
    migrations="$(psql_as postgres lite -tAc "select count(*) from $MIGRATIONS_TABLE" 2>/dev/null || echo "?")"
    say "postgres  running  127.0.0.1:$PGPORT, db lite: $counts; $migrations migrations applied"
  else
    say "postgres  stopped"
  fi
  if pid="$(running_pid lite)"; then say "lite      running  PID $pid, $API_URL"; else say "lite      stopped"; fi
  if pid="$(running_pid indexer)"; then say "indexer   running  PID $pid, http://127.0.0.1:$INDEXER_PORT"; else say "indexer   stopped"; fi
  if pid="$(running_pid loop)"; then
    say "loop      running  PID $pid, last POST $(last_post)"
  elif [ "$(setting loop)" = off ]; then
    say "loop      off (--no-loop)"
  else
    say "loop      stopped"
  fi
  config_lines
  if pg_running; then indexer_lines; fi
  if [ "$(setting sessions)" = short ]; then
    say "sessions  access tokens 120 s, refresh tokens 600 s (--short-sessions)"
  elif [ -f "$SETTINGS" ]; then
    say "sessions  access tokens 1 hour, refresh tokens 30 days"
  fi
}

cmd_e2e() {
  [ -f "$LOCAL_ENV" ] || die "no $LOCAL_ENV yet; run: $0 start"
  wait_for "$API_URL/v1/config" 200 3 || die "this stack's API doesn't answer at $API_URL; run: $0 start"
  # The stack's own env file, so the test's in-process indexer jobs index this stack's deployment into its database.
  exec env -i "${CLEAN_ENV[@]}" LITE_API="$API_URL" LITE_DB_URL="$LOCAL_DB_URL" "$DENO" run -A --frozen \
    --env-file="$LOCAL_ENV" --config "$DENO_CONFIG" "$ROOT/backend/tests/e2e/lite_e2e.ts" "$@"
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
  pg_running || die "the local database isn't up; run: $0 start"
  # invite-tester.ts prints the code once: it goes into the file, never to the terminal.
  code="$(clean LITE_DB_URL="$LOCAL_DB_URL" "$DENO" run -A --frozen --config "$DENO_CONFIG" \
    "$ROOT/backend/scripts/invite-tester.ts" "$label" 1 14)" || die "invite-tester.ts failed; nothing written"
  [[ "$code" =~ ^DYOR-[A-Z2-9]{5}-[A-Z2-9]{5}$ ]] || die "invite-tester.ts printed something unexpected; nothing written"
  if [ ! -f "$INVITES" ]; then
    printf '# Local-stack invites (backend/scripts/local-stack.sh invite): created UTC, label, code. Single use, 14 days.\n' >"$INVITES"
  fi
  chmod 600 "$INVITES"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" "$code" >>"$INVITES"
  say "wrote 1 invite to $INVITES"
}

case "${1:-}" in
  start)
    shift
    cmd_start "$@"
    ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  migrate) cmd_migrate ;;
  e2e)
    shift
    cmd_e2e "$@"
    ;;
  logs)
    shift
    cmd_logs "$@"
    ;;
  invite)
    shift
    cmd_invite "$@"
    ;;
  *) usage ;;
esac
