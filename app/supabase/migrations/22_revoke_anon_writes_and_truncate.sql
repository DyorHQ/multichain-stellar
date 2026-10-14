-- 22_revoke_anon_writes_and_truncate — least-privilege table grants (security audit 2026-09-22: "default anon write
-- grants"). Supabase's default privileges gave anon and authenticated EVERY table privilege (arwdDxtm) on every public
-- table, so today only RLS stands between the publishable key and a write, and TRUNCATE — which RLS does NOT apply to —
-- is granted to both roles. This removes the grants that no policy can ever use, so a future policy mistake cannot
-- expose a write path to anyone holding the publishable key. SELECT is kept everywhere (public reads are unchanged,
-- and tables without an anon policy keep returning an empty result, as today).
--
-- Analysis of pg_policies (2026-09-23), per table and command. A policy "applies to anon" if its roles include anon or
-- public. No policy applies to anon for INSERT, UPDATE, DELETE or ALL on ANY public table — every write/ALL policy is
-- `to authenticated` and keyed on app_wallet(), which is null without a wallet claim — so anon INSERT/UPDATE/DELETE is
-- dead on every table and is revoked everywhere:
--   activity        — only "owner manages own activity" (authenticated, ALL)                    → anon: no write policy
--   alerts          — only "owner manages own alerts" (authenticated, ALL)                      → anon: no write policy
--   comments        — "comments are public" (public, SELECT); author INSERT/DELETE are authenticated → anon: read only
--   device_tokens   — only "owner manages own devices" (authenticated, ALL)                     → anon: no write policy
--   email_accounts  — owner SELECT + DELETE (authenticated); anon already had no I/U/D (migration 16) → no-op for I/U/D
--   follows         — "follows are public" (public, SELECT); owner ALL is authenticated         → anon: read only
--   launches        — "launches are public" (public, SELECT); no write policy for anyone         → anon: read only
--   leaderboard     — "leaderboard is public" (public, SELECT); no write policy for anyone       → anon: read only
--   notifications   — only "owner manages own notifications" (authenticated, ALL)               → anon: no write policy
--   posts           — "posts are public" (public, SELECT); author INSERT/DELETE are authenticated → anon: read only
--   profiles        — "profiles are public" (public, SELECT); owner INSERT/UPDATE/DELETE are authenticated → read only
--   reactions       — "reactions are public" (public, SELECT); owner ALL is authenticated        → anon: read only
--   referral_codes  — "codes are public" (public, SELECT); owner ALL is authenticated            → anon: read only
--   referrals       — referee INSERT + parties SELECT, both authenticated                        → anon: no write policy
--   sessions        — only "owner manages own sessions" (authenticated, ALL)                    → anon: no write policy
--   user_settings   — owner ALL + owner SELECT (authenticated)                                  → anon: no write policy
--   watchlist       — owner ALL + owner SELECT (authenticated)                                  → anon: no write policy
--   auth_nonces, email_pepper_attempts, email_pepper_key_check (migrations 19/20) — already no anon/authenticated grants
--   user_journey (view) — no anon/authenticated grants since migration 14
-- TRUNCATE bypasses RLS entirely and no client path uses it (PostgREST cannot even issue it), so it is revoked from
-- anon AND authenticated on every table. authenticated keeps INSERT/UPDATE/DELETE (its owner policies need them).
--
-- Future tables: default privileges for tables that `postgres` creates in public (every migration runs as postgres)
-- stop granting anon INSERT/UPDATE/DELETE/TRUNCATE and authenticated TRUNCATE. (Supabase's separate default ACL for
-- objects created by supabase_admin cannot be altered from a migration; this project creates none.)
--
-- Reverse:
--   grant insert, update, delete, truncate on all tables in schema public to anon;
--   grant truncate on all tables in schema public to authenticated;
--   alter default privileges for role postgres in schema public grant insert, update, delete, truncate on tables to anon;
--   alter default privileges for role postgres in schema public grant truncate on tables to authenticated;
-- Verify after apply (expect zero rows):
--   select table_name, grantee, privilege_type from information_schema.role_table_grants
--    where table_schema = 'public' and ((grantee = 'anon' and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE'))
--                                    or (grantee = 'authenticated' and privilege_type = 'TRUNCATE'));

-- Guard: re-check the analysis at apply time. If any policy now lets anon/public write, stop instead of breaking it.
do $$
declare
  offending text;
begin
  select string_agg(format('%I.%I (%s: %s)', schemaname, tablename, policyname, cmd), ', ')
    into offending
    from pg_policies
   where schemaname = 'public'
     and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
     and roles && array['anon', 'public']::name[];
  if offending is not null then
    raise exception 'anon/public write policies exist — re-analyse before revoking: %', offending;
  end if;
end
$$;

revoke insert, update, delete, truncate on all tables in schema public from anon;
revoke truncate on all tables in schema public from authenticated;

alter default privileges for role postgres in schema public revoke insert, update, delete, truncate on tables from anon;
alter default privileges for role postgres in schema public revoke truncate on tables from authenticated;
