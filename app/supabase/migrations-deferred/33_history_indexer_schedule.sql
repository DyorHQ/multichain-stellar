-- 33_history_indexer_schedule — runs the history-indexer Edge Function every 30 seconds (pg_cron → pg_net), and once a
-- day prunes pg_cron's run log to two days and the indexer's run rows to seven (history_housekeeping()).
--
-- PLATFORM-ONLY and DEFERRED: it needs pg_cron, pg_net and Vault, which the PGlite harness does not have, and it must
-- not run before the function it calls exists. It lives in supabase/migrations-deferred/ until the owner has, in order:
--   (1) applied 32_wallet_history.sql (MCP apply_migration, so supabase_migrations records it) — this file refuses
--       without 32's history_cron_digest(), the function the Edge Function checks the cron header with;
--   (2) enabled pg_cron and pg_net (Dashboard → Database → Extensions) and checked that `net` is not an exposed API
--       schema (Settings → API);
--   (3) deployed history-indexer (verify_jwt = false, supabase/config.toml).
-- Then: set v_armed below to true and v_indexer_url to this project's function URL, apply this file with MCP
-- apply_migration (name 33_history_indexer_schedule) as postgres, and move it into supabase/migrations/ with v_armed
-- true and v_indexer_url back to null (migrations_test.ts lists it in PLATFORM_ONLY: on PGlite it must refuse with
-- "requires pg_cron and pg_net"). Idempotent: re-running keeps both Vault secrets and replaces both jobs.
--
-- The Vault secrets it needs, created here when missing (no person, file, chat or Edge secret ever holds the first):
--   history_cron_secret  the x-history-cron header value: 32 random bytes from pgcrypto's gen_random_bytes (schema
--                        extensions), as 64 hex characters, generated inside Postgres. The cron job reads it at each
--                        tick; the Edge Function compares the header's SHA-256 with history_cron_digest() (32). One
--                        that already exists is kept only if it is 32–512 visible ASCII characters (no spaces: the
--                        function refuses any other header); otherwise this file refuses, and the fix is to delete it.
--                        To rotate: delete the row (delete from vault.secrets where name = 'history_cron_secret') and
--                        apply this file again. NOT INSTANT: each warm function instance keeps the old digest for up to
--                        a minute, so for up to 60 s the old value is still accepted and the new one refused (a tick
--                        or two answer 403); after that the old value is dead everywhere.
--   history_indexer_url  https://<project ref>.supabase.co/functions/v1/history-indexer, from v_indexer_url (a
--                        database's own project: a branch or staging stack sets its own, or creates the secret itself,
--                        so it never calls production's function). Not secret.
--   history_indexer_region  optional, created by hand (select vault.create_secret('eu-west-1', 'history_indexer_region',
--                        'history-indexer x-region')): pins the function next to the database.
-- Caveats of Vault and pg_net (Supabase's own, the same for a secret created in the dashboard): vault.create_secret
-- writes the value and encrypts it in one transaction, so the plaintext reaches the WAL (and backups made from it) and
-- a dead tuple until vacuum; pg_net keeps each queued request, headers included, in net.http_request_queue until its
-- worker sends it (readable by roles that can log in, i.e. postgres). cron.job stores the job's text, which names the
-- secret, never its value.
--
-- The job runs as postgres (pg_cron runs a job as the role that scheduled it): it reads vault.decrypted_secrets
-- (Supabase grants postgres select on it; this file's own Vault reads below fail loudly if not) and passes the values
-- to net.http_post, whose arguments the caller evaluates. It sends only the cron secret and an empty body; the function
-- answers 202 at once and works in the background under a lease, so ticks never overlap work. A tick that fired is not
-- a run that worked: cron.job_run_details says "succeeded" as soon as net.http_post queued the request. Watch
-- net._http_response (kept 6 h) and history_health() (supabase/README.md "Wallet history cache").
--
-- Reverse: select cron.unschedule('history-indexer'); select cron.unschedule('history-indexer-housekeeping');
--          (to stop indexing without unscheduling: update public.history_indexer_state set paused = true where id;)
--          the Vault rows can stay (or: delete from vault.secrets where name in ('history_cron_secret', 'history_indexer_url');)
-- Verify after apply (booleans and counts only — never select a decrypted value into a transcript):
--   select jobname, schedule, active from cron.job where jobname like 'history-indexer%';            -- 2 rows, active
--   select count(*) from vault.decrypted_secrets where name = 'history_cron_secret' and decrypted_secret ~ '^[0-9a-f]{64}$';  -- 1
--   select status_code, count(*) from net._http_response where created > now() - interval '10 minutes' group by 1;  -- 202
--   select public.history_health();

do $migration$
declare
  v_armed constant boolean := false;  -- SET TRUE once (1)–(3) in the header all hold
  v_indexer_url constant text := null;  -- SET when arming: 'https://<project ref>.supabase.co/functions/v1/history-indexer'
  c_url_shape constant text := '^https://[a-z0-9.-]+(:[0-9]+)?/functions/v1/history-indexer$';
begin
  if not v_armed then
    raise exception 'not armed: apply only after migration 32, pg_cron + pg_net and the history-indexer deploy (see the header)';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    raise exception 'requires pg_cron and pg_net: enable both (Dashboard → Database → Extensions) first';
  end if;
  if to_regprocedure('public.history_commit(uuid, text, integer, bigint, bigint, bigint, bigint, text[], jsonb)') is null
     or to_regprocedure('public.history_housekeeping()') is null
     or to_regprocedure('public.history_cron_digest()') is null then
    raise exception 'apply migration 32 (with history_cron_digest) first';
  end if;
  if to_regprocedure('vault.create_secret(text, text, text, uuid)') is null or to_regclass('vault.decrypted_secrets') is null then
    raise exception 'requires Vault (supabase_vault)';
  end if;

  -- The cron secret, generated here when missing: 32 random bytes, 64 hex characters (header-safe). Never selected,
  -- returned or raised: the only reads below are a shape check, a digest comparison and the job's own, at each tick.
  if not exists (select 1 from vault.decrypted_secrets where name = 'history_cron_secret') then
    if to_regprocedure('extensions.gen_random_bytes(integer)') is null then
      raise exception 'requires pgcrypto in schema extensions (gen_random_bytes) to generate the cron secret';
    end if;
    begin
      perform vault.create_secret(pg_catalog.encode(extensions.gen_random_bytes(32), 'hex'), 'history_cron_secret',
                                  'history-indexer cron header (generated by migration 33)');
    exception when unique_violation then
      null; -- created meanwhile
    end;
  end if;
  -- The Edge Function's rule for a header (auth.ts plausibleToken): 32–512 visible ASCII characters. [!-~] is 0x21–0x7e
  -- by code point; the length is checked apart because a regex bound stops at 255.
  if not exists (select 1 from vault.decrypted_secrets
                  where name = 'history_cron_secret' and pg_catalog.length(decrypted_secret) between 32 and 512
                    and decrypted_secret ~ '^[!-~]+$') then
    raise exception 'the Vault secret history_cron_secret must be 32–512 visible ASCII characters (no spaces): delete it and apply again (a new one is generated)';
  end if;
  if public.history_cron_digest() is distinct from
     (select pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(decrypted_secret, 'UTF8')), 'hex')
        from vault.decrypted_secrets where name = 'history_cron_secret') then
    raise exception 'history_cron_digest does not read the Vault secret history_cron_secret: check that postgres can read vault.decrypted_secrets';
  end if;

  -- The function's URL: this database's own project.
  if not exists (select 1 from vault.decrypted_secrets where name = 'history_indexer_url') then
    if v_indexer_url is null or v_indexer_url !~ c_url_shape then
      raise exception 'set v_indexer_url to https://<project ref>.supabase.co/functions/v1/history-indexer (or create the Vault secret history_indexer_url) first';
    end if;
    begin
      perform vault.create_secret(v_indexer_url, 'history_indexer_url', 'history-indexer URL');
    exception when unique_violation then
      null;
    end;
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'history_indexer_url' and decrypted_secret ~ c_url_shape) then
    raise exception 'the Vault secret history_indexer_url must be https://<host>/functions/v1/history-indexer';
  end if;

  perform cron.unschedule(j.jobid) from cron.job j where j.jobname in ('history-indexer', 'history-indexer-housekeeping');

  perform cron.schedule('history-indexer', '30 seconds', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'history_indexer_url'),
      headers := jsonb_strip_nulls(jsonb_build_object(
        'Content-Type', 'application/json',
        'x-region', (select decrypted_secret from vault.decrypted_secrets where name = 'history_indexer_region'),
        'x-history-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'history_cron_secret'))),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000)
  $job$);

  perform cron.schedule('history-indexer-housekeeping', '17 3 * * *', $job$
    delete from cron.job_run_details where start_time < now() - interval '2 days';
    select public.history_housekeeping();
  $job$);
end
$migration$;
