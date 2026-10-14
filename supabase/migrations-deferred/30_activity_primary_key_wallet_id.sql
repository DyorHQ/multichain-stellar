-- 30_activity_primary_key_wallet_id — step B of scoping activity row ids to their wallet (security audit 2026-09-26,
-- SB-5). Step A is migration 25.
--
-- DEFERRED: this file lives outside supabase/migrations on purpose, so no `db push` applies it early. Apply it only
-- once BOTH hold:
--   (a) the first iOS build that upserts activity with ?on_conflict=wallet,id has shipped, and app_config
--       'ios'.min_build (migration 28) is at least that build; and
--   (b) every older build is expired in App Store Connect / TestFlight. (a) alone is not enough: builds without the
--       "Update required" check (every build shipped so far) ignore min_build.
-- Older builds upsert with on_conflict=id, which PostgREST refuses (42P10) as soon as no unique constraint on id alone
-- exists — their activity mirror would stop syncing.
-- Before applying: set v_required_build below to that build number (the guard refuses while it is 0, and while the
-- live min_build is lower) and v_older_builds_expired to true once (b) holds, then move this file into
-- supabase/migrations/ so the repository matches the database.
--
-- What it does: the primary key becomes (wallet, id) and the id-only uniqueness goes (the (wallet, id) constraint from
-- migration 25 is dropped too, since the new primary key is the same index). A row id is then only unique within its
-- wallet, so another wallet's row with the same id can no longer block a victim's upsert. Idempotent.
--
-- Reverse (only while no two wallets share an id):
--   alter table public.activity drop constraint activity_pkey;
--   alter table public.activity add constraint activity_pkey primary key (id);
--   alter table public.activity add constraint activity_wallet_id_key unique (wallet, id);
-- Verify after apply:
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--    where conrelid = 'public.activity'::regclass and contype in ('p', 'u');   -- activity_pkey PRIMARY KEY (wallet, id) only

do $$
declare
  v_required_build       constant int := 0;          -- SET THIS to the first build that sends on_conflict=wallet,id
  v_older_builds_expired constant boolean := false;  -- SET TRUE once every older build is expired (App Store Connect)
  v_min_build            int;
begin
  if v_required_build <= 0 then
    raise exception 'set v_required_build to the first iOS build that upserts activity with on_conflict=wallet,id';
  end if;
  if not v_older_builds_expired then
    raise exception 'expire every build older than % in App Store Connect / TestFlight first, then set v_older_builds_expired', v_required_build;
  end if;
  select (value->>'min_build')::int into v_min_build from public.app_config where key = 'ios';
  if v_min_build is null or v_min_build < v_required_build then
    raise exception 'app_config ios.min_build is %, below build %: older builds would stop syncing activity',
      coalesce(v_min_build::text, 'unset'), v_required_build;
  end if;

  if pg_get_constraintdef((select oid from pg_constraint
                            where conrelid = 'public.activity'::regclass and contype = 'p')) <> 'PRIMARY KEY (wallet, id)' then
    alter table public.activity drop constraint activity_pkey;
    alter table public.activity add constraint activity_pkey primary key (wallet, id);
  end if;
  alter table public.activity drop constraint if exists activity_wallet_id_key;

  if exists (select 1 from pg_constraint
              where conrelid = 'public.activity'::regclass and contype in ('p', 'u')
                and pg_get_constraintdef(oid) in ('PRIMARY KEY (id)', 'UNIQUE (id)')) then
    raise exception 'activity still has an id-only unique constraint';
  end if;
end
$$;
