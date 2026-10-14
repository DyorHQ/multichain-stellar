#!/usr/bin/env bash
# Deploys the history-indexer Edge Function (supabase/functions/history-indexer and the _shared/history_scans.ts it
# imports) to the DyorHQ Supabase project with the Supabase CLI.
#
# It deploys the COMMITTED tree only (git archive of HEAD, so nothing uncommitted can ride along), with version.ts
# stamped with HEAD's short SHA in a temporary copy (the repository keeps the "__DEPLOY_SHA__" placeholder). Every run
# records that version in public.history_indexer_runs, so a deploy or a rollback can be confirmed from the database.
#
# Nothing else changes: no migration, no Edge secret, no schedule (migrations 32 and 33 are applied already).
# verify_jwt stays off (supabase/config.toml, and --no-verify-jwt here): the function checks its own cron header.
#
# Needs the Supabase CLI (brew install supabase/tap/supabase), signed in with `supabase login`. --dry-run does
# everything but the upload and lists the files with their SHA-256.
#
#   scripts/dev/deploy-history-indexer.sh --dry-run
#   scripts/dev/deploy-history-indexer.sh
set -euo pipefail

PROJECT_REF="fmnjqrguvopusfufmirs"
FUNCTION="history-indexer"

dry=0
case "${1:-}" in
  --dry-run) dry=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [[ -n "$(git status --porcelain -- supabase)" ]]; then
  echo "supabase/ has uncommitted changes: commit them first (only the committed tree is deployed)." >&2
  exit 1
fi
sha="$(git rev-parse --short HEAD)"
if [[ ! "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "could not read HEAD's short SHA" >&2
  exit 1
fi
if ! git show "HEAD:supabase/functions/$FUNCTION/version.ts" | grep -q '"__DEPLOY_SHA__"'; then
  echo "supabase/functions/$FUNCTION/version.ts at HEAD has no __DEPLOY_SHA__ placeholder" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git archive HEAD supabase | tar -x -C "$tmp"
version="$tmp/supabase/functions/$FUNCTION/version.ts"
sed -i '' "s/\"__DEPLOY_SHA__\"/\"$sha\"/" "$version"
if ! grep -q "export const VERSION = \"$sha\";" "$version"; then
  echo "stamping version.ts failed" >&2
  exit 1
fi

echo "history-indexer at $sha (the files the function imports):"
( cd "$tmp/supabase/functions" &&
  for f in "$FUNCTION"/*.ts _shared/history_scans.ts; do
    case "$f" in *_test.ts|*/print_scans.ts) continue ;; esac
    shasum -a 256 "$f"
  done )

if [[ $dry -eq 1 ]]; then
  echo "dry run: nothing uploaded."
  exit 0
fi

if ! command -v supabase >/dev/null 2>&1; then
  echo "the Supabase CLI is not installed: brew install supabase/tap/supabase, then supabase login" >&2
  exit 1
fi

( cd "$tmp" && supabase functions deploy "$FUNCTION" --project-ref "$PROJECT_REF" --no-verify-jwt --use-api )
echo "Deployed $FUNCTION $sha. The next runs (every 30 s) record version $sha in public.history_indexer_runs."
