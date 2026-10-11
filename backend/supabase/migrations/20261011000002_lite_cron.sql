-- Runs the lite-indexer Edge Function every minute (pg_cron + pg_net). The URL and the shared secret come from
-- Vault, created once per project (docs/RUNBOOK-testnet.md §3):
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/lite-indexer', 'lite_indexer_url');
--   select vault.create_secret('<random>', 'lite_cron_secret');   -- same value as the LITE_CRON_SECRET function secret
-- Skipped where the extensions don't exist (plain Postgres in CI).
do $outer$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice 'pg_cron/pg_net not available: lite-indexer schedule skipped';
    return;
  end if;
  create extension if not exists pg_cron;
  create extension if not exists pg_net;
  perform cron.unschedule(jobid) from cron.job where jobname = 'lite-indexer';
  perform cron.schedule('lite-indexer', '* * * * *', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'lite_indexer_url'),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'lite_cron_secret')),
      body := '{}'::jsonb,
      timeout_milliseconds := 55000)
  $job$);
end
$outer$;
