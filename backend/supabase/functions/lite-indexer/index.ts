// lite-indexer: called every minute by pg_cron (x-cron-secret). Reads launchpad and Moments events from Stellar
// RPC (7-day retention), keeps lite.* tables current, settles sponsored transactions, graduates completed curves
// (keeper, permissionless) and advances CCTP bridge transfers.
import { advanceBridges } from "../_shared/bridge.ts";
import { sql } from "../_shared/db.ts";
import { env } from "../_shared/env.ts";
import { json } from "../_shared/http.ts";
import { settle } from "../_shared/plans.ts";
import deployment from "../_shared/deployments/testnet.json" with { type: "json" };
import { invoke, loadAccount, native, rpcServer, sendSigned, sponsor, sv, txStatus } from "../_shared/stellar.ts";
import { keepAlive } from "../_shared/ttl.ts";

const CURSOR = "events";

function contractIdOf(e: any): string {
  const c = e.contractId;
  if (!c) return "";
  return typeof c === "string" ? c : typeof c.contractId === "function" ? c.contractId() : String(c);
}

async function fetchMetadata(uri: string): Promise<{ title: string | null; media: string | null }> {
  if (!uri.startsWith("https://")) return { title: null, media: null };
  try {
    const res = await fetch(uri, { signal: AbortSignal.timeout(3_000) });
    if (!res.ok) return { title: null, media: null };
    const m = await res.json();
    return { title: typeof m.name === "string" ? m.name.slice(0, 80) : null, media: typeof (m.image ?? m.animation_url) === "string" ? (m.image ?? m.animation_url) : null };
  } catch {
    return { title: null, media: null };
  }
}

export async function indexEvents(): Promise<{ events: number; latest: number; reset: boolean }> {
  const net = env.network;
  const ids = [net.contracts.launchpad, net.contracts.moments].filter((x): x is string => Boolean(x));
  const latest = (await rpcServer().getLatestLedger()).sequence;
  const cur = await sql()`select ledger, cursor, network_id from lite.indexer_cursors where name = ${CURSOR}`;
  let reset = false;
  if (cur.length && (cur[0].ledger as number) > latest + 100) {
    // The ledger went backwards: a testnet reset. Everything indexed is gone on-chain.
    reset = true;
    await sql()`truncate lite.launch_trades, lite.launches, lite.moment_collects, lite.moments, lite.indexer_cursors`;
    console.warn("testnet reset detected; indexed data cleared. Redeploy contracts (docs/RUNBOOK-testnet.md).");
    return { events: 0, latest, reset };
  }
  if (ids.length === 0) return { events: 0, latest, reset };

  const deployLedger = Number((deployment as any).deployLedger ?? 0);
  const req: any = { filters: [{ type: "contract", contractIds: ids }], limit: 500 };
  if (cur.length && cur[0].cursor) req.cursor = cur[0].cursor;
  else req.startLedger = Math.max(deployLedger || latest - 100_000, latest - 110_000);

  let count = 0;
  for (let round = 0; round < 5; round++) {
    const res = await rpcServer().getEvents(req);
    for (const e of res.events as any[]) {
      await handle(e, contractIdOf(e));
      count++;
    }
    await sql()`
      insert into lite.indexer_cursors (name, ledger, cursor, network_id) values (${CURSOR}, ${res.latestLedger}, ${res.cursor ?? null}, ${net.passphrase})
      on conflict (name) do update set ledger = excluded.ledger, cursor = excluded.cursor, updated_at = now()`;
    if ((res.events as any[]).length < 500 || !res.cursor) break;
    delete req.startLedger;
    req.cursor = res.cursor;
  }
  return { events: count, latest, reset };
}

export async function handle(e: any, contract: string): Promise<void> {
  const topics = (e.topic as any[]).map((t) => native(t));
  const kind = String(topics[0]);
  const data = native(e.value);
  const ts = new Date(e.ledgerClosedAt);
  const net = env.network;

  if (contract === net.contracts.launchpad) {
    if (kind === "launch") {
      await sql()`
        insert into lite.launches (token, creator, quote, name, symbol, uri, launch_index, supply, phantom, threshold, creator_fee_bps, quote_reserve, token_reserve, created_ledger, created_at)
        values (${topics[1]}, ${topics[2]}, ${data.quote}, ${data.name}, ${data.symbol}, ${data.uri}, ${data.index}, ${String(data.supply)}, ${String(data.phantom)}, ${String(data.threshold)},
                ${data.creator_fee_bps}, ${String(data.phantom)}, ${String(data.supply)}, ${e.ledger}, ${ts})
        on conflict (token) do nothing`;
    } else if (kind === "trade") {
      const price = Number(data.quote_reserve) / Number(data.token_reserve);
      const inserted = await sql()`
        insert into lite.launch_trades (event_id, token, trader, side, quote_amount, token_amount, fees, price, tx_hash, ledger, ts)
        values (${e.id}, ${topics[1]}, ${topics[2]}, ${data.is_buy ? "buy" : "sell"}, ${String(data.quote_amount)}, ${String(data.token_amount)}, ${String(data.fees)},
                ${price}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
        on conflict (event_id) do nothing returning event_id`;
      if (inserted.length) {
        await sql()`
          update lite.launches set quote_reserve = ${String(data.quote_reserve)}, token_reserve = ${String(data.token_reserve)}, real_quote = ${String(data.real_quote)},
                 last_price = ${price}, volume_quote = volume_quote + ${String(data.quote_amount)}, trades = trades + 1, updated_at = now()
           where token = ${topics[1]}`;
      }
    } else if (kind === "complete") {
      await sql()`update lite.launches set completed = true, updated_at = now() where token = ${topics[1]}`;
    } else if (kind === "graduate") {
      await sql()`update lite.launches set graduated = true, completed = true, pair = ${data.pair}, updated_at = now() where token = ${topics[1]}`;
    }
    return;
  }

  if (contract === net.contracts.moments) {
    if (kind === "publish") {
      const meta = await fetchMetadata(String(data.uri));
      await sql()`
        insert into lite.moments (id, creator, uri, title, media_url, price, quote, max_editions, deadline, created_ledger, created_at)
        values (${Number(topics[1])}, ${topics[2]}, ${data.uri}, ${meta.title}, ${meta.media}, ${String(data.price)}, ${data.quote}, ${Number(data.max_editions)},
                ${new Date(Number(data.deadline) * 1000)}, ${e.ledger}, ${ts})
        on conflict (id) do nothing`;
    } else if (kind === "collect") {
      const inserted = await sql()`
        insert into lite.moment_collects (event_id, moment_id, collector, quantity, first_token_id, paid, tx_hash, ledger, ts)
        values (${e.id}, ${Number(topics[1])}, ${topics[2]}, ${Number(data.quantity)}, ${Number(data.first_token_id)}, ${String(data.paid)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
        on conflict (event_id) do nothing returning event_id`;
      if (inserted.length) await sql()`update lite.moments set minted = ${Number(data.minted)}, updated_at = now() where id = ${Number(topics[1])}`;
    }
  }
}

/** Settles sponsored transactions the phone stopped polling. */
export async function settlePending(): Promise<number> {
  const rows = await sql()`select hash, plan_id, step_id from lite.tx_log where status = 'pending' and created_at < now() - interval '5 seconds' order by created_at limit 50`;
  let n = 0;
  for (const r of rows) {
    const s = await txStatus(r.hash as string);
    if (s.status === "PENDING") continue;
    await settle(r.hash as string, s.status === "SUCCESS" ? "success" : "failed", s.ledger, s.feeCharged, s.error, r.plan_id as string | null, r.step_id as string | null);
    n++;
  }
  return n;
}

/** Graduates completed curves nobody graduated yet. The call is permissionless; the sponsor pays the fee. */
export async function keeper(): Promise<number> {
  const pad = env.network.contracts.launchpad;
  if (!pad) return 0;
  const rows = await sql()`select token from lite.launches where completed and not graduated order by updated_at limit 3`;
  let n = 0;
  for (const r of rows) {
    try {
      const sp = sponsor();
      const acct = (await loadAccount(sp.publicKey()))!;
      const tx = await invoke(acct, pad, "graduate", [sv.addr(r.token as string)], 120);
      tx.sign(sp);
      await sendSigned(tx);
      n++;
    } catch (err) {
      console.warn("graduate failed", r.token, String((err as Error).message));
    }
  }
  return n;
}

/** Keeps the contracts, the launch-token WASM and every launch token's instance from archiving. */
export async function ttl() {
  const c = env.network.contracts;
  const mine = [c.launchpad, c.moments].filter((x): x is string => Boolean(x));
  if (mine.length === 0) return { checked: 0, extended: 0 };
  const tokens = await sql()`select token from lite.launches order by updated_at desc limit 200`;
  const tokenHash = (deployment as any).launchTokenWasmHash as string | undefined;
  return await keepAlive([...mine, ...tokens.map((t) => t.token as string)], tokenHash ? [tokenHash] : []);
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    const secret = env.cronSecret;
    if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);
    const started = Date.now();
    const out: Record<string, unknown> = {};
    for (const [name, step] of [["events", indexEvents], ["settled", settlePending], ["graduated", keeper], ["bridges", advanceBridges], ["ttl", ttl]] as const) {
      try {
        out[name] = await step();
      } catch (err) {
        out[name] = { error: String((err as Error).message ?? err).slice(0, 200) };
      }
    }
    out.ms = Date.now() - started;
    return json(out);
  });
}
