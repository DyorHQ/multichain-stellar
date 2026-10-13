-- Public-read bucket for launch images, Moment media and metadata JSON. Writes happen only through signed upload
-- URLs the lite function issues, and through the function itself (service-role key); no storage policies for anon or
-- authenticated users. Skipped where the storage schema doesn't exist (plain Postgres in CI).
do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('lite-media', 'lite-media', true, 26214400,
            array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/quicktime','application/json'])
    on conflict (id) do nothing;
  else
    raise notice 'storage schema not present: lite-media bucket skipped';
  end if;
end $$;
