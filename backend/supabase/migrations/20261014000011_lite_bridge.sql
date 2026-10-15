-- The bridge's relay cap and measured time (docs/DESIGN-stellar-parity.md §6.10 and §6.15; WP-17). DyorHQ's keeper
-- relays every CCTP transfer from Monad to Stellar (mint_and_forward on Stellar: protocol upkeep), at most 10 a day for
-- each user. relay_day is the UTC day a transfer from Monad holds one of its user's 10: the day it started (POST
-- /v1/bridge/start hands out its Monad steps), or the later day its burn was reported (POST /v1/bridge/:id/source).
-- The API counts the user's transfers of the day, under a lock per user, before it records the next one. The keeper
-- relays a burn's message for one transfer only. A quote's time is the median of the last 20 completed transfers each
-- way. No new table or function: nothing to grant.

alter table lite.bridge_transfers add column if not exists relay_day date;
-- Transfers from before this migration hold a relay on the day they started.
update lite.bridge_transfers set relay_day = (created_at at time zone 'utc')::date
 where relay_day is null and direction = 'monad_to_stellar' and route = 'cctp';
-- Exactly the transfers the keeper relays hold a relay day.
alter table lite.bridge_transfers drop constraint if exists bridge_transfers_relay_day;
alter table lite.bridge_transfers add constraint bridge_transfers_relay_day
  check ((relay_day is not null) = (direction = 'monad_to_stellar' and route = 'cctp'));

-- The relay cap: a user's transfers of one day.
create index if not exists bridge_transfers_relay_day on lite.bridge_transfers (address, relay_day) where relay_day is not null;
-- One burn, one relay: each message the keeper relayed completed one transfer.
create unique index if not exists bridge_transfers_relayed on lite.bridge_transfers (message)
  where direction = 'monad_to_stellar' and status = 'completed';
-- A quote's time: the last completed transfers each way.
create index if not exists bridge_transfers_completed on lite.bridge_transfers (direction, route, updated_at desc)
  where status = 'completed';
