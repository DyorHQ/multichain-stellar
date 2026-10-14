-- Migration 08: profile-picture storage for DyorHQ Social.
-- Applied to the live project (ref fmnjqrguvopusfufmirs) on 2026-09-09. The `profiles.avatar_url` column already
-- existed; this adds a public `avatars` bucket and wallet-scoped write policies. Only public URLs are stored in
-- `profiles` — never image bytes — and a wallet may only write inside its own folder (avatars/<wallet>/…).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read" on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists "avatars_owner_insert" on storage.objects;
create policy "avatars_owner_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.app_wallet());

drop policy if exists "avatars_owner_update" on storage.objects;
create policy "avatars_owner_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.app_wallet())
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.app_wallet());

drop policy if exists "avatars_owner_delete" on storage.objects;
create policy "avatars_owner_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.app_wallet());
