-- lite.bridge_transfers' relay day, its one-burn-one-relay rule and measured time (migration 20261014000011;
-- docs/DESIGN-stellar-parity.md §6.10): exactly the transfers the keeper relays (from Monad, over CCTP) hold a relay
-- day; a start takes today's under the user's lock, so the cap counts the user's starts of the day whether or not their
-- burn was reported, and not another user's or another day's; reporting a burn keeps a start of today's day and moves
-- an earlier one's to today; a message completes one relayed transfer only; a quote's time reads the last 20 completed
-- transfers that way, newest first; the indexes behind them exist. The statements are _shared/bridge.ts's, run as
-- lite_api. One transaction, rolled back.
begin;

-- 1. The column, its rule and the indexes.
do $$
begin
  if (select data_type from information_schema.columns
       where table_schema = 'lite' and table_name = 'bridge_transfers' and column_name = 'relay_day') is distinct from 'date' then
    raise exception 'bridge_transfers.relay_day is missing or not a date';
  end if;
  begin
    insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day)
    values ('G' || repeat('A', 55), 'stellar_to_monad', 'cctp', 10000000, '0x' || repeat('d', 40), current_date);
    raise exception 'a transfer to Monad got a relay day';
  exception when check_violation then null;
  end;
  begin
    insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day)
    values ('G' || repeat('A', 55), 'monad_to_stellar', 'oneclick', 1000000, 'G' || repeat('A', 55), current_date);
    raise exception 'a 1Click transfer got a relay day';
  exception when check_violation then null;
  end;
  begin
    insert into lite.bridge_transfers (address, direction, route, amount, recipient)
    values ('G' || repeat('A', 55), 'monad_to_stellar', 'cctp', 1000000, 'G' || repeat('A', 55));
    raise exception 'a transfer the keeper relays has no relay day';
  exception when check_violation then null;
  end;
  if not exists (select 1 from pg_indexes where schemaname = 'lite' and tablename = 'bridge_transfers'
                  and indexname = 'bridge_transfers_relay_day' and indexdef like '%(address, relay_day)%') then
    raise exception 'the relay cap has no index';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'lite' and tablename = 'bridge_transfers'
                  and indexname = 'bridge_transfers_relayed' and indexdef like 'CREATE UNIQUE INDEX%(message)%') then
    raise exception 'one burn, one relay has no unique index';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'lite' and tablename = 'bridge_transfers'
                  and indexname = 'bridge_transfers_completed' and indexdef like '%(direction, route, updated_at DESC)%') then
    raise exception 'a quote''s time has no index';
  end if;
  raise notice 'ok: relay_day, its rule and the indexes';
end $$;

-- 2. As lite_api: starts take today's relays under the user's lock, reported or not; a report keeps today's and moves
--    an earlier day's to today.
do $$
declare
  me constant text := 'G' || repeat('B', 55);
  other constant text := 'G' || repeat('C', 55);
  dead constant text := '0x' || repeat('d', 40);
  t uuid;
  late_id uuid;
  out_id uuid;
  late boolean;
  n int;
begin
  execute 'set local role lite_api';
  -- Ten starts today (newInboundTransfer): the lock, the day's count, then the transfer with today's relay day. Three
  -- are reported (setSourceTx), seven aren't: every one counts.
  for i in 1..10 loop
    perform pg_advisory_xact_lock(hashtextextended('lite.bridge_relays:' || me, 0));
    select count(*)::int into n from lite.bridge_transfers where address = me and relay_day = (now() at time zone 'utc')::date;
    if n <> i - 1 then raise exception 'start %: the day holds % relays, not %', i, n, i - 1; end if;
    insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day)
    values (me, 'monad_to_stellar', 'cctp', '1000000', me, (now() at time zone 'utc')::date)
    returning id into t;
    if i <= 3 then
      select relay_day < (now() at time zone 'utc')::date into late from lite.bridge_transfers
       where id = t and address = me and status = 'awaiting_source';
      if late then raise exception 'a start of today''s reads as late'; end if;
      update lite.bridge_transfers set source_tx = '0x' || lpad(to_hex(i), 64, '0'), status = 'attesting', updated_at = now(),
             relay_day = case when relay_day is not null then (now() at time zone 'utc')::date end
       where id = t;
    end if;
  end loop;
  -- relaysToday: ten, so the API refuses an 11th start (RELAYS_PER_DAY) though seven burns weren't reported.
  select count(*)::int into n from lite.bridge_transfers where address = me and relay_day = (now() at time zone 'utc')::date;
  if n <> 10 then raise exception 'the relay cap counts % transfers, not 10', n; end if;
  -- Not counted: another user's, and one started yesterday whose burn isn't reported yet.
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day)
  values (other, 'monad_to_stellar', 'cctp', '1000000', other, (now() at time zone 'utc')::date);
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day, created_at, updated_at)
  values (me, 'monad_to_stellar', 'cctp', '1000000', me, (now() at time zone 'utc')::date - 1, now() - interval '1 day', now() - interval '1 day')
  returning id into late_id;
  select count(*)::int into n from lite.bridge_transfers where address = me and relay_day = (now() at time zone 'utc')::date;
  if n <> 10 then raise exception 'the relay cap counts % transfers, not 10, with another user''s and yesterday''s', n; end if;
  -- Reporting yesterday's start: it reads as late (the API refuses it while today's 10 are taken); once reported it
  -- holds one of today's.
  select relay_day < (now() at time zone 'utc')::date into late from lite.bridge_transfers
   where id = late_id and address = me and status = 'awaiting_source';
  if late is not true then raise exception 'a start of yesterday''s doesn''t read as late'; end if;
  update lite.bridge_transfers set source_tx = '0x' || repeat('e', 64), status = 'attesting', updated_at = now(),
         relay_day = case when relay_day is not null then (now() at time zone 'utc')::date end
   where id = late_id;
  select count(*)::int into n from lite.bridge_transfers where address = me and relay_day = (now() at time zone 'utc')::date;
  if n <> 11 then raise exception 'a late report moved its relay to today: % relays, not 11', n; end if;
  -- A transfer to Monad: the user claims it on Monad, nobody relays it, and reporting its burn leaves it without a day.
  insert into lite.bridge_transfers (address, direction, route, amount, recipient)
  values (me, 'stellar_to_monad', 'cctp', '10000000', dead) returning id into out_id;
  update lite.bridge_transfers set source_tx = repeat('a', 64), status = 'attesting', updated_at = now(),
         relay_day = case when relay_day is not null then (now() at time zone 'utc')::date end
   where id = out_id;
  if (select relay_day from lite.bridge_transfers where id = out_id) is not null then
    raise exception 'a transfer to Monad got a relay day';
  end if;
  delete from lite.bridge_transfers where address in (me, other);
  execute 'reset role';
  raise notice 'ok: the relay day and the relay cap';
end $$;

-- 3. As lite_api: a message completes one relayed transfer; relayInbound finds the one that did.
do $$
declare
  me constant text := 'G' || repeat('E', 55);
  msg constant text := '0x' || repeat('28', 464);
  first_id uuid;
  second_id uuid;
begin
  execute 'set local role lite_api';
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, source_tx, status, relay_day)
  values (me, 'monad_to_stellar', 'cctp', '1000000', me, '0x' || repeat('1', 64), 'attesting', (now() at time zone 'utc')::date)
  returning id into first_id;
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, source_tx, status, relay_day)
  values (me, 'monad_to_stellar', 'cctp', '1000000', me, '0x' || repeat('1', 64), 'attesting', (now() at time zone 'utc')::date)
  returning id into second_id;
  update lite.bridge_transfers set message = msg, attestation = '0x' || repeat('82', 65), dest_tx = repeat('c', 64),
         status = 'completed', updated_at = now() where id = first_id;
  if not exists (select 1 from lite.bridge_transfers
                  where message = msg and direction = 'monad_to_stellar' and status = 'completed' and id <> second_id) then
    raise exception 'the second transfer doesn''t see its burn relayed for the first';
  end if;
  begin
    update lite.bridge_transfers set message = msg, status = 'completed', updated_at = now() where id = second_id;
    raise exception 'one message completed two relayed transfers';
  exception when unique_violation then null;
  end;
  -- What relayInbound records instead: the transfer fails, unrelayed.
  update lite.bridge_transfers set error = 'Not relayed: its burn was relayed for another transfer.', status = 'failed',
         updated_at = now() where id = second_id;
  delete from lite.bridge_transfers where address = me;
  execute 'reset role';
  raise notice 'ok: one burn, one relay';
end $$;

-- 4. As lite_api: a quote's time reads the last 20 completed transfers that way, newest first, in seconds.
do $$
declare
  me constant text := 'G' || repeat('D', 55);
  dead constant text := '0x' || repeat('d', 40);
  secs float8[];
begin
  execute 'set local role lite_api';
  -- 25 completed transfers from Monad: the i-th finished i hours ago, after 10·i seconds. Newer ones are noise: one to
  -- Monad, one still attesting and one over another route.
  for i in 1..25 loop
    insert into lite.bridge_transfers (address, direction, route, amount, recipient, status, relay_day, created_at, updated_at)
    values (me, 'monad_to_stellar', 'cctp', '1000000', me, 'completed', (now() at time zone 'utc')::date,
            now() - make_interval(hours => i, secs => 10 * i), now() - make_interval(hours => i));
  end loop;
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, status, relay_day, created_at, updated_at) values
    (me, 'stellar_to_monad', 'cctp', '10000000', dead, 'completed', null, now() - interval '20 minutes', now()),
    (me, 'monad_to_stellar', 'cctp', '1000000', me, 'attesting', (now() at time zone 'utc')::date, now() - interval '20 minutes', now()),
    (me, 'monad_to_stellar', 'oneclick', '1000000', me, 'completed', null, now() - interval '20 minutes', now());
  select array_agg(seconds) into secs from (
    select extract(epoch from updated_at - created_at)::float8 as seconds from lite.bridge_transfers
     where direction = 'monad_to_stellar' and route = 'cctp' and status = 'completed' order by updated_at desc limit 20
  ) recent;
  if array_length(secs, 1) <> 20 then raise exception 'a quote''s time reads % transfers, not 20', array_length(secs, 1); end if;
  if secs[1] <> 10 or secs[20] <> 200 then raise exception 'not the newest 20, newest first: % … %', secs[1], secs[20]; end if;
  execute 'reset role';
  raise notice 'ok: a quote''s time reads the last 20 completed transfers that way';
end $$;

rollback;
