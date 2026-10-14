-- 21_storage_owner_only_read — stop anyone from LISTING the avatars and launch-media buckets (security audit
-- 2026-09-22: "anyone can list the files in the storage buckets").
--
-- Migrations 08/09 added avatars_public_read / launch_media_public_read: SELECT on storage.objects for role PUBLIC
-- (so anon) over the whole bucket. A public bucket does not need them to serve files — /storage/v1/object/public/…
-- (and /render/image/public/…) are served without any RLS check — so their only effect was to let the publishable key
-- call POST /storage/v1/object/list/<bucket> and enumerate every wallet folder and file. They are replaced by an
-- owner-only SELECT for signed-in wallets on their own folder, <bucket>/<app_wallet()>/…
--
-- What depends on SELECT (checked in the iOS app and web app, 2026-09-23):
--   * Uploads — SupabaseClient.uploadPublic sends x-upsert: true, and Storage needs SELECT + INSERT + UPDATE for an
--     upsert. Every path is "<signed-in wallet>/<file>" (avatars/<wallet>/avatar.jpg, launch-media/<wallet>/<uuid>.jpg,
--     launch-media/<wallet>/moment-<hash>.<ext>), which the owner SELECT covers.
--   * Account deletion — SupabaseClient.deleteObjects lists avatars/<wallet>/ then deletes those paths: owner-only.
--   * Everything else reads by public URL: profile avatars, launchpad logos, Moment media/mirrors, pin-media's fetch
--     (…/object/public/launch-media/<wallet>/<file>), and on-chain URIs — none of them use SELECT.
--   * The web app has no Storage calls.
--
-- Reverse: drop the two *_owner_read policies and recreate
--   create policy "avatars_public_read" on storage.objects for select using (bucket_id = 'avatars');
--   create policy "launch_media_public_read" on storage.objects for select using (bucket_id = 'launch-media');

-- Guard: public reads keep working without a SELECT policy only while both buckets stay public.
do $$
begin
  if (select count(*) from storage.buckets where id in ('avatars', 'launch-media') and public) <> 2 then
    raise exception 'avatars and launch-media must both be public buckets before their public-read policies are dropped';
  end if;
end
$$;

drop policy if exists "avatars_public_read" on storage.objects;
drop policy if exists "launch_media_public_read" on storage.objects;

drop policy if exists "avatars_owner_read" on storage.objects;
create policy "avatars_owner_read" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.app_wallet());

drop policy if exists "launch_media_owner_read" on storage.objects;
create policy "launch_media_owner_read" on storage.objects
  for select to authenticated
  using (bucket_id = 'launch-media' and (storage.foldername(name))[1] = public.app_wallet());
