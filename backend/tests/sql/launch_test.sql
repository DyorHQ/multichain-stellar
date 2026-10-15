-- Launches (migration 20261014000007; docs/DESIGN-stellar-parity.md §6.9, §6.11, §6.15, §12.2): anon and authenticated
-- can't reach the new tables or functions and lite_api can; RLS is on; the checks keep out what the indexer never
-- writes; token_candles merges curve trades and priced pool swaps into one series; token_price_at answers the last
-- price at a time (events of one ledger in their order), the opening price before any trade and nothing before the
-- launch; launch_holders counts positive balances without the launchpad and the pair. One transaction, rolled back.
begin;

-- 1. anon and authenticated can neither read nor write the tables, nor call the functions; RLS is on; lite_api can.
do $$
declare r text; t text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach t in array array['launch_metadata', 'pool_swaps', 'creator_claims', 'token_events', 'token_balances', 'watch_groups', 'watch_contracts'] loop
      begin
        execute format('set local role %I', r);
        execute format('select 1 from lite.%I limit 1', t);
        raise exception '% could read lite.%', r, t;
      exception when insufficient_privilege then null;
      end;
      execute 'reset role';
    end loop;
    foreach t in array array['lite.token_price_at(''C'', now())', 'lite.token_candles(''C'', interval ''1 hour'', 10)', 'lite.launch_holders(''C'', array[''C''])'] loop
      begin
        execute format('set local role %I', r);
        execute format('select * from %s', t);
        raise exception '% could call %', r, t;
      exception when insufficient_privilege then null;
      end;
      execute 'reset role';
    end loop;
  end loop;
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'lite' and c.relname in ('launch_metadata', 'pool_swaps', 'creator_claims', 'token_events', 'token_balances', 'watch_groups', 'watch_contracts')
                and not c.relrowsecurity) then
    raise exception 'RLS is off on a launch table';
  end if;
  if has_function_privilege('public', 'lite.launch_holders(text, text[])', 'execute') then raise exception 'PUBLIC can execute lite.launch_holders'; end if;
  foreach t in array array['launch_metadata', 'pool_swaps', 'creator_claims', 'token_events', 'token_balances', 'watch_groups', 'watch_contracts'] loop
    if not has_table_privilege('lite_api', format('lite.%I', t), 'select, insert, update, delete, truncate') then raise exception 'lite_api lacks lite.%', t; end if;
  end loop;
  if not has_function_privilege('lite_api', 'lite.token_candles(text, interval, integer)', 'execute') then raise exception 'lite_api cannot call lite.token_candles'; end if;
  if not has_sequence_privilege('lite_api', pg_get_serial_sequence('lite.watch_groups', 'id'), 'usage') then raise exception 'lite_api cannot number watch groups'; end if;
  raise notice 'ok: anon and authenticated are refused, lite_api is not';
end $$;

-- A launch on the curve (opening price 2.5e11 / 1e16 = 0.000025), traded, then graduated into a pool.
insert into lite.launches (token, creator, quote, name, symbol, uri, launch_index, supply, phantom, threshold, quote_reserve,
                           token_reserve, created_ledger, created_at, pair)
values ('CTOKEN', 'GCREATOR', 'CXLM', 'Test Cat', 'TCAT', '', 0, 10000000000000000, 250000000000, 93000000000,
        250000000000, 10000000000000000, 100, timestamptz '2026-10-14 10:00+00', 'CPAIR');
insert into lite.launch_trades (event_id, token, trader, side, quote_amount, token_amount, fees, price, ledger, ts) values
  ('0000000000000000200-0000000001', 'CTOKEN', 'GA', 'buy', 100, 1, 0, 0.000030, 200, timestamptz '2026-10-14 10:05+00'),
  ('0000000000000000200-0000000003', 'CTOKEN', 'GB', 'buy', 300, 1, 0, 0.000032, 200, timestamptz '2026-10-14 10:05+00'),
  ('0000000000000000200-0000000002', 'CTOKEN', 'GC', 'sell', 200, 1, 0, 0.000031, 200, timestamptz '2026-10-14 10:05+00'),
  ('0000000000000000300-0000000001', 'CTOKEN', 'GA', 'buy', 400, 1, 0, 0.000040, 300, timestamptz '2026-10-14 10:20+00');
insert into lite.pool_swaps (event_id, token, pair, trader, side, quote_amount, token_amount, price, tx_hash, ledger, ts) values
  ('0000000000000000500-0000000003', 'CTOKEN', 'CPAIR', 'GA', 'buy', 50, 1, 0.000050, 'tx1', 500, timestamptz '2026-10-14 11:10+00'),
  -- Its sync isn't read yet: no price, so neither a candle nor a price at a time counts it.
  ('0000000000000000600-0000000003', 'CTOKEN', 'CPAIR', 'GB', 'sell', 60, 1, null, 'tx2', 600, timestamptz '2026-10-14 11:20+00');

-- 2. What the indexer never writes is refused.
do $$
begin
  begin
    insert into lite.token_events (event_id, token, kind, from_address, to_address, amount, ledger, ts)
    values ('e1', 'CTOKEN', 'burn', null, 'GA', 1, 1, now());
    raise exception 'a burn without a holder was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.token_events (event_id, token, kind, from_address, to_address, amount, ledger, ts)
    values ('e2', 'CTOKEN', 'approve', 'GA', 'GB', 1, 1, now());
    raise exception 'an approval was stored as a token event';
  exception when check_violation then null;
  end;
  begin
    insert into lite.token_events (event_id, token, kind, from_address, to_address, amount, ledger, ts)
    values ('e3', 'CTOKEN', 'transfer', 'GA', 'GB', -1, 1, now());
    raise exception 'a negative amount was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.launch_metadata (uri, address, name, symbol) values ('u1', 'GNOTANADDRESS', 'Cat', 'CAT');
    raise exception 'metadata of no address was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.launch_metadata (uri, address, name, symbol)
    values ('u2', 'GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH', 'Cat', 'cat');
    raise exception 'a lower-case ticker was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.launch_metadata (uri, address, name, symbol)
    values ('u3', 'GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH', repeat('é', 17), 'CAT');
    raise exception 'a 34-byte name was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.pool_swaps (event_id, token, pair, trader, side, quote_amount, token_amount, ledger, ts)
    values ('p1', 'CTOKEN', 'CPAIR', 'GA', 'hold', 1, 1, 1, now());
    raise exception 'a swap with no side was stored';
  exception when check_violation then null;
  end;
  raise notice 'ok: malformed rows are refused';
end $$;

-- 3. token_price_at: the last priced trade or swap at or before the time, a ledger's events in their order; the opening
--    price before any; nothing before the launch.
do $$
declare got numeric;
begin
  if lite.token_price_at('CTOKEN', timestamptz '2026-10-14 09:59+00') is not null then raise exception 'a price before the launch'; end if;
  got := lite.token_price_at('CTOKEN', timestamptz '2026-10-14 10:01+00');
  if got <> 0.000025 then raise exception 'opening price %, expected 0.000025', got; end if;
  -- Three trades in ledger 200 at one time: the last by event order (…0003) sets the price.
  got := lite.token_price_at('CTOKEN', timestamptz '2026-10-14 10:05+00');
  if got <> 0.000032 then raise exception 'price after ledger 200 %, expected 0.000032', got; end if;
  got := lite.token_price_at('CTOKEN', timestamptz '2026-10-14 11:00+00');
  if got <> 0.000040 then raise exception 'price before graduation %, expected 0.000040', got; end if;
  got := lite.token_price_at('CTOKEN', timestamptz '2026-10-14 11:15+00');
  if got <> 0.000050 then raise exception 'pool price %, expected 0.000050', got; end if;
  -- The unpriced swap at 11:20 doesn't count.
  got := lite.token_price_at('CTOKEN', timestamptz '2026-10-14 12:00+00');
  if got <> 0.000050 then raise exception 'price after an unpriced swap %, expected 0.000050', got; end if;
  if lite.token_price_at('CNONE', now()) is not null then raise exception 'a price for no launch'; end if;
  raise notice 'ok: token_price_at';
end $$;

-- 4. token_candles: curve trades and priced pool swaps in one series of buckets, oldest first, the newest p_limit.
do $$
declare r record; n int;
begin
  select count(*) into n from lite.token_candles('CTOKEN', interval '15 minutes', 300);
  if n <> 3 then raise exception '% buckets, expected 3 (10:00, 10:15 and 11:00)', n; end if;
  select * into r from lite.token_candles('CTOKEN', interval '15 minutes', 300) limit 1;
  if r.bucket <> timestamptz '2026-10-14 10:00+00' or r.open <> 0.000030 or r.close <> 0.000032 or r.high <> 0.000032
     or r.low <> 0.000030 or r.volume <> 600 then
    raise exception 'the 10:00 bucket is %', r;
  end if;
  select * into r from lite.token_candles('CTOKEN', interval '15 minutes', 300) order by bucket desc limit 1;
  if r.bucket <> timestamptz '2026-10-14 11:00+00' or r.close <> 0.000050 or r.volume <> 50 then
    raise exception 'the pool bucket is % (the unpriced swap must not count)', r;
  end if;
  select count(*) into n from lite.token_candles('CTOKEN', interval '15 minutes', 2);
  if n <> 2 then raise exception 'p_limit 2 gave % buckets', n; end if;
  if (select min(bucket) from lite.token_candles('CTOKEN', interval '15 minutes', 2)) <> timestamptz '2026-10-14 10:15+00' then
    raise exception 'p_limit keeps the newest buckets';
  end if;
  raise notice 'ok: token_candles';
end $$;

-- 5. launch_holders: positive balances, without the launchpad and the pair; a null in the list excludes nothing.
do $$
begin
  insert into lite.token_balances (token, address, balance, updated_ledger) values
    ('CTOKEN', 'CPAD', 6000, 1), ('CTOKEN', 'CPAIR', 2000, 1), ('CTOKEN', 'GA', 3, 1), ('CTOKEN', 'GB', 1, 1),
    ('CTOKEN', 'GC', 0, 1), ('CTOKEN', 'GD', -1, 1);
  if lite.launch_holders('CTOKEN', array['CPAD', 'CPAIR']) <> 2 then raise exception 'holders without the launchpad and pair: %', lite.launch_holders('CTOKEN', array['CPAD', 'CPAIR']); end if;
  if lite.launch_holders('CTOKEN', array['CPAD', null]) <> 3 then raise exception 'before graduation (no pair): %', lite.launch_holders('CTOKEN', array['CPAD', null]); end if;
  if lite.launch_holders('CTOKEN', array[null, null]::text[]) <> 4 then raise exception 'nothing excluded: %', lite.launch_holders('CTOKEN', array[null, null]::text[]); end if;
  if lite.launch_holders('CNONE', array['CPAD']) <> 0 then raise exception 'holders of no launch'; end if;
  raise notice 'ok: launch_holders';
end $$;

-- 6. As lite_api: the indexer's writes, a watch group numbered, a reset's truncate.
do $$
declare g bigint;
begin
  execute 'set local role lite_api';
  insert into lite.watch_groups (start_ledger, ledger) values (100, 99) returning id into g;
  insert into lite.watch_contracts (contract, role, token, from_ledger, group_id) values ('CTOKEN', 'token', 'CTOKEN', 100, g);
  insert into lite.creator_claims (event_id, token, creator, amount, ledger, ts) values ('c1', 'CTOKEN', 'GCREATOR', 5, 1, now());
  update lite.token_balances set balance = 4, checked_ledger = 700, checked_at = now() where token = 'CTOKEN' and address = 'GA';
  insert into lite.launch_metadata (uri, address, name, symbol, links)
  values ('https://example/launches/x.json', 'GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH', 'Cat', 'CAT', '{"website": null}');
  truncate lite.watch_contracts, lite.watch_groups;
  execute 'reset role';
  raise notice 'ok: lite_api writes the launch tables';
end $$;

rollback;
