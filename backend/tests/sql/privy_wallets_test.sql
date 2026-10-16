-- lite.privy_wallets (migration 20261016000013; DyorHQ/internal ios-app/stellar-v2/privy-stellar-wallets.md §5.1): one
-- Privy Stellar wallet per Privy user, ids and a G-address only; lite_api finds and adds rows and can't change or
-- delete them; anon and authenticated can't reach the table. The statements are lite/routes/privy.ts's, run as
-- lite_api. One transaction, rolled back.
begin;

-- 1. Columns, and checks that admit Privy's ids and a G-address only.
do $$
declare cols text;
begin
  select string_agg(column_name, ',' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'lite' and table_name = 'privy_wallets';
  if cols is distinct from 'user_id,wallet_id,address,created_at' then
    raise exception 'privy_wallets columns: %', cols;
  end if;
  begin
    insert into lite.privy_wallets (user_id, wallet_id, address) values ('someone', 'w1', 'G' || repeat('A', 55));
    raise exception 'a user id that is no Privy DID was stored';
  exception when check_violation then null;
  end;
  begin
    insert into lite.privy_wallets (user_id, wallet_id, address) values ('did:privy:abc', 'w1', 'SB' || repeat('A', 54));
    raise exception 'a secret key was stored as the address';
  exception when check_violation then null;
  end;
  raise notice 'ok: privy_wallets holds ids and a G-address only';
end $$;

-- 2. anon and authenticated can neither read nor write it; RLS is on.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    begin
      execute format('set local role %I', r);
      perform 1 from lite.privy_wallets limit 1;
      raise exception '% could read lite.privy_wallets', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
  end loop;
  if not (select relrowsecurity from pg_class where oid = 'lite.privy_wallets'::regclass) then
    raise exception 'RLS is off on lite.privy_wallets';
  end if;
  raise notice 'ok: only lite_api reaches privy_wallets';
end $$;

-- 3. As lite_api: the route's insert (on conflict do nothing) and lookups; one wallet per user, each wallet and
--    address once; no update, no delete.
set local role lite_api;
insert into lite.privy_wallets (user_id, wallet_id, address)
values ('did:privy:cmuser1', 'wallet1', 'G' || repeat('B', 55)) on conflict (user_id) do nothing;
insert into lite.privy_wallets (user_id, wallet_id, address)
values ('did:privy:cmuser1', 'wallet2', 'G' || repeat('C', 55)) on conflict (user_id) do nothing;
do $$
begin
  if (select wallet_id from lite.privy_wallets where user_id = 'did:privy:cmuser1') <> 'wallet1' then
    raise exception 'a second wallet replaced the first';
  end if;
  begin
    insert into lite.privy_wallets (user_id, wallet_id, address) values ('did:privy:cmuser2', 'wallet1', 'G' || repeat('D', 55));
    raise exception 'one wallet was stored for two users';
  exception when unique_violation then null;
  end;
  begin
    update lite.privy_wallets set address = 'G' || repeat('E', 55) where user_id = 'did:privy:cmuser1';
    raise exception 'lite_api changed a wallet''s address';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from lite.privy_wallets where user_id = 'did:privy:cmuser1';
    raise exception 'lite_api deleted a wallet';
  exception when insufficient_privilege then null;
  end;
  raise notice 'ok: lite_api adds and reads, never changes';
end $$;
reset role;

rollback;
