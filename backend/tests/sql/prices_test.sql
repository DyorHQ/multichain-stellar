-- Reference prices and the asset directory (migration 20261014000006; docs/DESIGN-stellar-parity.md §6.6, §6.12,
-- §12.2): anon and authenticated can't reach the tables or ref_usd_at, lite_api can; the checks keep out what no
-- provider sends (a price of 0, a bucket off its interval's grid, an image that isn't https); ref_usd_at answers the
-- close of the candle covering a time, the smallest interval first, and null when none covers it, by lookup rather
-- than by scanning a full history; the job's upserts (a quote never replaces a newer one, and the job learns whether
-- it was written) and purge's deletes run as lite_api. One transaction, rolled back.
begin;

-- 1. anon and authenticated can neither read nor write the tables, nor call ref_usd_at; RLS is on.
do $$
declare r text; t text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach t in array array['ref_quotes', 'ref_candles', 'asset_directory'] loop
      begin
        execute format('set local role %I', r);
        execute format('select 1 from lite.%I limit 1', t);
        raise exception '% could read lite.%', r, t;
      exception when insufficient_privilege then null;
      end;
      execute 'reset role';
    end loop;
    begin
      execute format('set local role %I', r);
      insert into lite.ref_quotes (ref, usd, source, market, quoted_at) values ('XLM', 0.19, 'kraken', 'Kraken XLM/USD', now());
      raise exception '% could write lite.ref_quotes', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
    begin
      execute format('set local role %I', r);
      perform lite.ref_usd_at('XLM', now());
      raise exception '% could call lite.ref_usd_at', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
  end loop;
  if exists (select 1 from pg_class where oid in ('lite.ref_quotes'::regclass, 'lite.ref_candles'::regclass, 'lite.asset_directory'::regclass) and not relrowsecurity) then
    raise exception 'RLS is off on a prices table';
  end if;
  if has_function_privilege('public', 'lite.ref_usd_at(text, timestamptz)', 'execute') then
    raise exception 'PUBLIC can execute lite.ref_usd_at';
  end if;
  raise notice 'ok: anon and authenticated are refused';
end $$;

-- 2. What no provider sends is refused: a price of 0, a bucket off its grid, an unknown interval, an http image.
do $$
begin
  begin
    insert into lite.ref_quotes (ref, usd, source, market, quoted_at) values ('XLM', 0, 'kraken', 'Kraken XLM/USD', now());
    raise exception 'a quote of 0 was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.ref_quotes (ref, usd, source, market, quoted_at) values ('XLM', 0.19, 'constant', 'Kraken XLM/USD', now());
    raise exception 'a quote from no provider was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.ref_candles (ref, interval_s, bucket, open, high, low, close, source)
    values ('XLM', 900, timestamptz '2026-10-14 10:20:00+00', 1, 1, 1, 1, 'kraken');
    raise exception 'a 15-minute candle off the grid was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.ref_candles (ref, interval_s, bucket, open, high, low, close, source)
    values ('XLM', 300, timestamptz '2026-10-14 10:20:00+00', 1, 1, 1, 1, 'kraken');
    raise exception 'a 5-minute candle was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.ref_candles (ref, interval_s, bucket, open, high, low, close, source)
    values ('XLM', 3600, timestamptz '2026-10-14 10:00:00+00', 1, 1, 1, 0, 'kraken');
    raise exception 'a close of 0 was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.asset_directory (asset, image, expires_at)
    values ('AQUA:GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA', 'http://aqua.network/logo.png', now());
    raise exception 'an http image was stored';
  exception when check_violation then null;
  end;
  raise notice 'ok: checks';
end $$;

-- 3. As lite_api: the job's upserts, ref_usd_at's preference, and purge's deletes.
do $$
declare
  n int;
  v numeric;
  written text;
begin
  execute 'set local role lite_api';
  -- jobs/refprices.ts's upsert: a quote replaces the stored one unless that one is newer, and returns its ref only
  -- when it was written.
  insert into lite.ref_quotes (ref, usd, source, market, change_24h, volume_24h_usd, quoted_at)
  values ('XLM', 0.1837, 'kraken', 'Kraken XLM/USD', -0.0123, 6711470.2, now() - interval '1 minute')
  on conflict (ref) do update set usd = excluded.usd, source = excluded.source, market = excluded.market,
    change_24h = excluded.change_24h, volume_24h_usd = excluded.volume_24h_usd, quoted_at = excluded.quoted_at, updated_at = now()
  where lite.ref_quotes.quoted_at <= excluded.quoted_at
  returning ref into written;
  if written is distinct from 'XLM' then raise exception 'the first quote was not reported written: %', written; end if;
  insert into lite.ref_quotes (ref, usd, source, market, change_24h, volume_24h_usd, quoted_at)
  values ('XLM', 0.1840, 'horizon', 'Stellar DEX XLM/USDC', null, null, now())
  on conflict (ref) do update set usd = excluded.usd, source = excluded.source, market = excluded.market,
    change_24h = excluded.change_24h, volume_24h_usd = excluded.volume_24h_usd, quoted_at = excluded.quoted_at, updated_at = now()
  where lite.ref_quotes.quoted_at <= excluded.quoted_at
  returning ref into written;
  if (select usd from lite.ref_quotes where ref = 'XLM') <> 0.1840 then raise exception 'the quote was not replaced'; end if;
  if written is distinct from 'XLM' then raise exception 'the newer quote was not reported written: %', written; end if;
  insert into lite.ref_quotes (ref, usd, source, market, change_24h, volume_24h_usd, quoted_at)
  values ('XLM', 0.1700, 'horizon', 'Stellar DEX XLM/USDC', null, null, now() - interval '20 minutes')
  on conflict (ref) do update set usd = excluded.usd, source = excluded.source, market = excluded.market,
    change_24h = excluded.change_24h, volume_24h_usd = excluded.volume_24h_usd, quoted_at = excluded.quoted_at, updated_at = now()
  where lite.ref_quotes.quoted_at <= excluded.quoted_at
  returning ref into written;
  if (select usd from lite.ref_quotes where ref = 'XLM') <> 0.1840 then raise exception 'an older quote replaced a newer one'; end if;
  if written is not null then raise exception 'an older quote was reported written'; end if;

  -- A day, the hour 10:00-11:00 inside it, and the quarter 10:15-10:30 inside that; USDC has the day only.
  insert into lite.ref_candles (ref, interval_s, bucket, open, high, low, close, volume, source)
  select r, i, b::timestamptz, p, p, p, p, 1, 'kraken'
    from (values
      ('XLM', 86400, '2026-10-14 00:00:00+00', 0.18),
      ('XLM', 3600, '2026-10-14 10:00:00+00', 0.19),
      ('XLM', 900, '2026-10-14 10:15:00+00', 0.195),
      ('XLM', 900, '2026-09-01 00:00:00+00', 0.25),
      ('XLM', 3600, '2025-09-01 00:00:00+00', 0.35),
      ('USDC', 86400, '2026-10-14 00:00:00+00', 0.9998)
    ) as v(r, i, b, p);

  v := lite.ref_usd_at('XLM', timestamptz '2026-10-14 10:20:00+00');
  if v is distinct from 0.195 then raise exception 'inside the quarter: % (expected the 15-minute close)', v; end if;
  v := lite.ref_usd_at('XLM', timestamptz '2026-10-14 10:15:00+00');
  if v is distinct from 0.195 then raise exception 'at the quarter''s start: %', v; end if;
  -- A bucket's end belongs to the next one: 10:30 isn't in the quarter, so the hour answers.
  v := lite.ref_usd_at('XLM', timestamptz '2026-10-14 10:30:00+00');
  if v is distinct from 0.19 then raise exception 'after the quarter: % (expected the hourly close)', v; end if;
  v := lite.ref_usd_at('XLM', timestamptz '2026-10-14 12:00:00+00');
  if v is distinct from 0.18 then raise exception 'outside the hour: % (expected the daily close)', v; end if;
  v := lite.ref_usd_at('XLM', timestamptz '2026-10-15 00:00:00+00');
  if v is not null then raise exception 'past every candle: %', v; end if;
  v := lite.ref_usd_at('USDC', timestamptz '2026-10-14 10:20:00+00');
  if v is distinct from 0.9998 then raise exception 'USDC: %', v; end if;
  v := lite.ref_usd_at('BUSDC', timestamptz '2026-10-14 10:20:00+00');
  if v is not null then raise exception 'BUSDC has no candles of its own (it is valued as USDC): %', v; end if;

  -- purge: 15-minute candles older than 35 days and hourly ones older than 400 days go; daily ones stay.
  delete from lite.ref_candles where interval_s = 900 and bucket < timestamptz '2026-10-14 12:00:00+00' - interval '35 days';
  delete from lite.ref_candles where interval_s = 3600 and bucket < timestamptz '2026-10-14 12:00:00+00' - interval '400 days';
  select count(*) into n from lite.ref_candles;
  if n <> 4 then raise exception 'after purge % candles are left, expected 4', n; end if;

  insert into lite.asset_directory (asset, home_domain, name, image, expires_at)
  values ('AQUA:GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA', 'aqua.network', 'AQUA',
          'https://aqua.network/assets/img/aqua-logo.png', now() + interval '7 days')
  on conflict (asset) do update set name = excluded.name, image = excluded.image, home_domain = excluded.home_domain,
    fetched_at = now(), expires_at = excluded.expires_at;
  select count(*) into n from lite.asset_directory where expires_at > now();
  if n <> 1 then raise exception 'asset_directory: % fresh rows', n; end if;
  execute 'reset role';
  raise notice 'ok: lite_api writes, ref_usd_at prefers the smallest interval in range, purge';
end $$;

-- 4. ref_usd_at on a full history, as purge leaves it (15-minute candles for 35 days, hourly ones for 400, daily ones
--    for 720, for XLM and USDC; each close names its interval): the same answer as the covering candle found by range,
--    at times around every edge, on bucket boundaries and between them; and each call is a lookup, not a scan: a
--    launch's day (97 buckets of 15 minutes) and month (721 hourly ones) read at most one candle per reference asset
--    for each interval a call tries.
do $$
declare
  at_time timestamptz;
  calls int := 0;
  before bigint;
  candles_read bigint;
  r record;
  read_so_far constant text := 'select coalesce(seq_tup_read, 0) + coalesce(idx_tup_fetch, 0) from pg_stat_xact_user_tables
    where relid = ''lite.ref_candles''::regclass';
begin
  execute 'set local role lite_api';
  delete from lite.ref_candles;
  insert into lite.ref_candles (ref, interval_s, bucket, open, high, low, close, volume, source)
  select ref, i, b, c, c, c, c, 1, 'kraken'
    from (values ('XLM', 0), ('USDC', 100000)) as refs(ref, base)
   cross join (values (900, interval '35 days', interval '15 minutes', timestamptz '2026-10-14 20:00+00'),
                      (3600, interval '400 days', interval '1 hour', timestamptz '2026-10-14 20:00+00'),
                      (86400, interval '720 days', interval '1 day', timestamptz '2026-10-14 00:00+00')) as iv(i, span, step, last)
   cross join generate_series(iv.last - iv.span, iv.last, iv.step) as b
   cross join lateral (select (base + i + extract(epoch from b) / 1e10)::numeric as c) as price;

  select count(*) as times,
         count(*) filter (where got is distinct from expected) as differ,
         count(*) filter (where floor(got) = 900) as quarters,
         count(*) filter (where floor(got) = 3600) as hours,
         count(*) filter (where floor(got) = 86400) as days,
         count(*) filter (where got is null) as unknown
    into r
    from (
      select lite.ref_usd_at('XLM', t) as got,
             (select c.close
                from (values (900), (3600), (86400)) as iv(s)
               cross join lateral (select close, bucket from lite.ref_candles
                                    where ref = 'XLM' and interval_s = iv.s and bucket <= t
                                    order by bucket desc limit 1) as c
               where c.bucket > t - make_interval(secs => iv.s)
               order by iv.s limit 1) as expected
        from (
          select generate_series(timestamptz '2026-09-09 12:00+00', timestamptz '2026-09-10 06:00+00', interval '7 minutes 13 seconds')
          union all select generate_series(timestamptz '2025-09-09 12:00+00', timestamptz '2025-09-10 12:00+00', interval '11 minutes')
          union all select generate_series(timestamptz '2024-10-22 00:00+00', timestamptz '2024-10-26 00:00+00', interval '37 minutes')
          union all select generate_series(timestamptz '2026-10-14 18:00+00', timestamptz '2026-10-15 02:00+00', interval '5 minutes')
          union all select generate_series(timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-01 03:00+00', interval '15 minutes')
                         + interval '1 microsecond' * s
                      from (values (-1), (0), (1)) as edge(s)
        ) as times(t)
    ) as answers;
  if r.differ <> 0 then raise exception 'ref_usd_at differs from the covering candle at % of % times', r.differ, r.times; end if;
  if least(r.quarters, r.hours, r.days, r.unknown) = 0 then
    raise exception 'the times miss a case: % from 15-minute candles, % hourly, % daily, % unknown', r.quarters, r.hours, r.days, r.unknown;
  end if;

  execute read_so_far into before;
  for at_time in select generate_series(timestamptz '2026-10-13 20:07+00', timestamptz '2026-10-14 20:07+00', interval '15 minutes')
                 union all select generate_series(timestamptz '2026-09-14 20:07+00', timestamptz '2026-10-14 20:07+00', interval '1 hour') loop
    perform lite.ref_usd_at('XLM', at_time);
    calls := calls + 1;
  end loop;
  execute read_so_far into candles_read;
  candles_read := candles_read - before;
  if candles_read > calls * 3 * 2 then
    raise exception 'ref_usd_at read % candles in % calls: it scans the history instead of looking its bucket up', candles_read, calls;
  end if;
  execute 'reset role';
  raise notice 'ok: ref_usd_at matches the covering candle at % times, and read % candles in % calls', r.times, candles_read, calls;
end $$;

rollback;
