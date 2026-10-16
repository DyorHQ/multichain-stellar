-- Portfolio and Recent Activity reads (docs/DESIGN-stellar-parity.md §6.7, §6.10 and §6.15; WP-18): an account's logged
-- transactions by section and time (GET /v1/activity?section=, Portfolio's spot figures and network fees per section),
-- its curve trades and collects by time (Portfolio's launch and Moments figures), and its bridge and anchor transfers by
-- time (both lists). launch_trades and moment_collects have had theirs since migration 1, under the same names: created
-- here only where they are missing.
--
-- Every logged transaction has its section. Migration 05 added the column but left the rows before it without one, and
-- an API older than migration 05's still logs rows without one until the new functions are deployed. Both get it here,
-- by the rule the API logs with (plans.ts sectionOf), so the section filter, Portfolio and Recent Activity read one
-- stored section: the rows logged so far once, and any row logged without one from now on as it is inserted.

create index if not exists tx_log_section on lite.tx_log (address, section, created_at desc);
create index if not exists launch_trades_trader on lite.launch_trades (trader, ts desc);
create index if not exists moment_collects_collector on lite.moment_collects (collector, ts desc);
create index if not exists bridge_transfers_address on lite.bridge_transfers (address, created_at desc);
create index if not exists anchor_transfers_address on lite.anchor_transfers (address, created_at desc);

-- ------------------------------------------------------------------------------------------------ sections

-- The section a logged transaction counts in, from its kind and intent (plans.ts sectionOf): a swap is the launch
-- section's when it spends or receives a launch token, Spot's otherwise; null for a kind no section counts.
create or replace function lite.tx_section(p_kind text, p_intent jsonb)
returns text
language sql stable
set search_path = lite, pg_temp
as $$
  select case
    when p_kind = 'swap' then
      case when exists (
        select 1 from lite.launches l
         where l.token in (select jsonb_object_keys(case when jsonb_typeof(s) = 'object' then s end)
                             from (values (p_intent -> 'spend'), (p_intent -> 'receive')) as sides(s)))
      then 'launch' else 'spot' end
    when p_kind = 'payment' then 'spot'
    when p_kind in ('trust', 'activate', 'faucet', 'restore') then 'account'
    when left(p_kind, 5) = 'earn_' then 'earn'
    when left(p_kind, 7) = 'launch_' then 'launch'
    when left(p_kind, 7) = 'moment_' then 'moments'
    when p_kind in ('approve', 'bridge_out') then 'bridge'
  end
$$;

-- Gives a row logged without a section the one its kind and intent count in.
create or replace function lite.fill_tx_log_section()
returns trigger
language plpgsql
set search_path = lite, pg_temp
as $$
begin
  new.section := lite.tx_section(new.kind, new.intent);
  return new;
end
$$;

drop trigger if exists tx_log_fill_section on lite.tx_log;
create trigger tx_log_fill_section
  before insert on lite.tx_log
  for each row
  when (new.section is null)
  execute function lite.fill_tx_log_section();

-- The rows logged before migration 05, and since by an older API.
update lite.tx_log set section = lite.tx_section(kind, intent) where section is null;

-- ------------------------------------------------------------------------------------------------ access

-- Closed to everyone but lite_api, as every lite function is (migrations 1 and 4).
revoke all on function lite.tx_section(text, jsonb) from public;
revoke all on function lite.fill_tx_log_section() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function lite.tx_section(text, jsonb) from anon';
    execute 'revoke all on function lite.fill_tx_log_section() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function lite.tx_section(text, jsonb) from authenticated';
    execute 'revoke all on function lite.fill_tx_log_section() from authenticated';
  end if;
end $$;
grant execute on function lite.tx_section(text, jsonb) to lite_api;
grant execute on function lite.fill_tx_log_section() to lite_api;
