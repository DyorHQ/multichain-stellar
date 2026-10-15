-- Moments and media as the board, a Moment's page and My Moments show them (docs/DESIGN-stellar-parity.md §6.9, §6.11
-- and §6.15; WP-16):
-- - moment_metadata: what POST /v1/moments/metadata wrote (title, description, place, date, the media and its poster),
--   by the URI a Moment carries on chain. Kept across indexer resets, like every metadata table.
-- - moments gains what the indexer learns besides the contract's own fields: the metadata joined by URI, the terms the
--   Moment was published under (get_moment, read once), its collects and collectors, and whether it is listed (a
--   deployment's smoke Moments, and Moments without a title and an image, never are).
-- - moment_editions: who holds each edition now, from the contract's mint, collect and transfer events.
-- - media_uploads and reserve_media_upload(): each upload ticket, counted against the user's daily budget before the
--   URL is issued.
-- - moment_creator_share(): what a collect pays the creator, as the contract splits it.
-- - refuse_lite_media_rewrite(): lite-media is write-once. The trigger refuses every update of one of its objects,
--   which is how Storage overwrites (its service write is an insert that updates on conflict) and how it moves one.
--   Attached only where storage.objects exists: CI's plain Postgres and the local stack have no Storage.

-- ------------------------------------------------------------------------------------------------ metadata

create table if not exists lite.moment_metadata (
  -- <media base>moments/<address>/<uuid>.json: the URI a Moment is published with.
  uri text primary key,
  -- Who wrote it; only this address may publish with it.
  address text not null check (address ~ '^G[A-Z2-7]{55}$'),
  title text not null check (char_length(title) between 1 and 80),
  description text check (char_length(description) <= 500),
  place text check (char_length(place) between 1 and 64),
  taken_on date,
  media_type text not null check (media_type in ('image', 'video')),
  -- <media base>uploads/<address>/<file>: the photo or the video.
  media_url text not null,
  -- The photo itself, or the video's poster: always an image, the NFT's `image`.
  poster_url text not null,
  created_at timestamptz not null default now()
);
create index if not exists moment_metadata_address on lite.moment_metadata (address, created_at desc);

-- ------------------------------------------------------------------------------------------------ moments

alter table lite.moments add column if not exists description text;
alter table lite.moments add column if not exists place text;
alter table lite.moments add column if not exists taken_on date;
alter table lite.moments add column if not exists media_type text check (media_type in ('image', 'video'));
-- The photo, or the video's poster.
alter table lite.moments add column if not exists poster_url text;
-- The platform share and the royalty the Moment was published under (get_moment); null until read.
alter table lite.moments add column if not exists platform_bps int check (platform_bps between 0 and 10000);
alter table lite.moments add column if not exists royalty_bps int check (royalty_bps between 0 and 10000);
alter table lite.moments add column if not exists collects int not null default 0;
alter table lite.moments add column if not exists collectors int not null default 0;
-- False for the deployment's smoke Moments and for those without a title and an image: indexed, never in the feed.
alter table lite.moments add column if not exists listed boolean not null default true;

-- Rows indexed before this migration: their media was read from the metadata JSON's image (or animation_url), so a
-- video's URL is the video and it has no poster. Only a photo is its own poster; the rest stay off the feed.
update lite.moments
   set media_type = case when media_url ~* '\.(mp4|mov)$' then 'video' else 'image' end,
       poster_url = case when media_url ~* '\.(mp4|mov)$' then null else media_url end
 where media_url is not null and media_type is null;
update lite.moments m
   set collects = c.collects, collectors = c.collectors
  from (select moment_id, count(*)::int as collects, count(distinct collector)::int as collectors
          from lite.moment_collects group by moment_id) c
 where c.moment_id = m.id;
update lite.moments set listed = false where title is null or poster_url is null;

create index if not exists moments_feed on lite.moments (created_at desc, id desc) where listed;
create index if not exists moments_creator on lite.moments (creator, created_at desc);
create index if not exists moment_collects_moment on lite.moment_collects (moment_id, ts desc);

-- ------------------------------------------------------------------------------------------------ editions

-- Who holds each edition: an edition is the collection's token id, minted to its collector by `collect` (its mint and
-- collect events) and moved by `transfer`. owner_event is the event that set the owner: one older than it (a page read
-- again) never moves the edition back.
create table if not exists lite.moment_editions (
  contract text not null check (contract ~ '^C[A-Z2-7]{55}$'),
  token_id int not null check (token_id >= 0),
  -- Null until the collect event that minted it is read (its mint event comes first, in the same transaction).
  moment_id int references lite.moments(id) on delete cascade,
  owner text not null,
  owner_event text not null,
  updated_ledger int not null,
  updated_at timestamptz not null default now(),
  primary key (contract, token_id)
);
create index if not exists moment_editions_owner on lite.moment_editions (owner, moment_id);
create index if not exists moment_editions_moment on lite.moment_editions (moment_id, owner);

-- The editions collected before this migration, held by their collectors (transfers were not indexed then), in the
-- collection the indexed rows describe: the Moments contract of the indexer's cursor (main_events.ts deploymentKey,
-- "<passphrase>|<launchpad>|<moments>").
insert into lite.moment_editions (contract, token_id, moment_id, owner, owner_event, updated_ledger)
select k.moments, c.first_token_id + g.i, c.moment_id, c.collector, c.event_id, c.ledger
  from lite.moment_collects c
  cross join lateral generate_series(0, c.quantity - 1) as g(i)
  cross join (select split_part(network_id, '|', 3) as moments from lite.indexer_cursors where name = 'events') k
 where k.moments ~ '^C[A-Z2-7]{55}$'
on conflict (contract, token_id) do nothing;

-- What a collect paying `p_paid` gives the creator: the contract keeps paid × platform bps / 10,000 (rounded down) for
-- the treasury and sends the rest to the creator (contracts/moments collect()).
create or replace function lite.moment_creator_share(p_paid numeric, p_platform_bps int)
returns numeric
language sql immutable
set search_path = lite, pg_temp
as $$
  select p_paid - floor(p_paid * p_platform_bps / 10000)
$$;

-- ------------------------------------------------------------------------------------------------ uploads

-- One row per upload ticket issued: uploads/<address>/<uuid>.<ext>, the content type and the size the phone declared.
create table if not exists lite.media_uploads (
  path text primary key,
  address text not null check (address ~ '^G[A-Z2-7]{55}$'),
  content_type text not null
    check (content_type in ('image/jpeg', 'image/png', 'image/webp', 'image/gif', 'video/mp4', 'video/quicktime')),
  bytes bigint not null check (bytes > 0),
  -- The UTC day the budget counts it in.
  day date not null default ((now() at time zone 'utc')::date),
  created_at timestamptz not null default now()
);
create index if not exists media_uploads_day on lite.media_uploads (address, day);

-- Records an upload ticket when it fits the address's budget for the UTC day (at most p_max_uploads tickets and
-- p_max_bytes declared bytes), and answers whether it did. One address's tickets are counted one at a time.
create or replace function lite.reserve_media_upload(p_address text, p_path text, p_content_type text, p_bytes bigint,
                                                     p_max_uploads int, p_max_bytes bigint)
returns boolean
language plpgsql
set search_path = lite, pg_temp
as $$
declare
  v_day date := (now() at time zone 'utc')::date;
  v_count int;
  v_bytes bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended('lite.media_uploads:' || p_address, 0));
  select count(*), coalesce(sum(bytes), 0) into v_count, v_bytes
    from lite.media_uploads where address = p_address and day = v_day;
  if v_count + 1 > p_max_uploads or v_bytes + p_bytes > p_max_bytes then
    return false;
  end if;
  insert into lite.media_uploads (path, address, content_type, bytes, day)
  values (p_path, p_address, p_content_type, p_bytes, v_day);
  return true;
end
$$;

-- ------------------------------------------------------------------------------------------------ write-once storage

-- Refuses the update it fires on: lite-media's objects are written once and never changed, overwritten or moved.
create or replace function lite.refuse_lite_media_rewrite()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  raise exception 'lite-media is write-once: % can''t be changed, overwritten or moved', old.name;
end
$$;

do $$
begin
  if to_regclass('storage.objects') is not null then
    drop trigger if exists lite_media_write_once on storage.objects;
    create trigger lite_media_write_once
      before update on storage.objects
      for each row
      when (old.bucket_id = 'lite-media' or new.bucket_id = 'lite-media')
      execute function lite.refuse_lite_media_rewrite();
  else
    raise notice 'storage.objects not present: the lite-media write-once trigger is skipped';
  end if;
end $$;

-- ------------------------------------------------------------------------------------------------ access

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.moment_metadata, lite.moment_editions, lite.media_uploads from public;
revoke all on function lite.moment_creator_share(numeric, int) from public;
revoke all on function lite.reserve_media_upload(text, text, text, bigint, int, bigint) from public;
revoke all on function lite.refuse_lite_media_rewrite() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on lite.moment_metadata, lite.moment_editions, lite.media_uploads from anon';
    execute 'revoke all on function lite.moment_creator_share(numeric, int) from anon';
    execute 'revoke all on function lite.reserve_media_upload(text, text, text, bigint, int, bigint) from anon';
    execute 'revoke all on function lite.refuse_lite_media_rewrite() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on lite.moment_metadata, lite.moment_editions, lite.media_uploads from authenticated';
    execute 'revoke all on function lite.moment_creator_share(numeric, int) from authenticated';
    execute 'revoke all on function lite.reserve_media_upload(text, text, text, bigint, int, bigint) from authenticated';
    execute 'revoke all on function lite.refuse_lite_media_rewrite() from authenticated';
  end if;
end $$;
-- TRUNCATE on moment_editions: the indexer clears it with the other indexed tables (lite-indexer/jobs/reset.ts).
grant select, insert, update, delete on lite.moment_metadata, lite.media_uploads to lite_api;
grant select, insert, update, delete, truncate on lite.moment_editions to lite_api;
grant execute on function lite.moment_creator_share(numeric, int) to lite_api;
grant execute on function lite.reserve_media_upload(text, text, text, bigint, int, bigint) to lite_api;
grant execute on function lite.refuse_lite_media_rewrite() to lite_api;

-- The RLS-and-policy loop of 20261013000004: RLS on every lite table, and lite_api's one policy on each.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'lite' loop
    execute format('alter table lite.%I enable row level security', t.tablename);
    execute format('drop policy if exists lite_api_all on lite.%I', t.tablename);
    execute format('create policy lite_api_all on lite.%I for all to lite_api using (true) with check (true)', t.tablename);
  end loop;
end $$;
