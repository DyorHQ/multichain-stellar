-- Refresh tokens (docs/DESIGN-stellar-parity.md §5.9, §6.15 and §6.18; WP-02b). auth/verify starts a family with one
-- token; auth/refresh spends a token (single use) and issues its successor in the same family; presenting a spent token
-- again revokes the whole family, and so does sign-out. Only sha256(token) is stored, as hex: the token itself
-- ("lrt_" and 32 random bytes in base64url) never reaches the database. Rows are deleted a week after they expire, at
-- most 500 per refresh.

create table if not exists lite.auth_refresh (
  id uuid primary key default gen_random_uuid(),
  family uuid not null,
  address text not null check (address ~ '^G[A-Z2-7]{55}$'),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz,
  -- The token issued when this one was spent.
  replaced_by uuid
);
create index if not exists auth_refresh_family on lite.auth_refresh (family);
create index if not exists auth_refresh_address on lite.auth_refresh (address);
-- The cleanup's range scan.
create index if not exists auth_refresh_expiry on lite.auth_refresh (expires_at);

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.auth_refresh from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on lite.auth_refresh from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on lite.auth_refresh from authenticated'; end if;
end $$;
grant select, insert, update, delete on lite.auth_refresh to lite_api;

-- The RLS-and-policy loop of 20261013000004: RLS on every lite table, and lite_api's one policy on each.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'lite' loop
    execute format('alter table lite.%I enable row level security', t.tablename);
    execute format('drop policy if exists lite_api_all on lite.%I', t.tablename);
    execute format('create policy lite_api_all on lite.%I for all to lite_api using (true) with check (true)', t.tablename);
  end loop;
end $$;
