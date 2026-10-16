-- Hybrid fees in the database (migration 20261014000005; docs/DESIGN-stellar-parity.md §4.3, §6.15): what DyorHQ may
-- sponsor (lite.reserve_sponsorship): once per address and kind, a released one retried, at most p_max_attempts
-- attempts, the daily count and fee caps per kind and the daily cap per hashed IP; the tx_log columns for fees; the
-- per-user budget gone; and access: lite_api runs it all, anon and authenticated reach none of it.
-- One transaction, rolled back.
begin;

-- 1. Once per address and kind; the read-only check agrees with the reservation and inserts nothing.
do $$
declare r record; a constant text := 'G' || repeat('A', 55); ip constant text := repeat('a', 64);
begin
  execute 'set local role lite_api';
  -- limits: 3 attempts, 10 a day, 1,000 stroops a day, 10 per IP
  if lite.sponsorship_refusal(a, 'activate', ip, 100, 3, 10, 1000, 10) is not null then raise exception 'a first activation refused'; end if;
  if exists (select 1 from lite.sponsorships) then raise exception 'the read-only check inserted a row'; end if;
  select * into r from lite.reserve_sponsorship(a, 'activate', ip, 100, 3, 10, 1000, 10);
  if r.id is null or r.refusal is not null then raise exception 'first activation: %', r.refusal; end if;
  if (select status from lite.sponsorships where id = r.id) <> 'reserved' then raise exception 'a new sponsorship is not reserved'; end if;
  select * into r from lite.reserve_sponsorship(a, 'activate', ip, 100, 3, 10, 1000, 10);
  if r.id is not null or r.refusal is distinct from 'once' then raise exception 'second activation: % %', r.id, r.refusal; end if;
  if lite.sponsorship_refusal(a, 'activate', ip, 100, 3, 10, 1000, 10) is distinct from 'once' then raise exception 'the check missed once'; end if;
  -- Sent and successful ones count as used too.
  update lite.sponsorships set status = 'success', tx_hash = repeat('1', 64), fee_charged = 300 where address = a;
  select * into r from lite.reserve_sponsorship(a, 'activate', ip, 100, 3, 10, 1000, 10);
  if r.refusal is distinct from 'once' then raise exception 'activation after a success: %', r.refusal; end if;
  -- The other kind is a sponsorship of its own.
  select * into r from lite.reserve_sponsorship(a, 'starter', ip, 100, 3, 10, 1000, 10);
  if r.id is null then raise exception 'the starter after an activation: %', r.refusal; end if;
  -- Two reserved rows of one address and kind can't exist, whatever calls the insert.
  begin
    insert into lite.sponsorships (address, kind, ip_hash, fee_reserved) values (a, 'starter', ip, 1);
    raise exception 'a second reserved starter was stored';
  exception when unique_violation then null;
  end;
  execute 'reset role';
  delete from lite.sponsorships;
  raise notice 'ok: once per address and kind';
end $$;

-- 2. A released sponsorship (nothing reached the network) or a failed one (it did, and failed) frees the address for a
--    retry; every try is an attempt, and the attempt cap refuses the next one. Attempts are per address.
do $$
declare r record; a constant text := 'G' || repeat('B', 55); ip constant text := repeat('b', 64);
begin
  execute 'set local role lite_api';
  for i in 1..3 loop
    select * into r from lite.reserve_sponsorship(a, 'starter', ip, 100, 3, 10, 1000, 10);
    if r.id is null then raise exception 'attempt %: %', i, r.refusal; end if;
    update lite.sponsorships set status = case when i = 2 then 'failed' else 'released' end where id = r.id;
  end loop;
  if (select count(*) from lite.sponsorships where address = a) <> 3 then raise exception 'each attempt is a row'; end if;
  select * into r from lite.reserve_sponsorship(a, 'starter', ip, 100, 3, 10, 1000, 10);
  if r.id is not null or r.refusal is distinct from 'attempts' then raise exception 'a fourth attempt: % %', r.id, r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('C', 55), 'starter', ip, 100, 3, 10, 1000, 10);
  if r.id is null then raise exception 'another address: %', r.refusal; end if;
  execute 'reset role';
  delete from lite.sponsorships;
  raise notice 'ok: released retry and attempts';
end $$;

-- 3. The daily count per kind: today's reserved, sent, successful and failed ones count; released ones and the other
--    kind don't; yesterday's don't.
do $$
declare r record; ip constant text := repeat('c', 64);
begin
  execute 'set local role lite_api';
  -- limit: 2 a day
  select * into r from lite.reserve_sponsorship('G' || repeat('D', 55), 'activate', ip, 1, 3, 2, 1000, 10);
  if r.id is null then raise exception 'first of the day: %', r.refusal; end if;
  update lite.sponsorships set status = 'failed' where id = r.id;
  select * into r from lite.reserve_sponsorship('G' || repeat('E', 55), 'activate', ip, 1, 3, 2, 1000, 10);
  if r.id is null then raise exception 'second of the day: %', r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('F', 55), 'activate', ip, 1, 3, 2, 1000, 10);
  if r.refusal is distinct from 'daily_count' then raise exception 'third of the day: %', r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('F', 55), 'starter', ip, 1, 3, 2, 1000, 10);
  if r.id is null then raise exception 'the other kind: %', r.refusal; end if;
  update lite.sponsorships set status = 'released' where address = 'G' || repeat('E', 55);
  select * into r from lite.reserve_sponsorship('G' || repeat('F', 55), 'activate', ip, 1, 3, 2, 1000, 10);
  if r.id is null then raise exception 'after a release: %', r.refusal; end if;
  update lite.sponsorships set day = day - 1 where kind = 'activate';
  select * into r from lite.reserve_sponsorship('G' || repeat('G', 55), 'activate', ip, 1, 3, 2, 1000, 10);
  if r.id is null then raise exception 'a new day: %', r.refusal; end if;
  execute 'reset role';
  delete from lite.sponsorships;
  raise notice 'ok: daily count';
end $$;

-- 4. The daily fee cap per kind: reserved fees count until settled, then the fee charged does; released ones don't.
do $$
declare r record; ip constant text := repeat('d', 64);
begin
  execute 'set local role lite_api';
  -- limit: 1,000 stroops a day
  select * into r from lite.reserve_sponsorship('G' || repeat('H', 55), 'starter', ip, 600, 3, 10, 1000, 10);
  if r.id is null then raise exception '600 of 1,000: %', r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('I', 55), 'starter', ip, 500, 3, 10, 1000, 10);
  if r.refusal is distinct from 'daily_fee' then raise exception '600 + 500 of 1,000: %', r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('I', 55), 'starter', ip, 400, 3, 10, 1000, 10);
  if r.id is null then raise exception '600 + 400 of 1,000: %', r.refusal; end if;
  -- Settled at 100 instead of 600: 500 is free again.
  update lite.sponsorships set status = 'success', fee_charged = 100 where address = 'G' || repeat('H', 55);
  select * into r from lite.reserve_sponsorship('G' || repeat('J', 55), 'starter', ip, 500, 3, 10, 1000, 10);
  if r.id is null then raise exception '100 + 400 + 500 of 1,000: %', r.refusal; end if;
  update lite.sponsorships set status = 'released' where address = 'G' || repeat('J', 55);
  select * into r from lite.reserve_sponsorship('G' || repeat('K', 55), 'starter', ip, 500, 3, 10, 1000, 10);
  if r.id is null then raise exception 'after a release: %', r.refusal; end if;
  -- The cap is per kind.
  select * into r from lite.reserve_sponsorship('G' || repeat('K', 55), 'activate', ip, 900, 3, 10, 1000, 10);
  if r.id is null then raise exception 'the other kind: %', r.refusal; end if;
  execute 'reset role';
  delete from lite.sponsorships;
  raise notice 'ok: daily fee';
end $$;

-- 5. The daily cap per hashed IP, across kinds; another IP is unaffected.
do $$
declare r record; x constant text := repeat('e', 64); y constant text := repeat('f', 64);
begin
  execute 'set local role lite_api';
  -- limit: 2 per IP a day
  select * into r from lite.reserve_sponsorship('G' || repeat('L', 55), 'activate', x, 1, 3, 10, 1000, 2);
  if r.id is null then raise exception 'first from x: %', r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('M', 55), 'starter', x, 1, 3, 10, 1000, 2);
  if r.id is null then raise exception 'second from x: %', r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('N', 55), 'activate', x, 1, 3, 10, 1000, 2);
  if r.refusal is distinct from 'ip' then raise exception 'third from x: %', r.refusal; end if;
  select * into r from lite.reserve_sponsorship('G' || repeat('N', 55), 'activate', y, 1, 3, 10, 1000, 2);
  if r.id is null then raise exception 'first from y: %', r.refusal; end if;
  -- Raw IPs never fit the column.
  begin
    insert into lite.sponsorships (address, kind, ip_hash, fee_reserved) values ('G' || repeat('O', 55), 'starter', '203.0.113.7', 1);
    raise exception 'a raw IP was stored';
  exception when check_violation then null;
  end;
  execute 'reset role';
  delete from lite.sponsorships;
  raise notice 'ok: IP';
end $$;

-- 6. tx_log carries who paid, the step kind, the section and the outcome; the per-user budget is gone.
do $$
declare payer text;
begin
  execute 'set local role lite_api';
  insert into lite.tx_log (hash, inner_hash, address, kind, max_fee, step_kind, section, result)
  values (repeat('2', 64), repeat('2', 64), 'G' || repeat('P', 55), 'swap', 153400, 'swap_soroswap', 'spot', '{"amountOut": "1903400"}');
  select fee_payer into payer from lite.tx_log where hash = repeat('2', 64);
  if payer <> 'user' then raise exception 'a new row is paid by %, not the user', payer; end if;
  begin
    update lite.tx_log set fee_payer = 'nobody' where hash = repeat('2', 64);
    raise exception 'fee_payer took nobody';
  exception when check_violation then null;
  end;
  begin
    update lite.tx_log set section = 'casino' where hash = repeat('2', 64);
    raise exception 'section took casino';
  exception when check_violation then null;
  end;
  execute 'reset role';
  if to_regclass('lite.sponsor_usage') is not null then raise exception 'lite.sponsor_usage is still there'; end if;
  if to_regprocedure('lite.reserve_fee_budget(text, bigint, bigint)') is not null then raise exception 'lite.reserve_fee_budget is still there'; end if;
  if not exists (select 1 from pg_indexes where schemaname = 'lite' and indexname = 'tx_log_step_kind') then
    raise exception 'tx_log needs its step-kind index';
  end if;
  raise notice 'ok: tx_log fee columns';
end $$;

-- 7. lite_api writes the keeper's log, the job runs and the rent rotation; anon and authenticated reach none of the new
--    tables or functions; RLS is on everywhere.
do $$
declare r text;
begin
  execute 'set local role lite_api';
  insert into lite.keeper_log (hash, job, keeper, max_fee) values (repeat('3', 64), 'ttl', 'G' || repeat('Q', 55), 400);
  insert into lite.job_runs (job, started_at, ms, ok, result) values ('ops', now(), 12, true, '{}');
  insert into lite.ttl_checks (key, label, live_until) values ('AAAA', 'instance launchpad', 1);
  execute 'reset role';
  foreach r in array array['anon', 'authenticated'] loop
    begin
      execute format('set local role %I', r);
      perform 1 from lite.sponsorships limit 1;
      raise exception '% could read lite.sponsorships', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
    begin
      execute format('set local role %I', r);
      perform lite.reserve_sponsorship('G' || repeat('R', 55), 'starter', repeat('9', 64), 1, 3, 10, 1000, 10);
      raise exception '% could reserve a sponsorship', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
    begin
      execute format('set local role %I', r);
      perform lite.sponsorship_refusal('G' || repeat('R', 55), 'starter', repeat('9', 64), 1, 3, 10, 1000, 10);
      raise exception '% could check a sponsorship', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
  end loop;
  if exists (select 1 from pg_tables where schemaname = 'lite' and not rowsecurity) then
    raise exception 'a lite table has RLS off';
  end if;
  raise notice 'ok: lite_api only';
end $$;

rollback;
