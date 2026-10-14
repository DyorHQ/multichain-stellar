-- lite.auth_refresh (migration 20261014000012; docs/DESIGN-stellar-parity.md §5.9, §6.18): only token hashes can be
-- stored, each once; the API's statements spend a token once, revoke a family as a whole and clean up expired rows;
-- anon and authenticated can't reach the table, lite_api can. The statements are _shared/auth.ts's, run as lite_api.
-- One transaction, rolled back.
begin;

-- 1. The table holds a hash, never a token: its columns, and a check that admits sha256 hex only.
do $$
declare cols text;
begin
  select string_agg(column_name, ',' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'lite' and table_name = 'auth_refresh';
  if cols is distinct from 'id,family,address,token_hash,created_at,expires_at,used_at,revoked_at,replaced_by' then
    raise exception 'auth_refresh columns: %', cols;
  end if;
  begin
    insert into lite.auth_refresh (family, address, token_hash, expires_at)
    values (gen_random_uuid(), 'G' || repeat('A', 55), 'lrt_' || repeat('x', 43), now() + interval '30 days');
    raise exception 'a raw refresh token was stored';
  exception when check_violation then null;
  end;
  if not exists (select 1 from pg_indexes where schemaname = 'lite' and tablename = 'auth_refresh' and indexdef like '%(family)%')
     or not exists (select 1 from pg_indexes where schemaname = 'lite' and tablename = 'auth_refresh' and indexdef like '%(address)%') then
    raise exception 'auth_refresh needs its family and address indexes';
  end if;
  raise notice 'ok: auth_refresh stores sha256 hex only';
end $$;

-- 2. anon and authenticated can neither read nor write it; RLS is on.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    begin
      execute format('set local role %I', r);
      perform 1 from lite.auth_refresh limit 1;
      raise exception '% could read lite.auth_refresh', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
    begin
      execute format('set local role %I', r);
      insert into lite.auth_refresh (family, address, token_hash, expires_at)
      values (gen_random_uuid(), 'G' || repeat('A', 55), repeat('a', 64), now());
      raise exception '% could write lite.auth_refresh', r;
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
  end loop;
  if not (select relrowsecurity from pg_class where oid = 'lite.auth_refresh'::regclass) then
    raise exception 'RLS is off on lite.auth_refresh';
  end if;
  raise notice 'ok: anon and authenticated are refused';
end $$;

-- 3. As lite_api: a hash is unique, a token is spent once, a family is revoked as a whole, and an expired or revoked
--    token can't be spent.
do $$
declare
  a constant text := 'G' || repeat('A', 55);
  b constant text := 'G' || repeat('B', 55);
  fam_a constant uuid := gen_random_uuid();
  fam_b constant uuid := gen_random_uuid();
  h1 constant text := encode(sha256('lrt_one'::bytea), 'hex');
  h2 constant text := encode(sha256('lrt_two'::bytea), 'hex');
  h3 constant text := encode(sha256('lrt_three'::bytea), 'hex');
  h4 constant text := encode(sha256('lrt_four'::bytea), 'hex');
  spent uuid;
  n int;
begin
  execute 'set local role lite_api';
  insert into lite.auth_refresh (family, address, token_hash, expires_at) values
    (fam_a, a, h1, now() + interval '30 days'),
    (fam_a, a, h2, now() + interval '30 days'),
    (fam_b, b, h3, now() + interval '30 days'),
    (fam_b, b, h4, now() - interval '1 second');
  begin
    insert into lite.auth_refresh (family, address, token_hash, expires_at) values (gen_random_uuid(), a, h1, now() + interval '30 days');
    raise exception 'a token hash was stored twice';
  exception when unique_violation then null;
  end;

  -- Spending h1 (auth/refresh's statement) works once.
  update lite.auth_refresh set used_at = now()
   where token_hash = h1 and address = a and used_at is null and revoked_at is null and expires_at > now()
  returning family into spent;
  if spent is distinct from fam_a then raise exception 'h1 was not spent: %', spent; end if;
  spent := null;
  update lite.auth_refresh set used_at = now()
   where token_hash = h1 and address = a and used_at is null and revoked_at is null and expires_at > now()
  returning family into spent;
  if spent is not null then raise exception 'h1 was spent twice'; end if;
  -- Another address can't spend a's token, and an expired one can't be spent.
  update lite.auth_refresh set used_at = now()
   where token_hash = h2 and address = b and used_at is null and revoked_at is null and expires_at > now()
  returning family into spent;
  if spent is not null then raise exception 'b spent a''s token'; end if;
  update lite.auth_refresh set used_at = now()
   where token_hash = h4 and address = b and used_at is null and revoked_at is null and expires_at > now()
  returning family into spent;
  if spent is not null then raise exception 'an expired token was spent'; end if;

  -- Revoking family a (reuse or sign-out) revokes both its tokens and nothing else; h2 can't be spent then.
  update lite.auth_refresh set revoked_at = now()
   where family = (select family from lite.auth_refresh where token_hash = h1) and revoked_at is null;
  select count(*) into n from lite.auth_refresh where family = fam_a and revoked_at is not null;
  if n <> 2 then raise exception 'family a: % of 2 tokens revoked', n; end if;
  if exists (select 1 from lite.auth_refresh where family = fam_b and revoked_at is not null) then
    raise exception 'revoking family a touched family b';
  end if;
  update lite.auth_refresh set used_at = now()
   where token_hash = h2 and address = a and used_at is null and revoked_at is null and expires_at > now()
  returning family into spent;
  if spent is not null then raise exception 'a revoked token was spent'; end if;

  execute 'reset role';
  raise notice 'ok: unique hash, single use, family revoke';
end $$;

-- 4. The cleanup drops rows that expired more than 7 days ago, at most 500 per run, and nothing else.
do $$
declare
  a constant text := 'G' || repeat('C', 55);
  n int;
begin
  execute 'set local role lite_api';
  insert into lite.auth_refresh (family, address, token_hash, expires_at)
  select gen_random_uuid(), a, encode(sha256(('lrt_old_' || i)::bytea), 'hex'), now() - interval '8 days'
    from generate_series(1, 502) i;
  insert into lite.auth_refresh (family, address, token_hash, expires_at)
  values (gen_random_uuid(), a, encode(sha256('lrt_recent'::bytea), 'hex'), now() - interval '6 days');
  delete from lite.auth_refresh
   where id in (select id from lite.auth_refresh where expires_at < now() - interval '7 days' limit 500);
  select count(*) into n from lite.auth_refresh where address = a;
  if n <> 3 then raise exception 'after one cleanup % rows are left, expected 3', n; end if;
  delete from lite.auth_refresh
   where id in (select id from lite.auth_refresh where expires_at < now() - interval '7 days' limit 500);
  select count(*) into n from lite.auth_refresh where address = a;
  if n <> 1 then raise exception 'after two cleanups % rows are left, expected 1', n; end if;
  execute 'reset role';
  raise notice 'ok: cleanup';
end $$;

rollback;
