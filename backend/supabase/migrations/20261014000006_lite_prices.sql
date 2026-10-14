-- Reference prices and the asset directory (docs/DESIGN-stellar-parity.md §6.5, §6.6, §6.12 and §6.15; WP-13).
-- Testnet assets have no market, so XLM and USDC are valued at mainnet market prices: the indexer's refprices job
-- writes the provider's latest quote per reference asset every run (ref_quotes) and its candles on their cadence
-- (ref_candles: 15 minutes every 5 minutes, hourly, daily); purge keeps 15-minute candles 35 days and hourly ones
-- 400 days. The API reads both; nothing here holds a constant price. asset_directory caches what an asset issuer's
-- stellar.toml says about a classic asset (name, image) for 7 days.

-- The latest quote per reference asset ("XLM", "USDC"): one row each, replaced every run. An API read calls it stale
-- after 10 minutes and unknown after 24 hours.
create table if not exists lite.ref_quotes (
  ref text primary key check (ref ~ '^[A-Z0-9]{1,12}$'),
  usd numeric not null check (usd > 0),
  -- Where the price came from: the provider (kraken) or, for XLM only, the mainnet SDEX's XLM/USDC (horizon).
  source text not null check (source in ('kraken', 'horizon')),
  -- Shown with the price: "Kraken XLM/USD".
  market text not null,
  -- usd / the close 24 hours before quoted_at, minus 1; null when no candle reaches back that far.
  change_24h numeric,
  volume_24h_usd numeric check (volume_24h_usd >= 0),
  quoted_at timestamptz not null,
  updated_at timestamptz not null default now()
);

-- USD candles per reference asset, at 900, 3600 and 86400 s. A bucket starts at a multiple of its interval since the
-- epoch, as the providers' do, so the candle covering a time is found by range.
create table if not exists lite.ref_candles (
  ref text not null check (ref ~ '^[A-Z0-9]{1,12}$'),
  interval_s int not null check (interval_s in (900, 3600, 86400)),
  bucket timestamptz not null,
  open numeric not null check (open > 0),
  high numeric not null check (high > 0),
  low numeric not null check (low > 0),
  close numeric not null check (close > 0),
  -- In the reference asset, as the provider reports it.
  volume numeric check (volume >= 0),
  source text not null check (source in ('kraken', 'horizon')),
  updated_at timestamptz not null default now(),
  primary key (ref, interval_s, bucket),
  check (extract(epoch from bucket)::bigint % interval_s = 0)
);
-- purge's range deletes and the cadence's "last written" per interval.
create index if not exists ref_candles_interval on lite.ref_candles (interval_s, bucket);

-- What a classic asset's issuer publishes about it (SEP-1 [[CURRENCIES]]): read from the stellar.toml Horizon links to,
-- over https only, at most 100 KB in 3 s. A definite answer is kept 7 days, a failed fetch is retried after an hour.
create table if not exists lite.asset_directory (
  asset text primary key check (asset ~ '^[A-Za-z0-9]{1,12}:G[A-Z2-7]{55}$'),
  home_domain text,
  name text check (name is null or char_length(name) <= 64),
  image text check (image is null or image ~ '^https://'),
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null
);

-- The USD price of a reference asset at a time: the close of the candle whose bucket covers it, the smallest interval
-- first (15 minutes, then an hour, then a day); null when no candle covers it. Launch prices in USD are their quote
-- price × this (§6.6).
create or replace function lite.ref_usd_at(p_ref text, p_at timestamptz)
returns numeric
language sql stable
set search_path = lite, pg_temp
as $$
  select close
    from lite.ref_candles
   where ref = p_ref
     and bucket <= p_at
     and bucket > p_at - make_interval(secs => interval_s)
   order by interval_s asc
   limit 1
$$;

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.ref_quotes, lite.ref_candles, lite.asset_directory from public;
revoke all on function lite.ref_usd_at(text, timestamptz) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on lite.ref_quotes, lite.ref_candles, lite.asset_directory from anon';
    execute 'revoke all on function lite.ref_usd_at(text, timestamptz) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on lite.ref_quotes, lite.ref_candles, lite.asset_directory from authenticated';
    execute 'revoke all on function lite.ref_usd_at(text, timestamptz) from authenticated';
  end if;
end $$;
grant select, insert, update, delete on lite.ref_quotes, lite.ref_candles, lite.asset_directory to lite_api;
grant execute on function lite.ref_usd_at(text, timestamptz) to lite_api;

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
