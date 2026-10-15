-- Contracts v2 in the indexer and the keeper (docs/DESIGN-stellar-contracts-v2.md §13, §20.5, §20.6; CT-15):
-- - generations side by side. launches and moments gain generation (1 retired, 2 live), contract (the launchpad or
--   Moments contract that holds the row) and nonce (v2's address nonce). Launches stay keyed by token address in both
--   generations. v1 Moments stay keyed by their number in their contract, (contract, id), one v1 Moments contract per
--   database; v2 Moments are keyed by their NFT address and have no on-chain number (L15), so id is null for them and
--   `number` is the indexer's display number, in publish order per Moments contract. A v2 deployment has a cursor of
--   its own (lite-indexer/v2_events.ts): deploying it, or another v2, clears nothing.
-- - v2's state on the rows: venue, sharing, recipient, the phase with its clocks, the last recorded graduation failure
--   (origin, code and its name from _shared/v2_errors.ts, finding V10), refund mode, and what is booked for the keeper's
--   sweeps; a Moment's coin, terms, state, reserve, pool and how it ended (backstop or not, finding V11).
-- - v2_events: every v2 event once, by its id. A balance-like table moves only with an event this inserts, so a page
--   read twice changes nothing.
-- - launch_rewards and reward_releases: holder rewards per launch and asset (the quote, or the launch token itself).
-- - locker_positions and harvests: the LP the locker holds and each harvest round (take and compounded).
-- - refunds, creator_owed: rescued launches' refunds; fees owed to former recipients (launchpad) and failed harvest
--   payouts (locker).
-- - moment_positions, moment_withdrawals, vesting_claims, moment_coin_balances: collectors' entitlements and claims,
--   USDC paid out per role, coin holders after graduation.
-- - pool_candidates: other DEX pools of sharing launches, found from the Soroswap factory's and the Aquarius router's
--   pool-creation events, with their exclusion status (F2).
-- - keeper_skip: the only skip list (F5). The keeper honours it on testnet-qa only and ignores it, with a warning,
--   anywhere else (V5). keeper_alerts: each alert fired once.
-- - watch_v2_groups and watch_v2_contracts: the per-launch and per-Moment contracts whose v2 events the indexer reads
--   (launch tokens' rewards events, Moment NFTs and coins), at most 25 to a group, each group with its own cursor.
-- No table here has a foreign key to launches or moments: the testnet reset truncates those (jobs/reset.ts) and these
-- with them.

-- ------------------------------------------------------------------------------------------------ launches

alter table lite.launches add column if not exists generation smallint not null default 1;
alter table lite.launches add column if not exists contract text;
alter table lite.launches add column if not exists nonce numeric;
-- v2 has no launch counter (L15).
alter table lite.launches alter column launch_index drop not null;
-- The venue table's ids (launchpad-v2 venues()) the launch pinned, and whether its quote locks it to its venue.
alter table lite.launches add column if not exists venue int;
alter table lite.launches add column if not exists fallback_venue int;
alter table lite.launches add column if not exists venue_locked boolean;
alter table lite.launches add column if not exists holder_sharing boolean;
-- The creator fee recipient now, and a pending change (recip_prop until recip_set or recip_cncl).
alter table lite.launches add column if not exists recipient text;
alter table lite.launches add column if not exists pending_recipient text;
alter table lite.launches add column if not exists pending_recipient_at timestamptz;
alter table lite.launches add column if not exists pending_recipient_expires timestamptz;
-- The launch fee paid, in XLM stroops (O6).
alter table lite.launches add column if not exists launch_fee numeric;
alter table lite.launches add column if not exists phase text;
alter table lite.launches add column if not exists completed_at timestamptz;
-- Stuck from the first recorded failure or mark_stuck; null again once graduated.
alter table lite.launches add column if not exists stuck_since timestamptz;
alter table lite.launches add column if not exists fallback_at timestamptz;
alter table lite.launches add column if not exists fallback_allowed boolean not null default false;
-- The last recorded graduation failure (grad_fail): the venue tried, the namespaced pair and its name (V10).
alter table lite.launches add column if not exists fail_venue int;
alter table lite.launches add column if not exists fail_origin int;
alter table lite.launches add column if not exists fail_code int;
alter table lite.launches add column if not exists fail_name text;
alter table lite.launches add column if not exists failed_at timestamptz;
alter table lite.launches add column if not exists graduated_venue int;
alter table lite.launches add column if not exists graduated_fallback boolean;
alter table lite.launches add column if not exists unlocked_at timestamptz;
-- Refund mode (O2): the snapshot refunds share pro rata, and what holders took back.
alter table lite.launches add column if not exists rescued_at timestamptz;
alter table lite.launches add column if not exists rescued_by_admin boolean;
alter table lite.launches add column if not exists refund_quote numeric;
alter table lite.launches add column if not exists refund_supply numeric;
alter table lite.launches add column if not exists refunded numeric not null default 0;
-- Booked and not yet swept: protocol fees in the quote and the launch fee in XLM (claim_protocol_fees), creator fees
-- for the current recipient; the quote sent to the token for its holders.
alter table lite.launches add column if not exists protocol_fees_due numeric not null default 0;
alter table lite.launches add column if not exists launch_fee_due numeric not null default 0;
alter table lite.launches add column if not exists creator_fees_due numeric not null default 0;
alter table lite.launches add column if not exists holder_fees_total numeric not null default 0;
-- The treasury the keeper last saw excluded from this launch's rewards (exclude_treasury after a treasury change, V2).
alter table lite.launches add column if not exists treasury_checked text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'launches_generation_check' and conrelid = 'lite.launches'::regclass) then
    alter table lite.launches add constraint launches_generation_check check (generation in (1, 2));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'launches_phase_check' and conrelid = 'lite.launches'::regclass) then
    alter table lite.launches add constraint launches_phase_check
      check (phase is null or phase in ('curve', 'completed', 'graduated', 'rescued'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'launches_v2_check' and conrelid = 'lite.launches'::regclass) then
    -- v1 launches carry their launch index, v2 launches their nonce and phase.
    alter table lite.launches add constraint launches_v2_check
      check ((generation = 1 and launch_index is not null) or (generation = 2 and nonce is not null and phase is not null));
  end if;
end $$;

-- The v1 rows indexed so far belong to the launchpad of the indexer's cursor ("<passphrase>|<launchpad>|<moments>").
update lite.launches l set contract = k.launchpad
  from (select split_part(network_id, '|', 2) as launchpad from lite.indexer_cursors where name = 'events') k
 where l.generation = 1 and l.contract is null and k.launchpad ~ '^C[A-Z2-7]{55}$';

create index if not exists launches_generation on lite.launches (generation, created_at desc) where listed;
-- The keeper's work: completed launches waiting for graduation, graduated sharing launches, booked fees.
create index if not exists launches_v2_completed on lite.launches (contract) where generation = 2 and phase = 'completed';
create index if not exists launches_v2_fees on lite.launches (contract, quote)
  where generation = 2 and (protocol_fees_due > 0 or launch_fee_due > 0);

-- ------------------------------------------------------------------------------------------------ moments

alter table lite.moments add column if not exists generation smallint not null default 1;
alter table lite.moments add column if not exists contract text;
alter table lite.moments add column if not exists nonce numeric;
alter table lite.moments add column if not exists nft text;
-- v2's display number, in publish order per Moments contract (v1's is its on-chain id).
alter table lite.moments add column if not exists number int;
-- The coin graduation deploys at the address fixed at publish, and the NFT's name and symbol (the coin's too).
alter table lite.moments add column if not exists coin text;
alter table lite.moments add column if not exists name text;
alter table lite.moments add column if not exists symbol text;
alter table lite.moments add column if not exists threshold numeric;
alter table lite.moments add column if not exists creator_alloc_bps int;
alter table lite.moments add column if not exists rate_num numeric;
alter table lite.moments add column if not exists rate_den numeric;
-- The Moment's MomentsDurations from its publish event (vest_period, stuck_expiry, pending_backstop, …), in seconds.
alter table lite.moments add column if not exists durations jsonb;
alter table lite.moments add column if not exists state text;
alter table lite.moments add column if not exists reserve numeric not null default 0;
alter table lite.moments add column if not exists total_gross numeric not null default 0;
alter table lite.moments add column if not exists entitlements numeric not null default 0;
alter table lite.moments add column if not exists completed_at timestamptz;
-- Started only by a recorded failed graduation (F15); null again once graduated.
alter table lite.moments add column if not exists stuck_since timestamptz;
alter table lite.moments add column if not exists fail_origin int;
alter table lite.moments add column if not exists fail_code int;
alter table lite.moments add column if not exists fail_name text;
alter table lite.moments add column if not exists failed_at timestamptz;
alter table lite.moments add column if not exists pool text;
alter table lite.moments add column if not exists lp_token text;
alter table lite.moments add column if not exists liquidity numeric;
alter table lite.moments add column if not exists pool_coins numeric;
alter table lite.moments add column if not exists usdc_used numeric;
alter table lite.moments add column if not exists graduated_at timestamptz;
-- Expired: when, its reserve's split, and whether through pending_backstop, with no recorded failure (V11).
alter table lite.moments add column if not exists expired_at timestamptz;
alter table lite.moments add column if not exists expired_backstop boolean;
alter table lite.moments add column if not exists expiry_creator_share numeric;
alter table lite.moments add column if not exists expiry_treasury_share numeric;
-- The NFT's frozen edition size (its `closed` event).
alter table lite.moments add column if not exists edition_size int;

-- v1's number stays unique (its ON CONFLICT and the foreign keys use it); v2's rows have none, so it can't be the
-- primary key any more. The foreign keys to it are dropped and made again against the unique constraint.
do $$
declare c record;
begin
  for c in select conrelid::regclass as tbl, conname from pg_constraint
            where contype = 'f' and confrelid = 'lite.moments'::regclass loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
  if exists (select 1 from pg_constraint where conname = 'moments_pkey' and conrelid = 'lite.moments'::regclass) then
    alter table lite.moments drop constraint moments_pkey;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'moments_id_key' and conrelid = 'lite.moments'::regclass) then
    alter table lite.moments add constraint moments_id_key unique (id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'moments_nft_key' and conrelid = 'lite.moments'::regclass) then
    alter table lite.moments add constraint moments_nft_key unique (nft);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'moments_generation_check' and conrelid = 'lite.moments'::regclass) then
    alter table lite.moments add constraint moments_generation_check check (generation in (1, 2));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'moments_key_check' and conrelid = 'lite.moments'::regclass) then
    alter table lite.moments add constraint moments_key_check
      check ((generation = 1 and id is not null and nft is null) or (generation = 2 and nft is not null and id is null and contract is not null));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'moments_state_check' and conrelid = 'lite.moments'::regclass) then
    alter table lite.moments add constraint moments_state_check
      check (state is null or state in ('collecting', 'graduation_pending', 'graduated', 'expired'));
  end if;
end $$;
alter table lite.moments alter column id drop not null;

-- v2 collects are keyed by the Moment's NFT address.
alter table lite.moment_collects add column if not exists nft text;
alter table lite.moment_collects alter column moment_id drop not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'moment_collects_moment_id_fkey' and conrelid = 'lite.moment_collects'::regclass) then
    alter table lite.moment_collects add constraint moment_collects_moment_id_fkey
      foreign key (moment_id) references lite.moments(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'moment_editions_moment_id_fkey' and conrelid = 'lite.moment_editions'::regclass) then
    alter table lite.moment_editions add constraint moment_editions_moment_id_fkey
      foreign key (moment_id) references lite.moments(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'moment_collects_key_check' and conrelid = 'lite.moment_collects'::regclass) then
    alter table lite.moment_collects add constraint moment_collects_key_check check ((moment_id is null) <> (nft is null));
  end if;
end $$;

update lite.moments m set contract = k.moments
  from (select split_part(network_id, '|', 3) as moments from lite.indexer_cursors where name = 'events') k
 where m.generation = 1 and m.contract is null and k.moments ~ '^C[A-Z2-7]{55}$';

create index if not exists moments_generation on lite.moments (generation, created_at desc) where listed;
create index if not exists moments_v2_pending on lite.moments (contract) where generation = 2 and state in ('collecting', 'graduation_pending');
create index if not exists moment_collects_nft on lite.moment_collects (nft, ts desc) where nft is not null;

-- ------------------------------------------------------------------------------------------------ the event log

create table if not exists lite.v2_events (
  event_id text primary key,
  contract text not null,
  kind text not null,
  -- The launch token or Moment NFT it concerns, when it concerns one.
  subject text,
  topics jsonb not null,
  data jsonb,
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists v2_events_subject on lite.v2_events (subject, ts desc) where subject is not null;
create index if not exists v2_events_kind on lite.v2_events (contract, kind, ts desc);

-- ------------------------------------------------------------------------------------------------ holder rewards

-- One launch's rewards in one asset: the quote, or the launch token itself (F1). funded is what notifiers queued,
-- released what holders share, to_protocol what fell to the protocol (fewer than MIN_ELIGIBLE eligible), stranded what
-- excluded accounts had earned (it goes to the protocol too), claimed and swept what left.
create table if not exists lite.launch_rewards (
  token text not null,
  asset text not null,
  funded numeric not null default 0,
  released numeric not null default 0,
  to_protocol numeric not null default 0,
  stranded numeric not null default 0,
  claimed numeric not null default 0,
  swept numeric not null default 0,
  -- The reward per eligible unit (scaled by P) and the eligible supply after the last release.
  acc numeric,
  eligible numeric,
  updated_ledger int not null,
  updated_at timestamptz not null default now(),
  primary key (token, asset)
);

create table if not exists lite.reward_releases (
  event_id text primary key,
  token text not null,
  asset text not null,
  kind text not null check (kind in ('queued', 'released', 'to_protocol')),
  amount numeric not null check (amount >= 0),
  -- queued: the launchpad or the locker, and the first ledger that releases it.
  notifier text,
  releasable_from int,
  -- released and to_protocol: the eligible supply, and released: the new reward per share.
  eligible numeric,
  acc numeric,
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists reward_releases_token on lite.reward_releases (token, ts desc);

-- ------------------------------------------------------------------------------------------------ the locker

create table if not exists lite.locker_positions (
  pool text primary key,
  locker text not null,
  owner text not null,
  kind text not null,
  lp_token text not null,
  lp numeric not null,
  base text not null,
  quote text not null,
  ref_kind text not null check (ref_kind in ('launch', 'moment')),
  -- The launch token or the Moment's NFT address.
  ref text not null,
  harvest_bps int not null check (harvest_bps between 1 and 10000),
  principal numeric not null,
  registered_ledger int not null,
  registered_at timestamptz not null,
  last_harvest_at timestamptz,
  harvests int not null default 0,
  base_out numeric not null default 0,
  quote_out numeric not null default 0,
  updated_at timestamptz not null default now()
);
create index if not exists locker_positions_ref on lite.locker_positions (ref);

create table if not exists lite.harvests (
  event_id text primary key,
  pool text not null,
  lp_burned numeric not null,
  base_out numeric not null,
  quote_out numeric not null,
  growth numeric not null,
  take numeric not null,
  compounded numeric not null,
  principal numeric not null,
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists harvests_pool on lite.harvests (pool, ts desc);

-- ------------------------------------------------------------------------------------------------ refunds and owed fees

create table if not exists lite.refunds (
  event_id text primary key,
  token text not null,
  holder text not null,
  tokens_in numeric not null check (tokens_in > 0),
  quote_out numeric not null check (quote_out >= 0),
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists refunds_token on lite.refunds (token, ts desc);
create index if not exists refunds_holder on lite.refunds (holder, ts desc);

-- What `contract` owes `account` in `asset`: launchpad-v2's fees booked before a recipient change (cr_owed, owed_claim)
-- and the locker's failed harvest payouts (owed_credit, owed_paid).
create table if not exists lite.creator_owed (
  contract text not null,
  account text not null,
  asset text not null,
  owed numeric not null default 0 check (owed >= 0),
  credited numeric not null default 0,
  paid numeric not null default 0,
  updated_ledger int not null,
  updated_at timestamptz not null default now(),
  primary key (contract, account, asset)
);
create index if not exists creator_owed_account on lite.creator_owed (account) where owed > 0;

-- ------------------------------------------------------------------------------------------------ Moments v2

-- A collector's (or the creator's) coins in one Moment: editions and USDC collected, coins promised, coins claimed.
create table if not exists lite.moment_positions (
  nft text not null,
  account text not null,
  editions int not null default 0,
  gross numeric not null default 0,
  entitlement numeric not null default 0,
  collector_claimed numeric not null default 0,
  creator_claimed numeric not null default 0,
  updated_ledger int not null,
  updated_at timestamptz not null default now(),
  primary key (nft, account)
);
create index if not exists moment_positions_account on lite.moment_positions (account);

create table if not exists lite.moment_withdrawals (
  event_id text primary key,
  nft text not null,
  role text not null check (role in ('creator', 'platform', 'treasury')),
  to_address text not null,
  amount numeric not null check (amount >= 0),
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists moment_withdrawals_nft on lite.moment_withdrawals (nft, ts desc);

create table if not exists lite.vesting_claims (
  event_id text primary key,
  nft text not null,
  account text not null,
  collector_amount numeric not null check (collector_amount >= 0),
  creator_amount numeric not null check (creator_amount >= 0),
  tx_hash text,
  ledger int not null,
  ts timestamptz not null
);
create index if not exists vesting_claims_account on lite.vesting_claims (account, ts desc);
create index if not exists vesting_claims_nft on lite.vesting_claims (nft, ts desc);

-- A graduated Moment's coin holders, from the coin's own events.
create table if not exists lite.moment_coin_balances (
  coin text not null,
  address text not null,
  balance numeric not null,
  updated_ledger int not null,
  updated_at timestamptz not null default now(),
  primary key (coin, address)
);
create index if not exists moment_coin_balances_held on lite.moment_coin_balances (address) where balance > 0;

-- ------------------------------------------------------------------------------------------------ the keeper

-- Another DEX pool of a sharing launch's token (F2): exclude_pool is sent only when its simulation passes the floor, and
-- a pool under the floor is checked again an hour later. The graduation pool is excluded by the graduation itself. A
-- pool of two sharing launches is a candidate of each: each token excludes it from its own rewards.
create table if not exists lite.pool_candidates (
  pool text not null,
  -- The launch token whose rewards the pool would earn.
  token text not null,
  -- The pool's other token, as exclude_pool takes it.
  other text not null,
  kind text not null check (kind in ('soroswap', 'aquarius')),
  status text not null default 'pending'
    check (status in ('pending', 'below_floor', 'excluded', 'rejected', 'graduation_pool')),
  discovered_event text not null,
  discovered_ledger int not null,
  checked_at timestamptz,
  next_check_at timestamptz,
  error text,
  created_at timestamptz not null default now(),
  primary key (pool, token)
);
create index if not exists pool_candidates_due on lite.pool_candidates (next_check_at nulls first) where status in ('pending', 'below_floor');
create index if not exists pool_candidates_token on lite.pool_candidates (token);

-- The only skip list (F5): the e2e inserts a row before the step the keeper could race (§18.4, V5). Honoured only on
-- testnet-qa; every keeper job checks it, rescue and expire included. The deployment file carries none.
create table if not exists lite.keeper_skip (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('launch', 'moment')),
  -- The launch token or the Moment's NFT address.
  target text not null check (target ~ '^C[A-Z2-7]{55}$'),
  jobs text[] not null check (cardinality(jobs) > 0 and jobs <@ array['graduate', 'fallback', 'mark_stuck', 'rescue', 'expire', 'harvest']::text[]),
  -- Null: until the row is deleted.
  until timestamptz,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists keeper_skip_target on lite.keeper_skip (kind, target);

-- An alert fires once per (kind, target, key): key tells repeats apart (the failure's event, the stuck clock).
create table if not exists lite.keeper_alerts (
  kind text not null,
  target text not null,
  key text not null,
  detail jsonb,
  fired_at timestamptz not null default now(),
  primary key (kind, target, key)
);

-- The keeper's v2 jobs join lite.keeper_log's.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'lite.keeper_log'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%job%' loop
    execute format('alter table lite.keeper_log drop constraint %I', c.conname);
  end loop;
  alter table lite.keeper_log add constraint keeper_log_job_check check (job in (
    'graduate', 'ttl', 'relay', 'graduate_fallback', 'mark_stuck', 'rescue', 'expire', 'harvest', 'claim_protocol_fees',
    'sweep_protocol', 'exclude_treasury', 'exclude_pool'));
end $$;
-- What a v2 job acted on (detail.target), for the keeper's in-flight check.
create index if not exists keeper_log_target on lite.keeper_log ((detail ->> 'target'), job, created_at desc);

-- ------------------------------------------------------------------------------------------------ watched v2 contracts

create table if not exists lite.watch_v2_groups (
  id bigint generated always as identity primary key,
  start_ledger int not null,
  cursor text,
  ledger int not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists lite.watch_v2_contracts (
  contract text primary key,
  role text not null check (role in ('launch_token', 'nft', 'coin')),
  -- The launch token, or the Moment's NFT address.
  ref text not null,
  from_ledger int not null,
  group_id bigint references lite.watch_v2_groups(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists watch_v2_contracts_group on lite.watch_v2_contracts (group_id);

-- ------------------------------------------------------------------------------------------------ access

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.v2_events, lite.launch_rewards, lite.reward_releases, lite.locker_positions, lite.harvests,
  lite.refunds, lite.creator_owed, lite.moment_positions, lite.moment_withdrawals, lite.vesting_claims,
  lite.moment_coin_balances, lite.pool_candidates, lite.keeper_skip, lite.keeper_alerts, lite.watch_v2_groups,
  lite.watch_v2_contracts from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on lite.v2_events, lite.launch_rewards, lite.reward_releases, lite.locker_positions, lite.harvests,
        lite.refunds, lite.creator_owed, lite.moment_positions, lite.moment_withdrawals, lite.vesting_claims,
        lite.moment_coin_balances, lite.pool_candidates, lite.keeper_skip, lite.keeper_alerts, lite.watch_v2_groups,
        lite.watch_v2_contracts from %I', r);
    end if;
  end loop;
end $$;
-- No function in lite is PUBLIC's to call: each migration revoked its own; this one makes sure of all of them.
revoke execute on all functions in schema lite from public;
-- TRUNCATE: the testnet reset clears the indexed tables (lite-indexer/v2_events.ts).
grant select, insert, update, delete, truncate on lite.v2_events, lite.launch_rewards, lite.reward_releases,
  lite.locker_positions, lite.harvests, lite.refunds, lite.creator_owed, lite.moment_positions, lite.moment_withdrawals,
  lite.vesting_claims, lite.moment_coin_balances, lite.pool_candidates, lite.watch_v2_groups, lite.watch_v2_contracts
  to lite_api;
grant select, insert, update, delete on lite.keeper_skip, lite.keeper_alerts to lite_api;
grant usage, select on sequence lite.watch_v2_groups_id_seq, lite.keeper_skip_id_seq to lite_api;

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
