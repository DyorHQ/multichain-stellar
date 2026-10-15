-- lite.bridge_transfers' relay day and measured time (migration 20261014000011; docs/DESIGN-stellar-parity.md §6.10):
-- only a transfer the keeper relays (from Monad, over CCTP) can have a relay day; reporting its burn stamps the UTC day,
-- and never a transfer to Monad's; the relay cap counts a user's transfers of the day, not another user's, not another
-- day's and none whose burn wasn't reported; a quote's time reads the last 20 completed transfers that way, newest
-- first; the indexes behind both exist. The statements are _shared/bridge.ts's, run as lite_api. One transaction,
-- rolled back.
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
  if not exists (select 1 from pg_indexes where schemaname = 'lite' and tablename = 'bridge_transfers'
                  and indexname = 'bridge_transfers_relay_day' and indexdef like '%(address, relay_day)%') then
    raise exception 'the relay cap has no index';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'lite' and tablename = 'bridge_transfers'
                  and indexname = 'bridge_transfers_completed' and indexdef like '%(direction, route, updated_at DESC)%') then
    raise exception 'a quote''s time has no index';
  end if;
  raise notice 'ok: relay_day, its rule and the indexes';
end $$;

-- 2. As lite_api: reporting a burn stamps the relay day of a transfer from Monad only, and the cap counts the user's
--    transfers of the day.
do $$
declare
  me constant text := 'G' || repeat('B', 55);
  other constant text := 'G' || repeat('C', 55);
  dead constant text := '0x' || repeat('d', 40);
  t uuid;
  out_id uuid;
  waiting uuid;
  stamped date;
  n int;
begin
  execute 'set local role lite_api';
  -- Ten transfers from Monad, started (startBridge) and reported (setSourceTx) today.
  for i in 1..10 loop
    insert into lite.bridge_transfers (address, direction, route, amount, recipient)
    values (me, 'monad_to_stellar', 'cctp', '1000000', me) returning id into t;
    update lite.bridge_transfers set source_tx = '0x' || lpad(to_hex(i), 64, '0'), status = 'attesting', updated_at = now(),
           relay_day = case when direction = 'monad_to_stellar' and route = 'cctp' then (now() at time zone 'utc')::date end
     where id = t and address = me and status = 'awaiting_source';
  end loop;
  select relay_day into stamped from lite.bridge_transfers where id = t;
  if stamped is distinct from (now() at time zone 'utc')::date then raise exception 'relay day %, not today (UTC)', stamped; end if;
  -- A transfer to Monad, reported today: the user claims it on Monad, nobody relays it.
  insert into lite.bridge_transfers (address, direction, route, amount, recipient)
  values (me, 'stellar_to_monad', 'cctp', '10000000', dead) returning id into out_id;
  update lite.bridge_transfers set source_tx = repeat('a', 64), status = 'attesting', updated_at = now(),
         relay_day = case when direction = 'monad_to_stellar' and route = 'cctp' then (now() at time zone 'utc')::date end
   where id = out_id and address = me and status = 'awaiting_source';
  if (select relay_day from lite.bridge_transfers where id = out_id) is not null then
    raise exception 'a transfer to Monad got a relay day';
  end if;
  -- Not counted: a transfer from Monad whose burn wasn't reported, one reported yesterday, and another user's.
  insert into lite.bridge_transfers (address, direction, route, amount, recipient)
  values (me, 'monad_to_stellar', 'cctp', '1000000', me) returning id into waiting;
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, source_tx, status, relay_day)
  values (me, 'monad_to_stellar', 'cctp', '1000000', me, '0x' || repeat('e', 64), 'completed', (now() at time zone 'utc')::date - 1),
         (other, 'monad_to_stellar', 'cctp', '1000000', other, '0x' || repeat('f', 64), 'attesting', (now() at time zone 'utc')::date);
  -- assertRelayAllowed's count: ten, so the API refuses an eleventh start (RELAYS_PER_DAY).
  select count(*)::int into n from lite.bridge_transfers where address = me and relay_day = (now() at time zone 'utc')::date;
  if n <> 10 then raise exception 'the relay cap counts % transfers, not 10', n; end if;
  select count(*)::int into n from lite.bridge_transfers where address = other and relay_day = (now() at time zone 'utc')::date;
  if n <> 1 then raise exception 'another user''s transfers count %, not 1', n; end if;
  if (select relay_day from lite.bridge_transfers where id = waiting) is not null then
    raise exception 'a transfer whose burn wasn''t reported has a relay day';
  end if;
  delete from lite.bridge_transfers where address in (me, other);
  execute 'reset role';
  raise notice 'ok: the relay day and the relay cap';
end $$;

-- 3. As lite_api: a quote's time reads the last 20 completed transfers that way, newest first, in seconds.
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
    insert into lite.bridge_transfers (address, direction, route, amount, recipient, status, created_at, updated_at)
    values (me, 'monad_to_stellar', 'cctp', '1000000', me, 'completed',
            now() - make_interval(hours => i, secs => 10 * i), now() - make_interval(hours => i));
  end loop;
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, status, created_at, updated_at) values
    (me, 'stellar_to_monad', 'cctp', '10000000', dead, 'completed', now() - interval '20 minutes', now()),
    (me, 'monad_to_stellar', 'cctp', '1000000', me, 'attesting', now() - interval '20 minutes', now()),
    (me, 'monad_to_stellar', 'oneclick', '1000000', me, 'completed', now() - interval '20 minutes', now());
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
