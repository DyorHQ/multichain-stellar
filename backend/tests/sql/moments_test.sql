-- Moments and media (migration 20261014000009; docs/DESIGN-stellar-parity.md §6.9, §6.15, §12.2): anon and
-- authenticated can't reach the new tables or functions, lite_api can; the daily upload budget (50 tickets and 200 MB
-- per address and UTC day) holds, the 51st ticket of a day is refused, one at a time per address; a collect's share for
-- the creator rounds as the contract does; the checks keep out what the API never writes; and lite-media is write-once:
-- on a stand-in storage.objects (CI's plain Postgres has none), the trigger refuses an update, a move and Storage's
-- overwrite, and leaves other buckets alone. One transaction, rolled back.
begin;

-- 1. anon and authenticated can neither read nor write the tables, nor call the functions; RLS is on.
do $$
declare r text; t text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach t in array array['moment_metadata', 'moment_editions', 'media_uploads'] loop
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
      perform lite.reserve_media_upload('GAAA', 'uploads/x', 'image/png', 1, 50, 1000);
      raise exception '% could call lite.reserve_media_upload', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
    begin
      execute format('set local role %I', r);
      perform lite.moment_creator_share(100, 500);
      raise exception '% could call lite.moment_creator_share', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
  end loop;
  if exists (select 1 from pg_class where oid in ('lite.moment_metadata'::regclass, 'lite.moment_editions'::regclass, 'lite.media_uploads'::regclass) and not relrowsecurity) then
    raise exception 'RLS is off on a Moments table';
  end if;
  if has_function_privilege('public', 'lite.reserve_media_upload(text, text, text, bigint, int, bigint)', 'execute')
     or has_function_privilege('public', 'lite.moment_creator_share(numeric, int)', 'execute')
     or has_function_privilege('public', 'lite.refuse_lite_media_rewrite()', 'execute') then
    raise exception 'PUBLIC can execute a Moments function';
  end if;
  raise notice 'ok: anon and authenticated are refused';
end $$;

-- 2. The upload budget, as lite_api runs it: 50 tickets a UTC day per address, the 51st refused; 200 MB of declared
--    bytes; another address, or yesterday's tickets, count apart.
set local role lite_api;
do $$
declare
  a text := 'GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH';
  b text := 'GDFIMZHHSBGAIJUCBALCYGEO2GQKDVWJW4C3LFFLLINXU23OPVEXRITR';
  mb bigint := 1024 * 1024;
begin
  -- Yesterday's tickets don't count today.
  insert into lite.media_uploads (path, address, content_type, bytes, day)
  select format('uploads/%s/old-%s.jpg', a, i), a, 'image/jpeg', 25 * mb, (now() at time zone 'utc')::date - 1 from generate_series(1, 50) i;
  for i in 1..50 loop
    if not lite.reserve_media_upload(a, format('uploads/%s/%s.jpg', a, i), 'image/jpeg', 1, 50, 200 * mb) then
      raise exception 'ticket % of 50 refused', i;
    end if;
  end loop;
  if lite.reserve_media_upload(a, format('uploads/%s/51.jpg', a), 'image/jpeg', 1, 50, 200 * mb) then
    raise exception 'the 51st ticket of the day was issued';
  end if;
  if (select count(*) from lite.media_uploads where address = a and day = (now() at time zone 'utc')::date) <> 50 then
    raise exception 'a refused ticket was recorded';
  end if;
  -- Bytes: 8 × 25 MB fit, a ninth doesn't, and a small one still does.
  for i in 1..8 loop
    if not lite.reserve_media_upload(b, format('uploads/%s/%s.mp4', b, i), 'video/mp4', 25 * mb, 50, 200 * mb) then
      raise exception 'video % of 8 refused', i;
    end if;
  end loop;
  if lite.reserve_media_upload(b, format('uploads/%s/9.mp4', b), 'video/mp4', 1, 50, 200 * mb) then
    raise exception 'a ticket past 200 MB was issued';
  end if;
  raise notice 'ok: the upload budget';
end $$;
reset role;

-- 3. A collect's share for the creator: the contract keeps paid × bps / 10,000, rounded down, for the treasury.
do $$
begin
  if lite.moment_creator_share(30000000, 500) <> 28500000 then raise exception 'share of 3 XLM at 5%%'; end if;
  if lite.moment_creator_share(999, 500) <> 950 then raise exception 'the treasury''s part is rounded down'; end if;
  if lite.moment_creator_share(12345, 0) <> 12345 then raise exception 'share at 0 bps'; end if;
  if lite.moment_creator_share(10000000, 1000) <> 9000000 then raise exception 'share at the 10%% cap'; end if;
  raise notice 'ok: the creator''s share';
end $$;

-- 4. The checks keep out what the API never writes.
do $$
declare g text := 'GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH';
begin
  begin
    insert into lite.moment_metadata (uri, address, title, media_type, media_url, poster_url) values ('u1', g, 'A', 'audio', 'm', 'p');
    raise exception 'a media type other than image or video was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.moment_metadata (uri, address, title, media_type, media_url, poster_url) values ('u2', g, '', 'image', 'm', 'p');
    raise exception 'an empty title was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.moment_metadata (uri, address, title, media_type, media_url, poster_url) values ('u3', 'not-an-address', 'A', 'image', 'm', 'p');
    raise exception 'metadata by no account was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.media_uploads (path, address, content_type, bytes) values ('uploads/x', g, 'image/svg+xml', 1);
    raise exception 'an svg upload was recorded';
  exception when check_violation then null;
  end;
  begin
    insert into lite.moment_editions (contract, token_id, owner, owner_event, updated_ledger) values ('GNOTACONTRACT', 1, g, 'e', 1);
    raise exception 'an edition of no contract was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.moments (id, creator, uri, price, quote, max_editions, deadline, created_ledger, media_type)
    values (99, g, 'u', 1, 'C', 0, now(), 1, 'gif');
    raise exception 'a Moment with an unknown media type was stored';
  exception when check_violation then null;
  end;
  -- A new Moment is listed unless the indexer says otherwise, and starts with no collects.
  insert into lite.moments (id, creator, uri, price, quote, max_editions, deadline, created_ledger) values (98, g, 'u', 1, 'C', 0, now(), 1);
  if (select listed and collects = 0 and collectors = 0 from lite.moments where id = 98) is not true then
    raise exception 'a new Moment''s defaults';
  end if;
  raise notice 'ok: checks';
end $$;

-- 5. lite-media is write-once: the trigger on a stand-in storage.objects (created here, rolled back with the rest).
do $$
begin
  if to_regclass('storage.objects') is null then
    create schema if not exists storage;
    create table storage.objects (
      id uuid primary key default gen_random_uuid(),
      bucket_id text not null,
      name text not null,
      metadata jsonb,
      updated_at timestamptz not null default now(),
      unique (bucket_id, name)
    );
  end if;
  drop trigger if exists lite_media_write_once on storage.objects;
  create trigger lite_media_write_once
    before update on storage.objects
    for each row
    when (old.bucket_id = 'lite-media' or new.bucket_id = 'lite-media')
    execute function lite.refuse_lite_media_rewrite();
end $$;

do $$
declare v_name text;
begin
  insert into storage.objects (bucket_id, name, metadata) values ('lite-media', 'uploads/GA/a.jpg', '{"size": 1}');
  insert into storage.objects (bucket_id, name, metadata) values ('avatars', 'a.jpg', '{"size": 1}');
  -- An update, a move within the bucket and a move out of it are refused.
  begin
    update storage.objects set metadata = '{"size": 2}' where bucket_id = 'lite-media' and name = 'uploads/GA/a.jpg';
    raise exception 'a lite-media object was updated';
  exception when raise_exception then
    if sqlerrm not like 'lite-media is write-once%' then raise; end if;
  end;
  begin
    update storage.objects set name = 'uploads/GA/b.jpg' where bucket_id = 'lite-media';
    raise exception 'a lite-media object was moved';
  exception when raise_exception then
    if sqlerrm not like 'lite-media is write-once%' then raise; end if;
  end;
  begin
    update storage.objects set bucket_id = 'avatars' where bucket_id = 'lite-media';
    raise exception 'a lite-media object was moved out of the bucket';
  exception when raise_exception then
    if sqlerrm not like 'lite-media is write-once%' then raise; end if;
  end;
  -- Storage's overwrite: an insert that updates on conflict.
  begin
    insert into storage.objects (bucket_id, name, metadata) values ('lite-media', 'uploads/GA/a.jpg', '{"size": 3}')
    on conflict (bucket_id, name) do update set metadata = excluded.metadata;
    raise exception 'a lite-media object was overwritten';
  exception when raise_exception then
    if sqlerrm not like 'lite-media is write-once%' then raise; end if;
  end;
  -- Nor can another bucket's object move into lite-media.
  begin
    update storage.objects set bucket_id = 'lite-media', name = 'uploads/GA/c.jpg' where bucket_id = 'avatars';
    raise exception 'an object was moved into lite-media';
  exception when raise_exception then
    if sqlerrm not like 'lite-media is write-once%' then raise; end if;
  end;
  select name into v_name from storage.objects where bucket_id = 'lite-media';
  if v_name <> 'uploads/GA/a.jpg' or (select metadata->>'size' from storage.objects where bucket_id = 'lite-media') <> '1' then
    raise exception 'the lite-media object changed';
  end if;
  -- Other buckets are untouched by the trigger; a new lite-media object is a plain insert.
  update storage.objects set metadata = '{"size": 4}' where bucket_id = 'avatars';
  insert into storage.objects (bucket_id, name) values ('lite-media', 'uploads/GA/d.jpg')
  on conflict (bucket_id, name) do update set metadata = excluded.metadata;
  if (select count(*) from storage.objects where bucket_id = 'lite-media') <> 2 then raise exception 'a new lite-media object was refused'; end if;
  raise notice 'ok: lite-media is write-once';
end $$;

rollback;
