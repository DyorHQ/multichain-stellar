-- 24_email_pepper_network_limit_anonymous_only — the per-network pepper limit counts and holds only ANONYMOUS
-- requests (security audit 2026-09-26, SB-4; the patch in the audit report, section 11).
--
-- Migration 20 held every request, verified or not, to its client network's limit (60 / 15 min), and counted verified
-- requests toward it. Anyone behind the same NAT or carrier-grade NAT could therefore spend that budget with anonymous
-- requests and lock verified owners out, even though they had just proved their email with a one-time code. Now:
--   * anonymous requests (p_verified = false): unchanged — 10 / 15 min and 50 / 24 h per e, plus 60 / 15 min per
--     client network, counting anonymous requests only;
--   * verified requests (p_verified = true): 20 / 24 h per e, and no network limit. They are already bounded per
--     email by that budget, and the edge function reaches them only after email_pepper_lookup_gate() (10 per Privy
--     user and 30 per client network per 15 minutes, for uncached lookups), which keeps its own network limit on
--     purpose: it protects Privy's app-wide rate limit from floods of valid tokens.
-- A 'network' refusal from email_pepper_hmac() can now only answer an anonymous request, and proving the email then
-- lifts it.
--
-- The lookup gate a verified request passes first had the same weakness (review of the fixes, 2026-09-27): its network
-- limit protects Privy's app-wide rate limit from floods of valid tokens, but anyone behind the same NAT holding three
-- OTP-verified Privy accounts (10 lookups each) could spend it and lock verified owners out of uncached lookups. Now a
-- Privy user's first two lookups in any 15 minutes are not held to the network limit (they still count toward it);
-- from the third on it applies as before. Each exempt lookup needs its own OTP-verified Privy account, and the per-user
-- limit (10 per 15 minutes) is unchanged. email-rebind and delete-account pass no network, so they are unaffected.
--
-- Only those two conditions changed. The rest of each body is migration 20's, which was checked against the live
-- functions (read-only: the live prosrc equals migration 20's body without its comment lines — email_pepper_hmac md5
-- 1d8629a6115b4f9cff8a5e6e0bdb920a on 2026-09-26, email_pepper_lookup_gate md5 4313ab1fd15aa800bd638319f9893746 on
-- 2026-09-27). Grants are re-asserted. Idempotent.
--
-- Reverse: re-run sections 4 and 5 of 20_email_pepper.sql (create or replace with the old conditions).
-- Verify after apply:
--   select pg_get_functiondef('public.email_pepper_hmac(text,text,text,boolean)'::regprocedure)
--          like '%not p_verified and v_ip is not null and a.ip = v_ip and not a.verified%',           -- true
--          pg_get_functiondef('public.email_pepper_lookup_gate(text,text)'::regprocedure)
--          like '%a.subject = p_subject and a.created_at > now() - interval ''15 minutes''%offset 1 limit 1%'; -- true
--   select has_function_privilege('anon', 'public.email_pepper_hmac(text,text,text,boolean)', 'execute'),          -- false
--          has_function_privilege('authenticated', 'public.email_pepper_hmac(text,text,text,boolean)', 'execute'), -- false
--          has_function_privilege('service_role', 'public.email_pepper_hmac(text,text,text,boolean)', 'execute'),  -- true
--          has_function_privilege('anon', 'public.email_pepper_lookup_gate(text,text)', 'execute'),                -- false
--          has_function_privilege('authenticated', 'public.email_pepper_lookup_gate(text,text)', 'execute'),       -- false
--          has_function_privilege('service_role', 'public.email_pepper_lookup_gate(text,text)', 'execute');        -- true

create or replace function public.email_pepper_hmac(p_e text, p_t text, p_ip text, p_verified boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_ip          text := nullif(left(btrim(coalesce(p_ip, '')), 64), '');
  v_email_until timestamptz;
  v_net_until   timestamptz;
  v_key         text;
begin
  if p_e is null or p_e !~ '^[0-9a-f]{64}$' or p_t is null or p_t !~ '^[0-9a-f]{64}$' then
    raise exception 'e and t must each be 64 lowercase hex characters' using errcode = '22023';
  end if;
  if p_verified is null then
    raise exception 'p_verified must be true or false' using errcode = '22023';
  end if;

  -- Serialise attempts for the same email hash, then the same IP (always in that order, so no lock cycle): the counts
  -- below are exact under concurrency. Transaction-scoped, released at commit.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/email-pepper/e'), pg_catalog.hashtext(p_e));
  if v_ip is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/email-pepper/ip'), pg_catalog.hashtext(v_ip));
  end if;

  delete from public.email_pepper_attempts where created_at < now() - interval '1 day';

  -- Over a limit of L per window W when the L-th most recent attempt is still inside W; it is also the attempt that
  -- has to age out before the next one is allowed, so it gives retryAfter. Each request is held to its own budget for
  -- e (anonymous rows only, or verified rows only — neither can exhaust the other). An anonymous request is also held
  -- to its network's limit, which counts anonymous rows only; a verified request has no network limit (migration 24,
  -- SB-4), so nobody sharing a network can lock a verified owner out. The refusal says which limit fired: 'network'
  -- whenever the network's limit is among those spent (proving the email lifts it), else 'email'; retryAfter is when
  -- every spent limit has room again.
  select max(w.until) filter (where w.lim = 'email'), max(w.until) filter (where w.lim = 'network')
    into v_email_until, v_net_until
  from (
    (select a.created_at + interval '15 minutes' as until, 'email'::text as lim from public.email_pepper_attempts a
      where not p_verified and a.e = p_e and not a.verified and a.created_at > now() - interval '15 minutes'
      order by a.created_at desc offset 9 limit 1)
    union all
    (select a.created_at + interval '1 day', 'email'::text from public.email_pepper_attempts a
      where not p_verified and a.e = p_e and not a.verified and a.created_at > now() - interval '1 day'
      order by a.created_at desc offset 49 limit 1)
    union all
    (select a.created_at + interval '1 day', 'email'::text from public.email_pepper_attempts a
      where p_verified and a.e = p_e and a.verified and a.created_at > now() - interval '1 day'
      order by a.created_at desc offset 19 limit 1)
    union all
    (select a.created_at + interval '15 minutes', 'network'::text from public.email_pepper_attempts a
      where not p_verified and v_ip is not null and a.ip = v_ip and not a.verified
        and a.created_at > now() - interval '15 minutes'
      order by a.created_at desc offset 59 limit 1)
  ) w;
  if v_email_until is not null or v_net_until is not null then
    return jsonb_build_object(
      'retryAfter', greatest(1, ceil(extract(epoch from greatest(v_email_until, v_net_until) - now()))::int),
      'limit', case when v_net_until is not null then 'network' else 'email' end);
  end if;

  select s.decrypted_secret into v_key from vault.decrypted_secrets s where s.name = 'email_pepper_key';
  if v_key is null or v_key !~ '^[0-9a-f]{64}$' then
    raise exception 'email_pepper_key is missing or malformed' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.email_pepper_key_check c where c.kcv = encode(extensions.hmac(
      convert_to('dyorhq/email-pepper/kcv', 'UTF8'), decode(v_key, 'hex'), 'sha256'), 'hex')) then
    raise exception 'email_pepper_key does not match its recorded check value: refusing to serve peppers' using errcode = 'P0001';
  end if;

  insert into public.email_pepper_attempts (e, ip, verified) values (p_e, v_ip, p_verified);

  return jsonb_build_object('p', encode(extensions.hmac(
    convert_to('dyorhq/email-pepper/v1', 'UTF8') || decode('00', 'hex') || decode(p_e, 'hex') || decode(p_t, 'hex'),
    decode(v_key, 'hex'),
    'sha256'), 'hex'));
end;
$function$;

revoke all on function public.email_pepper_hmac(text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.email_pepper_hmac(text, text, text, boolean) to service_role;

comment on function public.email_pepper_hmac(text, text, text, boolean) is
  'email-pepper: rate-limits (per email hash: anonymous 10/15 min + 50/24 h, or with p_verified — set by the edge function only after a valid Privy access token for the user whose linked email hashes to this e — a separate 20/24 h; per client network 60/15 min, anonymous requests only), records the attempt, and returns {"p": HMAC-SHA256(vault email_pepper_key, "dyorhq/email-pepper/v1" || 0x00 || e || t)} or {"retryAfter": seconds, "limit": "email"|"network"}. Refuses if the key does not match email_pepper_key_check. Never returns the key. service_role only.';

create or replace function public.email_pepper_lookup_gate(p_subject text, p_ip text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_ip            text := nullif(left(btrim(coalesce(p_ip, '')), 64), '');
  v_subject_until timestamptz;
  v_net_until     timestamptz;
begin
  if p_subject is null or p_subject !~ '^[0-9a-f]{64}$' then
    raise exception 'subject must be 64 lowercase hex characters' using errcode = '22023';
  end if;

  -- Same discipline as email_pepper_hmac(): subject lock, then network lock, so the counts are exact.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/email-pepper/lookup-subject'), pg_catalog.hashtext(p_subject));
  if v_ip is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/email-pepper/lookup-ip'), pg_catalog.hashtext(v_ip));
  end if;

  delete from public.email_pepper_lookups where created_at < now() - interval '1 hour';

  select a.created_at + interval '15 minutes' into v_subject_until from public.email_pepper_lookups a
    where a.subject = p_subject and a.created_at > now() - interval '15 minutes'
    order by a.created_at desc offset 9 limit 1;
  -- The network limit holds a Privy user only from their third lookup in 15 minutes on (migration 24, SB-4), so
  -- nobody sharing the network can lock a verified owner out of their first two.
  if v_ip is not null and exists (select 1 from public.email_pepper_lookups a
                                   where a.subject = p_subject and a.created_at > now() - interval '15 minutes'
                                   offset 1 limit 1) then
    select a.created_at + interval '15 minutes' into v_net_until from public.email_pepper_lookups a
      where a.ip = v_ip and a.created_at > now() - interval '15 minutes'
      order by a.created_at desc offset 29 limit 1;
  end if;
  if v_subject_until is not null or v_net_until is not null then
    return jsonb_build_object(
      'retryAfter', greatest(1, ceil(extract(epoch from greatest(v_subject_until, v_net_until) - now()))::int),
      'limit', case when v_net_until is not null then 'network' else 'proof' end);
  end if;

  insert into public.email_pepper_lookups (subject, ip) values (p_subject, v_ip);
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.email_pepper_lookup_gate(text, text) from public, anon, authenticated;
grant execute on function public.email_pepper_lookup_gate(text, text) to service_role;

comment on function public.email_pepper_lookup_gate(text, text) is
  'email-pepper: before the edge function asks Privy which email a token''s user holds — at most 10 lookups per Privy user (p_subject, a hash of its id) per 15 min, and 30 per client network per 15 min for a user''s third lookup on (the first two are not held to it). Records the allowed lookup and returns {"ok": true}, or {"retryAfter": seconds, "limit": "proof"|"network"}. service_role only.';

-- Fail the migration if the new rule or the grants did not take.
do $$
begin
  if pg_catalog.pg_get_functiondef('public.email_pepper_hmac(text, text, text, boolean)'::regprocedure)
     not like '%not p_verified and v_ip is not null and a.ip = v_ip and not a.verified%' then
    raise exception 'email_pepper_hmac still counts verified requests toward the network limit';
  end if;
  if has_function_privilege('anon', 'public.email_pepper_hmac(text, text, text, boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.email_pepper_hmac(text, text, text, boolean)', 'execute')
     or not has_function_privilege('service_role', 'public.email_pepper_hmac(text, text, text, boolean)', 'execute') then
    raise exception 'email_pepper_hmac must be executable by service_role only';
  end if;
  if pg_catalog.pg_get_functiondef('public.email_pepper_lookup_gate(text, text)'::regprocedure)
     not like '%a.subject = p_subject and a.created_at > now() - interval ''15 minutes''%offset 1 limit 1%' then
    raise exception 'email_pepper_lookup_gate still holds a user''s first lookups to the network limit';
  end if;
  if has_function_privilege('anon', 'public.email_pepper_lookup_gate(text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.email_pepper_lookup_gate(text, text)', 'execute')
     or not has_function_privilege('service_role', 'public.email_pepper_lookup_gate(text, text)', 'execute') then
    raise exception 'email_pepper_lookup_gate must be executable by service_role only';
  end if;
end
$$;
