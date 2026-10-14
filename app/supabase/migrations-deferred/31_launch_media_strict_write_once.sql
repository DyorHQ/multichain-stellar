-- 31_launch_media_strict_write_once — ends migration 26's interim exception: no launch-media object can be uploaded
-- over any more, not even with the same bytes (security audit 2026-09-26, SB-6 / PR-2 / OH-6; review of the fixes,
-- 2026-09-27).
--
-- DEFERRED: this file lives outside supabase/migrations on purpose, so no `db push` applies it early. Apply it only once
-- BOTH hold:
--   (a) the first iOS build that uploads launch-media with x-upsert: false, and treats 409 Duplicate on a
--       moment-<keccak> name as "already uploaded" (its public URL is the mirror), has shipped; and
--   (b) every older build is expired in App Store Connect / TestFlight. Raising app_config ios.min_build (migration 28)
--       is not enough on its own: builds without the "Update required" check ignore it.
-- Older builds upload with x-upsert: true and give up on any non-2xx, so once this is applied they can no longer use the
-- same Moment photo or video twice. Before applying: set v_ready below to true, then move this file into
-- supabase/migrations/ so the repository matches the database.
--
-- What it does: drops launch_media_owner_update (so an upload over an existing launch-media path is refused at
-- Storage's permission probe), and replaces storage_launch_media_write_once() with the strict version, which refuses
-- every move or rename and every change to a launch-media row's version, size, eTag or type, for every role. That also
-- closes the MD5-collision swap migration 26 accepted for the interim. Idempotent.
--
-- Reverse: re-run supabase/migrations/26_storage_write_once_and_upload_limits.sql (restores the interim policy and
--          trigger function).
-- Verify after apply:
--   select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
--      and cmd in ('UPDATE', 'ALL') and (coalesce(qual, '') || coalesce(with_check, '')) like '%launch-media%';   -- 0
--   select pg_get_functiondef('public.storage_launch_media_write_once()'::regprocedure) like '%INTERIM%';          -- false

do $$
declare
  v_ready constant boolean := false;  -- SET TRUE once (a) and (b) in the header both hold
begin
  if not v_ready then
    raise exception 'not ready: apply only once the build that uploads launch-media with x-upsert: false is out and every older build is expired (see the header)';
  end if;
end
$$;

drop policy if exists "launch_media_owner_update" on storage.objects;

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
  raise exception 'launch-media objects are write-once: this name is already taken' using errcode = '23505';
end;
$function$;

revoke all on function public.storage_launch_media_write_once() from public, anon, authenticated, service_role;
comment on function public.storage_launch_media_write_once() is
  'BEFORE UPDATE on storage.objects (trigger dyorhq_launch_media_write_once): refuses moving or renaming a launch-media object and any change to its version, size, eTag or type, for every role (strict, migrations-deferred/31).';

do $$
begin
  if exists (select 1 from pg_policies
              where schemaname = 'storage' and tablename = 'objects' and cmd in ('UPDATE', 'ALL')
                and (coalesce(qual, '') || coalesce(with_check, '')) like '%launch-media%') then
    raise exception 'a launch-media UPDATE policy remains';
  end if;
  if pg_catalog.pg_get_functiondef('public.storage_launch_media_write_once()'::regprocedure) like '%INTERIM%' then
    raise exception 'storage_launch_media_write_once() still has the interim exception';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'storage.objects'::regclass and tgname = 'dyorhq_launch_media_write_once' and tgenabled = 'O') then
    raise exception 'trigger dyorhq_launch_media_write_once is missing or disabled: apply migration 26 first';
  end if;
end
$$;
