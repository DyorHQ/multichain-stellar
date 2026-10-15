-- Portfolio and Recent Activity reads (migration 20261014000010; docs/DESIGN-stellar-parity.md §6.5, §6.7, §6.10,
-- §6.15, §12.2): the indexes the reads use exist, on the columns they read by; and, as lite_api, the reads of
-- activity.ts, portfolio.ts and holdings.ts answer what they mean to on one account's rows and another's: activity by
-- section, kind, period and market (an Earn market by its pool and asset, an asset by its contract), settled only for
-- Portfolio; Portfolio's period rows, the account's curve trades and pool swaps joined to their quote, the creator's
-- proceeds as the contract splits them, completed bridge transfers and the first logged transaction; holdings' launch
-- tokens, indexed as held or traded. Every logged transaction has its section, by plans.ts sectionOf's rule: a row
-- logged without one gets it as it is inserted, and the migration's backfill gives the rows before it theirs. One
-- transaction, rolled back.
begin;

-- 1. The indexes, on the columns the reads go by.
do $$
declare
  want constant text[][] := array[
    ['tx_log', 'tx_log_section', 'CREATE INDEX tx_log_section ON lite.tx_log USING btree (address, section, created_at DESC)'],
    ['launch_trades', 'launch_trades_trader', 'CREATE INDEX launch_trades_trader ON lite.launch_trades USING btree (trader, ts DESC)'],
    ['moment_collects', 'moment_collects_collector', 'CREATE INDEX moment_collects_collector ON lite.moment_collects USING btree (collector, ts DESC)'],
    ['bridge_transfers', 'bridge_transfers_address', 'CREATE INDEX bridge_transfers_address ON lite.bridge_transfers USING btree (address, created_at DESC)'],
    ['anchor_transfers', 'anchor_transfers_address', 'CREATE INDEX anchor_transfers_address ON lite.anchor_transfers USING btree (address, created_at DESC)']];
  i int;
  def text;
begin
  for i in 1 .. array_length(want, 1) loop
    select indexdef into def from pg_indexes where schemaname = 'lite' and tablename = want[i][1] and indexname = want[i][2];
    if def is distinct from want[i][3] then raise exception 'lite.%: % is %', want[i][1], want[i][2], coalesce(def, 'missing'); end if;
  end loop;
  raise notice 'ok: the indexes';
end $$;

-- 2. As lite_api, on two accounts' rows.
do $$
declare
  me constant text := 'GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ';
  other constant text := 'GCRUXQPSZ5FJCMOQXCLEAWYD5AQ265VPQPG66IMLPCGC7RJ4XTOTIFDY';
  c_xlm constant text := 'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';
  c_usdc constant text := 'CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA';
  c_pool constant text := 'CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF';
  c_cat constant text := 'CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V';
  c_dog constant text := 'CAG7HXJ65BFFSKCG4OE64UCFY7DZXSANMPNYNXO4OOGWCDP6XM7OSGWG';
  c_now constant timestamptz := timestamptz '2026-10-14 09:41:00+00';
  week_ago constant timestamptz := c_now - interval '7 days';
  got text[];
  n numeric;
  first timestamptz;
begin
  execute 'set local role lite_api';

  insert into lite.tx_log (hash, inner_hash, address, kind, intent, status, max_fee, fee_charged, fee_payer, section, result, created_at) values
    ('s1', 's1', me, 'swap', jsonb_build_object('kind', 'swap', 'spend', jsonb_build_object(c_xlm, '1000000000'), 'receive', jsonb_build_object(c_usdc, '1')),
       'success', 1000, 41210, 'user', 'spot', '{"amountOut": "189718972"}', c_now - interval '1 day'),
    ('s2', 's2', me, 'swap', jsonb_build_object('kind', 'swap', 'spend', jsonb_build_object(c_xlm, '10'), 'receive', jsonb_build_object(c_usdc, '1')),
       'failed', 1000, 30000, 'user', 'spot', null, c_now - interval '2 days'),
    ('s3', 's3', me, 'swap', jsonb_build_object('kind', 'swap', 'spend', jsonb_build_object(c_xlm, '10'), 'receive', jsonb_build_object(c_usdc, '1')),
       'success', 1000, 41210, 'user', 'spot', null, c_now - interval '10 days'),
    ('l1', 'l1', me, 'launch_buy', jsonb_build_object('kind', 'launch_buy', 'spend', jsonb_build_object(c_xlm, '500000000'), 'receive', jsonb_build_object(c_cat, '1'),
       'display', jsonb_build_object('token', c_cat)), 'success', 1000, 41210, 'user', 'launch', null, c_now - interval '3 hours'),
    ('e1', 'e1', me, 'earn_deposit', jsonb_build_object('kind', 'earn_deposit', 'spend', jsonb_build_object(c_xlm, '1000000000'),
       'calls', jsonb_build_array(jsonb_build_object('contract', c_pool, 'fn', 'submit'))), 'success', 1000, 1250000, 'user', 'earn', null, c_now - interval '4 days'),
    ('e2', 'e2', me, 'earn_deposit', jsonb_build_object('kind', 'earn_deposit', 'spend', jsonb_build_object(c_usdc, '50000000'),
       'calls', jsonb_build_array(jsonb_build_object('contract', c_pool, 'fn', 'submit'))), 'success', 1000, 1250000, 'user', 'earn', null, c_now - interval '5 days'),
    ('t1', 't1', me, 'trust', '{"kind": "trust"}', 'success', 1000, 10000, 'user', 'account', null, c_now - interval '20 days'),
    ('o1', 'o1', other, 'swap', jsonb_build_object('kind', 'swap', 'spend', jsonb_build_object(c_xlm, '1'), 'receive', jsonb_build_object(c_usdc, '1')),
       'success', 1000, 41210, 'user', 'spot', null, c_now - interval '1 hour');

  -- activity.ts: the spot swaps of the week, any status; Portfolio's, settled ones only.
  select array_agg(t.hash order by t.created_at desc) into got from lite.tx_log t
   where t.address = me and coalesce(t.section, 'account') = 'spot' and t.kind = 'swap' and t.created_at > week_ago;
  if got is distinct from array['s1', 's2'] then raise exception 'the week''s spot swaps: %', got; end if;
  select array_agg(t.hash order by t.created_at desc) into got from lite.tx_log t
   where t.address = me and t.created_at > week_ago and t.status = 'success';
  if got is distinct from array['l1', 's1', 'e1', 'e2'] then raise exception 'the week''s settled transactions: %', got; end if;
  -- An Earn market: its pool's submit, spending or receiving its asset.
  select array_agg(t.hash order by t.created_at desc) into got from lite.tx_log t
   where t.address = me and t.section = 'earn'
     and t.intent -> 'calls' @> jsonb_build_array(jsonb_build_object('contract', c_pool))
     and (t.intent -> 'spend' ? c_xlm or t.intent -> 'receive' ? c_xlm);
  if got is distinct from array['e1'] then raise exception 'the XLM market''s history: %', got; end if;
  -- An asset: spent, received, or the launch a step names.
  select array_agg(t.hash order by t.created_at desc) into got from lite.tx_log t
   where t.address = me and (t.intent -> 'spend' ? c_cat or t.intent -> 'receive' ? c_cat or t.intent -> 'display' ->> 'token' = c_cat);
  if got is distinct from array['l1'] then raise exception 'the launch''s items: %', got; end if;

  -- portfolio.ts: the period's rows, and the account's first.
  select array_agg(t.hash order by t.hash) into got from lite.tx_log t where t.address = me and t.created_at > week_ago;
  if got is distinct from array['e1', 'e2', 'l1', 's1', 's2'] then raise exception 'the week''s rows: %', got; end if;
  select min(created_at) into first from lite.tx_log where address = me;
  if first <> c_now - interval '20 days' then raise exception 'the first transaction: %', first; end if;

  -- Two launches, the account's curve trades and pool swaps (one before the week), another account's.
  insert into lite.launches (token, creator, quote, name, symbol, launch_index, supply, phantom, threshold, quote_reserve, token_reserve, created_ledger, created_at)
  values (c_cat, me, c_xlm, 'E2E Cat', 'ECAT', 0, 10000000000000000, 300000000000, 50000000000, 300000000000, 10000000000000000, 1, c_now - interval '9 days'),
         (c_dog, other, c_usdc, 'Dog', 'DOG', 1, 10000000000000000, 300000000000, 50000000000, 300000000000, 10000000000000000, 1, c_now - interval '9 days');
  insert into lite.launch_trades (event_id, token, trader, side, quote_amount, token_amount, fees, price, ledger, ts) values
    ('t-1', c_cat, me, 'buy', 400000000, 9600000000000, 8997370, 0.00004, 10, c_now - interval '3 hours'),
    ('t-2', c_cat, me, 'sell', 99736981, 2400000000000, 997370, 0.00004, 11, c_now - interval '2 hours'),
    ('t-3', c_cat, me, 'buy', 100000000, 1000000000000, 1000000, 0.00004, 9, c_now - interval '8 days'),
    ('t-4', c_cat, other, 'buy', 100000000, 1000000000000, 1000000, 0.00004, 12, c_now - interval '1 hour');
  insert into lite.pool_swaps (event_id, token, pair, trader, side, quote_amount, token_amount, price, ledger, ts) values
    ('p-1', c_dog, 'CPAIR', me, 'buy', 50000000, 600000000000, 0.0001, 13, c_now - interval '1 hour');
  select array_agg(format('%s %s %s %s', (f.token = c_cat)::text, (l.quote = c_xlm)::text, f.side, f.fees) order by f.quote_amount desc) into got from (
    select token, side, quote_amount, token_amount, fees, ts from lite.launch_trades where trader = me
    union all
    select token, side, quote_amount, token_amount, 0 as fees, ts from lite.pool_swaps where trader = me
  ) as f join lite.launches l on l.token = f.token
  where f.ts > week_ago;
  if got is distinct from array['true true buy 8997370', 'true true sell 997370', 'false false buy 0'] then raise exception 'the week''s fills: %', got; end if;

  -- holdings.ts: the launch tokens held as indexed, or traded (the owner's view), each with its indexed balance.
  insert into lite.token_balances (token, address, balance, updated_ledger) values
    (c_cat, me, 0, 11), (c_dog, other, 5, 12);
  select array_agg(format('%s %s', l.symbol, coalesce(tb.balance, 0)) order by l.symbol) into got
    from lite.launches l left join lite.token_balances tb on tb.token = l.token and tb.address = me
   where l.token in (select token from lite.token_balances where address = me and balance > 0
                     union select token from lite.launch_trades where trader = me
                     union select token from lite.pool_swaps where trader = me);
  if got is distinct from array['DOG 0', 'ECAT 0'] then raise exception 'the owner''s launch tokens: %', got; end if;
  select array_agg(l.symbol) into got from lite.launches l
   where l.token in (select token from lite.token_balances where address = me and balance > 0);
  if got is not null then raise exception 'the public view''s launch tokens: %', got; end if;

  -- The creator's proceeds: what the contract leaves after the platform's 5% (rounded down), for the week's collects of
  -- the account's own Moments only.
  insert into lite.moments (id, creator, uri, title, price, quote, max_editions, deadline, created_ledger, platform_bps) values
    (1, me, 'u1', 'Mine', 19989479, c_xlm, 10, c_now + interval '1 day', 1, 500),
    (2, other, 'u2', 'Theirs', 20000000, c_xlm, 10, c_now + interval '1 day', 1, 500);
  insert into lite.moment_collects (event_id, moment_id, collector, quantity, first_token_id, paid, ledger, ts) values
    ('c-1', 1, other, 1, 1, 19989479, 20, c_now - interval '1 day'),
    ('c-2', 1, other, 1, 2, 19989479, 21, c_now - interval '9 days'),
    ('c-3', 2, me, 1, 1, 20000000, 22, c_now - interval '1 day');
  select sum(lite.moment_creator_share(c.paid, m.platform_bps)) into n
    from lite.moment_collects c join lite.moments m on m.id = c.moment_id
   where m.creator = me and m.platform_bps is not null and c.ts > week_ago
   group by m.quote;
  if n <> 19989479 - 999473 then raise exception 'the proceeds: %', n; end if;
  select array_agg(c.event_id) into got from lite.moment_collects c join lite.moments m on m.id = c.moment_id
   where c.collector = me and c.ts > week_ago;
  if got is distinct from array['c-3'] then raise exception 'the account''s collects: %', got; end if;

  -- Completed transfers of the week, the account's only.
  insert into lite.bridge_transfers (address, direction, route, amount, recipient, status, relay_day, created_at) values
    (me, 'monad_to_stellar', 'cctp', 12501250, me, 'completed', (c_now - interval '1 day')::date, c_now - interval '1 day'),
    (me, 'monad_to_stellar', 'cctp', 1000000, me, 'attesting', (c_now - interval '1 day')::date, c_now - interval '1 day'),
    (me, 'stellar_to_monad', 'cctp', 10000000, '0x' || repeat('d', 40), 'completed', null, c_now - interval '9 days'),
    (other, 'stellar_to_monad', 'cctp', 10000000, '0x' || repeat('d', 40), 'completed', null, c_now - interval '1 day');
  select array_agg(b.amount::text) into got from lite.bridge_transfers b
   where b.address = me and b.status = 'completed' and b.created_at > week_ago;
  if got is distinct from array['12501250'] then raise exception 'the week''s completed transfers: %', got; end if;

  execute 'reset role';
  raise notice 'ok: lite_api reads activity, Portfolio''s rows and holdings'' launch tokens';
end $$;

-- 3. The section of a row logged without one: by its kind and intent, as it is inserted (an API older than migration
--    05's logs no section) and, for the rows before the migration, by its backfill; a section given stands.
do $$
declare
  me constant text := 'G' || repeat('S', 55);
  c_xlm constant text := 'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';
  c_usdc constant text := 'CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA';
  c_fox constant text := 'CCFOX' || repeat('A', 51);
  got text[];
begin
  insert into lite.launches (token, creator, quote, name, symbol, launch_index, supply, phantom, threshold, quote_reserve, token_reserve, created_ledger)
  values (c_fox, me, c_xlm, 'Fox', 'FOX', 7, 10000000000000000, 300000000000, 50000000000, 300000000000, 10000000000000000, 1);

  execute 'set local role lite_api';
  insert into lite.tx_log (hash, inner_hash, address, kind, intent, status, max_fee) values
    ('n01', 'n01', me, 'swap', jsonb_build_object('spend', jsonb_build_object(c_xlm, '10'), 'receive', jsonb_build_object(c_usdc, '1')), 'success', 1000),
    ('n02', 'n02', me, 'swap', jsonb_build_object('spend', jsonb_build_object(c_xlm, '10'), 'receive', jsonb_build_object(c_fox, '1')), 'success', 1000),
    ('n03', 'n03', me, 'swap', jsonb_build_object('spend', jsonb_build_object(c_fox, '10'), 'receive', '[]'::jsonb), 'success', 1000),
    ('n04', 'n04', me, 'swap', '{}', 'success', 1000),
    ('n05', 'n05', me, 'payment', jsonb_build_object('spend', jsonb_build_object(c_fox, '10')), 'success', 1000),
    ('n06', 'n06', me, 'trust', '{}', 'success', 1000),
    ('n07', 'n07', me, 'faucet', null, 'success', 1000),
    ('n08', 'n08', me, 'earn_withdraw', '{}', 'success', 1000),
    ('n09', 'n09', me, 'launch_create', '{}', 'success', 1000),
    ('n10', 'n10', me, 'moment_collect', '{}', 'success', 1000),
    ('n11', 'n11', me, 'bridge_out', '{}', 'success', 1000),
    ('n12', 'n12', me, 'approve', '{}', 'success', 1000),
    ('n13', 'n13', me, 'mystery', '{}', 'success', 1000);
  insert into lite.tx_log (hash, inner_hash, address, kind, intent, status, max_fee, section) values
    ('n14', 'n14', me, 'swap', jsonb_build_object('spend', jsonb_build_object(c_xlm, '10'), 'receive', jsonb_build_object(c_fox, '1')), 'success', 1000, 'spot');
  select array_agg(hash || ' ' || coalesce(section, '-') order by hash) into got from lite.tx_log where address = me;
  if got is distinct from array['n01 spot', 'n02 launch', 'n03 launch', 'n04 spot', 'n05 spot', 'n06 account', 'n07 account', 'n08 earn',
                                'n09 launch', 'n10 moments', 'n11 bridge', 'n12 bridge', 'n13 -', 'n14 spot'] then
    raise exception 'sections as logged: %', got;
  end if;
  -- activity.ts's section filter: a row of a kind no section counts is the account's, as its item says.
  select array_agg(t.hash order by t.hash) into got from lite.tx_log t where t.address = me and coalesce(t.section, 'account') = 'account';
  if got is distinct from array['n06', 'n07', 'n13'] then raise exception 'the account''s section: %', got; end if;
  execute 'reset role';

  -- Rows as migration 05 left them, before this one: the migration's backfill.
  alter table lite.tx_log disable trigger tx_log_fill_section;
  insert into lite.tx_log (hash, inner_hash, address, kind, intent, status, max_fee) values
    ('b1', 'b1', me, 'swap', jsonb_build_object('spend', jsonb_build_object(c_xlm, '10'), 'receive', jsonb_build_object(c_usdc, '1')), 'success', 1000),
    ('b2', 'b2', me, 'swap', jsonb_build_object('spend', jsonb_build_object(c_xlm, '10'), 'receive', jsonb_build_object(c_fox, '1')), 'success', 1000),
    ('b3', 'b3', me, 'earn_deposit', '{}', 'success', 1000);
  alter table lite.tx_log enable trigger tx_log_fill_section;
  update lite.tx_log set section = lite.tx_section(kind, intent) where section is null;
  select array_agg(hash || ' ' || coalesce(section, '-') order by hash) into got from lite.tx_log where address = me and hash like 'b%';
  if got is distinct from array['b1 spot', 'b2 launch', 'b3 earn'] then raise exception 'the backfill: %', got; end if;

  if has_function_privilege('public', 'lite.tx_section(text, jsonb)', 'execute')
     or has_function_privilege('public', 'lite.fill_tx_log_section()', 'execute') then
    raise exception 'PUBLIC can execute the section functions';
  end if;
  if not has_function_privilege('lite_api', 'lite.tx_section(text, jsonb)', 'execute') then raise exception 'lite_api cannot call lite.tx_section'; end if;
  raise notice 'ok: every logged transaction has its section';
end $$;

rollback;
