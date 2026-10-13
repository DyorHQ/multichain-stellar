-- lite_api: the only role that reaches the lite schema. Lite lives in the DyorHQ project (owner decision, 2026-10-13,
-- DECISIONS #17), so the lite and lite-indexer functions connect as lite_api through LITE_DB_URL instead of the
-- postgres URL every function receives: a bug in Lite's SQL can read and write only lite.*, never the app's tables.
-- The role has no password here (log_statement = ddl would log it); new-testnet-secrets.ts --db-role sets a SCRAM
-- verifier out of band.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'lite_api') then
    create role lite_api login noinherit nocreatedb nocreaterole nobypassrls connection limit 20;
  end if;
end $$;

grant usage on schema lite to lite_api;
-- TRUNCATE: the indexer clears the indexed tables after a testnet reset.
grant select, insert, update, delete, truncate on all tables in schema lite to lite_api;
grant usage, select, update on all sequences in schema lite to lite_api;
grant execute on all functions in schema lite to lite_api;
alter default privileges in schema lite grant select, insert, update, delete, truncate on tables to lite_api;
alter default privileges in schema lite grant usage, select, update on sequences to lite_api;
alter default privileges in schema lite grant execute on functions to lite_api;

-- RLS stays on with no policy for anon or authenticated; lite_api gets one policy per table. A table added later
-- needs the same line.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'lite' loop
    execute format('drop policy if exists lite_api_all on lite.%I', t.tablename);
    execute format('create policy lite_api_all on lite.%I for all to lite_api using (true) with check (true)', t.tablename);
  end loop;
end $$;
