-- 29_waitlist — stores the website's waitlist signups (audit 2026-09-26, LR-4: the form only opened a mail draft, so
-- nothing was stored and nobody could tell whether they had joined).
--
-- Written only by the `waitlist` Edge Function (service role), which validates the email, drops honeypot submissions,
-- rate-limits per client network through edge_rate_gate (migration 27; the network is never stored, here or there),
-- and inserts with ON CONFLICT DO NOTHING — answering the same {"ok": true} whether or not the address was already on
-- the list, so the endpoint cannot be used to test which emails signed up. RLS on, no policies, no privileges for
-- anon or authenticated: the list is readable only with the service role (dashboard, exports).
--
-- Reverse: drop table public.waitlist;   (citext stays installed; other objects may use it)
-- Verify after apply:
--   select has_table_privilege('anon', 'public.waitlist', 'select,insert,update,delete'),          -- false
--          has_table_privilege('authenticated', 'public.waitlist', 'select,insert,update,delete'), -- false
--          (select relrowsecurity from pg_class where oid = 'public.waitlist'::regclass);          -- true

create extension if not exists citext with schema extensions;

create table if not exists public.waitlist (
  email      extensions.citext primary key check (char_length(email::text) between 3 and 254),
  source     text check (source is null or char_length(source) <= 64),
  created_at timestamptz not null default now()
);
alter table public.waitlist enable row level security;
revoke all on public.waitlist from public, anon, authenticated;
comment on table public.waitlist is
  'Website waitlist signups (email, optional source tag, time). Written only by the waitlist Edge Function with the service role; RLS on, no policies, no anon/authenticated privileges. Holds no IP address or other request data.';

do $$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if has_table_privilege(r, 'public.waitlist', 'select, insert, update, delete, truncate, references, trigger') then
      raise exception '% still has privileges on public.waitlist', r;
    end if;
  end loop;
  if not (select relrowsecurity from pg_class where oid = 'public.waitlist'::regclass) then
    raise exception 'RLS is not enabled on public.waitlist';
  end if;
end
$$;
