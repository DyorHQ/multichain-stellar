-- Run after the migrations: psql -v ON_ERROR_STOP=1 -f lite_schema_test.sql
-- One transaction, rolled back: the test leaves no row, table or truncation behind, even in a database in use.
begin;

-- 1. anon/authenticated can read or write nothing in schema lite.
do $$
declare t record; denied int := 0; total int := 0;
begin
  for t in select tablename from pg_tables where schemaname = 'lite' loop
    total := total + 1;
    begin
      execute 'set local role anon';
      execute format('select 1 from lite.%I limit 1', t.tablename);
      raise exception 'anon could read lite.%', t.tablename;
    exception when insufficient_privilege then denied := denied + 1;
    end;
    execute 'reset role';
    begin
      execute 'set local role authenticated';
      execute format('insert into lite.%I default values', t.tablename);
      raise exception 'authenticated could write lite.%', t.tablename;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
  end loop;
  -- every table has RLS on
  if exists (select 1 from pg_tables where schemaname = 'lite' and not rowsecurity) then
    raise exception 'a lite table has RLS off';
  end if;
  raise notice 'ok: % tables closed to anon and authenticated', denied;
end $$;

-- 2. Candles bucket trades.
do $$
declare n int;
begin
  insert into lite.launches (token, creator, quote, name, symbol, launch_index, supply, phantom, threshold, quote_reserve, token_reserve, created_ledger)
  values ('CTEST', 'GCREATOR', 'CQUOTE', 'T', 'T', 0, 1, 1, 1, 1, 1, 1);
  insert into lite.launch_trades (event_id, token, trader, side, quote_amount, token_amount, fees, price, ledger, ts) values
    ('e1', 'CTEST', 'GA', 'buy', 10, 100, 0, 1.0, 1, timestamptz '2026-10-11 10:00:05'),
    ('e2', 'CTEST', 'GA', 'buy', 10, 90, 0, 1.2, 2, timestamptz '2026-10-11 10:00:40'),
    ('e3', 'CTEST', 'GB', 'sell', 5, 40, 0, 1.1, 3, timestamptz '2026-10-11 10:01:10');
  select count(*) into n from lite.candles('CTEST', '1 minute');
  if n <> 2 then raise exception 'expected 2 candles, got %', n; end if;
  if (select high from lite.candles('CTEST', '1 minute') order by bucket asc limit 1) <> 1.2 then raise exception 'bad high'; end if;
  delete from lite.launches where token = 'CTEST';
  raise notice 'ok: candles';
end $$;

-- 3. lite_api (the functions' LITE_DB_URL role) works inside lite and nowhere else.
create table public.lite_api_sentinel (x int);
insert into public.lite_api_sentinel values (1);
do $$
declare n int; r record;
begin
  execute 'set local role lite_api';
  select * into r from lite.reserve_sponsorship('G' || repeat('R', 55), 'activate', repeat('0', 64), 1, 3, 10, 10, 5);
  if r.id is null then raise exception 'lite_api: sponsorship reservation refused (%)', r.refusal; end if;
  select count(*) into n from lite.sponsorships where id = r.id;
  if n <> 1 then raise exception 'lite_api: cannot read its own sponsorship row'; end if;
  delete from lite.sponsorships where id = r.id;
  perform 1 from lite.app_config where key = 'lite';
  truncate lite.indexer_cursors;
  begin
    perform 1 from public.lite_api_sentinel;
    raise exception 'lite_api could read public.lite_api_sentinel';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  raise notice 'ok: lite_api works in lite and is refused outside it';
end $$;
drop table public.lite_api_sentinel;

rollback;
