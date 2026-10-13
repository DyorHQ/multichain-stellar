-- DyorHQ Lite (Stellar) schema, in the DyorHQ Supabase project next to the Pro app's tables (DECISIONS #17).
-- Every table has RLS on and NO policy for anon/authenticated: PostgREST exposes nothing. The Edge Functions
-- connect as lite_api (migration 4) and enforce auth themselves (lite JWT + tester allowlist).

create schema if not exists lite;
revoke all on schema lite from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema lite from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema lite from authenticated'; end if;
end $$;

-- ------------------------------------------------------------------------------------------------ access

create table lite.invites (
  id uuid primary key default gen_random_uuid(),
  code_hash text not null unique,              -- sha256 hex of the invite code; the code itself is never stored
  label text not null,
  max_uses int not null default 1 check (max_uses between 1 and 100),
  uses int not null default 0,
  expires_at timestamptz not null default now() + interval '14 days',
  created_at timestamptz not null default now(),
  check (uses <= max_uses)
);

create table lite.testers (
  address text primary key check (address ~ '^G[A-Z2-7]{55}$'),
  invite_id uuid references lite.invites(id),
  label text,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table lite.auth_nonces (
  nonce text primary key,
  address text not null,
  message text not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index auth_nonces_expiry on lite.auth_nonces (expires_at);

-- ------------------------------------------------------------------------------------------------ transactions

-- What the server built. /tx/submit only fee-bumps a transaction whose hash is a step here, for its owner.
create table lite.plans (
  id uuid primary key default gen_random_uuid(),
  address text not null,
  kind text not null,
  steps jsonb not null,                        -- [{id, label, spec, intent, xdr, hash, status, built_at}]
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes'
);
create index plans_address on lite.plans (address, created_at desc);

create table lite.tx_log (
  hash text primary key,                       -- outer (fee-bump) hash
  inner_hash text not null unique,
  address text not null,
  plan_id uuid references lite.plans(id) on delete set null,
  step_id text,
  kind text not null,
  intent jsonb,
  status text not null default 'pending' check (status in ('pending', 'success', 'failed')),
  fee_charged bigint,
  max_fee bigint not null,
  ledger int,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tx_log_address on lite.tx_log (address, created_at desc);
create index tx_log_pending on lite.tx_log (status) where status = 'pending';

create table lite.sponsor_usage (
  address text not null,
  day date not null default (now() at time zone 'utc')::date,
  fee_stroops bigint not null default 0,
  tx_count int not null default 0,
  reserves_sponsored int not null default 0,
  primary key (address, day)
);

-- Atomically reserves `amount` stroops of today's budget for `addr`; false when it would exceed `budget`.
create or replace function lite.reserve_fee_budget(addr text, amount bigint, budget bigint)
returns boolean language plpgsql as $$
declare ok boolean;
begin
  insert into lite.sponsor_usage (address, day, fee_stroops, tx_count)
  values (addr, (now() at time zone 'utc')::date, 0, 0)
  on conflict (address, day) do nothing;
  update lite.sponsor_usage
     set fee_stroops = fee_stroops + amount, tx_count = tx_count + 1
   where address = addr and day = (now() at time zone 'utc')::date and fee_stroops + amount <= budget
  returning true into ok;
  return coalesce(ok, false);
end $$;

create table lite.swap_quotes (
  id uuid primary key default gen_random_uuid(),
  address text not null,
  request jsonb not null,
  best jsonb not null,
  alternatives jsonb not null default '[]',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '60 seconds'
);

-- ------------------------------------------------------------------------------------------------ indexed chain data

create table lite.launches (
  token text primary key,
  creator text not null,
  quote text not null,
  name text not null,
  symbol text not null,
  uri text not null default '',
  launch_index int not null,
  supply numeric not null,
  phantom numeric not null,
  threshold numeric not null,
  creator_fee_bps int not null default 0,
  quote_reserve numeric not null,
  token_reserve numeric not null,
  real_quote numeric not null default 0,
  completed boolean not null default false,
  graduated boolean not null default false,
  pair text,
  last_price numeric,                          -- quote per token, base units ratio
  volume_quote numeric not null default 0,
  trades int not null default 0,
  created_ledger int not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index launches_recent on lite.launches (created_at desc);
create index launches_hot on lite.launches (volume_quote desc) where not graduated;

create table lite.launch_trades (
  event_id text primary key,
  token text not null references lite.launches(token) on delete cascade,
  trader text not null,
  side text not null check (side in ('buy', 'sell')),
  quote_amount numeric not null,
  token_amount numeric not null,
  fees numeric not null,
  price numeric not null,                      -- quote per token after the trade (virtual reserves ratio)
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index launch_trades_token on lite.launch_trades (token, ts desc);
create index launch_trades_trader on lite.launch_trades (trader, ts desc);

create table lite.moments (
  id int primary key,
  creator text not null,
  uri text not null,
  title text,
  media_url text,
  price numeric not null,
  quote text not null,
  max_editions int not null,
  minted int not null default 0,
  deadline timestamptz not null,
  created_ledger int not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index moments_recent on lite.moments (created_at desc);

create table lite.moment_collects (
  event_id text primary key,
  moment_id int not null references lite.moments(id) on delete cascade,
  collector text not null,
  quantity int not null,
  first_token_id int not null,
  paid numeric not null,
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index moment_collects_collector on lite.moment_collects (collector, ts desc);

create table lite.bridge_transfers (
  id uuid primary key default gen_random_uuid(),
  address text not null,
  direction text not null check (direction in ('monad_to_stellar', 'stellar_to_monad')),
  route text not null check (route in ('cctp', 'oneclick')),
  amount numeric not null,
  recipient text not null,
  source_tx text,
  message text,
  attestation text,
  dest_tx text,
  status text not null default 'awaiting_source'
    check (status in ('awaiting_source', 'attesting', 'relaying', 'completed', 'failed')),
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index bridge_transfers_open on lite.bridge_transfers (status) where status in ('attesting', 'relaying');

create table lite.anchor_transfers (
  id uuid primary key default gen_random_uuid(),
  address text not null,
  anchor text not null,
  kind text not null check (kind in ('deposit', 'withdraw')),
  asset text not null,
  amount numeric,
  anchor_tx_id text not null,
  status text not null default 'incomplete',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (anchor, anchor_tx_id)
);

create table lite.indexer_cursors (
  name text primary key,
  ledger int not null,
  cursor text,
  network_id text not null,
  updated_at timestamptz not null default now()
);

create table lite.app_config (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
insert into lite.app_config (key, value) values
  ('lite', '{"enabled": true, "min_build": 1, "maintenance": false}');

-- ------------------------------------------------------------------------------------------------ candles

create or replace function lite.candles(p_token text, p_interval text, p_limit int default 200)
returns table (bucket timestamptz, open numeric, high numeric, low numeric, close numeric, volume numeric)
language sql stable as $$
  with t as (
    select date_bin(p_interval::interval, ts, timestamptz '2026-01-01') as bucket, ts, price, quote_amount
      from lite.launch_trades where token = p_token
  )
  select bucket,
         (array_agg(price order by ts asc))[1],
         max(price), min(price),
         (array_agg(price order by ts desc))[1],
         sum(quote_amount)
    from t group by bucket order by bucket desc limit least(p_limit, 1000)
$$;

-- ------------------------------------------------------------------------------------------------ lock it down

do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'lite' loop
    -- No FORCE: the table owner (the functions' database role) keeps access; anon/authenticated have no grants
    -- and no policies, so PostgREST can read or write nothing even if the schema is ever exposed.
    execute format('alter table lite.%I enable row level security', t.tablename);
  end loop;
end $$;

revoke all on all tables in schema lite from public;
revoke all on all functions in schema lite from public;
