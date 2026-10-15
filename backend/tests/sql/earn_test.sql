-- Earn's rate history (migration 20261014000008; docs/DESIGN-stellar-parity.md §6.10, §12.2): anon and authenticated
-- can't reach lite.earn_snapshots, lite_api can, and RLS is on; the checks keep out what Blend never reports (a rate
-- that isn't a number, a utilization above 1, an address that isn't a contract); as lite_api, the earn job's insert
-- (one snapshot per market per run), history's range read and the job's deletion of old snapshots, and positions' read
-- of an account's successful earn transactions. One transaction, rolled back.
begin;

-- 1. anon and authenticated can neither read nor write the table; RLS is on, with lite_api's policy.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    begin
      execute format('set local role %I', r);
      perform 1 from lite.earn_snapshots limit 1;
      raise exception '% could read lite.earn_snapshots', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
    begin
      execute format('set local role %I', r);
      insert into lite.earn_snapshots (pool, asset, taken_at, supply_apy, utilization, supplied, borrowed, pool_status)
      values ('CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF', 'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC', now(), 0.03, 0.6, 1, 0, 0);
      raise exception '% could write lite.earn_snapshots', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
  end loop;
  if (select not relrowsecurity from pg_class where oid = 'lite.earn_snapshots'::regclass) then
    raise exception 'RLS is off on lite.earn_snapshots';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'lite' and tablename = 'earn_snapshots' and policyname = 'lite_api_all') then
    raise exception 'lite.earn_snapshots has no lite_api policy';
  end if;
  raise notice 'ok: anon and authenticated are refused';
end $$;

-- 2. What Blend never reports is refused: a rate that isn't a number or is negative, a utilization above 1, a pool or an
--    asset that isn't a contract, a negative status.
do $$
declare
  c_pool constant text := 'CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF';
  c_xlm constant text := 'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';
  v record;
begin
  for v in
    select * from (values
      ('a NaN supply APY', 'NaN'::numeric, 0.05::numeric, 0.6::numeric, c_pool, c_xlm, 0),
      ('an infinite supply APY', 'Infinity'::numeric, 0.05::numeric, 0.6::numeric, c_pool, c_xlm, 0),
      ('a negative supply APY', -0.01::numeric, 0.05::numeric, 0.6::numeric, c_pool, c_xlm, 0),
      ('a NaN borrow APY', 0.03::numeric, 'NaN'::numeric, 0.6::numeric, c_pool, c_xlm, 0),
      ('a utilization above 1', 0.03::numeric, 0.05::numeric, 1.01::numeric, c_pool, c_xlm, 0),
      ('a NaN utilization', 0.03::numeric, 0.05::numeric, 'NaN'::numeric, c_pool, c_xlm, 0),
      ('an account as the pool', 0.03::numeric, 0.05::numeric, 0.6::numeric, 'GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ', c_xlm, 0),
      ('an asset named by its code', 0.03::numeric, 0.05::numeric, 0.6::numeric, c_pool, 'XLM', 0),
      ('a negative pool status', 0.03::numeric, 0.05::numeric, 0.6::numeric, c_pool, c_xlm, -1)
    ) as bad(what, supply_apy, borrow_apy, utilization, pool, asset, status)
  loop
    begin
      insert into lite.earn_snapshots (pool, asset, taken_at, supply_apy, borrow_apy, utilization, supplied, borrowed, pool_status)
      values (v.pool, v.asset, now(), v.supply_apy, v.borrow_apy, v.utilization, 1, 0, v.status);
      raise exception '% was stored', v.what;
    exception when check_violation then null;
    end;
  end loop;
  raise notice 'ok: checks';
end $$;

-- 3. As lite_api: the earn job's insert (a second one at the same time adds nothing), history's read of one market's
--    range, oldest first, the job's deletion of snapshots older than 400 days, and positions' read of an account's
--    successful earn transactions.
do $$
declare
  c_pool constant text := 'CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF';
  c_xlm constant text := 'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';
  c_busdc constant text := 'CAQCFVLOBK5GIULPNZRGATJJMIZL5BSP7X5YJVMGCPTUEPFM4AVSRCJU';
  c_user constant text := 'GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ';
  c_now constant timestamptz := timestamptz '2026-10-14 09:41:00+00';
  n int;
  times timestamptz[];
  kinds text[];
begin
  execute 'set local role lite_api';
  -- Two markets every 10 minutes for 31 days, and one snapshot 401 days old.
  insert into lite.earn_snapshots (pool, asset, taken_at, supply_apy, borrow_apy, utilization, supplied, borrowed, pool_status)
  select c_pool, m.asset, t.at, 0.031, 0.054, 0.61, 182345671200000, 111230859432000, 0
    from unnest(array[c_xlm, c_busdc]) as m(asset)
   cross join generate_series(c_now - interval '31 days', c_now, interval '10 minutes') as t(at);
  insert into lite.earn_snapshots (pool, asset, taken_at, supply_apy, borrow_apy, utilization, supplied, borrowed, pool_status)
  values (c_pool, c_xlm, c_now - interval '401 days', 0.02, null, 0.4, 1, 0, 1);

  -- jobs/earn.ts's insert (earn.ts snapshot()): one snapshot per market per run.
  insert into lite.earn_snapshots (pool, asset, taken_at, supply_apy, borrow_apy, utilization, supplied, borrowed, pool_status)
  values (c_pool, c_xlm, c_now, '0.04'::numeric, '0.07'::numeric, '0.7'::numeric, '1'::numeric, '0'::numeric, '0'::smallint)
  on conflict (pool, asset, taken_at) do nothing;
  if (select s.supply_apy from lite.earn_snapshots s where s.pool = c_pool and s.asset = c_xlm and s.taken_at = c_now) <> 0.031 then
    raise exception 'a second snapshot at the same time replaced the first';
  end if;

  -- earn.ts history(): one market, after the range's start, oldest first.
  select array_agg(h.taken_at order by h.taken_at) into times
    from (select s.taken_at, s.supply_apy, s.utilization from lite.earn_snapshots s
           where s.pool = c_pool and s.asset = c_xlm and s.taken_at > c_now - interval '7 days'
           order by s.taken_at) as h;
  if array_length(times, 1) <> 7 * 144 then raise exception 'a week holds % snapshots, expected %', array_length(times, 1), 7 * 144; end if;
  if times[1] <> c_now - interval '7 days' + interval '10 minutes' or times[array_length(times, 1)] <> c_now then
    raise exception 'the week runs from % to %', times[1], times[array_length(times, 1)];
  end if;

  -- jobs/earn.ts's deletion: snapshots older than 400 days.
  delete from lite.earn_snapshots s where s.taken_at < c_now - interval '400 days';
  select count(*) into n from lite.earn_snapshots s where s.taken_at < c_now - interval '400 days';
  if n <> 0 then raise exception '% snapshots older than 400 days are left', n; end if;
  select count(*) into n from lite.earn_snapshots;
  if n <> 2 * (31 * 144 + 1) then raise exception '% snapshots are left, expected %', n, 2 * (31 * 144 + 1); end if;

  -- earn.ts positions(): the account's successful earn transactions, with their intents; failed, pending and other
  -- transactions are left out.
  insert into lite.tx_log (hash, inner_hash, address, kind, intent, status, max_fee) values
    ('e1', 'e1', c_user, 'earn_deposit', jsonb_build_object('kind', 'earn_deposit', 'spend', jsonb_build_object(c_xlm, '1000000000'),
       'calls', jsonb_build_array(jsonb_build_object('contract', c_pool, 'fn', 'submit'))), 'success', 1000),
    ('e2', 'e2', c_user, 'earn_withdraw', jsonb_build_object('kind', 'earn_withdraw', 'spend', '{}'::jsonb, 'receive', jsonb_build_object(c_xlm, '400000000'),
       'calls', jsonb_build_array(jsonb_build_object('contract', c_pool, 'fn', 'submit'))), 'success', 1000),
    ('e3', 'e3', c_user, 'earn_deposit', '{}'::jsonb, 'failed', 1000),
    ('e4', 'e4', c_user, 'earn_deposit', '{}'::jsonb, 'pending', 1000),
    ('e5', 'e5', c_user, 'swap', '{}'::jsonb, 'success', 1000);
  select array_agg(p.kind order by p.kind) into kinds
    from (select t.kind, t.intent from lite.tx_log t
           where t.address = c_user and t.kind in ('earn_deposit', 'earn_withdraw') and t.status = 'success') as p;
  if kinds is distinct from array['earn_deposit', 'earn_withdraw'] then raise exception 'positions read %', kinds; end if;
  execute 'reset role';
  raise notice 'ok: lite_api snapshots, reads a week, deletes after 400 days, and reads the earn transactions';
end $$;

rollback;
