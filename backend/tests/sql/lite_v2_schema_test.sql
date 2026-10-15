-- Contracts v2 in the schema (migration 20261015000012; docs/DESIGN-stellar-contracts-v2.md §20.5, §20.6): anon and
-- authenticated can't reach the new tables, RLS is on, PUBLIC executes no lite function, lite_api reads and writes them;
-- v1 Moments (contract, id) and v2 Moments (NFT address) coexist, and so do v1 and v2 launches; v1's ON CONFLICT (id)
-- still has its arbiter; the keys and checks keep out what the indexer never writes; keeper_skip takes only the six
-- jobs; keeper_log takes the v2 keeper's jobs; the testnet reset's truncate clears the tables together. One
-- transaction, rolled back.
begin;

-- 1. anon and authenticated can neither read nor write the new tables; RLS is on; PUBLIC executes no lite function.
do $$
declare
  r text;
  t text;
  tables text[] := array['v2_events', 'launch_rewards', 'reward_releases', 'locker_positions', 'harvests', 'refunds',
    'creator_owed', 'moment_positions', 'moment_withdrawals', 'vesting_claims', 'moment_coin_balances', 'pool_candidates',
    'keeper_skip', 'keeper_alerts', 'watch_v2_groups', 'watch_v2_contracts'];
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach t in array tables loop
      begin
        execute format('set local role %I', r);
        execute format('select 1 from lite.%I limit 1', t);
        raise exception '% could read lite.%', r, t;
      exception when insufficient_privilege then null;
      end;
      execute 'reset role';
      begin
        execute format('set local role %I', r);
        execute format('insert into lite.%I default values', t);
        raise exception '% could write lite.%', r, t;
      exception when insufficient_privilege then null;
      end;
      execute 'reset role';
    end loop;
  end loop;
  foreach t in array tables loop
    if not (select relrowsecurity from pg_class where oid = format('lite.%I', t)::regclass) then
      raise exception 'RLS is off on lite.%', t;
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'lite' and tablename = t and policyname = 'lite_api_all') then
      raise exception 'lite.% has no lite_api policy', t;
    end if;
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'lite' and has_function_privilege('public', p.oid, 'execute')) then
    raise exception 'PUBLIC can execute a lite function';
  end if;
  raise notice 'ok: the v2 tables are closed to anon and authenticated, RLS on, no lite function is PUBLIC''s';
end $$;

-- 2. As lite_api, the role the functions use: v1 and v2 rows side by side.
set local role lite_api;
do $$
declare
  -- v_: none of them may share a column's name (PL/pgSQL can't tell `nft` the variable from lite.moments.nft).
  v_old text := 'C' || repeat('A', 55);
  v_new text := 'C' || repeat('B', 55);
  v_nft text := 'C' || repeat('N', 55);
  v_nft2 text := 'C' || repeat('M', 55);
  v_pad text := 'C' || repeat('P', 55);
  v_token text := 'C' || repeat('T', 55);
  v_creator text := 'G' || repeat('C', 55);
  n int;
begin
  -- A v1 Moment numbered 1 (in the v1 Moments contract v_old) and v2 Moments (in v_new), which have no number of their
  -- own, coexist.
  insert into lite.moments (id, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger)
  values (1, 1, v_old, v_creator, 'u1', 1, 'CQ', 10, now() + interval '1 day', 1);
  insert into lite.moments (id, nft, generation, contract, nonce, number, creator, uri, price, quote, max_editions, deadline,
                            created_ledger, state, durations)
  values (null, v_nft, 2, v_new, 18446744073709551615, 1, v_creator, 'u2', 1, 'CQ', 0, now() + interval '1 day', 2,
          'collecting', '{"vest_period": 600}');
  insert into lite.moments (id, nft, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger, state)
  values (null, v_nft2, 2, v_new, v_creator, 'u3', 1, 'CQ', 0, now() + interval '1 day', 3, 'collecting');
  select count(*) into n from lite.moments where contract in (v_old, v_new);
  if n <> 3 then raise exception 'expected 3 Moments, got %', n; end if;
  -- v1's handler inserts with ON CONFLICT (id): the unique constraint is its arbiter, and a v2 row never conflicts.
  insert into lite.moments (id, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger)
  values (1, 1, v_old, v_creator, 'again', 1, 'CQ', 10, now(), 9) on conflict (id) do nothing;
  if (select uri from lite.moments where id = 1) <> 'u1' then raise exception 'ON CONFLICT (id) did not hold the v1 row'; end if;
  insert into lite.moments (id, nft, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger)
  values (null, v_nft, 2, v_new, v_creator, 'again', 1, 'CQ', 0, now(), 9) on conflict (nft) do nothing;
  if (select uri from lite.moments where nft = v_nft) <> 'u2' then raise exception 'ON CONFLICT (nft) did not hold the v2 row'; end if;
  -- Collects and editions of each: v1's by number, v2's by NFT address (the edition's own collection).
  insert into lite.moment_collects (event_id, moment_id, collector, quantity, first_token_id, paid, ledger, ts)
  values ('c1', 1, v_creator, 1, 1, 1, 1, now());
  insert into lite.moment_collects (event_id, moment_id, nft, collector, quantity, first_token_id, paid, ledger, ts)
  values ('c2', null, v_nft, v_creator, 2, 1, 2, 2, now());
  insert into lite.moment_editions (contract, token_id, moment_id, owner, owner_event, updated_ledger)
  values (v_old, 1, 1, v_creator, 'c1', 1), (v_nft, 1, null, v_creator, 'c2', 2), (v_nft, 2, null, v_creator, 'c2', 2);
  -- A v1 Moment's rows still go with it; a v2 Moment's stay.
  delete from lite.moments where id = 1;
  select count(*) into n from lite.moment_collects where moment_id = 1;
  if n <> 0 then raise exception 'a v1 collect outlived its Moment'; end if;
  select count(*) into n from lite.moment_collects where nft = v_nft;
  if n <> 1 then raise exception 'the v2 collect went with a v1 Moment'; end if;

  -- A v1 launch with its index and a v2 launch with its nonce and phase, keyed by token alike.
  insert into lite.launches (token, creator, quote, name, symbol, launch_index, supply, phantom, threshold, quote_reserve,
                             token_reserve, created_ledger)
  values ('C' || repeat('V', 55), v_creator, 'CQ', 'One', 'ONE', 0, 1, 1, 1, 1, 1, 1);
  insert into lite.launches (token, creator, quote, name, symbol, launch_index, supply, phantom, threshold, quote_reserve,
                             token_reserve, created_ledger, generation, contract, nonce, venue, fallback_venue, venue_locked,
                             holder_sharing, recipient, launch_fee, phase)
  values (v_token, v_creator, 'CQ', 'Two', 'TWO', null, 1, 1, 1, 1, 1, 2, 2, v_pad, 7, 0, 0, false, true, v_creator, 100000000, 'curve');
  select count(*) into n from lite.launches where generation = 2 and contract = v_pad and nonce = 7;
  if n <> 1 then raise exception 'the v2 launch is missing'; end if;

  -- The new tables take what the indexer and the keeper write.
  insert into lite.v2_events (event_id, contract, kind, subject, topics, data, ledger, ts)
  values ('e1', v_pad, 'grad_fail', v_token, '["grad_fail"]', '{"origin": 4, "code": 10404}', 2, now());
  insert into lite.launch_rewards (token, asset, funded, released, updated_ledger) values (v_token, 'CQ', 5, 5, 2), (v_token, v_token, 7, 0, 2);
  insert into lite.reward_releases (event_id, token, asset, kind, amount, ledger, ts) values ('r1', v_token, v_token, 'released', 7, 2, now());
  insert into lite.locker_positions (pool, locker, owner, kind, lp_token, lp, base, quote, ref_kind, ref, harvest_bps, principal,
                                     registered_ledger, registered_at)
  values ('C' || repeat('L', 55), 'CLOCK', v_pad, 'Soroswap', 'C' || repeat('L', 55), 10, v_token, 'CQ', 'launch', v_token, 10000, 10, 2, now());
  insert into lite.harvests (event_id, pool, lp_burned, base_out, quote_out, growth, take, compounded, principal, ledger, ts)
  values ('h1', 'C' || repeat('L', 55), 1, 1, 1, 1, 1, 0, 10, 3, now());
  insert into lite.refunds (event_id, token, holder, tokens_in, quote_out, ledger, ts) values ('f1', v_token, v_creator, 10, 1, 3, now());
  insert into lite.creator_owed (contract, account, asset, owed, credited, updated_ledger) values (v_pad, v_creator, 'CQ', 5, 5, 3);
  insert into lite.moment_positions (nft, account, editions, gross, entitlement, updated_ledger) values (v_nft, v_creator, 2, 2, 100, 2);
  insert into lite.moment_withdrawals (event_id, nft, role, to_address, amount, ledger, ts) values ('w1', v_nft, 'creator', v_creator, 1, 3, now());
  insert into lite.vesting_claims (event_id, nft, account, collector_amount, creator_amount, ledger, ts) values ('v1', v_nft, v_creator, 60, 0, 4, now());
  insert into lite.moment_coin_balances (coin, address, balance, updated_ledger) values ('C' || repeat('K', 55), v_creator, 60, 4);
  insert into lite.pool_candidates (pool, token, other, kind, discovered_event, discovered_ledger) values ('C' || repeat('Q', 55), v_token, 'CQ', 'soroswap', 'e2', 3);
  -- A pool of two sharing launches is a candidate of each.
  insert into lite.pool_candidates (pool, token, other, kind, discovered_event, discovered_ledger) values ('C' || repeat('Q', 55), 'CQ', v_token, 'soroswap', 'e2', 3);
  insert into lite.keeper_alerts (kind, target, key) values ('payment_failure', v_token, 'e1');
  insert into lite.keeper_alerts (kind, target, key) values ('payment_failure', v_token, 'e1') on conflict do nothing;
  insert into lite.keeper_skip (kind, target, jobs, until, note)
  values ('launch', v_token, array['fallback', 'rescue'], now() + interval '1 hour', 'rescue journey'),
         ('moment', v_nft, array['graduate', 'expire'], null, 'held pending');
  insert into lite.watch_v2_groups (start_ledger) values (2);
  insert into lite.watch_v2_contracts (contract, role, ref, from_ledger) values (v_token, 'launch_token', v_token, 2), (v_nft, 'nft', v_nft, 2);
  insert into lite.keeper_log (hash, job, keeper, max_fee, detail)
  values (repeat('a', 64), 'exclude_treasury', 'G' || repeat('K', 55), 100, jsonb_build_object('target', v_token));
  raise notice 'ok: v1 and v2 Moments and launches coexist; lite_api writes the v2 tables';
end $$;

-- 3. The checks keep out what the indexer and the keeper never write.
do $$
declare
  bad text[] := array[
    -- a v2 Moment without its NFT address, or with a number of v1's
    $q$insert into lite.moments (id, nft, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger) values (null, null, 2, 'CX', 'G', 'u', 1, 'CQ', 0, now(), 1)$q$,
    $q$insert into lite.moments (id, nft, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger) values (5, 'CNEW', 2, 'CX', 'G', 'u', 1, 'CQ', 0, now(), 1)$q$,
    -- a v1 Moment without its number, a third generation, an unknown state
    $q$insert into lite.moments (id, generation, creator, uri, price, quote, max_editions, deadline, created_ledger) values (null, 1, 'G', 'u', 1, 'CQ', 0, now(), 1)$q$,
    $q$insert into lite.moments (id, generation, creator, uri, price, quote, max_editions, deadline, created_ledger) values (9, 3, 'G', 'u', 1, 'CQ', 0, now(), 1)$q$,
    $q$insert into lite.moments (id, nft, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger, state) values (null, 'CNEW2', 2, 'CX', 'G', 'u', 1, 'CQ', 0, now(), 1, 'stuck')$q$,
    -- a second v2 Moment at the same NFT address
    $q$insert into lite.moments (id, nft, generation, contract, creator, uri, price, quote, max_editions, deadline, created_ledger) values (null, 'C' || repeat('N', 55), 2, 'CX', 'G', 'u', 1, 'CQ', 0, now(), 1)$q$,
    -- a collect keyed by both, or by neither
    $q$insert into lite.moment_collects (event_id, moment_id, nft, collector, quantity, first_token_id, paid, ledger, ts) values ('x1', null, null, 'G', 1, 1, 1, 1, now())$q$,
    -- a v1 launch without its index, a v2 launch without its phase or nonce, an unknown phase
    $q$insert into lite.launches (token, creator, quote, name, symbol, launch_index, supply, phantom, threshold, quote_reserve, token_reserve, created_ledger) values ('CX1', 'G', 'CQ', 'n', 's', null, 1, 1, 1, 1, 1, 1)$q$,
    $q$insert into lite.launches (token, creator, quote, name, symbol, supply, phantom, threshold, quote_reserve, token_reserve, created_ledger, generation, nonce) values ('CX2', 'G', 'CQ', 'n', 's', 1, 1, 1, 1, 1, 1, 2, 1)$q$,
    $q$insert into lite.launches (token, creator, quote, name, symbol, supply, phantom, threshold, quote_reserve, token_reserve, created_ledger, generation, phase) values ('CX3', 'G', 'CQ', 'n', 's', 1, 1, 1, 1, 1, 1, 2, 'curve')$q$,
    $q$insert into lite.launches (token, creator, quote, name, symbol, supply, phantom, threshold, quote_reserve, token_reserve, created_ledger, generation, nonce, phase) values ('CX4', 'G', 'CQ', 'n', 's', 1, 1, 1, 1, 1, 1, 2, 1, 'stuck')$q$,
    -- keeper_skip: a job outside the six, no job, another kind, a target that isn't a contract
    $q$insert into lite.keeper_skip (kind, target, jobs) values ('launch', 'C' || repeat('T', 55), array['exclude_pool'])$q$,
    $q$insert into lite.keeper_skip (kind, target, jobs) values ('launch', 'C' || repeat('T', 55), array[]::text[])$q$,
    $q$insert into lite.keeper_skip (kind, target, jobs) values ('pool', 'C' || repeat('T', 55), array['harvest'])$q$,
    $q$insert into lite.keeper_skip (kind, target, jobs) values ('moment', 'G' || repeat('T', 55), array['expire'])$q$,
    -- keeper_log: a job nobody runs
    $q$insert into lite.keeper_log (hash, job, keeper, max_fee) values (repeat('b', 64), 'withdraw', 'G' || repeat('K', 55), 1)$q$,
    -- a reward release of another kind, a candidate in another status, a locker position of another reference
    $q$insert into lite.reward_releases (event_id, token, asset, kind, amount, ledger, ts) values ('r9', 'CT', 'CQ', 'paid', 1, 1, now())$q$,
    $q$insert into lite.pool_candidates (pool, token, other, kind, status, discovered_event, discovered_ledger) values ('CP9', 'CT', 'CQ', 'soroswap', 'maybe', 'e', 1)$q$,
    -- the same pool twice for one launch
    $q$insert into lite.pool_candidates (pool, token, other, kind, discovered_event, discovered_ledger) values ('C' || repeat('Q', 55), 'C' || repeat('T', 55), 'CQ', 'soroswap', 'e9', 1)$q$,
    $q$insert into lite.locker_positions (pool, locker, owner, kind, lp_token, lp, base, quote, ref_kind, ref, harvest_bps, principal, registered_ledger, registered_at) values ('CP8', 'CL', 'CO', 'Soroswap', 'CP8', 1, 'CB', 'CQ', 'pool', 'CR', 10000, 1, 1, now())$q$
  ];
  q text;
begin
  foreach q in array bad loop
    begin
      execute q;
      raise exception 'accepted: %', q;
    exception when check_violation or not_null_violation or unique_violation then null;
    end;
  end loop;
  -- Every v2 job name keeper_log takes.
  insert into lite.keeper_log (hash, job, keeper, max_fee)
  select md5(j) || md5(j), j, 'G' || repeat('K', 55), 1
    from unnest(array['graduate', 'graduate_fallback', 'mark_stuck', 'rescue', 'expire', 'harvest', 'claim_protocol_fees',
                      'sweep_protocol', 'exclude_treasury', 'exclude_pool', 'ttl', 'relay']) as j;
  raise notice 'ok: the keys and checks refuse what the indexer never writes; keeper_log takes the v2 jobs';
end $$;

-- 4. The testnet reset's truncate (lite-indexer/jobs/reset.ts, then v2_events.ts V2_INDEXED_TABLES) clears them, as
--    lite_api: no foreign key from a v2 table holds up launches or moments.
do $$
declare n int;
begin
  truncate lite.launch_trades, lite.launches, lite.moment_collects, lite.moments, lite.pool_swaps, lite.creator_claims,
    lite.token_events, lite.token_balances, lite.watch_contracts, lite.watch_groups, lite.moment_editions, lite.indexer_cursors;
  truncate lite.v2_events, lite.launch_rewards, lite.reward_releases, lite.locker_positions, lite.harvests, lite.refunds,
    lite.creator_owed, lite.moment_positions, lite.moment_withdrawals, lite.vesting_claims, lite.moment_coin_balances,
    lite.pool_candidates, lite.keeper_alerts, lite.watch_v2_contracts, lite.watch_v2_groups;
  select (select count(*) from lite.moments) + (select count(*) from lite.launches) + (select count(*) from lite.launch_rewards)
    into n;
  if n <> 0 then raise exception 'the reset left % rows', n; end if;
  -- keeper_skip is the e2e's, not indexed: the reset keeps it.
  select count(*) into n from lite.keeper_skip;
  if n <> 2 then raise exception 'keeper_skip has % rows', n; end if;
  raise notice 'ok: the testnet reset clears the v1 and v2 tables, as lite_api';
end $$;
reset role;

rollback;
