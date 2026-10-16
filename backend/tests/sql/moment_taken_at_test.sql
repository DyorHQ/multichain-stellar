-- When a Moment happened (migration 20261016000013; docs/DESIGN-stellar-parity.md §6.9, §8.11.4): moment_metadata and
-- moments keep a date and time beside the day, in the one form POST /v1/moments/metadata writes; anything else is
-- refused, and a Moment published with a day alone keeps none. One transaction, rolled back.
begin;

do $$
declare g text := 'G' || repeat('A', 55);
begin
  insert into lite.moment_metadata (uri, address, title, taken_on, taken_at, media_type, media_url, poster_url)
  values ('t1', g, 'A', '2026-10-14', '2026-10-14T18:30:00+02:00', 'image', 'm', 'p'),
         ('t2', g, 'B', '2026-10-14', '2026-10-14T16:30:00Z', 'image', 'm', 'p'),
         ('t3', g, 'C', '2026-10-14', null, 'image', 'm', 'p');
  if (select taken_at from lite.moment_metadata where uri = 't1') <> '2026-10-14T18:30:00+02:00' then
    raise exception 'the date and time changed';
  end if;
  if (select taken_at from lite.moment_metadata where uri = 't3') is not null then raise exception 'a day alone has a time'; end if;
  begin
    insert into lite.moment_metadata (uri, address, title, taken_at, media_type, media_url, poster_url)
    values ('t4', g, 'D', '2026-10-14 18:30', 'image', 'm', 'p');
    raise exception 'a date and time in another form was kept';
  exception when check_violation then null;
  end;
  begin
    insert into lite.moment_metadata (uri, address, title, taken_at, media_type, media_url, poster_url)
    values ('t5', g, 'E', '2026-10-14T18:30:00+02:00' || repeat('0', 10), 'image', 'm', 'p');
    raise exception 'a date and time past 32 characters was kept';
  exception when check_violation then null;
  end;
  -- lite.moments keeps it under the same check, for the indexer to copy.
  if not exists (select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace
                  where n.nspname = 'lite' and t.relname = 'moments' and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%taken_at%') then
    raise exception 'lite.moments.taken_at has no check';
  end if;
  raise notice 'ok: a Moment keeps its date and time';
end $$;

rollback;
