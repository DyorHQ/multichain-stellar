// The launchpad's and Moments' events from Stellar RPC (7-day retention): keeps the cursor, starts over when the
// cursor no longer describes the chain (reset.ts), and hands each event to its contract's handler.
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { native, rpcServer } from "../../_shared/stellar.ts";
import { launchpadEvent } from "../handlers/launchpad.ts";
import { momentsEvent } from "../handlers/moments.ts";
import { clearIndexed, resetAllowed } from "./reset.ts";

const CURSOR = "events";

/** A contract event with its topics and data decoded to native values. */
export interface ContractEvent {
  raw: any;
  kind: string;
  topics: any[];
  data: any;
  ts: Date;
}

/** What the indexed tables describe: the network and its launchpad and Moments contracts, kept with the cursor. */
export function deploymentKey(net: { passphrase: string; contracts: { launchpad?: string | null; moments?: string | null } }): string {
  return [net.passphrase, net.contracts.launchpad ?? "", net.contracts.moments ?? ""].join("|");
}

function contractIdOf(e: any): string {
  const c = e.contractId;
  if (!c) return "";
  return typeof c === "string" ? c : typeof c.contractId === "function" ? c.contractId() : String(c);
}

export async function indexEvents(): Promise<{ events: number; latest: number; reset: boolean }> {
  const net = env.network;
  const ids = [net.contracts.launchpad, net.contracts.moments].filter((x): x is string => Boolean(x));
  const key = deploymentKey(net);
  const latest = (await rpcServer().getLatestLedger()).sequence;
  const cur = await sql()`select ledger, cursor, network_id from lite.indexer_cursors where name = ${CURSOR}`;
  let reset = false;
  if (cur.length && (cur[0].ledger as number) > latest + 100) {
    // The ledger went backwards: a testnet reset. Everything indexed is gone on-chain. Off testnet it can only be an
    // RPC behind the chain: wait for it.
    if (!resetAllowed("ledger_backwards", net.name, env.indexerAllowReset)) {
      console.warn(`RPC answers ledger ${latest}, behind the indexed ${cur[0].ledger}; waiting for it to catch up.`);
      return { events: 0, latest, reset };
    }
    reset = true;
    await clearIndexed();
    console.warn("testnet reset detected; indexed data cleared. Redeploy contracts.");
    return { events: 0, latest, reset };
  }
  let cursor: string | null = cur.length ? (cur[0].cursor as string | null) : null;
  if (cur.length && cur[0].network_id !== key) {
    // Other contracts than the indexed ones (deploy-contracts.ts ran again, no network reset): the rows describe
    // contracts the app no longer pins, and the new Moments contract numbers its Moments from 1 again, which the old
    // rows would shadow (`on conflict do nothing`). Start over from the new deployment's ledger.
    if (!resetAllowed("new_deployment", net.name, env.indexerAllowReset)) {
      throw new Error("new contracts: the indexed data describes others. Set LITE_INDEXER_ALLOW_RESET=1 to clear it and index the new ones.");
    }
    reset = true;
    await clearIndexed();
    console.warn("new contracts detected; indexed data cleared, indexing again from their deploy ledger.");
    cursor = null;
  }
  if (ids.length === 0) return { events: 0, latest, reset };

  const deployLedger = net.deployment?.indexFromLedger ?? net.deployment?.deployLedger ?? 0;
  const filters = [{ type: "contract", contractIds: ids }];
  const fromStart = async () => ({ filters, limit: 500, startLedger: await streamStart(deployLedger, latest) });
  let req: any = cursor ? { filters, limit: 500, cursor } : await fromStart();

  let count = 0;
  // RPC scans a bounded ledger window per request and answers with a cursor at the window's end, so a page with
  // fewer than `limit` events doesn't mean we're caught up: keep paging until the cursor reaches the latest ledger
  // (bounded per run; the next minute's run continues).
  for (let round = 0; round < 30; round++) {
    let res: any;
    try {
      res = await rpcServer().getEvents(req);
    } catch (err) {
      // A cursor older than RPC retention (~7 days) is refused: restart from what RPC still has.
      if (round === 0 && req.cursor) {
        console.warn("cursor refused, restarting from retention window", String((err as Error).message).slice(0, 120));
        req = await fromStart();
        res = await rpcServer().getEvents(req);
      } else {
        throw err;
      }
    }
    for (const e of res.events as any[]) {
      await handle(e, contractIdOf(e));
      count++;
    }
    await sql()`
      insert into lite.indexer_cursors (name, ledger, cursor, network_id) values (${CURSOR}, ${res.latestLedger}, ${res.cursor ?? null}, ${key})
      on conflict (name) do update set ledger = excluded.ledger, cursor = excluded.cursor, network_id = excluded.network_id, updated_at = now()`;
    if (!res.cursor) break;
    if (cursorLedger(res.cursor) >= res.latestLedger - 1 && (res.events as any[]).length < 500) break;
    req = { filters, limit: 500, cursor: res.cursor };
  }
  return { events: count, latest, reset };
}

/** How far inside RPC's window a stream with no usable cursor starts, as watch.ts's groups do (RETENTION_MARGIN):
 *  about 100 s, since the window moves on while a run reads. */
const START_MARGIN = 20;

/** Where a stream with no usable cursor starts reading: its contracts' deploy ledger (or, without one, about 5.8 days
 *  back), but never before the oldest ledger RPC keeps. Testnet's public RPC keeps about 13 hours, far less than the
 *  7 days the window above assumes, so on a fresh database the deploy ledger is already out of reach and getEvents
 *  refuses it. An RPC that doesn't answer getHealth gets the old start, and getEvents has the last word. */
export async function streamStart(fromLedger: number, latest: number): Promise<number> {
  const wanted = Math.max(fromLedger || latest - 100_000, latest - 110_000);
  let oldest = 0;
  try {
    oldest = Number((await rpcServer().getHealth()).oldestLedger) || 0;
  } catch {
    oldest = 0;
  }
  return oldest > 0 ? Math.max(wanted, oldest + START_MARGIN) : wanted;
}

/** Event cursors are "<TOID>-<index>"; a TOID's high 32 bits are the ledger sequence. */
export function cursorLedger(cursor: string): number {
  try {
    return Number(BigInt(cursor.split("-")[0]) >> 32n);
  } catch {
    return 0;
  }
}

/** Decodes an event and hands it to its contract's handler. */
export async function handle(e: any, contract: string): Promise<void> {
  const topics = (e.topic as any[]).map((t) => native(t));
  const event: ContractEvent = { raw: e, kind: String(topics[0]), topics, data: native(e.value), ts: new Date(e.ledgerClosedAt) };
  const net = env.network;
  if (contract === net.contracts.launchpad) return await launchpadEvent(event);
  if (contract === net.contracts.moments) return await momentsEvent(event);
}
