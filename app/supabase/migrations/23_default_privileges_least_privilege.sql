-- 23_default_privileges_least_privilege — close the two default grants migrations 18 and 22 left open (security audit
-- 2026-09-26, SB-8).
--
-- 1. New functions. The schema's default privileges for role postgres still grant EXECUTE on every NEW function to
--    anon and authenticated (and PostgreSQL grants it to PUBLIC), so the next SECURITY DEFINER function anyone adds is
--    callable with the publishable key unless its author remembers to revoke it — exactly what migration 18 had to fix
--    for three functions. From now on a new function is executable only by its owner (and the service role, which
--    every migration here grants explicitly); a function that a policy or the app must call gets an explicit
--    `grant execute … to authenticated` (or anon) in its own migration. Existing functions are unchanged: app_wallet()
--    keeps its grants (every RLS policy calls it), and trigger functions need no EXECUTE grant to fire.
-- 2. Table privileges no API role can use. Migration 22 revoked INSERT/UPDATE/DELETE/TRUNCATE; REFERENCES, TRIGGER and
--    MAINTAIN (PostgreSQL 17) were never revoked. PostgREST uses none of them. SELECT (and authenticated's writes, all
--    behind RLS) are unchanged.
--
-- The iOS app and the web app call no RPC with an API key, so nothing they do changes. Idempotent.
--
-- Reverse:
--   alter default privileges for role postgres grant execute on functions to public;
--   alter default privileges for role postgres in schema public grant execute on functions to anon, authenticated;
--   grant references, trigger, maintain on all tables in schema public to anon, authenticated;
--   alter default privileges for role postgres in schema public grant references, trigger, maintain on tables to anon, authenticated;
-- Verify after apply:
--   select coalesce(n.nspname, '(global)'), defaclobjtype, defaclacl from pg_default_acl d
--     left join pg_namespace n on n.oid = d.defaclnamespace
--    where (n.nspname = 'public' or d.defaclnamespace = 0) and pg_get_userbyid(d.defaclrole) = 'postgres';
--    -- f rows: no anon/authenticated, and no PUBLIC (an "=X/postgres" entry)
--   select count(*) from information_schema.role_table_grants where table_schema = 'public'
--    and grantee in ('anon', 'authenticated') and privilege_type in ('REFERENCES', 'TRIGGER');   -- 0

-- PUBLIC's EXECUTE on functions is a GLOBAL default (hard-wired by PostgreSQL), and a per-schema default can only add
-- to the global one, never remove from it, so PUBLIC must be revoked globally for role postgres; anon and authenticated
-- were granted per schema, so they are revoked per schema. Supabase-managed schemas (auth, storage, …) create their
-- functions as other roles and are unaffected.
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;

revoke references, trigger, maintain on all tables in schema public from anon, authenticated;
alter default privileges for role postgres in schema public revoke references, trigger, maintain on tables from anon, authenticated;

-- Fail the migration if any of it did not take.
do $$
declare
  leftover text;
begin
  select string_agg(format('%s.%s', c.relname, r.rolname), ', ') into leftover
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('anon'::name), ('authenticated'::name)) as r(rolname)
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
     and (has_table_privilege(r.rolname, c.oid, 'references') or has_table_privilege(r.rolname, c.oid, 'trigger'));
  if leftover is not null then
    raise exception 'REFERENCES/TRIGGER still granted: %', leftover;
  end if;
  -- A function created now, as postgres, must not be executable by anon or authenticated (checked for real, then
  -- dropped, so the global PUBLIC default is covered too). The probe tests the running role's defaults, so the
  -- migration must run as postgres (CLI db push, the dashboard and apply_migration all do).
  if current_user <> 'postgres' then
    raise exception 'apply migration 23 as postgres (running as %)', current_user;
  end if;
  create function public.zz_migration_23_probe() returns int language sql as 'select 1';
  if has_function_privilege('anon', 'public.zz_migration_23_probe()', 'execute')
     or has_function_privilege('authenticated', 'public.zz_migration_23_probe()', 'execute') then
    raise exception 'new functions would still be executable by PUBLIC/anon/authenticated';
  end if;
  drop function public.zz_migration_23_probe();
end
$$;
