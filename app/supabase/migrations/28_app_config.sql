-- 28_app_config — public, read-only app configuration; first key: the minimum iOS build (security audit 2026-09-26,
-- GP-2: builds 12 and earlier hard-code retired contract stacks, and nothing could make them update).
--
-- This is the server switch only. NO BUILD READS IT YET (checked 2026-09-27 on main and the sec2 iOS branches):
-- raising min_build blocks nothing until the first build with the check below ships, and it never affects a build
-- without that check — builds 12 and earlier included. Retiring those builds needs App Store Connect / TestFlight
-- expiry; every deploy step written as "once build N is the minimum" means "once build N (with this check and the new
-- behaviour) has shipped AND every older build is expired", not merely "once min_build is raised".
--
-- The contract a build implements: GET <SUPABASE_URL>/rest/v1/app_config?key=eq.ios&select=value with the publishable
-- key it already uses, at launch and on returning to the foreground (at most every 10 minutes). When its
-- CFBundleVersion is below value.min_build it shows a blocking "Update required" screen (value.message, a link to
-- value.url) that still allows viewing balances and exporting keys but disables every signing action. It fails open on
-- any network or parse error, so a broken row can never lock anyone out of their funds — which is also why the 'ios'
-- row is CHECKed to keep the shape the app parses.
--
-- Access: RLS on; anon and authenticated may SELECT (policy "app config is public"); nobody but the service role and
-- the dashboard can write (no write policies, and no write grants for anon or authenticated). Never store a secret
-- here: every row is public.
--
-- Raise the minimum (dashboard SQL editor, as postgres):
--   update public.app_config set value = jsonb_set(value, '{min_build}', '15') where key = 'ios';
--
-- Reverse: drop table public.app_config;   (the app then fails open: nothing is blocked)
-- Verify after apply:
--   select value from public.app_config where key = 'ios';   -- {"url": "https://testflight.apple.com", "message": "", "min_build": 0}
--   select has_table_privilege('anon', 'public.app_config', 'select'),                        -- true
--          has_table_privilege('anon', 'public.app_config', 'insert,update,delete,truncate'), -- false
--          has_table_privilege('authenticated', 'public.app_config', 'insert,update,delete,truncate'); -- false

create table if not exists public.app_config (
  key        text primary key check (key ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'),
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  constraint app_config_ios_shape check (
    key <> 'ios' or coalesce(
      jsonb_typeof(value) = 'object'
      and jsonb_typeof(value->'min_build') = 'number'
      and (value->>'min_build') ~ '^[0-9]{1,9}$'
      and jsonb_typeof(value->'message') = 'string'
      and char_length(value->>'message') <= 500
      and jsonb_typeof(value->'url') = 'string'
      and char_length(value->>'url') <= 500
      and (value->>'url') ~ '^https://[^[:space:]]+$',
      false)
  )
);
alter table public.app_config enable row level security;
revoke all on public.app_config from public, anon, authenticated;
grant select on public.app_config to anon, authenticated;

drop policy if exists "app config is public" on public.app_config;
create policy "app config is public" on public.app_config for select to anon, authenticated using (true);

drop trigger if exists app_config_touch on public.app_config;
create trigger app_config_touch before update on public.app_config
  for each row execute function public.touch_updated_at();

-- min_build 0 blocks nothing; the owner raises it when a build must be retired.
insert into public.app_config (key, value)
values ('ios', '{"min_build": 0, "message": "", "url": "https://testflight.apple.com"}')
on conflict (key) do nothing;

comment on table public.app_config is
  'Public, read-only app configuration (anyone with the publishable key can read every row: never store a secret). Written only by the service role / dashboard. Key ''ios'': {min_build, message, url} — the minimum CFBundleVersion below which a build that implements the check shows "Update required" (builds without the check ignore it).';

-- Fail the migration if the access rules did not take.
do $$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if not has_table_privilege(r, 'public.app_config', 'select')
       or has_table_privilege(r, 'public.app_config', 'insert, update, delete, truncate, references, trigger') then
      raise exception '% must be able to SELECT public.app_config and nothing else', r;
    end if;
  end loop;
  if not (select relrowsecurity from pg_class where oid = 'public.app_config'::regclass) then
    raise exception 'RLS is not enabled on public.app_config';
  end if;
  if not exists (select 1 from public.app_config where key = 'ios') then
    raise exception 'the ios row is missing';
  end if;
end
$$;
