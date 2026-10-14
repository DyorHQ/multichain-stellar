-- 25_activity_wallet_id_unique — step A of scoping activity row ids to their wallet (security audit 2026-09-26, SB-5).
--
-- The app derives an activity row's id from the transaction hash (BackendSync.stableID), which is public, and upserts
-- with on_conflict=id. activity.id is the whole primary key, so another wallet can insert a row under the victim's
-- future id first (in its own folder of rows, which RLS allows): the victim's upsert then hits the other wallet's row,
-- which its RLS cannot touch, and the victim's row is never written.
--
-- The fix is two migrations around one app build:
--   A (this one, additive, safe now): a unique constraint on (wallet, id), so the app can upsert with
--     ?on_conflict=wallet,id and Prefer: resolution=merge-duplicates. The id-only primary key still exists, so a
--     squatted id still fails the insert until B; nothing else changes and no existing client is affected.
--   B (supabase/migrations-deferred/30_activity_primary_key_wallet_id.sql): make (wallet, id) the primary key and drop
--     the id-only uniqueness. Apply it only once the first app build that upserts with on_conflict=wallet,id has
--     shipped AND every older build is expired in App Store Connect / TestFlight (raising app_config ios.min_build,
--     migration 28, does not stop builds that never read it): older builds send on_conflict=id, which PostgREST
--     refuses (42P10) once no unique constraint on id alone exists. Until B, the squat above still works.
--
-- Reverse: alter table public.activity drop constraint activity_wallet_id_key;
-- Verify after apply:
--   select pg_get_constraintdef(oid) from pg_constraint
--    where conrelid = 'public.activity'::regclass and conname = 'activity_wallet_id_key';   -- UNIQUE (wallet, id)

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.activity'::regclass and conname = 'activity_wallet_id_key') then
    alter table public.activity add constraint activity_wallet_id_key unique (wallet, id);
  end if;
  if pg_get_constraintdef((select oid from pg_constraint
                            where conrelid = 'public.activity'::regclass and conname = 'activity_wallet_id_key'))
     <> 'UNIQUE (wallet, id)' then
    raise exception 'activity_wallet_id_key exists but is not UNIQUE (wallet, id)';
  end if;
end
$$;
