-- Stellar wallets of the accounts that sign in with Privy (Apple, Google, email code, Privy passkey): one per Privy
-- user, made by POST /v1/privy/wallet through Privy's API and owned by that user (DyorHQ/internal
-- ios-app/stellar-v2/privy-stellar-wallets.md). The row is what POST /v1/privy/sign relays for: a wallet not listed here
-- is no wallet DyorHQ made, and its address is what Privy's signature is checked against. No key, token or secret is
-- stored: only Privy's ids and the public G-address.

create table if not exists lite.privy_wallets (
  user_id text primary key check (user_id ~ '^did:privy:[A-Za-z0-9]{1,64}$'),
  wallet_id text not null unique check (wallet_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  address text not null unique check (address ~ '^G[A-Z2-7]{55}$'),
  created_at timestamptz not null default now()
);

-- Closed to everyone but lite_api, as every lite table is (migrations 1 and 4).
revoke all on lite.privy_wallets from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on lite.privy_wallets from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on lite.privy_wallets from authenticated'; end if;
end $$;
-- Rows are added, never changed: the API finds a user's wallet, or adds it once. Migration 4's default privileges
-- gave lite_api everything on new lite tables; the rest is taken back.
grant select, insert on lite.privy_wallets to lite_api;
revoke update, delete, truncate on lite.privy_wallets from lite_api;

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
