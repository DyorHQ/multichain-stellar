-- The bridge's relay cap and measured time (docs/DESIGN-stellar-parity.md §6.10 and §6.15; WP-17). DyorHQ's keeper
-- relays every CCTP transfer from Monad to Stellar (mint_and_forward on Stellar: protocol upkeep), at most 10 a day for
-- each user. relay_day is the UTC day a transfer's burn on Monad was reported (POST /v1/bridge/:id/source), from when the
-- keeper relays it; the API counts the user's transfers of the day before it hands out the next one's Monad steps. A
-- quote's time is the median of the last 20 completed transfers each way. No new table or function: nothing to grant.

alter table lite.bridge_transfers add column if not exists relay_day date;
-- Only a transfer the keeper relays has a relay day.
alter table lite.bridge_transfers drop constraint if exists bridge_transfers_relay_day;
alter table lite.bridge_transfers add constraint bridge_transfers_relay_day
  check (relay_day is null or (direction = 'monad_to_stellar' and route = 'cctp'));
-- Transfers reported before this migration count on the day they started.
update lite.bridge_transfers set relay_day = (created_at at time zone 'utc')::date
 where relay_day is null and direction = 'monad_to_stellar' and route = 'cctp' and source_tx is not null;

-- The relay cap: a user's transfers of one day.
create index if not exists bridge_transfers_relay_day on lite.bridge_transfers (address, relay_day) where relay_day is not null;
-- A quote's time: the last completed transfers each way.
create index if not exists bridge_transfers_completed on lite.bridge_transfers (direction, route, updated_at desc)
  where status = 'completed';
