-- 26_storage_write_once_and_upload_limits — launch-media objects can no longer be swapped, and uploads to the public
-- buckets are bounded per wallet and overall (security audit 2026-09-26, OH-6, SB-6 / PR-2, and the storage half of
-- SB-2; revised after the review of the fixes, 2026-09-27).
--
-- How Storage writes (supabase/storage: src/storage/uploader.ts, database/pg.ts; read 2026-09-27): before it reads any
-- bytes it runs a permission probe AS THE CALLER, the INSERT it would make (with x-upsert: true, the INSERT … ON
-- CONFLICT DO UPDATE), and rolls it back, so RLS decides who may upload what. Once the bytes are stored it writes the
-- row AS THE SERVICE ROLE, which RLS does not check: INSERT … ON CONFLICT (bucket_id, name) WHERE archived_at IS NULL
-- DO UPDATE, with the real metadata (size, eTag) and a new version. A rule enforced only by RLS therefore holds for one
-- request at a time, not for concurrent ones: two x-upsert uploads to one new path both pass the probe and the later
-- completion overwrites the earlier; parallel (or long-held resumable) uploads from one wallet all pass a quota that
-- counts committed rows. What must hold whatever the concurrency is enforced by triggers on storage.objects, which fire
-- for the service role's write too. A trigger's refusal fails the upload and Storage deletes the stored bytes.
--
-- 1. launch-media is write-once. Its public URLs are written on-chain (a token's logo, a Moment's media mirror, a video
--    Moment's poster fallback, which is filed under the VIDEO's hash and so is not covered by the on-chain hash, PR-2),
--    so the bytes behind one must never change. Trigger dyorhq_launch_media_write_once refuses any move or rename, and
--    any change to a row's version, size, eTag or type (as 409 Duplicate, which Storage also answers when x-upsert:
--    false finds the path taken), for every role. Takedowns use DELETE (supabase/README.md, "Takedown"), which it does
--    not touch.
--    INTERIM, until migrations-deferred/31 is applied: the builds in use upload launch-media with x-upsert: true, fail
--    on any non-2xx, and name Moment media by content (moment-<keccak of the bytes>), so picking the same photo or
--    video again uploads over the same path. For moment-<64 hex> names only, the owner may therefore still upload over
--    an existing object when the new bytes are the same: equal size, eTag and type (policy launch_media_owner_update
--    plus the trigger's exception). Every other name is write-once now. S3's eTag is MD5-based, so an owner able to
--    build an MD5 collision could still swap such an object for different bytes of the same size; the app checks a
--    Moment photo against its on-chain hash, but not a poster. Migration 31 removes the exception once the app uploads
--    with x-upsert: false and treats 409 as already uploaded, and older builds are expired.
-- 2. Upload names are pinned to what the app writes:
--      avatars       <wallet>/avatar.jpg only (insert and update)
--      launch-media  <wallet>/<uuid>.jpg (launch logos), <wallet>/moment-<64 hex>.<jpg|mp4|mov> (Moment media) and
--                    <wallet>/moment-<uuid>.<jpg|mp4|mov> (the names builds before content-hash naming wrote)
--    Every object in both buckets was checked against these shapes on 2026-09-26 (read-only): only one manual test
--    object (<wallet>/selftest.jpg) falls outside them, and existing objects are not affected by an insert policy.
-- 3. Upload budgets. The insert policies check them, so a spent budget is refused before any bytes are sent. Trigger
--    dyorhq_storage_upload_gate checks them again when the row is written, under a per-wallet lock, so concurrent
--    uploads from one wallet cannot overshoot:
--      * a wallet on public.upload_blocklist can upload to neither bucket (takedowns);
--      * launch-media, per wallet: at most 40 objects, and 500 MiB including the new one, in any rolling 24 hours;
--      * launch-media, overall: at most 1,000 uploads and 5 GiB in any rolling 24 hours (public.storage_upload_events).
--        This is a circuit breaker: wallets cost nothing, so the per-wallet budget alone does not bound the total.
--        wallet-auth bounds how many new wallets one client network can bring in (edge_rate_gate 'wallet-auth',
--        migration 27), and this bounds the rest. It is approximate under concurrency (no global lock, so one wallet's
--        upload never waits on another's). While it is spent, every launch-media upload fails (403) until older
--        uploads age out; raise it with a new migration if real use approaches it.
-- 4. Bucket MIME allow-lists shrink to the types the app has ever sent (checked in git history): avatars image/jpeg;
--    launch-media image/jpeg, video/mp4, video/quicktime. Size limits are re-asserted (5 MB and 50 MB).
--
-- The budget functions run as their owner (postgres), which must bypass RLS to count the objects in storage.objects
-- whatever its SELECT policies are. On this project postgres has BYPASSRLS, SELECT and TRIGGER on storage.objects, and
-- supautils lets it manage that table's policies and drop its triggers (all checked read-only 2026-09-27). The check at
-- the end fails the migration if the owner cannot see every object, rather than let the quota count nothing and
-- silently allow everything.
--
-- Reverse (only if the app's uploads break):
--   drop trigger dyorhq_launch_media_write_once on storage.objects; drop trigger dyorhq_storage_upload_gate on storage.objects;
--   drop function public.storage_launch_media_write_once(); drop function public.storage_objects_upload_gate();
--   recreate avatars_owner_insert / avatars_owner_update / launch_media_owner_insert / launch_media_owner_update as in
--   migrations 08/09; drop function public.storage_upload_allowed(text);
--   drop function public.storage_wallet_upload_budget(text, bigint); drop table public.upload_blocklist;
--   drop table public.storage_upload_events; and restore the MIME lists from 08/10.
-- Verify after apply:
--   select tgname, tgenabled from pg_trigger where tgrelid = 'storage.objects'::regclass and tgname like 'dyorhq_%';
--     -- dyorhq_launch_media_write_once O, dyorhq_storage_upload_gate O
--   select policyname, cmd from pg_policies where schemaname = 'storage' and tablename = 'objects' order by 1;
--     -- launch_media_owner_update limited to <wallet>/moment-<64 hex> names
--   select id, file_size_limit, allowed_mime_types from storage.buckets where id in ('avatars', 'launch-media');
--   select has_function_privilege('anon', 'public.storage_upload_allowed(text)', 'execute'),          -- false
--          has_function_privilege('authenticated', 'public.storage_upload_allowed(text)', 'execute'), -- true
--          has_table_privilege('authenticated', 'public.upload_blocklist', 'select');                 -- false

-- Wallets barred from uploading (takedowns; supabase/README.md). Managed from the dashboard / SQL editor only: RLS on,
-- no policies, no privileges for anon or authenticated.
create table if not exists public.upload_blocklist (
  wallet     text primary key check (wallet ~ '^0x[0-9a-f]{40}$'),
  reason     text check (reason is null or char_length(reason) <= 500),
  created_at timestamptz not null default now()
);
alter table public.upload_blocklist enable row level security;
revoke all on public.upload_blocklist from public, anon, authenticated;
comment on table public.upload_blocklist is
  'Wallets that may not upload to the avatars or launch-media buckets (content takedowns). Read by storage_upload_allowed() and the dyorhq_storage_upload_gate trigger; written only from the dashboard / service role.';

-- One row per launch-media upload the upload gate let through (bucket, bytes, time; not who), for the bucket's overall
-- budget; purged after two days. Owner-only: RLS on, no policies, no privileges for any API role.
create table if not exists public.storage_upload_events (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text not null,
  bytes      bigint not null check (bytes >= 0),
  created_at timestamptz not null default now()
);
alter table public.storage_upload_events enable row level security;
revoke all on public.storage_upload_events from public, anon, authenticated, service_role;
create index if not exists storage_upload_events_bucket_created_idx on public.storage_upload_events (bucket_id, created_at);
comment on table public.storage_upload_events is
  'One row per launch-media upload dyorhq_storage_upload_gate allowed (bucket, bytes, time; no wallet), for the bucket''s overall 24-hour budget; purged after two days. RLS on, no policies, no grants to anon/authenticated/service_role.';

-- The per-wallet launch-media budget: true when p_wallet has stored fewer than 40 objects there in the last 24 hours,
-- and those objects plus p_bytes more come to at most 500 MiB. The name range uses the (bucket_id, name COLLATE "C")
-- index: '0' is the character after '/'. Internal: callable only by its owner (the policies and the trigger reach it
-- through SECURITY DEFINER functions).
create or replace function public.storage_wallet_upload_budget(p_wallet text, p_bytes bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select count(*) < 40
     and coalesce(sum(case when o.metadata->>'size' ~ '^[0-9]{1,15}$' then (o.metadata->>'size')::bigint else 0 end), 0)
         + greatest(coalesce(p_bytes, 0), 0) <= 500 * 1024 * 1024
    from storage.objects o
   where o.bucket_id = 'launch-media'
     and o.name collate "C" >= p_wallet || '/' and o.name collate "C" < p_wallet || '0'
     and o.created_at > now() - interval '1 day'
$function$;

revoke all on function public.storage_wallet_upload_budget(text, bigint) from public, anon, authenticated, service_role;
comment on function public.storage_wallet_upload_budget(text, bigint) is
  'Per-wallet launch-media budget: fewer than 40 objects, and at most 500 MiB including p_bytes more, in the last 24 hours. Owner-only; used by storage_upload_allowed() and the dyorhq_storage_upload_gate trigger.';

-- The upload check the INSERT (and UPDATE) policies call, before Storage reads any bytes: the caller's wallet
-- (app_wallet()) is not blocklisted and, for launch-media, has budget left. SECURITY DEFINER so it can read the blocklist
-- and count the caller's objects whatever the SELECT policies are; it only ever looks at the caller's own folder and
-- returns a boolean.
create or replace function public.storage_upload_allowed(p_bucket text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select w.wallet is not null
     and not exists (select 1 from public.upload_blocklist b where b.wallet = w.wallet)
     and (p_bucket is distinct from 'launch-media' or public.storage_wallet_upload_budget(w.wallet, 0))
  from (select public.app_wallet() as wallet) w
$function$;

revoke all on function public.storage_upload_allowed(text) from public, anon, authenticated;
grant execute on function public.storage_upload_allowed(text) to authenticated, service_role;
comment on function public.storage_upload_allowed(text) is
  'Upload check for the storage INSERT/UPDATE policies: true when the calling wallet (app_wallet()) is not on upload_blocklist and, for launch-media, has budget left (storage_wallet_upload_budget). Looks only at the caller''s own folder; returns a boolean only. The dyorhq_storage_upload_gate trigger re-checks when the row is written.';

-- The same rules when the row is written, for every writer (Storage's probe as the caller, and its completion as the
-- service role). Only objects in a wallet's own folder count: the insert policies pin every name an API role can write
-- to one, so anything else was written by the owner (dashboard, service role).
create or replace function public.storage_objects_upload_gate()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_wallet text := (storage.foldername(new.name))[1];
  v_bytes  bigint := case
    when new.metadata->>'size' ~ '^[0-9]{1,15}$' then (new.metadata->>'size')::bigint
    when new.metadata->>'contentLength' ~ '^[0-9]{1,15}$' then (new.metadata->>'contentLength')::bigint
    else 0 end;
  v_count  bigint;
  v_total  bigint;
begin
  if new.bucket_id is distinct from 'launch-media' and new.bucket_id is distinct from 'avatars' then
    return new;
  end if;
  if v_wallet is null or v_wallet !~ '^0x[0-9a-f]{40}$' then
    return new;
  end if;

  -- One write per wallet at a time (released at commit): each statement below takes a new snapshot, so the count then
  -- includes every upload of this wallet that completed first, however many were started together.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/storage-upload/wallet'), pg_catalog.hashtext(v_wallet));
  if exists (select 1 from public.upload_blocklist b where b.wallet = v_wallet) then
    raise exception 'uploads from this wallet are blocked' using errcode = '42501';
  end if;
  if new.bucket_id = 'avatars' then
    return new;
  end if;
  if not public.storage_wallet_upload_budget(v_wallet, v_bytes) then
    raise exception 'this wallet''s upload limit is reached — try again tomorrow' using errcode = '42501';
  end if;

  -- The bucket's overall budget. Purging skips rows another upload is purging, so no upload waits on another.
  delete from public.storage_upload_events e
   where e.id in (select o.id from public.storage_upload_events o
                   where o.bucket_id = 'launch-media' and o.created_at < now() - interval '2 days'
                   for update skip locked);
  select count(*), coalesce(sum(e.bytes), 0) into v_count, v_total
    from public.storage_upload_events e
   where e.bucket_id = 'launch-media' and e.created_at > now() - interval '1 day';
  if v_count >= 1000 or v_total + v_bytes > 5::bigint * 1024 * 1024 * 1024 then
    raise exception 'uploads are paused for now — try again later' using errcode = '42501';
  end if;
  insert into public.storage_upload_events (bucket_id, bytes) values ('launch-media', v_bytes);
  return new;
end;
$function$;

revoke all on function public.storage_objects_upload_gate() from public, anon, authenticated, service_role;
comment on function public.storage_objects_upload_gate() is
  'BEFORE INSERT on storage.objects (trigger dyorhq_storage_upload_gate): for avatars and launch-media objects in a wallet folder, refuses a blocklisted wallet and, for launch-media, a spent per-wallet budget (under a per-wallet lock) or a spent overall 24-hour budget (1,000 uploads, 5 GiB).';

-- Write-once for launch-media (see header). SQLSTATE 23505 is what Storage answers as 409 Duplicate; 42501 as 403.
create or replace function public.storage_launch_media_write_once()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if old.bucket_id is distinct from 'launch-media' and new.bucket_id is distinct from 'launch-media' then
    return new;
  end if;
  if new.bucket_id is distinct from old.bucket_id or new.name is distinct from old.name then
    raise exception 'launch-media objects cannot be moved or renamed' using errcode = '42501';
  end if;
  -- The stored bytes and their type stay the same (e.g. only updated_at or the owner changes).
  if new.version is not distinct from old.version
     and new.metadata->>'eTag' is not distinct from old.metadata->>'eTag'
     and new.metadata->>'size' is not distinct from old.metadata->>'size'
     and new.metadata->>'mimetype' is not distinct from old.metadata->>'mimetype' then
    return new;
  end if;
  -- INTERIM (migrations-deferred/31 removes it): a content-addressed Moment object may be uploaded again with the same
  -- bytes. Storage's permission probe runs as the caller and is always rolled back: the policies decide it, and the
  -- completion, which carries the real size and eTag, is checked here.
  if old.name ~ '^0x[0-9a-f]{40}/moment-[0-9a-f]{64}\.(jpg|mp4|mov)$' then
    if current_user in ('anon', 'authenticated') then
      return new;
    end if;
    if new.metadata->>'eTag' is not null and new.metadata->>'size' is not null
       and new.metadata->>'eTag' = old.metadata->>'eTag'
       and new.metadata->>'size' = old.metadata->>'size'
       and new.metadata->>'mimetype' is not distinct from old.metadata->>'mimetype' then
      return new;
    end if;
  end if;
  raise exception 'launch-media objects are write-once: this name is already taken' using errcode = '23505';
end;
$function$;

revoke all on function public.storage_launch_media_write_once() from public, anon, authenticated, service_role;
comment on function public.storage_launch_media_write_once() is
  'BEFORE UPDATE on storage.objects (trigger dyorhq_launch_media_write_once): refuses moving or renaming a launch-media object and any change to its version, size, eTag or type. Interim exception until migrations-deferred/31: the same bytes may be uploaded again under a <wallet>/moment-<64 hex> name.';

-- CREATE OR REPLACE needs only the TRIGGER privilege on storage.objects (supabase_storage_admin owns it).
create or replace trigger dyorhq_storage_upload_gate before insert on storage.objects
  for each row execute function public.storage_objects_upload_gate();
create or replace trigger dyorhq_launch_media_write_once before update on storage.objects
  for each row execute function public.storage_launch_media_write_once();

-- 1. launch-media: uploading over an existing object only for content-addressed Moment names (interim; see header).
drop policy if exists "launch_media_owner_update" on storage.objects;
create policy "launch_media_owner_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'launch-media'
    and (storage.foldername(name))[1] = public.app_wallet()
    and name ~ '^0x[0-9a-f]{40}/moment-[0-9a-f]{64}\.(jpg|mp4|mov)$'
  )
  with check (
    bucket_id = 'launch-media'
    and (storage.foldername(name))[1] = public.app_wallet()
    and name ~ '^0x[0-9a-f]{40}/moment-[0-9a-f]{64}\.(jpg|mp4|mov)$'
    and public.storage_upload_allowed('launch-media')
  );

-- 2. Pinned names and the budgets.
drop policy if exists "launch_media_owner_insert" on storage.objects;
create policy "launch_media_owner_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'launch-media'
    and (storage.foldername(name))[1] = public.app_wallet()
    and name ~ '^0x[0-9a-f]{40}/(moment-([0-9a-f]{64}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(jpg|mp4|mov)|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg)$'
    and public.storage_upload_allowed('launch-media')
  );

drop policy if exists "avatars_owner_insert" on storage.objects;
create policy "avatars_owner_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and name = public.app_wallet() || '/avatar.jpg' and public.storage_upload_allowed('avatars'));

drop policy if exists "avatars_owner_update" on storage.objects;
create policy "avatars_owner_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and name = public.app_wallet() || '/avatar.jpg')
  with check (bucket_id = 'avatars' and name = public.app_wallet() || '/avatar.jpg' and public.storage_upload_allowed('avatars'));

-- 3. Bucket limits.
update storage.buckets
   set file_size_limit = 5242880, allowed_mime_types = array['image/jpeg']
 where id = 'avatars';
update storage.buckets
   set file_size_limit = 52428800, allowed_mime_types = array['image/jpeg', 'video/mp4', 'video/quicktime']
 where id = 'launch-media';

-- Fail the migration if any of it did not take.
do $$
declare
  offending text;
  r         text;
begin
  -- Both triggers exist and fire (tgenabled 'O': on origin, i.e. for every normal session).
  if (select count(*) from pg_trigger
       where tgrelid = 'storage.objects'::regclass and tgenabled = 'O'
         and ((tgname = 'dyorhq_storage_upload_gate' and tgfoid = 'public.storage_objects_upload_gate()'::regprocedure)
           or (tgname = 'dyorhq_launch_media_write_once' and tgfoid = 'public.storage_launch_media_write_once()'::regprocedure))) <> 2 then
    raise exception 'the storage.objects triggers dyorhq_storage_upload_gate / dyorhq_launch_media_write_once are missing or disabled';
  end if;
  -- The only launch-media UPDATE policy is the interim one, limited to content-addressed Moment names.
  select string_agg(policyname, ', ') into offending from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and cmd in ('UPDATE', 'ALL')
     and (coalesce(qual, '') || coalesce(with_check, '')) like '%launch-media%'
     and not (policyname = 'launch_media_owner_update' and cmd = 'UPDATE'
              and qual like '%moment-[0-9a-f]{64}%' and with_check like '%moment-[0-9a-f]{64}%');
  if offending is not null then
    raise exception 'launch-media objects can still be overwritten beyond content-addressed names: %', offending;
  end if;
  -- The budget functions' owner must see every object, or the quota would count nothing and allow everything.
  select string_agg(p.oid::regprocedure::text, ', ') into offending
    from pg_proc p join pg_roles o on o.oid = p.proowner
   where p.oid in ('public.storage_wallet_upload_budget(text, bigint)'::regprocedure,
                   'public.storage_upload_allowed(text)'::regprocedure,
                   'public.storage_objects_upload_gate()'::regprocedure)
     and not (o.rolsuper or (o.rolbypassrls and has_table_privilege(o.oid, 'storage.objects', 'select')));
  if offending is not null then
    raise exception 'the owner of % must bypass RLS and be able to read storage.objects', offending;
  end if;
  if has_function_privilege('anon', 'public.storage_upload_allowed(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.storage_upload_allowed(text)', 'execute') then
    raise exception 'storage_upload_allowed(text) must be executable by authenticated and not by anon';
  end if;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.storage_wallet_upload_budget(text, bigint)', 'execute') then
      raise exception '% can execute storage_wallet_upload_budget', r;
    end if;
    if has_table_privilege(r, 'public.storage_upload_events', 'select, insert, update, delete, truncate, references, trigger') then
      raise exception '% has privileges on storage_upload_events', r;
    end if;
  end loop;
  if has_table_privilege('anon', 'public.upload_blocklist', 'select, insert, update, delete')
     or has_table_privilege('authenticated', 'public.upload_blocklist', 'select, insert, update, delete') then
    raise exception 'upload_blocklist must not be reachable by anon or authenticated';
  end if;
  if (select count(*) from storage.buckets
       where (id = 'avatars' and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg'])
          or (id = 'launch-media' and file_size_limit = 52428800
              and allowed_mime_types = array['image/jpeg', 'video/mp4', 'video/quicktime'])) <> 2 then
    raise exception 'bucket limits for avatars / launch-media did not take';
  end if;
end
$$;
