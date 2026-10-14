-- Migration 09: image storage for launchpad coins (DyorHQ Launch).
-- Applied to the live project (ref fmnjqrguvopusfufmirs) on 2026-09-10. A public `launch-media` bucket; a signed-in
-- wallet uploads to its own folder, and the resulting public URL is written on-chain as the token's logo.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('launch-media', 'launch-media', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists "launch_media_public_read" on storage.objects;
create policy "launch_media_public_read" on storage.objects
  for select using (bucket_id = 'launch-media');

drop policy if exists "launch_media_owner_insert" on storage.objects;
create policy "launch_media_owner_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'launch-media' and (storage.foldername(name))[1] = public.app_wallet());

drop policy if exists "launch_media_owner_update" on storage.objects;
create policy "launch_media_owner_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'launch-media' and (storage.foldername(name))[1] = public.app_wallet())
  with check (bucket_id = 'launch-media' and (storage.foldername(name))[1] = public.app_wallet());
