-- Launches as the board, a launch's page and My Launchpad show them (docs/DESIGN-stellar-parity.md §6.9, §6.11 and
-- §6.15; WP-14):
-- - launch_metadata: what POST /v1/launches/metadata wrote (name, ticker, description, image, links), by the URI a
--   launch carries on chain; only its writer may launch with it. Kept across indexer resets, like every metadata table.
-- - launches gains what the indexer learns besides the curve: the launch's fee terms, the graduation (burn, pool
--   reserves, which side of the pair is the launch token, when), creator fees claimed, the metadata joined by URI,
--   whether it is listed (a deployment's smoke launches never are) and whether its ticker imitates another.
-- - pool_swaps and creator_claims: Soroswap trades after graduation and creator fee claims, one row per event.
-- - token_events and token_balances: each launch token's transfers, mints and burns, and the balances they add up to,
--   kept in the same transaction (holders and balances never need an RPC fan-out).
-- - watch_groups and watch_contracts: the launch tokens and graduated pairs the indexer reads events from, at most 25
--   to a group (one getEvents request), each group with its own cursor.
-- - token_price_at, token_candles and launch_holders: a launch's price at a time, its candles over curve trades and
--   pool swaps, and its holder count without the launchpad and the pair.

-- ------------------------------------------------------------------------------------------------ metadata

create table if not exists lite.launch_metadata (
  -- <media base>launches/<address>/<uuid>.json: the URI a launch is created with.
  uri text primary key,
  -- Who wrote it; only this address may launch with it.
  address text not null check (address ~ '^G[A-Z2-7]{55}$'),
  name text not null check (octet_length(name) between 1 and 32),
  symbol text not null check (symbol ~ '^[A-Z0-9]{2,10}$'),
  description text check (char_length(description) <= 500),
  -- <media base>uploads/<address>/<file>, or null.
  image text,
  -- {"website", "x", "telegram"}: https links, each null or at most 200 characters.
  links jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists launch_metadata_address on lite.launch_metadata (address, created_at desc);

-- ------------------------------------------------------------------------------------------------ launches

alter table lite.launches add column if not exists fee_bps int;
alter table lite.launches add column if not exists protocol_share_bps int;
-- Burned by the graduation (its event); burns by holders are counted from token_events.
alter table lite.launches add column if not exists burned numeric not null default 0;
-- The pair's reserves, from the graduation, then from the pair's sync, deposit and withdraw events: the latest one
-- applied (its event id; a page read again never moves the pool back) and its transaction, which prices that
-- transaction's swap.
alter table lite.launches add column if not exists pool_token numeric;
alter table lite.launches add column if not exists pool_quote numeric;
alter table lite.launches add column if not exists pool_event text;
alter table lite.launches add column if not exists pool_tx text;
-- Whether the pair's token_0 is the launch token, read once from the pair at graduation.
alter table lite.launches add column if not exists pair_token0_is_launch boolean;
alter table lite.launches add column if not exists graduated_ledger int;
alter table lite.launches add column if not exists graduated_at timestamptz;
-- The latest curve trade or pool swap.
alter table lite.launches add column if not exists last_trade_at timestamptz;
alter table lite.launches add column if not exists creator_fees_claimed numeric not null default 0;
-- From launch_metadata, joined by uri when the launch is indexed.
alter table lite.launches add column if not exists image_url text;
alter table lite.launches add column if not exists description text;
alter table lite.launches add column if not exists links jsonb;
-- False for the deployment's smoke launches: indexed, never in a live feed.
alter table lite.launches add column if not exists listed boolean not null default true;
-- The ticker folds to a reserved one (symbols.ts): flagged on every row, never in the markets.
alter table lite.launches add column if not exists look_alike boolean not null default false;
-- False once part of the token's events couldn't be read (older than RPC retention, or a refused cursor).
alter table lite.launches add column if not exists holders_complete boolean not null default true;
alter table lite.launches add column if not exists ttl_checked_at timestamptz;
-- The Soroswap pool's swap fee, recorded at graduation.
alter table lite.launches add column if not exists pool_fee_bps int;

create index if not exists launches_board on lite.launches (graduated, created_at desc) where listed;
create index if not exists launches_creator on lite.launches (creator, created_at desc);
create index if not exists launches_pair on lite.launches (pair) where pair is not null;

-- ------------------------------------------------------------------------------------------------ trades and claims

-- Soroswap swaps of a graduated launch token. side is 'buy' when the launch token left the pool; price is the pool's
-- quote per token after the swap (the sync of the same transaction), null until that sync is read.
create table if not exists lite.pool_swaps (
  event_id text primary key,
  token text not null references lite.launches(token) on delete cascade,
  pair text not null,
  trader text not null,
  side text not null check (side in ('buy', 'sell')),
  quote_amount numeric not null check (quote_amount >= 0),
  token_amount numeric not null check (token_amount >= 0),
  price numeric,
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists pool_swaps_token on lite.pool_swaps (token, ts desc);
create index if not exists pool_swaps_trader on lite.pool_swaps (trader, ts desc);
create index if not exists pool_swaps_tx on lite.pool_swaps (pair, tx_hash) where price is null;

create table if not exists lite.creator_claims (
  event_id text primary key,
  token text not null references lite.launches(token) on delete cascade,
  creator text not null,
  amount numeric not null check (amount >= 0),
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists creator_claims_token on lite.creator_claims (token, ts desc);
create index if not exists creator_claims_creator on lite.creator_claims (creator, ts desc);

-- ------------------------------------------------------------------------------------------------ launch tokens

create table if not exists lite.token_events (
  event_id text primary key,
  token text not null references lite.launches(token) on delete cascade,
  kind text not null check (kind in ('transfer', 'mint', 'burn')),
  from_address text,
  to_address text,
  -- A transfer to a muxed address: its id (u64), as text.
  to_muxed_id text,
  amount numeric not null check (amount >= 0),
  tx_hash text,
  ledger int not null,
  ts timestamptz not null,
  check ((kind = 'transfer' and from_address is not null and to_address is not null)
      or (kind = 'mint' and from_address is null and to_address is not null)
      or (kind = 'burn' and from_address is not null and to_address is null))
);
create index if not exists token_events_burns on lite.token_events (token) where kind = 'burn';

-- What token_events add up to per holder (G… or C…). reconcile checks them against a live balance(), oldest check
-- first, and overwrites a mismatch; checked_ledger is the ledger that balance was read at, so an event up to it is
-- already counted.
create table if not exists lite.token_balances (
  token text not null references lite.launches(token) on delete cascade,
  address text not null,
  balance numeric not null,
  updated_ledger int not null,
  checked_ledger int,
  checked_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (token, address)
);
create index if not exists token_balances_held on lite.token_balances (address) where balance > 0;
create index if not exists token_balances_check on lite.token_balances (checked_at nulls first);

-- ------------------------------------------------------------------------------------------------ watched contracts

-- One getEvents request reads a group: at most 5 filters of 5 contract ids. A group reads from start_ledger until it
-- has a cursor, then from the cursor; ledger is how far it has read.
create table if not exists lite.watch_groups (
  id bigint generated always as identity primary key,
  start_ledger int not null,
  cursor text,
  ledger int not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists lite.watch_contracts (
  contract text primary key,
  role text not null check (role in ('token', 'pair')),
  -- The launch token: the contract itself, or the one the pair trades.
  token text not null references lite.launches(token) on delete cascade,
  -- Its first ledger: the launch's, or the graduation's.
  from_ledger int not null,
  group_id bigint references lite.watch_groups(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists watch_contracts_group on lite.watch_contracts (group_id);

-- ------------------------------------------------------------------------------------------------ functions

-- A launch's price in its quote asset at a time: after its last curve trade or priced pool swap at or before p_at
-- (events of one ledger in their order), else its opening price (phantom / supply) once it exists; null before it.
create or replace function lite.token_price_at(p_token text, p_at timestamptz)
returns numeric
language sql stable
set search_path = lite, pg_temp
as $$
  select coalesce(
    (select price from (
        (select price, ts, event_id from lite.launch_trades
          where token = p_token and ts <= p_at order by ts desc, event_id desc limit 1)
        union all
        (select price, ts, event_id from lite.pool_swaps
          where token = p_token and ts <= p_at and price is not null order by ts desc, event_id desc limit 1)
      ) as last_trade order by ts desc, event_id desc limit 1),
    (select phantom / supply from lite.launches where token = p_token and created_at <= p_at)
  )
$$;

-- OHLC in the quote asset and volume in quote base units over curve trades and priced pool swaps together, in buckets
-- of p_interval from the epoch: the newest p_limit (at most 1000), oldest first.
create or replace function lite.token_candles(p_token text, p_interval interval, p_limit int default 300)
returns table (bucket timestamptz, open numeric, high numeric, low numeric, close numeric, volume numeric)
language sql stable
set search_path = lite, pg_temp
as $$
  select * from (
    select date_bin(p_interval, t.ts, timestamptz 'epoch') as bucket,
           (array_agg(t.price order by t.ts, t.event_id))[1] as open,
           max(t.price) as high,
           min(t.price) as low,
           (array_agg(t.price order by t.ts desc, t.event_id desc))[1] as close,
           sum(t.quote_amount) as volume
      from (
        select ts, event_id, price, quote_amount from lite.launch_trades where token = p_token
        union all
        select ts, event_id, price, quote_amount from lite.pool_swaps where token = p_token and price is not null
      ) as t
     group by 1
     order by 1 desc
     limit least(greatest(p_limit, 1), 1000)
  ) as newest
  order by bucket
$$;

-- Accounts and contracts holding a launch token, besides p_excluded (the launchpad, holding the curve's tokens, and
-- the pair, holding the pool's). Null entries in p_excluded (no pair yet) exclude nothing.
create or replace function lite.launch_holders(p_token text, p_excluded text[])
returns int
language sql stable
set search_path = lite, pg_temp
as $$
  select count(*)::int from lite.token_balances
   where token = p_token and balance > 0 and not (address = any(coalesce(array_remove(p_excluded, null), '{}')))
$$;

-- ------------------------------------------------------------------------------------------------ access

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.launch_metadata, lite.pool_swaps, lite.creator_claims, lite.token_events, lite.token_balances,
  lite.watch_groups, lite.watch_contracts from public;
revoke all on function lite.token_price_at(text, timestamptz), lite.token_candles(text, interval, int),
  lite.launch_holders(text, text[]) from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on lite.launch_metadata, lite.pool_swaps, lite.creator_claims, lite.token_events, '
        'lite.token_balances, lite.watch_groups, lite.watch_contracts from %I', r);
      execute format('revoke all on function lite.token_price_at(text, timestamptz), lite.token_candles(text, interval, int), '
        'lite.launch_holders(text, text[]) from %I', r);
    end if;
  end loop;
end $$;
-- TRUNCATE: the indexer clears every indexed table after a testnet reset or a new deployment (jobs/reset.ts).
grant select, insert, update, delete, truncate on lite.launch_metadata, lite.pool_swaps, lite.creator_claims,
  lite.token_events, lite.token_balances, lite.watch_groups, lite.watch_contracts to lite_api;
grant usage, select on all sequences in schema lite to lite_api;
grant execute on function lite.token_price_at(text, timestamptz), lite.token_candles(text, interval, int),
  lite.launch_holders(text, text[]) to lite_api;

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
