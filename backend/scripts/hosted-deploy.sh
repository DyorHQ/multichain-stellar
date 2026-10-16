#!/bin/bash
# Deploys the Stellar backend to the hosted DyorHQ project (the maintainers' runbook), one confirmed step at a time:
# the `lite` schema's migrations, the lite_api role's password, the function secrets, the lite and lite-indexer
# functions, the Vault entries the cron job reads, and the cron job last (it calls the indexer every minute and fails
# until the function and the Vault entries exist).
#
#   backend/scripts/hosted-deploy.sh check        # read-only: CLI, project, files, what's already there
#   backend/scripts/hosted-deploy.sh all          # every step below, in order, each asking "yes" first
#   backend/scripts/hosted-deploy.sh <step>       # migrate | role | secrets | functions | vault | cron | verify
#   YES=1 backend/scripts/hosted-deploy.sh all    # no questions (the owner has read the steps)
#
# Run it from the repository's main checkout, on main, with the Supabase CLI logged in to the account that owns the
# project. It never prints a secret: the SQL files that hold one (.secrets/lite-api-role.sql, .secrets/testnet-vault.sql)
# go to the database with `supabase db query --file`, which reads them itself, and are deleted once applied; the
# function secrets go with `supabase secrets set --env-file`. Migrations are applied as SQL, like the SQL editor does,
# so the DyorHQ app's own migration history isn't touched. Never `supabase db push` or `supabase config push` here.
set -euo pipefail
REF=fmnjqrguvopusfufmirs
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS="$ROOT/.secrets"
MIG="$ROOT/backend/supabase/migrations"
API="https://$REF.supabase.co/functions/v1/lite"
say() { printf 'hosted-deploy: %s\n' "$*"; }
die() {
  printf 'hosted-deploy: %s\n' "$*" >&2
  exit 1
}
confirm() {
  [ "${YES:-}" = 1 ] && return 0
  printf 'hosted-deploy: %s — type yes to continue: ' "$1"
  read -r answer
  [ "$answer" = yes ] || die "stopped before: $1"
}
# --linked with --project-ref goes through the Management API for that project; no folder needs linking.
query() { supabase db query --linked --project-ref "$REF" "$@"; }
# Runs a command whose input holds a secret (a SQL file with a password or a Vault value, the function secrets) with all
# of its output kept back: a failed statement's error can quote the statement, so only "failed" is ever printed.
quiet_secret() {
  local what=$1
  shift
  "$@" >/dev/null 2>&1 || die "$what failed (its output is withheld because it may contain the secret); nothing was deleted, run this step again"
}
# The migrations in filename order, but the cron job's, which runs last (step cron).
migrations() { find "$MIG" -name '*.sql' ! -name '*_lite_cron.sql' | LC_ALL=C sort; }
cron_migration() { find "$MIG" -name '*_lite_cron.sql'; }
# Whether schema lite exists; a query that doesn't answer stops the run (never read as "no schema").
schema_exists() {
  local out
  out=$(query "select exists (select 1 from pg_namespace where nspname = 'lite') as lite" 2>&1) || die "couldn't query $REF: $(printf '%s' "$out" | tail -2)"
  if printf '%s' "$out" | grep -qE '"lite": *true'; then return 0; fi
  printf '%s' "$out" | grep -qE '"lite": *false' || die "couldn't read whether schema lite exists on $REF"
  return 1
}

check() {
  command -v supabase >/dev/null || die "the Supabase CLI isn't installed"
  command -v deno >/dev/null || die "deno isn't installed"
  supabase projects list -o json 2>/dev/null | grep -q "\"$REF\"" || die "this CLI login can't see project $REF (supabase login with the owner's account)"
  say "project $REF is visible to this CLI login"
  local branch
  branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
  say "checkout: $branch at $(git -C "$ROOT" rev-parse --short HEAD)$( [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] && echo ' (with uncommitted changes)')"
  [ "$branch" = main ] || say "warning: not on main"
  for f in testnet-functions.env lite-api-role.sql testnet-vault.sql; do
    if [ -f "$SECRETS/$f" ]; then say "secrets file $f: present"; else say "secrets file $f: missing"; fi
  done
  say "migrations: $(migrations | wc -l | tr -d ' ') + the cron job's"
  if schema_exists; then say "schema lite: already on the project (step migrate refuses to run twice)"; else say "schema lite: not there yet"; fi
}

migrate() {
  schema_exists && die "schema lite already exists on $REF: the migrations ran before; apply any new one by hand"
  confirm "apply $(migrations | wc -l | tr -d ' ') migrations (schema lite, the lite_api role, the media bucket, tables, contracts v2) to $REF"
  local f
  for f in $(migrations); do
    say "migration $(basename "$f")"
    query --file "$f" >/dev/null
  done
  say "migrations applied"
}

role() {
  [ -f "$SECRETS/lite-api-role.sql" ] || die "no .secrets/lite-api-role.sql: make it with new-testnet-secrets.ts --db-role $REF aws-1-eu-west-1.pooler.supabase.com"
  confirm "set the lite_api role's password (a SCRAM verifier, from .secrets/lite-api-role.sql)"
  quiet_secret "setting the lite_api password" query --file "$SECRETS/lite-api-role.sql"
  rm -f "$SECRETS/lite-api-role.sql"
  say "lite_api role password set; .secrets/lite-api-role.sql deleted"
}

secrets() {
  [ -f "$SECRETS/testnet-functions.env" ] || die "no .secrets/testnet-functions.env"
  confirm "set the function secrets on $REF from .secrets/testnet-functions.env (names: $(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$SECRETS/testnet-functions.env" | tr '\n' ' '))"
  quiet_secret "setting the function secrets" supabase secrets set --project-ref "$REF" --env-file "$SECRETS/testnet-functions.env"
  say "function secrets set"
}

functions() {
  confirm "deploy the lite and lite-indexer functions from $(git -C "$ROOT" rev-parse --short HEAD) to $REF"
  supabase functions deploy lite lite-indexer --project-ref "$REF" --workdir "$ROOT/backend" --use-api
  say "functions deployed"
}

vault() {
  if [ ! -f "$SECRETS/testnet-vault.sql" ]; then
    deno run -A --config "$ROOT/backend/supabase/functions/deno.json" "$ROOT/backend/scripts/new-testnet-secrets.ts" --vault-sql "$REF"
  fi
  confirm "create or update the Vault entries lite_indexer_url and lite_cron_secret (from .secrets/testnet-vault.sql)"
  quiet_secret "setting the Vault entries" query --file "$SECRETS/testnet-vault.sql"
  rm -f "$SECRETS/testnet-vault.sql"
  say "Vault entries set; .secrets/testnet-vault.sql deleted"
}

cron() {
  confirm "schedule the lite-indexer cron job (every minute) on $REF"
  query --file "$(cron_migration)" >/dev/null
  say "cron job scheduled"
}

verify() {
  say "GET $API/v1/config"
  curl -fsS --max-time 30 "$API/v1/config" | python3 -I -c '
import json, sys
c = json.load(sys.stdin)
d = c.get("deployment") or {}
print("  network:", c.get("network"), "| deployment:", d.get("id") or d, "| pinned contracts:", len(c.get("contracts") or c.get("pinned") or {}))
'
  say "GET $API/v1/economics"
  curl -fsS --max-time 30 "$API/v1/economics" | python3 -I -c '
import json, sys
e = json.load(sys.stdin)
lp = e.get("launchpad") or {}
print("  launchpad keys:", sorted(lp.keys())[:12])
print("  launch fee:", lp.get("launchFee"), "| moments:", "present" if e.get("moments") else "absent")
'
  say "the cron job's last runs"
  query "select status, left(coalesce(return_message, ''), 120) as message, start_time from cron.job_run_details where jobid = (select jobid from cron.job where jobname = 'lite-indexer') order by start_time desc limit 5"
}

step=${1:-}
case "$step" in
  check) check ;;
  migrate | role | secrets | functions | vault | cron | verify) check >/dev/null && "$step" ;;
  all)
    check
    migrate
    role
    secrets
    functions
    vault
    cron
    say "waiting 90 s for the first indexer runs"
    sleep 90
    verify
    ;;
  *) die "usage: $0 check | all | migrate | role | secrets | functions | vault | cron | verify" ;;
esac
