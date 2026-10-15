-- Hybrid fees (docs/DESIGN-stellar-parity.md §4, §6.11 and §6.15; WP-10). Users pay their own network fees in XLM.
-- DyorHQ pays only an account's setup and, where activation is sponsored (mainnet), one starter swap into XLM; each
-- such sponsorship is reserved here first, against limits that live in Postgres, never in memory. The keeper pays
-- protocol upkeep (graduation, rent) and logs every transaction it sends. The per-user daily fee budget goes: nobody's
-- fees are sponsored step by step any more.

-- ------------------------------------------------------------------------------------------------ tx_log

-- Who paid each transaction, what kind of step it was, the section it counts in (Portfolio, Recent Activity) and what
-- it delivered ({amountOut}). Every row before this migration was fee-bumped by the sponsor; from now on the user pays,
-- unless the API records otherwise (the sponsor for a setup or the starter swap, `external` for the testnet faucet).
alter table lite.tx_log add column if not exists fee_payer text;
update lite.tx_log set fee_payer = 'sponsor' where fee_payer is null;
alter table lite.tx_log alter column fee_payer set default 'user';
alter table lite.tx_log alter column fee_payer set not null;
alter table lite.tx_log drop constraint if exists tx_log_fee_payer;
alter table lite.tx_log add constraint tx_log_fee_payer check (fee_payer in ('user', 'sponsor', 'external'));
alter table lite.tx_log add column if not exists step_kind text;
alter table lite.tx_log add column if not exists section text;
alter table lite.tx_log drop constraint if exists tx_log_section;
alter table lite.tx_log add constraint tx_log_section
  check (section is null or section in ('spot', 'earn', 'launch', 'moments', 'bridge', 'cash', 'account'));
alter table lite.tx_log add column if not exists result jsonb;
-- max_fee (the fee the transaction declared) and fee_charged (what it cost once settled), in stroops, are migration 1's.
-- GET /v1/fees: the p90 of the declared fee per step kind over 7 days.
create index if not exists tx_log_step_kind on lite.tx_log (step_kind, created_at) where status = 'success';

-- ------------------------------------------------------------------------------------------------ sponsorships

drop function if exists lite.reserve_fee_budget(text, bigint, bigint);
drop table if exists lite.sponsor_usage;

-- One row per sponsorship DyorHQ reserved: `activate` (an account's setup) or `starter` (the first swap into XLM).
-- reserved → sent → success | failed, or reserved → released when nothing reached the network. A released row
-- costs nothing and frees the address for a retry; it still counts as an attempt.
create table if not exists lite.sponsorships (
  id uuid primary key default gen_random_uuid(),
  address text not null check (address ~ '^G[A-Z2-7]{55}$'),
  kind text not null check (kind in ('activate', 'starter')),
  status text not null default 'reserved' check (status in ('reserved', 'sent', 'success', 'failed', 'released')),
  -- HMAC-SHA256(LITE_JWT_SECRET, ip + "|" + day), hex: the IP itself is never stored.
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  -- The UTC day the daily caps count it on.
  day date not null default (now() at time zone 'utc')::date,
  -- The most the sponsor may pay for it, and what it paid once settled, in stroops.
  fee_reserved bigint not null check (fee_reserved >= 0),
  fee_charged bigint check (fee_charged is null or fee_charged >= 0),
  tx_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Once per address and kind: a second one can't be reserved while the first is reserved, sent or successful.
create unique index if not exists sponsorships_once on lite.sponsorships (address, kind)
  where status in ('reserved', 'sent', 'success');
create index if not exists sponsorships_day on lite.sponsorships (kind, day);
create index if not exists sponsorships_ip on lite.sponsorships (ip_hash, day);
create index if not exists sponsorships_tx on lite.sponsorships (tx_hash) where tx_hash is not null;

-- Why DyorHQ wouldn't sponsor `p_kind` for this address and IP now, or null when it would: 'once' (one already
-- reserved, sent or successful), 'attempts' (p_max_attempts rows already, released ones included), 'daily_count'
-- (p_per_day of this kind today), 'daily_fee' (today's fees of this kind plus p_fee above p_fee_cap) or 'ip'
-- (p_per_ip today from this IP, any kind). Released rows cost nothing, so they count only as attempts. Read-only:
-- the API asks it before it offers a sponsored plan, and lite.reserve_sponsorship asks it again under its lock.
create or replace function lite.sponsorship_refusal(
  p_address text, p_kind text, p_ip_hash text, p_fee bigint,
  p_max_attempts int, p_per_day int, p_fee_cap bigint, p_per_ip int)
returns text
language sql stable
set search_path = lite, pg_temp
as $$
  with today as (select (now() at time zone 'utc')::date as day)
  select case
    when exists (select 1 from lite.sponsorships
                  where address = p_address and kind = p_kind and status in ('reserved', 'sent', 'success')) then 'once'
    when (select count(*) from lite.sponsorships where address = p_address and kind = p_kind) >= p_max_attempts then 'attempts'
    when (select count(*) from lite.sponsorships, today
           where kind = p_kind and sponsorships.day = today.day and status <> 'released') >= p_per_day then 'daily_count'
    when (select coalesce(sum(coalesce(fee_charged, fee_reserved)), 0) from lite.sponsorships, today
           where kind = p_kind and sponsorships.day = today.day and status <> 'released') + p_fee > p_fee_cap then 'daily_fee'
    when (select count(*) from lite.sponsorships, today
           where ip_hash = p_ip_hash and sponsorships.day = today.day and status <> 'released') >= p_per_ip then 'ip'
  end
$$;

-- Reserves one sponsorship: (the new row's id, null), or (null, the refusal of lite.sponsorship_refusal). One
-- reservation at a time, so the counts and sums it checks are the ones it acts on, whatever runs alongside.
create or replace function lite.reserve_sponsorship(
  p_address text, p_kind text, p_ip_hash text, p_fee bigint,
  p_max_attempts int, p_per_day int, p_fee_cap bigint, p_per_ip int,
  out id uuid, out refusal text)
language plpgsql
set search_path = lite, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('lite.sponsorships', 0));
  refusal := lite.sponsorship_refusal(p_address, p_kind, p_ip_hash, p_fee, p_max_attempts, p_per_day, p_fee_cap, p_per_ip);
  if refusal is null then
    insert into lite.sponsorships (address, kind, ip_hash, fee_reserved)
    values (p_address, p_kind, p_ip_hash, p_fee)
    returning sponsorships.id into id;
  end if;
end
$$;

-- ------------------------------------------------------------------------------------------------ keeper and jobs

-- Every transaction the keeper key sends (§4.7): graduations, rent upkeep, the CCTP relay.
create table if not exists lite.keeper_log (
  hash text primary key,
  job text not null check (job in ('graduate', 'ttl', 'relay')),
  keeper text not null check (keeper ~ '^G[A-Z2-7]{55}$'),
  max_fee bigint not null check (max_fee >= 0),
  fee_charged bigint,
  status text not null default 'pending' check (status in ('pending', 'success', 'failed')),
  ledger int,
  error text,
  -- What it was for: the launch graduated, the entries extended.
  detail jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists keeper_log_recent on lite.keeper_log (created_at desc);
create index if not exists keeper_log_pending on lite.keeper_log (status) where status = 'pending';

-- One row per run of an indexer job (lite-indexer/index.ts records them; the ops job keeps 7 days).
create table if not exists lite.job_runs (
  id bigint generated always as identity primary key,
  job text not null,
  started_at timestamptz not null,
  ms int not null,
  ok boolean not null,
  result jsonb
);
create index if not exists job_runs_job on lite.job_runs (job, started_at desc);

-- The rent keeper's rotation (§4.8b): when each entry it keeps alive was last checked, so every run checks the ones
-- checked longest ago first. `key` is the ledger key's XDR in base64.
create table if not exists lite.ttl_checks (
  key text primary key,
  label text not null,
  live_until int,
  checked_at timestamptz not null default now()
);
create index if not exists ttl_checks_oldest on lite.ttl_checks (checked_at);

-- ------------------------------------------------------------------------------------------------ access

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.sponsorships, lite.keeper_log, lite.job_runs, lite.ttl_checks from public;
revoke all on function lite.sponsorship_refusal(text, text, text, bigint, int, int, bigint, int) from public;
revoke all on function lite.reserve_sponsorship(text, text, text, bigint, int, int, bigint, int) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on lite.sponsorships, lite.keeper_log, lite.job_runs, lite.ttl_checks from anon';
    execute 'revoke all on function lite.sponsorship_refusal(text, text, text, bigint, int, int, bigint, int) from anon';
    execute 'revoke all on function lite.reserve_sponsorship(text, text, text, bigint, int, int, bigint, int) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on lite.sponsorships, lite.keeper_log, lite.job_runs, lite.ttl_checks from authenticated';
    execute 'revoke all on function lite.sponsorship_refusal(text, text, text, bigint, int, int, bigint, int) from authenticated';
    execute 'revoke all on function lite.reserve_sponsorship(text, text, text, bigint, int, int, bigint, int) from authenticated';
  end if;
end $$;
grant select, insert, update, delete on lite.sponsorships, lite.keeper_log, lite.job_runs, lite.ttl_checks to lite_api;
grant usage, select on sequence lite.job_runs_id_seq to lite_api;
grant execute on function lite.sponsorship_refusal(text, text, text, bigint, int, int, bigint, int) to lite_api;
grant execute on function lite.reserve_sponsorship(text, text, text, bigint, int, int, bigint, int) to lite_api;

-- The RLS-and-policy loop of 20261013000004: RLS on every lite table, and lite_api's one policy on each.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'lite' loop
    execute format('alter table lite.%I enable row level security', t.tablename);
    execute format('drop policy if exists lite_api_all on lite.%I', t.tablename);
    execute format('create policy lite_api_all on lite.%I for all to lite_api using (true) with check (true)', t.tablename);
  end loop;
end $$;
