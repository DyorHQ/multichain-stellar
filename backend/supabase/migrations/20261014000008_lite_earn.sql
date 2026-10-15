-- Earn's rate history (docs/DESIGN-stellar-parity.md §6.10 and §6.15; WP-15). Every 10 minutes the indexer's earn job
-- reads each Blend market (a pool's reserve of a registry asset) and keeps what it saw: the supply and borrow APY and
-- the utilization as fractions, the reserve's size in base units and the pool's status. GET /v1/earn/history reads a
-- market's supply APY and utilization for a week or a month. The job deletes snapshots older than 400 days.

create table if not exists lite.earn_snapshots (
  pool text not null check (pool ~ '^C[A-Z2-7]{55}$'),
  -- The reserve's token contract.
  asset text not null check (asset ~ '^C[A-Z2-7]{55}$'),
  taken_at timestamptz not null,
  -- Blend's estimates: the supply APY compounds weekly, the borrow APY daily. Neither is a constant or a default: a
  -- reserve whose rate can't be read isn't snapshotted (NaN and infinity fail these checks).
  supply_apy numeric not null check (supply_apy >= 0 and supply_apy < 'Infinity'),
  borrow_apy numeric check (borrow_apy >= 0 and borrow_apy < 'Infinity'),
  utilization numeric not null check (utilization >= 0 and utilization <= 1),
  -- Supplied and borrowed, in the asset's base units.
  supplied numeric not null check (supplied >= 0 and supplied < 'Infinity'),
  borrowed numeric not null check (borrowed >= 0 and borrowed < 'Infinity'),
  -- Blend's pool status (0-1 active, 2-3 on ice, 4-5 frozen, 6 setup).
  pool_status smallint not null check (pool_status >= 0),
  -- History's range scan, and one snapshot per market per run.
  primary key (pool, asset, taken_at)
);
-- The job's deletion of old snapshots, across markets.
create index if not exists earn_snapshots_taken on lite.earn_snapshots (taken_at);

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.earn_snapshots from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on lite.earn_snapshots from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on lite.earn_snapshots from authenticated'; end if;
end $$;
grant select, insert, update, delete on lite.earn_snapshots to lite_api;

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
