-- 27_edge_rate_limits — per-wallet, per-network and overall budgets for the Edge Functions that spend a third party's
-- quota, write on behalf of anonymous callers, or hand out sessions (security audit 2026-09-26, SB-2 and OH-6; LR-4 for
-- the waitlist; revised after the review of the fixes, 2026-09-27).
--
-- A wallet-auth session costs nothing but a fresh key, so "signed in" alone does not bound pin-media (Pinata) or
-- aurora-proxy (the Aurora API key), and the waitlist has no sign-in at all. Each call now first passes
-- edge_rate_gate(scope, subject, ip), the same shape as email_pepper_lookup_gate (migration 20): the limits live
-- here, allowed calls are recorded, refused calls are not (so hammering does not extend a lockout), and an advisory
-- lock per subject, per network and (for a scope with an overall limit) per scope makes the counts exact under
-- concurrency.
--
--   scope          subject (the function passes)   per subject             per client network        overall
--   pin-media      the session's wallet            20 / 15 min, 100 / day  60 / 15 min               1,000 / day
--   aurora         the session's wallet (tokens,   120 / 15 min            360 / 15 min
--                  quote, deposit/submit)
--   aurora-status  the session's wallet (status    900 / 15 min            2,700 / 15 min
--                  polls: every 4 s for about
--                  10 min per bridge, several
--                  bridges tracked at once)
--   waitlist       'all' (a global cap)            500 / hour              5 / 15 min, 20 / day
--   wallet-auth    none                                                    30 / 15 min, 200 / day
--
-- wallet-auth calls the gate only for a wallet signing in for the first time (no profile row yet), so a returning
-- wallet is never counted or refused, whoever shares its network. It bounds how many new wallets, and so how many
-- per-wallet budgets (here and in storage, migration 26), one client network can bring in. pin-media's overall limit is
-- a circuit breaker on the Pinata account: when it is spent, pinning fails for everyone until older pins age out.
--
-- The client network is what the function reads from cf-connecting-ip: an IPv4 address, or an IPv6 /64 — a /48 for
-- wallet-auth and the waitlist, whose limits exist to stop one party from rotating addresses, and a /48 is what a
-- tunnel broker hands out for free (_shared/net.ts). It is never stored: edge_rate_events keeps
-- HMAC-SHA256(salt, network), with a random salt that is generated inside the database and readable by no API role, so
-- the stored value cannot be brute-forced back to an address (the IPv4 space is small enough that a plain hash could).
-- Rows older than a day are purged on every call. Known limit: a party with many IPv4 addresses (a proxy pool) or a
-- larger IPv6 block still gets many network budgets; the per-subject and overall limits bound what that buys.
--
-- edge_rate_events and edge_rate_salt: RLS on, no policies, and no privileges for anon, authenticated or
-- service_role — only edge_rate_gate(), running as the owner, touches them. edge_rate_gate(text, text, text) is
-- executable by service_role only. Returns {"ok": true} or {"retryAfter": seconds, "limit": "subject"|"network"|"global"}.
--
-- Reverse: drop function public.edge_rate_gate(text, text, text); drop table public.edge_rate_events;
--          drop table public.edge_rate_salt;   (and redeploy pin-media / aurora-proxy / waitlist / wallet-auth without
--          the gate first: they fail closed without it)
-- Verify after apply:
--   select has_function_privilege('anon', 'public.edge_rate_gate(text,text,text)', 'execute'),            -- false
--          has_function_privilege('authenticated', 'public.edge_rate_gate(text,text,text)', 'execute'),   -- false
--          has_function_privilege('service_role', 'public.edge_rate_gate(text,text,text)', 'execute'),    -- true
--          has_table_privilege('service_role', 'public.edge_rate_events', 'select,insert,update,delete'), -- false
--          has_table_privilege('service_role', 'public.edge_rate_salt', 'select,insert,update,delete'),   -- false
--          (select count(*) from public.edge_rate_salt);                                                  -- 1

create table if not exists public.edge_rate_salt (
  id         boolean primary key default true check (id),
  salt       bytea not null check (octet_length(salt) = 32),
  created_at timestamptz not null default now()
);
alter table public.edge_rate_salt enable row level security;
revoke all on public.edge_rate_salt from public, anon, authenticated, service_role;
insert into public.edge_rate_salt (salt) values (extensions.gen_random_bytes(32)) on conflict (id) do nothing;
comment on table public.edge_rate_salt is
  'Random salt for edge_rate_events.net (HMAC of the client network). Rotating it only resets the network counters. No API role has access.';

create table if not exists public.edge_rate_events (
  id         uuid primary key default gen_random_uuid(),
  scope      text not null,
  subject    text check (subject is null or char_length(subject) <= 64),
  net        text check (net is null or net ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
-- Named and re-asserted, so a table created by an earlier revision of this migration accepts the current scopes.
alter table public.edge_rate_events drop constraint if exists edge_rate_events_scope_check;
alter table public.edge_rate_events add constraint edge_rate_events_scope_check
  check (scope in ('pin-media', 'aurora', 'aurora-status', 'waitlist', 'wallet-auth'));
alter table public.edge_rate_events enable row level security;
revoke all on public.edge_rate_events from public, anon, authenticated, service_role;
create index if not exists edge_rate_events_subject_idx on public.edge_rate_events (scope, subject, created_at desc) where subject is not null;
create index if not exists edge_rate_events_net_idx on public.edge_rate_events (scope, net, created_at desc) where net is not null;
create index if not exists edge_rate_events_scope_idx on public.edge_rate_events (scope, created_at desc);
create index if not exists edge_rate_events_created_at_idx on public.edge_rate_events (created_at);
comment on table public.edge_rate_events is
  'One row per Edge Function call edge_rate_gate() allowed (scope, subject, HMAC of the client network, time); purged after a day. Never stores an IP address. RLS on, no policies, no grants to anon/authenticated/service_role: only edge_rate_gate() (as owner) touches it.';

create or replace function public.edge_rate_gate(p_scope text, p_subject text, p_ip text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_subject       text := nullif(btrim(coalesce(p_subject, '')), '');
  v_ip            text := nullif(left(btrim(coalesce(p_ip, '')), 64), '');
  v_net           text;
  v_subject_until timestamptz;
  v_net_until     timestamptz;
  v_global_until  timestamptz;
begin
  if p_scope is null or p_scope not in ('pin-media', 'aurora', 'aurora-status', 'waitlist', 'wallet-auth') then
    raise exception 'unknown rate-limit scope' using errcode = '22023';
  end if;
  if v_subject is not null and char_length(v_subject) > 64 then
    raise exception 'subject must be at most 64 characters' using errcode = '22023';
  end if;
  if v_ip is not null then
    select encode(extensions.hmac(convert_to('dyorhq/edge-rate/v1/net:' || v_ip, 'UTF8'), s.salt, 'sha256'), 'hex')
      into v_net from public.edge_rate_salt s;
    if v_net is null then
      raise exception 'edge_rate_salt is missing' using errcode = 'P0001';
    end if;
  end if;

  -- Subject lock, then network lock, then — for the scopes with an overall ('global') limit below — the scope lock
  -- (always in that order, so no lock cycle). Released at commit.
  if v_subject is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/edge-rate/subject'), pg_catalog.hashtext(p_scope || '/' || v_subject));
  end if;
  if v_net is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/edge-rate/net'), pg_catalog.hashtext(p_scope || '/' || v_net));
  end if;
  if p_scope = 'pin-media' then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/edge-rate/scope'), pg_catalog.hashtext(p_scope));
  end if;

  delete from public.edge_rate_events where created_at < now() - interval '1 day';

  -- Over a limit of L per window W when the L-th most recent allowed call is still inside W; it is also the call that
  -- has to age out before the next one is allowed, so it gives retryAfter. A null subject or network skips its limits;
  -- a 'global' limit counts every call in the scope.
  select max(x.until) filter (where l.kind = 'subject'), max(x.until) filter (where l.kind = 'network'),
         max(x.until) filter (where l.kind = 'global')
    into v_subject_until, v_net_until, v_global_until
  from (values
      ('pin-media',     'subject', interval '15 minutes',   20),
      ('pin-media',     'subject', interval '1 day',       100),
      ('pin-media',     'network', interval '15 minutes',   60),
      ('pin-media',     'global',  interval '1 day',      1000),
      ('aurora',        'subject', interval '15 minutes',  120),
      ('aurora',        'network', interval '15 minutes',  360),
      ('aurora-status', 'subject', interval '15 minutes',  900),
      ('aurora-status', 'network', interval '15 minutes', 2700),
      ('waitlist',      'subject', interval '1 hour',      500),
      ('waitlist',      'network', interval '15 minutes',    5),
      ('waitlist',      'network', interval '1 day',        20),
      ('wallet-auth',   'network', interval '15 minutes',   30),
      ('wallet-auth',   'network', interval '1 day',       200)
    ) as l(scope, kind, win, lim)
  cross join lateral (
    select e.created_at + l.win as until
      from public.edge_rate_events e
     where e.scope = p_scope
       and ((l.kind = 'subject' and v_subject is not null and e.subject = v_subject)
         or (l.kind = 'network' and v_net is not null and e.net = v_net)
         or l.kind = 'global')
       and e.created_at > now() - l.win
     order by e.created_at desc
     offset l.lim - 1 limit 1
  ) x
  where l.scope = p_scope;

  if v_subject_until is not null or v_net_until is not null or v_global_until is not null then
    return jsonb_build_object(
      'retryAfter', greatest(1, ceil(extract(epoch from greatest(v_subject_until, v_net_until, v_global_until) - now()))::int),
      'limit', case when v_net_until is not null then 'network' when v_global_until is not null then 'global' else 'subject' end);
  end if;

  insert into public.edge_rate_events (scope, subject, net) values (p_scope, v_subject, v_net);
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.edge_rate_gate(text, text, text) from public, anon, authenticated;
grant execute on function public.edge_rate_gate(text, text, text) to service_role;
comment on function public.edge_rate_gate(text, text, text) is
  'Edge Function budgets (pin-media, aurora, aurora-status, waitlist, wallet-auth) per subject, per client network (stored only as a salted HMAC) and overall. Records the allowed call and returns {"ok": true}, or {"retryAfter": seconds, "limit": "subject"|"network"|"global"}. service_role only.';

-- Fail the migration if any API role can touch the ledger or the salt, or anyone but the service role can call the gate.
do $$
declare
  r     text;
  privs constant text := 'select, insert, update, delete, truncate, references, trigger';
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'public.edge_rate_events', privs) or has_table_privilege(r, 'public.edge_rate_salt', privs) then
      raise exception '% still has privileges on edge_rate_events / edge_rate_salt', r;
    end if;
  end loop;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, 'public.edge_rate_gate(text, text, text)', 'execute') then
      raise exception '% can still execute edge_rate_gate', r;
    end if;
  end loop;
  if not has_function_privilege('service_role', 'public.edge_rate_gate(text, text, text)', 'execute') then
    raise exception 'service_role cannot execute edge_rate_gate';
  end if;
  if (select count(*) from public.edge_rate_salt) <> 1 then
    raise exception 'edge_rate_salt must hold exactly one salt';
  end if;
end
$$;
