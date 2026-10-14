-- Reference prices and the asset directory (migration 20261014000006; docs/DESIGN-stellar-parity.md §6.6, §6.12,
-- §12.2): anon and authenticated can't reach the tables or ref_usd_at, lite_api can; the checks keep out what no
-- provider sends (a price of 0, a bucket off its interval's grid, an image that isn't https); ref_usd_at answers the
-- close of the candle covering a time, the smallest interval first, and null when none covers it; the job's upserts
-- (a quote never replaces a newer one) and purge's deletes run as lite_api. One transaction, rolled back.
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
begin
  execute 'set local role lite_api';
  -- jobs/refprices.ts's upsert: a quote replaces the stored one unless that one is newer.
  insert into lite.ref_quotes (ref, usd, source, market, change_24h, volume_24h_usd, quoted_at)
  values ('XLM', 0.1837, 'kraken', 'Kraken XLM/USD', -0.0123, 6711470.2, now() - interval '1 minute')
  on conflict (ref) do update set usd = excluded.usd, source = excluded.source, market = excluded.market,
    change_24h = excluded.change_24h, volume_24h_usd = excluded.volume_24h_usd, quoted_at = excluded.quoted_at, updated_at = now()
  where lite.ref_quotes.quoted_at <= excluded.quoted_at;
  insert into lite.ref_quotes (ref, usd, source, market, change_24h, volume_24h_usd, quoted_at)
  values ('XLM', 0.1840, 'horizon', 'Stellar DEX XLM/USDC', null, null, now())
  on conflict (ref) do update set usd = excluded.usd, source = excluded.source, market = excluded.market,
    change_24h = excluded.change_24h, volume_24h_usd = excluded.volume_24h_usd, quoted_at = excluded.quoted_at, updated_at = now()
  where lite.ref_quotes.quoted_at <= excluded.quoted_at;
  if (select usd from lite.ref_quotes where ref = 'XLM') <> 0.1840 then raise exception 'the quote was not replaced'; end if;
  insert into lite.ref_quotes (ref, usd, source, market, change_24h, volume_24h_usd, quoted_at)
  values ('XLM', 0.1700, 'horizon', 'Stellar DEX XLM/USDC', null, null, now() - interval '20 minutes')
  on conflict (ref) do update set usd = excluded.usd, source = excluded.source, market = excluded.market,
    change_24h = excluded.change_24h, volume_24h_usd = excluded.volume_24h_usd, quoted_at = excluded.quoted_at, updated_at = now()
  where lite.ref_quotes.quoted_at <= excluded.quoted_at;
  if (select usd from lite.ref_quotes where ref = 'XLM') <> 0.1840 then raise exception 'an older quote replaced a newer one'; end if;

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

rollback;
