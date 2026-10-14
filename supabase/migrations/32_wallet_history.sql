-- 32_wallet_history — a server cache of the wallet history the app's five scans read (WalletHistoryScans), filled by
-- the history-indexer Edge Function, so a history screen reads one RPC instead of minutes of public eth_getLogs.
--
-- The app's Swift decoders stay the single source of truth: this stores RAW logs (the eth_getLogs fields the app's
-- Log(json:) parses, plus blockTimestamp) and the exact block ranges they cover, never totals.
--
-- Scans (definitions in supabase/functions/_shared/history-scans.json, mirrored by the history_scans seed below and by
-- WalletHistoryScans in Swift; HistoryScanParityTests and supabase/tests/history_cache_test.ts fail on any drift):
--   global — wallet-independent, indexed once for everyone; the wallet is an indexed topic of each log:
--     launchpad     any contract, topic0 ∈ {CurveBuy, CurveSell, Paid, PaidToken, Claimed, ClaimedToken}, wallet = topic1
--     fee-sharing   every stack's holderFeeSharing, topic0 Claimed(address,address,uint256), wallet = topic2
--     moments       every cohort's factory/collect/vesting/hook, topic0 ∈ the five Moments events, wallet = topic2
--   wallet — per enrolled wallet (a profile row, i.e. a signed-in DyorHQ user; watch-only addresses are not enrolled):
--     transfers-in  any contract, Transfer, wallet = topic2, from genesis
--     transfers-out any contract, Transfer, wallet = topic1, from genesis
--
-- THE INVARIANT (HistoryStore's): a block range joins `covered` only in the same transaction that stores every log the
-- endpoint returned for it, only after every piece of it was answered, and only under the scan definition
-- (`def_version`) the filter was built from. history_commit() is the only write path. A log the app could never be
-- served (no address-shaped topic at the wallet position) is not stored; a log whose data exceeds 16 KiB is stored
-- without its data and reported as `omitted` (the app reads that block itself). A range the indexer could not read
-- (too dense, or never answered) is recorded as a HOLE: never covered, served as `holes`, retried every 6 hours (a
-- row's retry clock is not moved by a new hole beside older ones: history_mark_hole).
-- Logs are only dropped by the 20,000-per-wallet-and-scan cap (the app's HistoryStore.logCap: the newest 20,000 are
-- kept, `cap_floor` is where they start), by a redefinition and by history_reset().
--
-- Access: every table has RLS on, no policies, and no privileges for anon, authenticated or service_role. The indexer
-- (service role) uses only history_lease / history_state / history_commit / history_mark_hole / history_set_first_tx /
-- history_release, and history_cron_digest, the SHA-256 of the Vault secret history_cron_secret it checks the cron
-- tick's header against (migration 33 generates the secret inside Postgres; no function returns it). The app (anon or
-- authenticated) uses only history_read(): one exact wallet, index-bound, paged
-- under ~1.5 MB. The owner (postgres, SQL editor) has history_health / history_reset / history_redefine_scan /
-- history_housekeeping, and two switches on history_indexer_state: `paused` (the indexer stops at its next call) and
-- `serving` (history_read answers serving:false and the app discards it). Enrolment is by trigger on profiles
-- (ensureProfile upserts it on every launch and sign-in); deleting a profile deletes that wallet's per-wallet cache.
-- `tracked` in history_read says whether a profile exists, which profiles (world-readable) already say.
--
-- Errors the indexer acts on: PT409 (HTTP 409) the lease is not held or the indexer is paused → stop the run;
-- PT412 (HTTP 412) the scan definition changed since history_state → stop the run; 22023 a refused argument or answer.
-- PostgREST runs service_role under authenticator's statement_timeout 8 s and lock_timeout 8 s (service_role has no
-- settings of its own), and authenticator preloads pg-safeupdate: every UPDATE/DELETE here has a WHERE clause.
--
-- Runs unchanged in the PGlite harness: no pg_cron, pg_net or Vault here (the schedule is
-- migrations-deferred/33_history_indexer_schedule.sql). Idempotent.
--
-- Reverse: drop trigger if exists profiles_history_enrol on public.profiles;
--          drop trigger if exists profiles_history_forget on public.profiles;
--          drop function public.history_read(text, text, bigint, bigint, boolean),
--               public.history_commit(uuid, text, integer, bigint, bigint, bigint, bigint, text[], jsonb),
--               public.history_mark_hole(uuid, text, integer, text, bigint, bigint),
--               public.history_lease(uuid, integer, text), public.history_release(uuid, bigint, bigint, jsonb, jsonb, text),
--               public.history_state(uuid, integer, timestamptz), public.history_set_first_tx(uuid, text, text, bigint, bigint, text),
--               public.history_apply_cap(text, text), public.history_require_lease(uuid, text), public.history_ranges(int8multirange),
--               public.history_redefine_scan(text, bytea[], bytea[], bigint, bigint), public.history_reset(text, boolean),
--               public.history_health(bigint), public.history_housekeeping(),
--               public.history_enrol_profile(), public.history_forget_profile(), public.history_octets(bytea[], integer),
--               public.history_cron_digest();
--          drop table public.history_logs, public.history_wallet_scans, public.history_wallets, public.history_scans,
--               public.history_subject_caps, public.history_indexer_state, public.history_indexer_runs;
--          (unschedule the cron jobs of 33 first; the app falls back to reading the chain itself)
-- Verify after apply:
--   select has_function_privilege('anon', 'public.history_read(text,text,bigint,bigint,boolean)', 'execute'),                 -- true
--          has_function_privilege('anon', 'public.history_commit(uuid,text,integer,bigint,bigint,bigint,bigint,text[],jsonb)', 'execute'), -- false
--          has_function_privilege('service_role', 'public.history_commit(uuid,text,integer,bigint,bigint,bigint,bigint,text[],jsonb)', 'execute'), -- true
--          has_function_privilege('service_role', 'public.history_reset(text,boolean)', 'execute'),                            -- false
--          has_function_privilege('anon', 'public.history_cron_digest()', 'execute'),                                        -- false
--          has_function_privilege('authenticated', 'public.history_cron_digest()', 'execute'),                               -- false
--          has_function_privilege('service_role', 'public.history_cron_digest()', 'execute'),                                -- true
--          has_table_privilege('service_role', 'public.history_logs', 'select'),                                              -- false
--          (select count(*) from public.history_wallets) = (select count(*) from public.profiles);                            -- true
--   select proconfig from pg_proc where oid = 'public.history_enrol_profile()'::regprocedure;        -- {search_path="",lock_timeout=200ms}
--   The definitions, one canonical line per scan, to diff against
--   `deno run supabase/functions/history-indexer/print_scans.ts` (the same lines from history-scans.json):
--   select id || '|' || kind || '|' || wallet_topic || '|' || floor_block || '|'
--          || coalesce((select string_agg('0x' || encode(a, 'hex'), ',' order by a) from unnest(addresses) a), '') || '|'
--          || (select string_agg('0x' || encode(t, 'hex'), ',' order by t) from unnest(topic0s) t)
--     from public.history_scans order by id;

-- ── Tables ────────────────────────────────────────────────────────────────────────────────────────────────────────────

-- Whether every element of `p` is `p_len` bytes (and none is null): the CHECKs on history_scans.
create or replace function public.history_octets(p bytea[], p_len integer)
returns boolean
language sql
immutable
set search_path = ''
as $function$
  select coalesce(bool_and(x is not null and octet_length(x) = p_len), true) from unnest(p) x;
$function$;

-- One row per scan: its definition (def_version moves on every redefinition) and, for a global scan, what is covered
-- and what could not be read (holes). Small and updated by every global commit: half-empty pages keep updates HOT.
create table if not exists public.history_scans (
  id               text primary key check (id in ('launchpad', 'fee-sharing', 'moments', 'transfers-in', 'transfers-out')),
  kind             text not null check (kind in ('global', 'wallet')),
  wallet_topic     smallint not null check (wallet_topic in (1, 2)),
  floor_block      bigint not null check (floor_block >= 0),
  addresses        bytea[] not null default '{}',
  topic0s          bytea[] not null,
  def_version      integer not null default 1 check (def_version >= 1),
  covered          int8multirange not null default '{}',
  holes            int8multirange not null default '{}',
  holes_checked_at timestamptz,
  head_block       bigint check (head_block >= 0),
  head_timestamp   bigint check (head_timestamp >= 0),
  updated_at       timestamptz not null default now(),
  constraint history_scans_addresses check (public.history_octets(addresses, 20)),
  constraint history_scans_topic0s check (cardinality(topic0s) between 1 and 8 and public.history_octets(topic0s, 32)),
  constraint history_scans_wallet_kind_uncovered check (kind = 'global' or (covered = '{}'::int8multirange and holes = '{}'::int8multirange)),
  constraint history_scans_holes_uncovered check (not (holes && covered))
) with (fillfactor = 50);

-- One row per enrolled wallet (a profile, phase 1).
create table if not exists public.history_wallets (
  wallet              text primary key check (wallet ~ '^0x[0-9a-f]{40}$'),
  requested_at        timestamptz not null default now(),
  enrolled_at         timestamptz not null default now(),
  first_tx_state      text not null default 'unknown' check (first_tx_state in ('unknown', 'found', 'none')),
  first_tx_block      bigint check (first_tx_block >= 0),
  first_tx_head       bigint check (first_tx_head >= 0),
  first_tx_checked_at timestamptz,
  first_tx_source     text check (first_tx_source is null or first_tx_source ~ '^[a-z0-9-]{1,20}(\+[a-z0-9-]{1,20})?$'),
  constraint history_wallets_first_tx check (
    (first_tx_state = 'unknown' and first_tx_block is null)
    or (first_tx_state = 'found' and first_tx_block is not null)
    or (first_tx_state = 'none' and first_tx_block is null and first_tx_head is not null))
);
create index if not exists history_wallets_requested_idx on public.history_wallets (requested_at desc);

-- Per enrolled wallet, per wallet scan: what is covered, what could not be read, and where the log cap starts.
create table if not exists public.history_wallet_scans (
  wallet           text not null references public.history_wallets (wallet) on delete cascade,
  scan             text not null references public.history_scans (id) check (scan in ('transfers-in', 'transfers-out')),
  covered          int8multirange not null default '{}',
  holes            int8multirange not null default '{}',
  holes_checked_at timestamptz,
  cap_floor        bigint check (cap_floor >= 0),
  head_block       bigint check (head_block >= 0),
  head_timestamp   bigint check (head_timestamp >= 0),
  log_count        integer not null default 0 check (log_count >= 0),
  updated_at       timestamptz not null default now(),
  primary key (wallet, scan),
  constraint history_wallet_scans_holes_uncovered check (not (holes && covered))
) with (fillfactor = 50);

-- Every stored log, once per (scan, subject): subject is the 20-byte address at the scan's wallet topic.
create table if not exists public.history_logs (
  scan            text not null references public.history_scans (id),
  subject         bytea not null check (octet_length(subject) = 20),
  block_number    bigint not null check (block_number >= 0),
  log_index       integer not null check (log_index >= 0),
  tx_hash         bytea not null check (octet_length(tx_hash) = 32),
  address         bytea not null check (octet_length(address) = 20),
  topics          bytea[] not null check (cardinality(topics) between 1 and 4),
  data            bytea check (data is null or octet_length(data) <= 16384),
  data_length     integer not null check (data_length >= 0),
  block_timestamp bigint not null check (block_timestamp >= 0),
  primary key (scan, subject, block_number, log_index),
  constraint history_logs_data_omitted check ((data is null) = (data_length > 16384))
);
-- The `omitted` list of history_read, index-bound however many oversized logs a subject has.
create index if not exists history_logs_omitted_idx on public.history_logs (scan, subject, block_number desc, log_index desc)
  where data is null;

-- Per global scan and subject past the 20,000-log cap: where the kept logs start (history_commit's write-time cap).
-- One primary-key lookup for history_read; an OFFSET 19,999 probe is not index-ordered under a generic plan.
create table if not exists public.history_subject_caps (
  scan      text not null references public.history_scans (id) check (scan in ('launchpad', 'fee-sharing', 'moments')),
  subject   bytea not null check (octet_length(subject) = 20),
  cap_floor bigint not null check (cap_floor >= 0),
  primary key (scan, subject)
);

-- The indexer's lease (one run at a time), the owner's two switches, the last head, and what the indexer remembers
-- about each endpoint between runs (rest, learned span and batch, pace, 429 ratio, requests per UTC day; no URL).
create table if not exists public.history_indexer_state (
  id             boolean primary key default true check (id),
  lease_owner    uuid,
  lease_until    timestamptz,
  paused         boolean not null default false,
  serving        boolean not null default true,
  head_block     bigint check (head_block >= 0),
  head_timestamp bigint check (head_timestamp >= 0),
  last_run_at    timestamptz,
  endpoints      jsonb check (endpoints is null or (jsonb_typeof(endpoints) = 'object' and octet_length(endpoints::text) <= 16384)),
  updated_at     timestamptz not null default now()
) with (fillfactor = 50);
insert into public.history_indexer_state (id) values (true) on conflict (id) do nothing;

-- One row per run: started by history_lease, finished by history_release (a run killed by the platform has no
-- released_at). Kept 7 days by history_housekeeping(). The summary holds counts only, never a wallet address.
create table if not exists public.history_indexer_runs (
  owner       uuid primary key,
  started_at  timestamptz not null default now(),
  released_at timestamptz,
  version     text check (version is null or version ~ '^[0-9A-Za-z._-]{1,40}$'),
  stop        text check (stop is null or stop ~ '^[A-Za-z][A-Za-z0-9:_-]{0,39}$'),
  summary     jsonb check (summary is null or octet_length(summary::text) <= 16384)
);
create index if not exists history_indexer_runs_started_idx on public.history_indexer_runs (started_at desc);

alter table public.history_scans enable row level security;
alter table public.history_wallets enable row level security;
alter table public.history_wallet_scans enable row level security;
alter table public.history_logs enable row level security;
alter table public.history_subject_caps enable row level security;
alter table public.history_indexer_state enable row level security;
alter table public.history_indexer_runs enable row level security;
revoke all on public.history_scans, public.history_wallets, public.history_wallet_scans, public.history_logs,
              public.history_subject_caps, public.history_indexer_state, public.history_indexer_runs
  from public, anon, authenticated, service_role;

comment on table public.history_logs is
  'Raw logs of the five history scans (eth_getLogs fields + blockTimestamp), keyed by scan and the wallet topic. Written only by history_commit() in the same transaction that extends coverage. RLS on, no policies, no API-role privileges.';

-- ── Scan definitions (mirror supabase/functions/_shared/history-scans.json) ───────────────────────────────────────────
-- Inserted once; a later change goes through history_redefine_scan() in its own migration (it also trims coverage).
insert into public.history_scans (id, kind, wallet_topic, floor_block, addresses, topic0s) values
  ('launchpad', 'global', 1, 103542521, '{}', array[
     '\xec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455',  -- CurveBuy(address,address,uint256,uint256,uint256,uint256)
     '\x8113d738abdcb6b38357e9d53a54a7157861a09031b453651f0fe7fe151f59df',  -- CurveSell(address,address,uint256,uint256,uint256,uint256)
     '\x737c69225d647e5994eab1a6c301bf6d9232beb2759ae1e27a8966b4732bc489',  -- Paid(address,uint256)
     '\x8e75d141563dab9e2b7c297c2c15c67d7553b6201efe3c78fb9a1805e71c3d19',  -- PaidToken(address,address,uint256)
     '\xd8138f8a3f377c5259ca548e70e4c2de94f129f5a11036a15b69513cba2b426a',  -- Claimed(address,uint256)
     '\xdbc1ea3a8459e4c7e11fb385b52bbb5cc8c8ab85eec5d883ac9aa78c171f5141'   -- ClaimedToken(address,address,uint256)
   ]::bytea[]),
  ('fee-sharing', 'global', 2, 103542521, array[
     '\x5358a136a50ee4f961b532064dc641e8f4fa5656',  -- v2 (0x3B1f…)
     '\xc618bb26bbc3c84c30519f31e32ee52ea2bfac52',  -- 0x6B1C…
     '\x70f8f64c6a4a76a507e322bcef19e6e37abe4ef6',  -- 0x10F3…
     '\x1413cb051f78a4605cd150d4e97b1b06f81e2bdf',  -- 0x2F02…
     '\x0c7a1f7625696babf9a7309ed3c4a9086efee8dd'   -- 0xad3d…
   ]::bytea[], array[
     '\xf7a40077ff7a04c7e61f6f26fb13774259ddf1b6bce9ecf26a8276cdd3992683'   -- Claimed(address,address,uint256)
   ]::bytea[]),
  ('moments', 'global', 2, 105347754, array[
     '\x95eb7f5a88b10d9df32ac54f48c767927fa80840', '\xe6beb4a10827a2e50b155b7386b1369d504186cc',  -- v2 factory, collect
     '\x6eb483c1e1be2b6700ad590dde326b597a13649a', '\xda7042cf42b26be4d6816c9eeb1b0bee8e3fe0cc',  -- v2 vesting, hook
     '\x0fd4ac52bbf387dbb3156805769bfc0c260f7e26', '\xb53897a4c6280480c267351518d184c2e6591d30',  -- cohort 3
     '\x05584910ab57d65723eb878d295b3353a4cbb021', '\xd5bfff467fdae04664357e75bf059986c41260cc',
     '\xc12b6b6948185cef75f861c5327702c30cb8a581', '\x8f65ea0236b5fa6351a45bd48244c3525fb92493',  -- cohort 2
     '\xe087eff01c567f88a7cb6bdbdbf04b46fee56c99', '\x501d703588c4feabbee5a9a77408c7fcbd3a20cc',
     '\x64698c7702d85f87f43a6dff7d495cdd2327c020', '\xb4ee9e67d9e1772bc6949748e3755ea7c1dfe32c',  -- cohort 1
     '\x360e2068eaec5b5a9af60a7c4059bd4b30b7209c', '\x8aa322471bef2996d3b50cb12f63c6a0054460cc'
   ]::bytea[], array[
     '\xc475c499a9357ec964b24130f5e1e4b21748160d33ce0df8721acb1e370b7c96',  -- Collected(uint256,address,uint256 ×8)
     '\xd9cb1e2714d65a111c0f20f060176ad657496bd47a3de04ec7c3d4ca232112ac',  -- Claimed(uint256,address,uint256,uint256)
     '\xcf7d23a3cbe4e8b36ff82fd1b05b1b17373dc7804b4ebbd6e2356716ef202372',  -- Withdrawn(uint256,address,uint256)
     '\x538e1189c5c6413ddd9194fe5e947ef693ea737bd368a9e0aca4c286854c9bd8',  -- FeesWithdrawn(uint256,address,uint256)
     '\xdb7fe8c848b875fe70036b24da1910e5e09c9ade908d9ddedbf970ae0fd7c8b7'   -- Published(uint256,address,address,address,uint256,uint16,uint256,uint256,uint64)
   ]::bytea[]),
  ('transfers-in', 'wallet', 2, 0, '{}', array[
     '\xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'   -- Transfer(address,address,uint256)
   ]::bytea[]),
  ('transfers-out', 'wallet', 1, 0, '{}', array[
     '\xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
   ]::bytea[])
on conflict (id) do nothing;

-- ── Internal helpers (no API role may execute them) ───────────────────────────────────────────────────────────────────

-- A multirange as inclusive [from, to] pairs, ascending.
create or replace function public.history_ranges(p int8multirange)
returns jsonb
language sql
immutable
set search_path = ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_array(lower(r), upper(r) - 1) order by lower(r)), '[]'::jsonb) from unnest(p) r;
$function$;

-- Refuses (PT409, which PostgREST answers as HTTP 409) unless `p_owner` holds the indexer lease and the indexer is not
-- paused. Its own code: 55P03 is also Postgres's "lock timeout", which must never read as a lost lease.
create or replace function public.history_require_lease(p_owner uuid, p_fn text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_state public.history_indexer_state%rowtype;
begin
  select * into v_state from public.history_indexer_state s where s.id;
  if v_state.paused then
    raise exception '%: the indexer is paused', p_fn using errcode = 'PT409';
  end if;
  if p_owner is null or v_state.lease_owner is distinct from p_owner or v_state.lease_until <= pg_catalog.clock_timestamp() then
    raise exception '%: the lease is not held', p_fn using errcode = 'PT409';
  end if;
end;
$function$;

-- The log cap (HistoryStore.logCap, 20,000 per wallet and scan; HistoryStore.trim's rule): past it, every log older
-- than the block of the 20,000th newest goes, with the coverage and holes below that block, and cap_floor is where
-- the kept logs start (it never goes back down). Only the count of stored logs moves it: never a dense or unread range
-- (those are holes). Returns the wallet's cap_floor (null: none).
create or replace function public.history_apply_cap(p_wallet text, p_scan text)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  c_cap     constant integer := 20000;
  v_subject bytea := decode(substr(p_wallet, 3), 'hex');
  v_row     public.history_wallet_scans%rowtype;
  v_kept    bigint;
  v_deleted integer;
begin
  select * into v_row from public.history_wallet_scans where wallet = p_wallet and scan = p_scan for update;
  if not found then return null; end if;
  if v_row.log_count <= c_cap then return v_row.cap_floor; end if;
  select l.block_number into v_kept from public.history_logs l
   where l.scan = p_scan and l.subject = v_subject
   order by l.block_number desc, l.log_index desc offset c_cap - 1 limit 1;
  if v_kept is null or v_kept <= coalesce(v_row.cap_floor, 0) then return v_row.cap_floor; end if;
  delete from public.history_logs l where l.scan = p_scan and l.subject = v_subject and l.block_number < v_kept;
  get diagnostics v_deleted = row_count;
  update public.history_wallet_scans
     set cap_floor = v_kept,
         covered = covered * pg_catalog.int8multirange(pg_catalog.int8range(v_kept, null)),
         holes = holes * pg_catalog.int8multirange(pg_catalog.int8range(v_kept, null)),
         log_count = greatest(0, log_count - v_deleted),
         updated_at = now()
   where wallet = p_wallet and scan = p_scan;
  return v_kept;
end;
$function$;

-- ── Enrolment (profiles) ──────────────────────────────────────────────────────────────────────────────────────────────

-- A profile written (ensureProfile upserts it on every launch and sign-in) enrols its wallet and marks it requested now.
-- Best effort: enrolment never fails the profile write (the wallet is then untracked, and the app reads the chain).
-- Nor does it make the write wait: a row another transaction holds (history_reset, a scan redefinition, a commit)
-- would make it wait into the caller's statement_timeout, whose 57014 no handler may catch, and the profile upsert would
-- fail. lock_timeout 200 ms (this function only) turns that wait into 55P03, which the handler catches: enrolment then
-- degrades to the warning (requested_at not moved; a new wallet enrolled at its next write). The scan rows are inserted
-- only when missing: a plain read waits on no lock, so a returning user's write never queues behind a reset there.
-- An owner's wallet change (below) can fail on that lock timeout too; it is simply retried.
create or replace function public.history_enrol_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
set lock_timeout = '200ms'
as $function$
begin
  if tg_op = 'UPDATE' and old.wallet is distinct from new.wallet then
    delete from public.history_wallets where wallet = old.wallet;
    delete from public.history_logs where scan in ('transfers-in', 'transfers-out') and subject = decode(substr(old.wallet, 3), 'hex');
  end if;
  begin
    insert into public.history_wallets (wallet, requested_at) values (new.wallet, now())
    on conflict (wallet) do update set requested_at = excluded.requested_at;
    if (select count(*) from public.history_wallet_scans ws where ws.wallet = new.wallet) < 2 then
      insert into public.history_wallet_scans (wallet, scan) values (new.wallet, 'transfers-in'), (new.wallet, 'transfers-out')
      on conflict (wallet, scan) do nothing;
    end if;
  exception when others then
    raise warning 'history enrolment failed: %', sqlerrm;
  end;
  return null;
end;
$function$;

-- A profile deleted (account deletion) deletes the wallet's per-wallet cache. The wallet row goes first: its delete
-- waits for a commit holding it (history_commit takes FOR KEY SHARE; commits are sized to finish well under a second),
-- so the logs delete that follows sees that commit's rows. Global-scan logs naming the wallet are public chain data
-- indexed for every address and stay (supabase/README.md "Wallet history cache"). Run summaries never hold addresses.
create or replace function public.history_forget_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  delete from public.history_wallets where wallet = old.wallet;
  delete from public.history_logs where scan in ('transfers-in', 'transfers-out') and subject = decode(substr(old.wallet, 3), 'hex');
  return null;
end;
$function$;

drop trigger if exists profiles_history_enrol on public.profiles;
create trigger profiles_history_enrol after insert or update on public.profiles
  for each row execute function public.history_enrol_profile();
drop trigger if exists profiles_history_forget on public.profiles;
create trigger profiles_history_forget after delete on public.profiles
  for each row execute function public.history_forget_profile();

-- Every existing profile, requested when it was last written.
insert into public.history_wallets (wallet, requested_at)
select p.wallet, p.updated_at from public.profiles p
on conflict (wallet) do nothing;
insert into public.history_wallet_scans (wallet, scan)
select w.wallet, s.scan from public.history_wallets w cross join (values ('transfers-in'), ('transfers-out')) s(scan)
on conflict (wallet, scan) do nothing;

-- ── Indexer RPCs (service role only) ──────────────────────────────────────────────────────────────────────────────────

-- Takes (or renews) the lease for `p_seconds`. {"ok": false, "paused": bool} while another run holds it or the owner
-- paused the indexer. Taking it starts a history_indexer_runs row (`p_version`: the deploy's short git SHA) and hands
-- the run the endpoint memory the previous run left.
create or replace function public.history_lease(p_owner uuid, p_seconds integer, p_version text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_state public.history_indexer_state%rowtype;
  v_until timestamptz;
  v_new   boolean;
begin
  if p_owner is null or p_seconds is null or p_seconds not between 30 and 390
     or (p_version is not null and p_version !~ '^[0-9A-Za-z._-]{1,40}$') then
    raise exception 'history_lease: an owner, 30–390 seconds and an optional short version are required' using errcode = '22023';
  end if;
  select * into v_state from public.history_indexer_state s where s.id for update;
  if v_state.paused then
    return jsonb_build_object('ok', false, 'paused', true);
  end if;
  if v_state.lease_owner is distinct from p_owner and v_state.lease_until > pg_catalog.clock_timestamp() then
    return jsonb_build_object('ok', false, 'paused', false);
  end if;
  v_new := v_state.lease_owner is distinct from p_owner;
  update public.history_indexer_state s
     set lease_owner = p_owner,
         lease_until = pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => p_seconds),
         last_run_at = case when v_new then now() else s.last_run_at end,
         updated_at = now()
   where s.id
  returning s.lease_until into v_until;
  if v_new then
    insert into public.history_indexer_runs (owner, started_at, version) values (p_owner, now(), p_version)
    on conflict (owner) do nothing;
  end if;
  return jsonb_build_object('ok', true, 'paused', false, 'until', v_until, 'started', v_new,
                            'endpoints', coalesce(v_state.endpoints, '{}'::jsonb));
end;
$function$;

-- Ends a run: records its stop reason and summary (an oversized summary is replaced by a truncated stub, never by the
-- previous run's), and — while it still holds the lease — releases it, moves the head forward and stores the endpoint
-- memory. Safe to call twice (the shutdown handler may race the normal release).
create or replace function public.history_release(p_owner uuid, p_head bigint, p_head_timestamp bigint, p_summary jsonb,
                                                  p_endpoints jsonb default null, p_stop text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_summary jsonb := p_summary;
  v_stop    text := p_stop;
begin
  if p_owner is null then
    raise exception 'history_release: an owner is required' using errcode = '22023';
  end if;
  if v_stop is not null and v_stop !~ '^[A-Za-z][A-Za-z0-9:_-]{0,39}$' then v_stop := 'other'; end if;
  if v_summary is not null and octet_length(v_summary::text) > 16384 then
    v_summary := jsonb_build_object('v', v_summary -> 'v', 'truncated', true, 'stop', v_summary -> 'stop', 'counts', v_summary -> 'counts');
    if octet_length(v_summary::text) > 16384 then
      v_summary := jsonb_build_object('v', p_summary -> 'v', 'truncated', true);
    end if;
  end if;
  update public.history_indexer_runs r
     set released_at = coalesce(r.released_at, now()), stop = coalesce(r.stop, v_stop), summary = coalesce(r.summary, v_summary)
   where r.owner = p_owner;
  update public.history_indexer_state s
     set lease_until = pg_catalog.clock_timestamp(),
         head_block = case when p_head is not null and p_head >= coalesce(s.head_block, 0) then p_head else s.head_block end,
         head_timestamp = case when p_head is not null and p_head >= coalesce(s.head_block, 0) then p_head_timestamp else s.head_timestamp end,
         endpoints = case when p_endpoints is not null and jsonb_typeof(p_endpoints) = 'object'
                               and octet_length(p_endpoints::text) <= 16384 then p_endpoints else s.endpoints end,
         updated_at = now()
   where s.id and s.lease_owner = p_owner;
end;
$function$;

-- What the run plans from: the scans (definitions with def_version, coverage, holes), and the wallets requested in the
-- last 30 days, at most p_max_wallets, fairest first: wallets with on-chain activity (a found first transaction or a
-- stored transfer) or enrolled over 7 days ago, then the rest, each group most recently requested first. `deep` says
-- whether the wallet has on-chain activity (only those get the read below the 30-day window); `skipped` counts active
-- wallets left out for capacity. With p_requested_after: only wallets requested after it (a run's mid-run refresh).
create or replace function public.history_state(p_owner uuid, p_max_wallets integer, p_requested_after timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_scans   jsonb;
  v_wallets jsonb;
  v_active  integer;
  v_count   integer;
begin
  perform public.history_require_lease(p_owner, 'history_state');
  if p_max_wallets is null or p_max_wallets not between 1 and 5000 then
    raise exception 'history_state: p_max_wallets must be 1–5000' using errcode = '22023';
  end if;
  select jsonb_agg(jsonb_build_object(
           'id', s.id, 'kind', s.kind, 'walletTopic', s.wallet_topic, 'floor', s.floor_block, 'defVersion', s.def_version,
           'addresses', (select coalesce(jsonb_agg('0x' || encode(a, 'hex') order by a), '[]') from unnest(s.addresses) a),
           'topic0s', (select coalesce(jsonb_agg('0x' || encode(t, 'hex') order by t), '[]') from unnest(s.topic0s) t),
           'covered', public.history_ranges(s.covered), 'holes', public.history_ranges(s.holes),
           'holesCheckedAt', s.holes_checked_at, 'head', s.head_block) order by s.id)
    into v_scans from public.history_scans s;
  select count(*)::int into v_active from public.history_wallets w where w.requested_at > now() - interval '30 days';
  select coalesce(jsonb_agg(x.doc order by x.fair desc, x.requested_at desc), '[]'), count(*)::int into v_wallets, v_count
  from (
    select a.requested_at, a.deep or a.enrolled_at < now() - interval '7 days' as fair, jsonb_build_object(
             'wallet', a.wallet, 'requestedAt', a.requested_at, 'deep', a.deep,
             'firstTx', jsonb_build_object('state', a.first_tx_state, 'block', a.first_tx_block, 'head', a.first_tx_head,
                                           'checkedAt', a.first_tx_checked_at, 'source', a.first_tx_source),
             'scans', (select coalesce(jsonb_object_agg(ws.scan, jsonb_build_object(
                         'covered', public.history_ranges(ws.covered), 'holes', public.history_ranges(ws.holes),
                         'holesCheckedAt', ws.holes_checked_at, 'capFloor', ws.cap_floor, 'head', ws.head_block,
                         'logCount', ws.log_count)), '{}')
                       from public.history_wallet_scans ws where ws.wallet = a.wallet)) as doc
      from (
        select w.*, (w.first_tx_state = 'found'
                     or exists (select 1 from public.history_wallet_scans ws where ws.wallet = w.wallet and ws.log_count > 0)) as deep
          from public.history_wallets w
         where w.requested_at > now() - interval '30 days'
           and (p_requested_after is null or w.requested_at > p_requested_after)
      ) a
     order by (a.deep or a.enrolled_at < now() - interval '7 days') desc, a.requested_at desc
     limit p_max_wallets
  ) x;
  return jsonb_build_object('scans', v_scans, 'wallets', v_wallets, 'now', now(),
                            'active', v_active, 'skipped', case when p_requested_after is null then greatest(0, v_active - v_count) else 0 end,
                            'head', (select s.head_block from public.history_indexer_state s where s.id));
end;
$function$;

-- Stores one fully answered range: every log the endpoint returned for scan `p_scan` over [p_from, p_to] under
-- definition `p_def_version` (for a wallet scan: for the wallets `p_wallets` the filter carried, ≤ 100), and extends
-- coverage by exactly that range (and removes it from the holes), in one transaction. Refuses and stores nothing if the
-- definition moved on (PT412), or if any log does not match the scan's filter, lies outside the range, or is
-- malformed (22023). Lock order: the scan row (FOR UPDATE for a global scan — one writer per global scan; FOR SHARE for
-- a wallet scan, so a redefinition waits for it or it sees the new version), then the wallets (FOR KEY SHARE, against a
-- concurrent profile delete), then their scan rows (FOR UPDATE, in wallet order, before any insert: commits sharing a
-- wallet serialise), then the logs in primary-key order. Global scans keep the newest 20,000 logs per subject (the read
-- serves no more; history_subject_caps records where they start, and nothing older is stored again). p_logs: [{"a": address, "t": [topics], "d": data hex | null, "n": data length, "b": block,
-- "h": tx hash, "i": log index, "s": block timestamp}, …]. Returns {"inserted", "trimmed", "capFloors": {wallet: block}}.
create or replace function public.history_commit(p_owner uuid, p_scan text, p_def_version integer, p_from bigint, p_to bigint,
                                                 p_head bigint, p_head_timestamp bigint, p_wallets text[], p_logs jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  c_cap       constant integer := 20000;
  v_kind      text;
  v_def       public.history_scans%rowtype;
  v_wallets   text[] := '{}';
  v_subjects  bytea[] := '{}';
  v_requested bytea[] := '{}';
  v_touched   bytea[] := '{}';
  v_locked    integer;
  v_bad       integer;
  v_inserted  integer := 0;
  v_trimmed   integer := 0;
  v_n         integer;
  v_counts    jsonb := '{}';
  v_caps      jsonb := '{}';
  v_cap       bigint;
  v_kept      bigint;
  v_s         bytea;
  w           record;
begin
  perform public.history_require_lease(p_owner, 'history_commit');
  if p_def_version is null or p_from is null or p_to is null or p_head is null or p_head_timestamp is null
     or p_from < 0 or p_from > p_to or p_to > p_head or p_head_timestamp < 0 then
    raise exception 'history_commit: bad definition version or range [%, %] for head %', p_from, p_to, p_head using errcode = '22023';
  end if;
  if p_logs is null or jsonb_typeof(p_logs) <> 'array' or jsonb_array_length(p_logs) > 5000 then
    raise exception 'history_commit: p_logs must be an array of at most 5,000 logs' using errcode = '22023';
  end if;
  select s.kind into v_kind from public.history_scans s where s.id = p_scan;  -- a scan's kind never changes
  if v_kind is null then raise exception 'history_commit: unknown scan %', p_scan using errcode = '22023'; end if;
  -- The definition, locked BEFORE anything is validated against it.
  if v_kind = 'global' then
    select * into v_def from public.history_scans s where s.id = p_scan for update;
  else
    select * into v_def from public.history_scans s where s.id = p_scan for share;
  end if;
  if v_def.def_version <> p_def_version then
    raise exception 'history_commit: scan % is at definition %, the filter was built from %', p_scan, v_def.def_version, p_def_version
      using errcode = 'PT412';
  end if;

  if v_kind = 'global' then
    if coalesce(cardinality(p_wallets), 0) <> 0 or p_from < v_def.floor_block then
      raise exception 'history_commit: a global scan takes no wallets and no block below its floor' using errcode = '22023';
    end if;
  else
    if coalesce(cardinality(p_wallets), 0) not between 1 and 100
       or exists (select 1 from unnest(p_wallets) x where x is null or x !~ '^0x[0-9a-f]{40}$')
       or (select count(distinct x) from unnest(p_wallets) x) <> cardinality(p_wallets) then
      raise exception 'history_commit: a wallet scan takes 1–100 distinct lowercase wallets' using errcode = '22023';
    end if;
    v_requested := array(select decode(substr(x, 3), 'hex') from unnest(p_wallets) x);
    select coalesce(array_agg(hw.wallet order by hw.wallet), '{}') into v_wallets
      from (select h.wallet from public.history_wallets h where h.wallet = any(p_wallets) order by h.wallet for key share) hw;
    select count(*)::int into v_locked
      from (select ws.wallet from public.history_wallet_scans ws
             where ws.scan = p_scan and ws.wallet = any(v_wallets) order by ws.wallet for update) l;
    v_subjects := array(select decode(substr(x, 3), 'hex') from unnest(v_wallets) x);
  end if;

  -- One statement parses, checks and stores the logs: if any log does not match the scan's filter or the range, or is
  -- malformed, nothing is inserted (`verdict`) and the commit is refused below. Stored: for a global scan every log
  -- with an address at the wallet topic, for a wallet scan those of the wallets still enrolled, never below a wallet's
  -- cap floor; inserted in primary-key order. Topics are at most four, read by position (->> past the end is null).
  with raw as (
    select e.a, e.t, e.d, e.n, e.b, e.h, e.i, e.s
      from jsonb_to_recordset(p_logs) as e(a text, t jsonb, d text, n integer, b bigint, h text, i integer, s bigint)
  ), parsed as (
    select r.*,
           jsonb_typeof(r.t) = 'array' and jsonb_array_length(r.t) between 1 and 4
             and (r.t ->> 0) ~ '^0x[0-9a-fA-F]{64}$'
             and coalesce((r.t ->> 1) ~ '^0x[0-9a-fA-F]{64}$', jsonb_array_length(r.t) < 2)
             and coalesce((r.t ->> 2) ~ '^0x[0-9a-fA-F]{64}$', jsonb_array_length(r.t) < 3)
             and coalesce((r.t ->> 3) ~ '^0x[0-9a-fA-F]{64}$', jsonb_array_length(r.t) < 4) as topics_ok
      from raw r
  ), decoded as (
    select p.*,
           case when p.topics_ok then array_remove(array[decode(substr(p.t ->> 0, 3), 'hex'), decode(substr(p.t ->> 1, 3), 'hex'),
                                                         decode(substr(p.t ->> 2, 3), 'hex'), decode(substr(p.t ->> 3, 3), 'hex')], null) end as topics
      from parsed p
  ), checked as (
    select d.*,
           case when cardinality(d.topics) > v_def.wallet_topic
                     and substr(d.topics[v_def.wallet_topic + 1], 1, 12) = '\x000000000000000000000000'::bytea
                then substr(d.topics[v_def.wallet_topic + 1], 13, 20) end as subject,
           coalesce(
             d.topics_ok
             and d.a ~ '^0x[0-9a-fA-F]{40}$'
             and d.h ~ '^0x[0-9a-fA-F]{64}$'
             and d.b between p_from and p_to
             and d.i >= 0 and d.s >= 0 and d.n >= 0
             and ((d.d is null and d.n > 16384) or (d.d ~ '^0x[0-9a-fA-F]*$' and d.n <= 16384 and length(d.d) = 2 + 2 * d.n))
             and d.topics[1] = any(v_def.topic0s)
             and (cardinality(v_def.addresses) = 0 or decode(substr(d.a, 3), 'hex') = any(v_def.addresses)),
             false) as ok
      from decoded d
  ), verdict as (
    select count(*) filter (where not c.ok or (v_def.kind = 'wallet' and (c.subject is null or not c.subject = any(v_requested))))::int as bad
      from checked c
  ), ins as (
    insert into public.history_logs (scan, subject, block_number, log_index, tx_hash, address, topics, data, data_length, block_timestamp)
    select p_scan, c.subject, c.b, c.i, decode(substr(c.h, 3), 'hex'), decode(substr(c.a, 3), 'hex'), c.topics,
           case when c.d is null then null else decode(substr(c.d, 3), 'hex') end, c.n, c.s
      from checked c
      cross join verdict v
      left join public.history_wallet_scans ws
        on v_def.kind = 'wallet' and ws.scan = p_scan and ws.wallet = '0x' || encode(c.subject, 'hex')
      left join public.history_subject_caps sc
        on v_def.kind = 'global' and sc.scan = p_scan and sc.subject = c.subject
     where v.bad = 0 and c.subject is not null
       and ((v_def.kind = 'global' and c.b >= coalesce(sc.cap_floor, 0))
            or (v_def.kind = 'wallet' and c.subject = any(v_subjects) and c.b >= coalesce(ws.cap_floor, 0)))
     order by c.subject, c.b, c.i
    on conflict (scan, subject, block_number, log_index) do nothing
    returning subject
  )
  select (select v.bad from verdict v), coalesce(sum(g.c), 0)::int,
         coalesce(jsonb_object_agg('0x' || encode(g.subject, 'hex'), g.c) filter (where g.subject is not null), '{}'),
         coalesce(array_agg(g.subject) filter (where g.subject is not null), '{}')
    into v_bad, v_inserted, v_counts, v_touched
    from (select subject, count(*)::int as c from ins group by subject) g;
  if v_bad > 0 then
    raise exception 'history_commit: % of % logs do not match scan % over [%, %]', v_bad, jsonb_array_length(p_logs), p_scan, p_from, p_to
      using errcode = '22023';
  end if;

  if v_kind = 'global' then
    update public.history_scans
       set covered = covered + pg_catalog.int8multirange(pg_catalog.int8range(p_from, p_to, '[]')),
           holes = holes - pg_catalog.int8multirange(pg_catalog.int8range(p_from, p_to, '[]')),
           head_timestamp = case when p_head >= coalesce(head_block, 0) then p_head_timestamp else head_timestamp end,
           head_block = greatest(coalesce(head_block, 0), p_head),
           updated_at = now()
     where id = p_scan;
    -- Write-time cap per subject: the newest 20,000 (every log of the block of the 20,000th newest kept), as served.
    foreach v_s in array v_touched loop
      v_kept := null;
      select l.block_number into v_kept from public.history_logs l
       where l.scan = p_scan and l.subject = v_s order by l.block_number desc, l.log_index desc offset c_cap - 1 limit 1;
      if v_kept is not null then
        delete from public.history_logs l where l.scan = p_scan and l.subject = v_s and l.block_number < v_kept;
        get diagnostics v_n = row_count;
        if v_n > 0 then
          v_trimmed := v_trimmed + v_n;
          insert into public.history_subject_caps (scan, subject, cap_floor) values (p_scan, v_s, v_kept)
          on conflict (scan, subject) do update set cap_floor = greatest(public.history_subject_caps.cap_floor, excluded.cap_floor);
        end if;
      end if;
    end loop;
    return jsonb_build_object('inserted', v_inserted, 'trimmed', v_trimmed, 'capFloors', '{}'::jsonb);
  end if;

  for w in select ws.wallet, coalesce((v_counts ->> ws.wallet)::int, 0) as added
             from public.history_wallet_scans ws
            where ws.scan = p_scan and ws.wallet = any(v_wallets)
            order by ws.wallet loop
    update public.history_wallet_scans
       set covered = case when p_to >= coalesce(cap_floor, 0)
                          then covered + pg_catalog.int8multirange(pg_catalog.int8range(greatest(p_from, coalesce(cap_floor, 0)), p_to, '[]'))
                          else covered end,
           holes = holes - pg_catalog.int8multirange(pg_catalog.int8range(p_from, p_to, '[]')),
           head_timestamp = case when p_head >= coalesce(head_block, 0) then p_head_timestamp else head_timestamp end,
           head_block = greatest(coalesce(head_block, 0), p_head),
           log_count = log_count + w.added,
           updated_at = now()
     where wallet = w.wallet and scan = p_scan;
  end loop;
  for w in select ws.wallet from public.history_wallet_scans ws
            where ws.scan = p_scan and ws.wallet = any(v_wallets) and ws.log_count > c_cap order by ws.wallet loop
    v_cap := public.history_apply_cap(w.wallet, p_scan);
    v_caps := v_caps || jsonb_build_object(w.wallet, v_cap);
  end loop;
  return jsonb_build_object('inserted', v_inserted, 'trimmed', 0, 'capFloors', v_caps);
end;
$function$;

-- Records [p_from, p_to] (≤ 10,000 blocks) as a hole: a range the indexer could not read (a block too dense to
-- answer, or one that never answered). A hole is never covered; it is served as `holes` (the app reads it itself),
-- re-planned once holes_checked_at is 6 hours old, and removed by the commit that finally covers it. For a wallet scan
-- the hole is per wallet and never reaches below its cap floor. holes_checked_at is the row's retry clock: the first
-- hole of a row, or a retry that failed again (the range is already a hole), starts it now; a new hole beside older
-- ones leaves it as it is (else a stream of new holes would postpone the older ones' retry for ever; the new one is
-- then retried with them, perhaps before 6 hours); a range with nothing left to record (covered, or below the cap
-- floor) changes nothing. Returns the row's holes.
create or replace function public.history_mark_hole(p_owner uuid, p_scan text, p_def_version integer, p_wallet text,
                                                    p_from bigint, p_to bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_kind    text;
  v_def     public.history_scans%rowtype;
  v_ws      public.history_wallet_scans%rowtype;
  v_holes   int8multirange;
  v_range   int8multirange;
  v_add     int8multirange;
  v_old     int8multirange;
  v_checked timestamptz;
begin
  perform public.history_require_lease(p_owner, 'history_mark_hole');
  if p_def_version is null or p_from is null or p_to is null or p_from < 0 or p_from > p_to or p_to - p_from >= 10000 then
    raise exception 'history_mark_hole: bad definition version or range' using errcode = '22023';
  end if;
  select s.kind into v_kind from public.history_scans s where s.id = p_scan;
  if v_kind is null then raise exception 'history_mark_hole: unknown scan %', p_scan using errcode = '22023'; end if;
  if v_kind = 'global' then
    select * into v_def from public.history_scans s where s.id = p_scan for update;
  else
    select * into v_def from public.history_scans s where s.id = p_scan for share;
  end if;
  if v_def.def_version <> p_def_version then
    raise exception 'history_mark_hole: scan % is at definition %', p_scan, v_def.def_version using errcode = 'PT412';
  end if;
  v_range := pg_catalog.int8multirange(pg_catalog.int8range(p_from, p_to, '[]'));
  -- The row, locked (the global scan's above), and what this call adds to its holes.
  if v_kind = 'global' then
    if p_wallet is not null or p_from < v_def.floor_block then
      raise exception 'history_mark_hole: a global hole takes no wallet and no block below the floor' using errcode = '22023';
    end if;
    v_add := v_range - v_def.covered;
    v_old := v_def.holes;
    v_checked := v_def.holes_checked_at;
  else
    if p_wallet is null or p_wallet !~ '^0x[0-9a-f]{40}$' then
      raise exception 'history_mark_hole: a wallet hole takes one lowercase wallet' using errcode = '22023';
    end if;
    select * into v_ws from public.history_wallet_scans ws where ws.wallet = p_wallet and ws.scan = p_scan for update;
    if not found then return '[]'::jsonb; end if;
    v_add := (v_range * pg_catalog.int8multirange(pg_catalog.int8range(coalesce(v_ws.cap_floor, 0), null))) - v_ws.covered;
    v_old := v_ws.holes;
    v_checked := v_ws.holes_checked_at;
  end if;
  v_checked := case when v_add = '{}'::int8multirange then v_checked                                 -- nothing to record
                    when v_old = '{}'::int8multirange or v_add <@ v_old then now()                    -- the first, or a failed retry
                    else coalesce(v_checked, now()) end;                                             -- a new hole beside older ones
  if v_kind = 'global' then
    update public.history_scans
       set holes = holes + v_add, holes_checked_at = v_checked, updated_at = now()
     where id = p_scan
    returning holes into v_holes;
  else
    update public.history_wallet_scans
       set holes = holes + v_add, holes_checked_at = v_checked, updated_at = now()
     where wallet = p_wallet and scan = p_scan
    returning holes into v_holes;
  end if;
  return public.history_ranges(coalesce(v_holes, '{}'));
end;
$function$;

-- Records the block of a wallet's first transaction (the first block its nonce is ≥ 1, confirmed by the indexer on a
-- second endpoint: `p_source` = "<label>+<label>"), or that it had sent none by `p_head`. A found block only ever moves
-- earlier (a later check that finds an earlier block wins; the same block refreshes checked_at); `none` never replaces
-- a found block. Returns whether the row changed.
create or replace function public.history_set_first_tx(p_owner uuid, p_wallet text, p_state text, p_block bigint, p_head bigint,
                                                       p_source text default null)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  perform public.history_require_lease(p_owner, 'history_set_first_tx');
  if p_wallet is null or p_wallet !~ '^0x[0-9a-f]{40}$' or p_head is null or p_head < 0
     or (p_source is not null and p_source !~ '^[a-z0-9-]{1,20}(\+[a-z0-9-]{1,20})?$')
     or not ((p_state = 'found' and p_block between 0 and p_head) or (p_state = 'none' and p_block is null)) then
    raise exception 'history_set_first_tx: bad arguments' using errcode = '22023';
  end if;
  update public.history_wallets
     set first_tx_state = p_state, first_tx_block = p_block, first_tx_head = p_head, first_tx_checked_at = now(),
         first_tx_source = p_source
   where wallet = p_wallet
     and (first_tx_state <> 'found' or (p_state = 'found' and p_block <= first_tx_block));
  return found;
end;
$function$;

-- ── Owner functions (postgres only: the SQL editor or a migration) ────────────────────────────────────────────────────

-- Scan redefinition (called by the migration that changes a scan, in the same PR as the JSON and the Swift change).
-- Moves def_version on (every commit or hole built from the old definition is then refused), and cuts every covered
-- range and hole at or above `p_valid_below`, dropping the logs there, so the indexer reads them again. p_valid_below =
-- the earliest block at which a log matching the new definition but not the old one can exist: a new contract → its
-- deploy block; a new topic0 (or a wider address list for an existing event) → the earliest deploy block of the
-- contracts that can emit it, which, when in doubt, is the scan's floor.
create or replace function public.history_redefine_scan(p_scan text, p_addresses bytea[], p_topic0s bytea[], p_floor bigint, p_valid_below bigint)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  if p_valid_below is null or p_valid_below < 0 then
    raise exception 'history_redefine_scan: p_valid_below is required';
  end if;
  perform 1 from public.history_scans s where s.id = p_scan for update;
  if not found then raise exception 'history_redefine_scan: unknown scan %', p_scan; end if;
  update public.history_scans
     set addresses = coalesce(p_addresses, addresses), topic0s = coalesce(p_topic0s, topic0s),
         floor_block = coalesce(p_floor, floor_block),
         def_version = def_version + 1,
         covered = case when kind = 'global'
                        then covered * pg_catalog.int8multirange(pg_catalog.int8range(coalesce(p_floor, floor_block), p_valid_below))
                        else covered end,
         holes = case when kind = 'global'
                      then holes * pg_catalog.int8multirange(pg_catalog.int8range(coalesce(p_floor, floor_block), p_valid_below))
                      else holes end,
         updated_at = now()
   where id = p_scan;
  update public.history_wallet_scans
     set covered = covered * pg_catalog.int8multirange(pg_catalog.int8range(0, p_valid_below)),
         holes = holes * pg_catalog.int8multirange(pg_catalog.int8range(0, p_valid_below)),
         updated_at = now()
   where scan = p_scan;
  delete from public.history_logs where scan = p_scan and block_number >= p_valid_below;
  update public.history_wallet_scans ws
     set log_count = (select count(*) from public.history_logs l where l.scan = ws.scan and l.subject = decode(substr(ws.wallet, 3), 'hex'))
   where ws.scan = p_scan;
end;
$function$;

-- Repair after bad data (the owner procedure: pause → fix → redeploy → history_reset → bump the app's historyEpoch →
-- resume): empties one scan (or every scan) — logs, coverage, holes, heads, cap floors, counts — in one transaction
-- and moves def_version on, so a commit still in flight from before is refused. p_first_tx also forgets every
-- first-transaction result.
create or replace function public.history_reset(p_scan text default null, p_first_tx boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_scans integer;
  v_logs  integer;
begin
  update public.history_scans
     set def_version = def_version + 1, covered = '{}', holes = '{}', holes_checked_at = null,
         head_block = null, head_timestamp = null, updated_at = now()
   where p_scan is null or id = p_scan;
  get diagnostics v_scans = row_count;
  if v_scans = 0 then raise exception 'history_reset: unknown scan %', p_scan; end if;
  update public.history_wallet_scans
     set covered = '{}', holes = '{}', holes_checked_at = null, cap_floor = null, head_block = null, head_timestamp = null,
         log_count = 0, updated_at = now()
   where p_scan is null or scan = p_scan;
  delete from public.history_logs where p_scan is null or scan = p_scan;
  get diagnostics v_logs = row_count;
  delete from public.history_subject_caps where p_scan is null or scan = p_scan;
  if p_first_tx then
    update public.history_wallets
       set first_tx_state = 'unknown', first_tx_block = null, first_tx_head = null, first_tx_checked_at = null, first_tx_source = null
     where true;
  end if;
  return jsonb_build_object('scans', v_scans, 'logsDeleted', v_logs);
end;
$function$;

-- The owner's dashboard in one call (SQL editor): lease and switches, run cadence, heads and lag per scan, wallet
-- completeness (window and deep, counted from greatest(floor, cap_floor)), holes and caps, sizes, dead tuples, the
-- last day's global inserts against the measured baseline, and each endpoint's pace and 429 ratio. Counts only.
create or replace function public.history_health(p_window bigint default 8574264)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_state public.history_indexer_state%rowtype;
  v_doc   jsonb;
begin
  select * into v_state from public.history_indexer_state s where s.id;
  select jsonb_build_object(
    'now', now(),
    'paused', v_state.paused, 'serving', v_state.serving,
    'leaseHeldFor', case when v_state.lease_until > pg_catalog.clock_timestamp()
                         then extract(epoch from v_state.lease_until - pg_catalog.clock_timestamp())::int end,
    'head', v_state.head_block,
    'secondsSinceStart', (select extract(epoch from now() - max(r.started_at))::int from public.history_indexer_runs r),
    'secondsSinceRelease', (select extract(epoch from now() - max(r.released_at))::int from public.history_indexer_runs r),
    'runsLastHour', (select jsonb_build_object('started', count(*), 'released', count(r.released_at))
                       from public.history_indexer_runs r where r.started_at > now() - interval '1 hour'),
    'stopsLastHour', (select coalesce(jsonb_object_agg(coalesce(x.stop, 'unreleased'), x.n), '{}')
                        from (select r.stop, count(*) n from public.history_indexer_runs r
                               where r.started_at > now() - interval '1 hour' group by r.stop) x),
    'lastVersion', (select r.version from public.history_indexer_runs r order by r.started_at desc limit 1),
    'scans', (select jsonb_object_agg(s.id, jsonb_build_object(
                'defVersion', s.def_version, 'head', s.head_block,
                'lag', case when s.kind = 'global' and s.head_block is not null then v_state.head_block - s.head_block end,
                'complete', case when s.kind = 'global' then s.head_block is not null
                                 and pg_catalog.int8range(s.floor_block, s.head_block, '[]') <@ s.covered end,
                'holeBlocks', (select coalesce(sum(upper(h) - lower(h)), 0) from unnest(s.holes) h)))
                from public.history_scans s),
    'wallets', (select jsonb_build_object(
                  'enrolled', (select count(*) from public.history_wallets),
                  'active', (select count(*) from public.history_wallets w where w.requested_at > now() - interval '30 days'),
                  'firstTx', (select coalesce(jsonb_object_agg(x.first_tx_state, x.n), '{}')
                                from (select w.first_tx_state, count(*) n from public.history_wallets w group by 1) x),
                  'windowComplete', count(*) filter (where ws.head_block is not null and pg_catalog.int8range(
                      greatest(ws.head_block - p_window + 1, coalesce(ws.cap_floor, 0), 0), ws.head_block, '[]') <@ ws.covered),
                  'deepComplete', count(*) filter (where ws.head_block is not null
                      and pg_catalog.int8range(coalesce(ws.cap_floor, 0), ws.head_block, '[]') <@ ws.covered),
                  'scanRows', count(*),
                  'capped', count(*) filter (where ws.cap_floor is not null),
                  'withHoles', count(*) filter (where ws.holes <> '{}'::int8multirange))
                from public.history_wallet_scans ws),
    'cappedSubjects', (select coalesce(jsonb_object_agg(x.scan, x.n), '{}')
                         from (select sc.scan, count(*) n from public.history_subject_caps sc group by sc.scan) x),
    'rows', (select coalesce(jsonb_object_agg(x.scan, x.n), '{}')
               from (select l.scan, count(*) n from public.history_logs l group by l.scan) x),
    'insertedLastDay', (select coalesce(jsonb_object_agg(x.key, x.n), '{}')
                          from (select e.key, sum((e.value)::bigint) n
                                  from public.history_indexer_runs r,
                                       jsonb_each_text(coalesce(r.summary -> 'counts' -> 'inserted', '{}')) e
                                 where r.started_at > now() - interval '1 day' and e.value ~ '^[0-9]{1,12}$'
                                 group by e.key) x),
    'globalBaseline', jsonb_build_object('launchpad', 405, 'fee-sharing', 1, 'moments', 43, 'note',
                                         'logs over each whole window on 2026-10-08; alarm when a day inserts 10x'),
    'sizes', jsonb_build_object(
               'history_logs', pg_catalog.pg_total_relation_size('public.history_logs'),
               'history_wallet_scans', pg_catalog.pg_total_relation_size('public.history_wallet_scans'),
               'history_indexer_runs', pg_catalog.pg_total_relation_size('public.history_indexer_runs')),
    'deadTuples', (select coalesce(jsonb_object_agg(t.relname, t.n_dead_tup), '{}') from pg_catalog.pg_stat_user_tables t
                    where t.schemaname = 'public' and t.relname like 'history\_%'),
    'endpoints', coalesce(v_state.endpoints, '{}'::jsonb))
  into v_doc;
  return v_doc;
end;
$function$;

-- Daily (33's housekeeping job): keeps 7 days of run rows (about 20,000). Returns how many it deleted.
create or replace function public.history_housekeeping()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_n integer;
begin
  delete from public.history_indexer_runs r where r.started_at < now() - interval '7 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

-- ── The cron tick's credential ───────────────────────────────────────────────────────────────────────────────────────

-- The SHA-256 of the Vault secret history_cron_secret, as 64 lowercase hex characters: what the history-indexer Edge
-- Function compares each x-history-cron header's SHA-256 with (auth.ts), so no header ever reaches the database and no
-- caller can make the function query it per request. Migration 33 generates the secret inside Postgres (32 random
-- bytes as 64 hex characters) and pg_cron's job sends it: no person, file or Edge secret ever holds it.
-- service_role only. Never returns, raises or logs the secret itself; its digest is useless as a header (the header
-- must be the preimage, 256 random bits). Null when Vault cannot be read (no vault schema, no privilege), when the secret
-- is missing, and when it is not 32–512 visible ASCII characters (the Edge Function's own rule for a header, so a
-- secret it would refuse to send is never served: migration 33 refuses one).
create or replace function public.history_cron_digest()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_secret text;
begin
  begin
    select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'history_cron_secret' limit 1;
  exception when undefined_table or invalid_schema_name or undefined_column or insufficient_privilege then
    return null;
  end;
  -- [!-~] is 0x21–0x7e by code point (the regex engine's ranges are), as in auth.ts; {32,512} would exceed its 255 bound.
  if v_secret is null or pg_catalog.length(v_secret) < 32 or pg_catalog.length(v_secret) > 512 or v_secret !~ '^[!-~]+$' then
    return null;
  end if;
  return pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_secret, 'UTF8')), 'hex');
end;
$function$;

-- ── The app's read ────────────────────────────────────────────────────────────────────────────────────────────────────

-- One wallet's cached history, in pages (supabase/README.md "Wallet history cache" for the contract). The first page
-- (p_cursor null) carries every served scan's metadata — query, defVersion, floor, capFloor, from/to, coverage, holes,
-- head, completeness, omitted — then logs newest first, scan by scan (launchpad, fee-sharing, moments, transfers-out,
-- transfers-in), up to 2,000 logs or about 1.5 MB; `next` continues it. The cursor carries page 1's per-scan bounds,
-- so a later page never skips what page 1 promised; every page repeats `serving`, `tracked`, and each scan's
-- defVersion and current capFloor, so the client can abort or clip. p_from_block / p_to_block bound the read (a
-- top-up, or the newly covered ranges a poll asks for); p_meta_only answers page 1's metadata without logs.
-- Wallet scans are served only for a tracked (enrolled) wallet.
create or replace function public.history_read(p_wallet text, p_cursor text default null, p_from_block bigint default null,
                                               p_to_block bigint default null, p_meta_only boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  c_order      constant text[] := array['launchpad', 'fee-sharing', 'moments', 'transfers-out', 'transfers-in'];
  c_max_logs   constant integer := 2000;
  c_max_bytes  constant integer := 1500000;
  c_omitted    constant integer := 100;
  v_wallet     text := lower(btrim(coalesce(p_wallet, '')));
  v_subject    bytea;
  v_tracked    boolean;
  v_serving    boolean;
  v_first_page boolean := p_cursor is null;
  v_scan_no    integer := 1;
  v_after_b    bigint;
  v_after_i    integer;
  v_bounds     bigint[] := array[]::bigint[];  -- lo1, hi1, …, lo5, hi5
  v_pairs      text[];
  v_logs_left  integer := c_max_logs;
  v_bytes_left integer := c_max_bytes;
  v_scans      jsonb := '{}';
  v_doc        jsonb;
  v_next       text;
  v_first      jsonb;
  v_def        public.history_scans%rowtype;
  v_ws         public.history_wallet_scans%rowtype;
  v_covered    int8multirange;
  v_holes      int8multirange;
  v_head       bigint;
  v_head_ts    bigint;
  v_cap_floor  bigint;
  v_lo         bigint;
  v_hi         bigint;
  v_ub_b       bigint;
  v_ub_i       integer;
  v_clip       int8multirange;
  v_fetched    integer;
  v_taken      integer;
  v_bytes      integer;
  v_logs       jsonb;
  v_last_b     bigint;
  v_last_i     integer;
  v_topics     jsonb;
  v_omitted    jsonb;
  i            integer;
begin
  if v_wallet !~ '^0x[0-9a-f]{40}$' then
    raise exception 'p_wallet must be a 0x-prefixed 40-hex address' using errcode = '22023';
  end if;
  if (p_from_block is not null and p_from_block < 0) or (p_to_block is not null and p_to_block < 0)
     or (p_from_block is not null and p_to_block is not null and p_from_block > p_to_block) then
    raise exception 'p_from_block / p_to_block must be block numbers, from ≤ to' using errcode = '22023';
  end if;
  if p_cursor is not null then
    if p_meta_only or p_cursor !~ '^v1:[1-5]:([0-9]{1,18}:[0-9]{1,9}|-:-):[0-9]{1,18}-[0-9]{1,18}(,[0-9]{1,18}-[0-9]{1,18}){4}$' then
      raise exception 'p_cursor is not a cursor history_read returned' using errcode = '22023';
    end if;
    v_scan_no := split_part(p_cursor, ':', 2)::integer;
    if split_part(p_cursor, ':', 3) <> '-' then
      v_after_b := split_part(p_cursor, ':', 3)::bigint;
      v_after_i := split_part(p_cursor, ':', 4)::integer;
    end if;
    v_pairs := string_to_array(split_part(p_cursor, ':', 5), ',');
    for i in 1 .. 5 loop
      v_bounds := v_bounds || split_part(v_pairs[i], '-', 1)::bigint || split_part(v_pairs[i], '-', 2)::bigint;
    end loop;
  end if;
  select s.serving into v_serving from public.history_indexer_state s where s.id;
  if not coalesce(v_serving, false) then
    return jsonb_build_object('version', 1, 'serving', false, 'wallet', v_wallet, 'scans', '{}'::jsonb, 'next', null);
  end if;
  v_subject := decode(substr(v_wallet, 3), 'hex');
  select exists (select 1 from public.history_wallets w where w.wallet = v_wallet) into v_tracked;

  for i in 1 .. 5 loop
    select * into v_def from public.history_scans s where s.id = c_order[i];
    if v_def.kind = 'wallet' and not v_tracked then
      if v_first_page then v_bounds := v_bounds || 1::bigint || 0::bigint; end if;
      continue;
    end if;
    if v_def.kind = 'global' then
      v_covered := v_def.covered; v_holes := v_def.holes; v_head := v_def.head_block; v_head_ts := v_def.head_timestamp;
      -- The log cap, as history_commit keeps it: past 20,000 logs for this subject the older blocks are gone.
      select sc.cap_floor into v_cap_floor from public.history_subject_caps sc where sc.scan = v_def.id and sc.subject = v_subject;
    else
      select * into v_ws from public.history_wallet_scans ws where ws.wallet = v_wallet and ws.scan = v_def.id;
      v_covered := coalesce(v_ws.covered, '{}'); v_holes := coalesce(v_ws.holes, '{}');
      v_head := v_ws.head_block; v_head_ts := v_ws.head_timestamp; v_cap_floor := v_ws.cap_floor;
    end if;

    if v_first_page then
      v_lo := greatest(v_def.floor_block, coalesce(v_cap_floor, 0), coalesce(p_from_block, 0));
      v_hi := case when v_head is null then -1 else least(v_head, coalesce(p_to_block, v_head)) end;
      if v_hi < v_lo then v_lo := 1; v_hi := 0; end if;  -- nothing to serve (encoded as the empty range 1-0)
      v_bounds := v_bounds || v_lo || v_hi;
    else
      v_lo := greatest(v_bounds[2 * i - 1], v_def.floor_block);  -- page 1's bound, never below the floor
      v_hi := v_bounds[2 * i];
    end if;
    v_clip := case when v_hi >= v_lo then pg_catalog.int8multirange(pg_catalog.int8range(v_lo, v_hi, '[]')) else '{}'::int8multirange end;

    if v_first_page then
      v_topics := jsonb_build_array((select jsonb_agg('0x' || encode(t, 'hex') order by t) from unnest(v_def.topic0s) t));
      if v_def.wallet_topic = 2 then v_topics := v_topics || 'null'::jsonb; end if;
      v_topics := v_topics || jsonb_build_array(jsonb_build_array('0x000000000000000000000000' || substr(v_wallet, 3)));
      select coalesce(jsonb_agg(jsonb_build_object('blockNumber', '0x' || to_hex(o.block_number),
                                                   'transactionHash', '0x' || encode(o.tx_hash, 'hex'),
                                                   'logIndex', '0x' || to_hex(o.log_index),
                                                   'address', '0x' || encode(o.address, 'hex'))
                                order by o.block_number desc, o.log_index desc), '[]')
        into v_omitted
        from (select l.block_number, l.log_index, l.tx_hash, l.address from public.history_logs l
               where l.scan = v_def.id and l.subject = v_subject and l.data is null
                 and l.block_number >= v_lo and l.block_number <= v_hi
               order by l.block_number desc, l.log_index desc limit c_omitted + 1) o;
      v_doc := jsonb_build_object(
        'kind', v_def.kind,
        'defVersion', v_def.def_version,
        'query', jsonb_build_object(
          'addresses', (select coalesce(jsonb_agg('0x' || encode(a, 'hex') order by a), '[]') from unnest(v_def.addresses) a),
          'topics', v_topics),
        'fingerprint', (select coalesce(string_agg('0x' || encode(a, 'hex'), ',' order by a), '') from unnest(v_def.addresses) a)
                       || '|' || (select string_agg(case when jsonb_typeof(p) = 'null' then '*'
                                                         else (select string_agg(x, '+' order by x) from jsonb_array_elements_text(p) x) end,
                                                    ',' order by o)
                                    from jsonb_array_elements(v_topics) with ordinality as q(p, o)),
        'floor', v_def.floor_block,
        'capFloor', v_cap_floor,
        'from', v_lo,
        'to', v_hi,
        'covered', public.history_ranges(v_covered * v_clip),
        'holes', public.history_ranges(v_holes * v_clip),
        'head', v_head,
        'headTimestamp', v_head_ts,
        'complete', v_head is not null and (v_hi < v_lo or pg_catalog.int8range(v_lo, v_hi, '[]') <@ v_covered),
        'omitted', case when jsonb_array_length(v_omitted) > c_omitted then v_omitted - c_omitted else v_omitted end,
        'omittedTruncated', jsonb_array_length(v_omitted) > c_omitted,
        'logs', '[]'::jsonb);
    else
      v_doc := jsonb_build_object('defVersion', v_def.def_version, 'capFloor', v_cap_floor, 'logs', '[]'::jsonb);
    end if;

    if i >= v_scan_no and not p_meta_only and v_hi >= v_lo then
      if v_logs_left > 0 then
        -- Sargable bounds only (index conditions even in a generic plan): scan = $, subject = $, block ≥ lo, and one
        -- row comparison below the cursor (continuing this scan) or below (hi + 1, 0).
        if i = v_scan_no and v_after_b is not null then
          v_ub_b := v_after_b; v_ub_i := v_after_i;
        else
          v_ub_b := v_hi + 1; v_ub_i := 0;
        end if;
        select count(*)::int,
               count(*) filter (where x.keep)::int,
               coalesce(max(x.run) filter (where x.keep), 0)::int,
               coalesce(jsonb_agg(x.j order by x.block_number desc, x.log_index desc) filter (where x.keep), '[]'),
               min(x.block_number) filter (where x.keep and x.rn = x.taken),
               min(x.log_index) filter (where x.keep and x.rn = x.taken)
          into v_fetched, v_taken, v_bytes, v_logs, v_last_b, v_last_i
          from (
            select y.*, y.rn <= v_logs_left and (y.run <= v_bytes_left or (y.rn = 1 and v_bytes_left = c_max_bytes)) as keep,
                   count(*) filter (where y.rn <= v_logs_left and (y.run <= v_bytes_left or (y.rn = 1 and v_bytes_left = c_max_bytes))) over () as taken
              from (
                select l.block_number, l.log_index,
                       jsonb_build_object(
                         'address', '0x' || encode(l.address, 'hex'),
                         'topics', (select jsonb_agg('0x' || encode(t, 'hex') order by o) from unnest(l.topics) with ordinality as q(t, o)),
                         'data', '0x' || encode(l.data, 'hex'),
                         'blockNumber', '0x' || to_hex(l.block_number),
                         'transactionHash', '0x' || encode(l.tx_hash, 'hex'),
                         'logIndex', '0x' || to_hex(l.log_index),
                         'blockTimestamp', '0x' || to_hex(l.block_timestamp),
                         'removed', false) as j,
                       row_number() over (order by l.block_number desc, l.log_index desc) as rn,
                       sum(260 + 70 * cardinality(l.topics) + 2 * octet_length(l.data))
                         over (order by l.block_number desc, l.log_index desc rows unbounded preceding) as run
                  from public.history_logs l
                 where l.scan = v_def.id and l.subject = v_subject
                   and l.block_number >= v_lo
                   and (l.block_number, l.log_index) < (v_ub_b, v_ub_i)
                   and l.data is not null
                 order by l.block_number desc, l.log_index desc
                 limit v_logs_left + 1
              ) y
          ) x;
        v_doc := jsonb_set(v_doc, '{logs}', v_logs);
        v_logs_left := v_logs_left - v_taken;
        v_bytes_left := v_bytes_left - v_bytes;
        if v_fetched > v_taken and v_next is null then
          v_next := case when v_taken = 0 and (i <> v_scan_no or v_after_b is null) then format('v1:%s:-:-', i)
                         when v_taken = 0 then format('v1:%s:%s:%s', i, v_after_b, v_after_i)
                         else format('v1:%s:%s:%s', i, v_last_b, v_last_i) end;
        end if;
      elsif v_next is null then
        v_next := format('v1:%s:-:-', i);
      end if;
    end if;
    v_scans := v_scans || jsonb_build_object(v_def.id, v_doc);
    if v_next is not null then
      v_logs_left := 0;  -- no log after the cursor's position on this page; remaining scans carry metadata only
    end if;
  end loop;

  if v_next is not null then
    v_next := v_next || ':' || (select string_agg(v_bounds[2 * k - 1] || '-' || v_bounds[2 * k], ',' order by k)
                                  from generate_series(1, 5) k);
  end if;
  if v_first_page and v_tracked then
    select jsonb_build_object('state', w.first_tx_state, 'block', w.first_tx_block) into v_first
      from public.history_wallets w where w.wallet = v_wallet;
  end if;
  return jsonb_build_object(
    'version', 1,
    'serving', true,
    'wallet', v_wallet,
    'tracked', v_tracked,
    'firstTx', v_first,
    'head', (select s.head_block from public.history_indexer_state s where s.id),
    'headTimestamp', (select s.head_timestamp from public.history_indexer_state s where s.id),
    'scans', v_scans,
    'next', v_next);
end;
$function$;

-- ── Privileges ────────────────────────────────────────────────────────────────────────────────────────────────────────

revoke all on function public.history_octets(bytea[], integer), public.history_ranges(int8multirange),
                       public.history_require_lease(uuid, text), public.history_apply_cap(text, text),
                       public.history_enrol_profile(), public.history_forget_profile(),
                       public.history_redefine_scan(text, bytea[], bytea[], bigint, bigint), public.history_reset(text, boolean),
                       public.history_health(bigint), public.history_housekeeping()
  from public, anon, authenticated, service_role;
revoke all on function public.history_lease(uuid, integer, text), public.history_release(uuid, bigint, bigint, jsonb, jsonb, text),
                       public.history_state(uuid, integer, timestamptz),
                       public.history_commit(uuid, text, integer, bigint, bigint, bigint, bigint, text[], jsonb),
                       public.history_mark_hole(uuid, text, integer, text, bigint, bigint),
                       public.history_set_first_tx(uuid, text, text, bigint, bigint, text),
                       public.history_cron_digest(),
                       public.history_read(text, text, bigint, bigint, boolean)
  from public, anon, authenticated;
grant execute on function public.history_lease(uuid, integer, text), public.history_release(uuid, bigint, bigint, jsonb, jsonb, text),
                          public.history_state(uuid, integer, timestamptz),
                          public.history_commit(uuid, text, integer, bigint, bigint, bigint, bigint, text[], jsonb),
                          public.history_mark_hole(uuid, text, integer, text, bigint, bigint),
                          public.history_set_first_tx(uuid, text, text, bigint, bigint, text),
                          public.history_cron_digest()
  to service_role;
grant execute on function public.history_read(text, text, bigint, bigint, boolean) to anon, authenticated, service_role;

-- Fail the migration if the access rules did not take.
do $$
declare
  r     text;
  t     text;
  f     text;
  privs constant text := 'select, insert, update, delete, truncate, references, trigger';
  internal constant text[] := array[
    'public.history_octets(bytea[], integer)', 'public.history_ranges(int8multirange)', 'public.history_require_lease(uuid, text)',
    'public.history_apply_cap(text, text)', 'public.history_enrol_profile()', 'public.history_forget_profile()',
    'public.history_redefine_scan(text, bytea[], bytea[], bigint, bigint)', 'public.history_reset(text, boolean)',
    'public.history_health(bigint)', 'public.history_housekeeping()'];
  indexer constant text[] := array[
    'public.history_lease(uuid, integer, text)', 'public.history_release(uuid, bigint, bigint, jsonb, jsonb, text)',
    'public.history_state(uuid, integer, timestamptz)',
    'public.history_commit(uuid, text, integer, bigint, bigint, bigint, bigint, text[], jsonb)',
    'public.history_mark_hole(uuid, text, integer, text, bigint, bigint)',
    'public.history_set_first_tx(uuid, text, text, bigint, bigint, text)', 'public.history_cron_digest()'];
begin
  foreach t in array array['history_scans', 'history_wallets', 'history_wallet_scans', 'history_logs', 'history_subject_caps',
                           'history_indexer_state', 'history_indexer_runs'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'RLS is not enabled on public.%', t;
    end if;
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
      if has_table_privilege(r, 'public.' || t, privs) then
        raise exception '% still has privileges on public.%', r, t;
      end if;
    end loop;
  end loop;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not has_function_privilege(r, 'public.history_read(text, text, bigint, bigint, boolean)', 'execute') then
      raise exception '% cannot execute history_read', r;
    end if;
    foreach f in array internal loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '% can execute the internal function %', r, f;
      end if;
    end loop;
    foreach f in array indexer loop
      if has_function_privilege(r, f, 'execute') <> (r = 'service_role') then
        raise exception 'execute on % for % is wrong', f, r;
      end if;
    end loop;
  end loop;
  if (select count(*) from public.history_scans) <> 5 then
    raise exception 'history_scans must hold the five scans';
  end if;
end
$$;
