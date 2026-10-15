-- Launches (migration 20261014000007; docs/DESIGN-stellar-parity.md §6.9, §6.11, §6.15, §12.2): anon and authenticated
-- can't reach the new tables or functions and lite_api can; RLS is on; the checks keep out what the indexer never
-- writes; token_candles merges curve trades and priced pool swaps into one series; token_price_at answers the last
-- price at a time (events of one ledger in their order), the opening price before any trade and nothing before the
-- launch; launch_holders counts positive balances without the launchpad and the pair; the indexer's writes, as
-- lite_api: record_token_event moves balances once per event and never adds one a live read already counts,
-- reconcile_balance never takes a balance back to an older read, and record_pool_swap names a sell's seller from its
-- transaction's transfer into the pair whichever is read first (a route through two pools sends the swap's output to
-- the next pool). One transaction, rolled back.
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
    foreach t in array array['lite.token_price_at(''C'', now())', 'lite.token_candles(''C'', interval ''1 hour'', 10)', 'lite.launch_holders(''C'', array[''C''])',
                             'lite.record_token_event(''e'', ''C'', ''mint'', null, ''G'', null, 1, null, 1, now())',
                             'lite.record_pool_swap(''e'', ''C'', ''P'', ''G'', ''buy'', 1, 1, null, 1, now())',
                             'lite.reconcile_balance(''C'', ''G'', 1, 1)'] loop
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
  foreach t in array array['lite.record_token_event(text, text, text, text, text, text, numeric, text, int, timestamptz)',
                           'lite.record_pool_swap(text, text, text, text, text, numeric, numeric, text, int, timestamptz)',
                           'lite.reconcile_balance(text, text, numeric, int)'] loop
    if has_function_privilege('public', t, 'execute') then raise exception 'PUBLIC can execute %', t; end if;
    if not has_function_privilege('lite_api', t, 'execute') then raise exception 'lite_api cannot call %', t; end if;
  end loop;
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

-- 7. As lite_api, record_token_event and reconcile_balance: a mint, a transfer and a burn move balances, each once; an
--    event a live read already counts (at or before its ledger) moves no balance that read set; a live read replaces a
--    balance unless the row holds something newer: an event after the read, or a read at a later ledger.
do $$
declare
  ts timestamptz := timestamptz '2026-10-14 12:00+00';
  outcome text;
  b record;
begin
  execute 'set local role lite_api';
  if not lite.record_token_event('0000000000000000800-0000000001', 'CTOKEN', 'mint', null, 'GM1', null, 100, 'tx8', 800, ts) then
    raise exception 'a new mint was not recorded';
  end if;
  if lite.record_token_event('0000000000000000800-0000000001', 'CTOKEN', 'mint', null, 'GM1', null, 100, 'tx8', 800, ts) then
    raise exception 'a mint read again was recorded again';
  end if;
  perform lite.record_token_event('0000000000000000801-0000000001', 'CTOKEN', 'transfer', 'GM1', 'GM2', null, 30, 'tx9', 801, ts);
  perform lite.record_token_event('0000000000000000802-0000000001', 'CTOKEN', 'burn', 'GM2', null, null, 5, 'tx10', 802, ts);
  select (select balance from lite.token_balances where token = 'CTOKEN' and address = 'GM1') as m1,
         (select balance from lite.token_balances where token = 'CTOKEN' and address = 'GM2') as m2,
         (select updated_ledger from lite.token_balances where token = 'CTOKEN' and address = 'GM2') as m2_ledger into b;
  if b.m1 <> 70 or b.m2 <> 25 or b.m2_ledger <> 802 then raise exception 'after a mint, a transfer and a burn: %', b; end if;

  -- A read at ledger 810 already counts a transfer at 805 the index hasn't read: 60, not 70.
  outcome := lite.reconcile_balance('CTOKEN', 'GM1', 60, 810);
  if outcome is distinct from 'corrected' then raise exception 'a stale balance read live: %', outcome; end if;
  perform lite.record_token_event('0000000000000000805-0000000001', 'CTOKEN', 'transfer', 'GM1', 'GM2', null, 10, 'tx11', 805, ts);
  -- After the read: counted.
  perform lite.record_token_event('0000000000000000811-0000000001', 'CTOKEN', 'transfer', 'GM1', 'GM2', null, 5, 'tx12', 811, ts);
  select (select balance from lite.token_balances where token = 'CTOKEN' and address = 'GM1') as m1,
         (select balance from lite.token_balances where token = 'CTOKEN' and address = 'GM2') as m2 into b;
  if b.m1 <> 55 or b.m2 <> 40 then raise exception 'events around a live read at 810: GM1 % (expected 55), GM2 % (expected 40)', b.m1, b.m2; end if;

  -- A read older than an event already applied leaves the balance (a lagging RPC node, or an overlapping run).
  outcome := lite.reconcile_balance('CTOKEN', 'GM1', 60, 810);
  select balance, checked_ledger into b from lite.token_balances where token = 'CTOKEN' and address = 'GM1';
  if outcome is distinct from 'newer' or b.balance <> 55 or b.checked_ledger <> 810 then
    raise exception 'a read older than an event took the balance back: %, %', outcome, b;
  end if;
  -- So does a read at a ledger before an earlier read's.
  perform lite.record_token_event('0000000000000000820-0000000001', 'CTOKEN', 'mint', null, 'GM3', null, 50, 'tx13', 820, ts);
  outcome := lite.reconcile_balance('CTOKEN', 'GM3', 50, 830);
  if outcome is distinct from 'same' then raise exception 'a matching read: %', outcome; end if;
  outcome := lite.reconcile_balance('CTOKEN', 'GM3', 40, 825);
  select balance, checked_ledger into b from lite.token_balances where token = 'CTOKEN' and address = 'GM3';
  if outcome is distinct from 'newer' or b.balance <> 50 or b.checked_ledger <> 830 then
    raise exception 'a read before an earlier read took the balance back: %, %', outcome, b;
  end if;
  if lite.reconcile_balance('CTOKEN', 'GNOBODY', 1, 830) is not null then raise exception 'a read for no balance row'; end if;
  execute 'reset role';
  raise notice 'ok: record_token_event and reconcile_balance';
end $$;

-- 8. As lite_api, record_pool_swap: a sell's trader is whoever sent the launch tokens into the pair last before it in
--    its transaction, whether that transfer is read before the swap or after it (the swap's `to`, the next pool of a
--    route through two pools, stands in until then); a buy's is its `to`. Each swap once, priced by its transaction's
--    sync when that was read first, and the launch's last trade moves on.
do $$
declare
  ts timestamptz := timestamptz '2026-10-14 12:30+00';
  t text;
  r record;
begin
  execute 'set local role lite_api';
  -- The transfer read first. A transfer into another pair names no one.
  perform lite.record_token_event('0000000000000000900-0000000000', 'CTOKEN', 'transfer', 'GELSEWHERE', 'COTHERPAIR', null, 7, 'txA', 900, ts);
  perform lite.record_token_event('0000000000000000900-0000000001', 'CTOKEN', 'transfer', 'GSELLER', 'CPAIR', null, 1000, 'txA', 900, ts);
  if not lite.record_pool_swap('0000000000000000900-0000000003', 'CTOKEN', 'CPAIR', 'CNEXTPOOL', 'sell', 20, 1000, 'txA', 900, ts) then
    raise exception 'a new swap was not recorded';
  end if;
  if lite.record_pool_swap('0000000000000000900-0000000003', 'CTOKEN', 'CPAIR', 'CNEXTPOOL', 'sell', 20, 1000, 'txA', 900, ts) then
    raise exception 'a swap read again was recorded again';
  end if;
  select trader into t from lite.pool_swaps where event_id = '0000000000000000900-0000000003';
  if t is distinct from 'GSELLER' then raise exception 'a sell read after its transfer: trader %', t; end if;

  -- The swap read first: its `to` until the transfer comes.
  perform lite.record_pool_swap('0000000000000000901-0000000003', 'CTOKEN', 'CPAIR', 'CNEXTPOOL', 'sell', 20, 1000, 'txB', 901, ts);
  select trader into t from lite.pool_swaps where event_id = '0000000000000000901-0000000003';
  if t is distinct from 'CNEXTPOOL' then raise exception 'a sell before its transfer: trader %', t; end if;
  perform lite.record_token_event('0000000000000000901-0000000001', 'CTOKEN', 'transfer', 'GSELLER2', 'CPAIR', null, 1000, 'txB', 901, ts);
  select trader into t from lite.pool_swaps where event_id = '0000000000000000901-0000000003';
  if t is distinct from 'GSELLER2' then raise exception 'a sell whose transfer came after it: trader %', t; end if;

  -- Two sells in one transaction, both swaps read before both transfers: each ends with the transfer just before it.
  perform lite.record_pool_swap('0000000000000000902-0000000003', 'CTOKEN', 'CPAIR', 'CNEXTPOOL', 'sell', 20, 1000, 'txC', 902, ts);
  perform lite.record_pool_swap('0000000000000000902-0000000006', 'CTOKEN', 'CPAIR', 'CNEXTPOOL', 'sell', 20, 1000, 'txC', 902, ts);
  perform lite.record_token_event('0000000000000000902-0000000001', 'CTOKEN', 'transfer', 'GS1', 'CPAIR', null, 1000, 'txC', 902, ts);
  perform lite.record_token_event('0000000000000000902-0000000004', 'CTOKEN', 'transfer', 'GS2', 'CPAIR', null, 1000, 'txC', 902, ts);
  select (select trader from lite.pool_swaps where event_id = '0000000000000000902-0000000003') as first,
         (select trader from lite.pool_swaps where event_id = '0000000000000000902-0000000006') as second into r;
  if r.first is distinct from 'GS1' or r.second is distinct from 'GS2' then raise exception 'two sells in one transaction: %', r; end if;

  -- A buy's trader is who got the tokens, whatever went into the pair before it.
  perform lite.record_token_event('0000000000000000903-0000000001', 'CTOKEN', 'transfer', 'GLP', 'CPAIR', null, 1, 'txD', 903, ts);
  perform lite.record_pool_swap('0000000000000000903-0000000003', 'CTOKEN', 'CPAIR', 'GBUYER', 'buy', 20, 1000, 'txD', 903, ts);
  select trader into t from lite.pool_swaps where event_id = '0000000000000000903-0000000003';
  if t is distinct from 'GBUYER' then raise exception 'a buy: trader %', t; end if;

  -- Priced by its transaction's sync read first; the launch's last trade is its time.
  update lite.launches set pool_tx = 'txE', last_price = 0.000060 where token = 'CTOKEN';
  perform lite.record_pool_swap('0000000000000000905-0000000003', 'CTOKEN', 'CPAIR', 'GBUYER', 'buy', 30, 500, 'txE', 905, timestamptz '2026-10-14 13:00+00');
  select s.price, l.last_trade_at into r from lite.pool_swaps s join lite.launches l on l.token = s.token
   where s.event_id = '0000000000000000905-0000000003';
  if r.price is distinct from 0.000060 or r.last_trade_at is distinct from timestamptz '2026-10-14 13:00+00' then
    raise exception 'a swap after its sync: %', r;
  end if;
  execute 'reset role';
  raise notice 'ok: record_pool_swap';
end $$;

rollback;
