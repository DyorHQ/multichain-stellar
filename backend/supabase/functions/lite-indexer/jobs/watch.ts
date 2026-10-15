// Launch tokens' and graduated pairs' events (docs/DESIGN-stellar-parity.md §6.11), a cursor per watch group.
// - Groups. One getEvents request takes at most 5 filters of 5 contract ids, so it reads a group of up to 25 contracts.
//   Contracts the launchpad handler registers join a new group at the earliest of their first ledgers; groups that
//   have caught up with the chain merge, at the earlier of their positions (an event read twice is dropped by its id).
// - Gaps. A group whose position RPC no longer keeps (older than its retention, or a cursor it refuses) starts again
//   a little inside the window RPC keeps at that moment (it slides on with every ledger), and the holders of its launch
//   tokens are marked incomplete. A group RPC still refuses is read again next run; the other groups still are.
// - Token events (OpenZeppelin stellar-tokens 0.7.2): transfer [transfer, from, to] with an i128, or {amount,
//   to_muxed_id} for a muxed destination; mint [mint, to] {amount}; burn [burn, from] {amount}. Each is recorded with
//   the balances it moves (lite.record_token_event); a balance reconcile read live already counts the events up to its
//   ledger.
// - Pair events (Soroswap, topics ("SoroswapPair", name)): sync, deposit and withdraw set the pool's reserves and price;
//   swap records a pool trade (lite.record_pool_swap; side buy when the launch token leaves the pool), priced by the
//   sync of the same transaction, whichever of the two is read first. A sell's trader is whoever sent the launch tokens
//   into the pair: on a route through more than one pool the swap's `to` is the next pool.
// - Launches indexed before migration 07 have no watched token: they are taken up here (their facts, fee terms and,
//   once graduated, the pool's fee and their pair's side), and launches whose fee terms couldn't be read are retried.
//   The deployment's smoke launches are unlisted.
import type { rpc } from "@stellar/stellar-sdk";
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { ratio, SOROSWAP_POOL_FEE_BPS } from "../../_shared/launchpad.ts";
import { NetworkConfig } from "../../_shared/networks.ts";
import { native, rpcServer } from "../../_shared/stellar.ts";
import { launchFacts, launchTerms, pairSide, watchContract } from "../handlers/launchpad.ts";
import { cursorLedger } from "./main_events.ts";

/** Contract ids per getEvents filter, and filters per request. */
const PER_FILTER = 5;
const FILTERS = 5;
/** Contracts in one group: one request reads them all. */
export const GROUP_SIZE = PER_FILTER * FILTERS;
/** Events per page. */
const PAGE_LIMIT = 1_000;
/** Pages per group per run. */
const PAGES = 10;
/** A group within this many ledgers of the chain's head has caught up. */
export const CAUGHT_UP_LEDGERS = 12;
/** A group that starts again for a gap starts this many ledgers (about 100 s) past the oldest one RPC keeps: the
 *  window moves on a ledger every 5 s or so, and another node behind the same URL may keep a little less. */
export const RETENTION_MARGIN = 20;
/** The job stops starting groups after this long (the indexer's budget is 45 s for every job). */
const RUN_MS = 15_000;
/** Launches taken up per run. */
const ENROL_PER_RUN = 20;

// ------------------------------------------------------------------------------------------------ positions

/** Where a group reads from: an event cursor once it has read a page, else the start of a ledger. */
export interface Position {
  cursor: string | null;
  ledger: number;
}

/** Event cursors are "<TOID>-<index>": compared as numbers. */
export function compareCursors(a: string, b: string): number {
  const [ta, ia] = a.split("-").map((s) => BigInt(s || "0"));
  const [tb, ib] = b.split("-").map((s) => BigInt(s || "0"));
  return ta !== tb ? (ta < tb ? -1 : 1) : ia === ib ? 0 : (ia ?? 0n) < (ib ?? 0n) ? -1 : 1;
}

/** The ledger a position is at. */
export function ledgerOf(p: Position): number {
  return p.cursor === null ? p.ledger : cursorLedger(p.cursor);
}

/** Whichever of two positions comes first: the start of a ledger comes before every event in it. */
export function earlier(a: Position, b: Position): Position {
  if (a.cursor !== null && b.cursor !== null) return compareCursors(a.cursor, b.cursor) <= 0 ? a : b;
  const [la, lb] = [ledgerOf(a), ledgerOf(b)];
  if (la !== lb) return la < lb ? a : b;
  return a.cursor === null ? a : b;
}

export interface GroupState {
  id: number;
  position: Position;
  /** The ledger it has read up to. */
  ledger: number;
  members: string[];
}

export interface Merge {
  /** The group kept, and those folded into it. */
  keep: number;
  drop: number[];
  members: string[];
  /** The earliest position among them. */
  position: Position;
  ledger: number;
}

/** Groups that have caught up, packed into as few groups of at most `size` members as fit (the largest first), each
 *  at the earliest position among those it takes in. Only packs that fold two or more groups are answered. */
export function mergeGroups(groups: GroupState[], size: number = GROUP_SIZE): Merge[] {
  const bins: GroupState[][] = [];
  for (const g of [...groups].sort((a, b) => b.members.length - a.members.length || a.id - b.id)) {
    const bin = bins.find((b) => b.reduce((n, x) => n + x.members.length, 0) + g.members.length <= size);
    if (bin) bin.push(g);
    else bins.push([g]);
  }
  return bins.filter((b) => b.length > 1).map((b) => {
    const [keep, ...rest] = [...b].sort((x, y) => x.id - y.id);
    return {
      keep: keep.id,
      drop: rest.map((g) => g.id),
      members: b.flatMap((g) => g.members),
      position: b.map((g) => g.position).reduce(earlier),
      ledger: Math.min(...b.map((g) => g.ledger)),
    };
  });
}

// ------------------------------------------------------------------------------------------------ decoding

export type TokenMove =
  | { kind: "transfer"; from: string; to: string; amount: bigint; toMuxedId: string | null }
  | { kind: "mint"; to: string; amount: bigint }
  | { kind: "burn"; from: string; amount: bigint };

const amountOf = (data: unknown): bigint => BigInt(typeof data === "bigint" ? data : (data as { amount: bigint }).amount);

/** A launch token's event, decoded (topics and data as scValToNative gives them); null for any other. */
export function decodeTokenEvent(topics: unknown[], data: unknown): TokenMove | null {
  switch (String(topics[0])) {
    case "transfer": {
      // SEP-41: the amount alone, or {amount, to_muxed_id} when the destination is muxed.
      const muxed = typeof data === "bigint" ? null : (data as { to_muxed_id?: unknown }).to_muxed_id;
      return { kind: "transfer", from: String(topics[1]), to: String(topics[2]), amount: amountOf(data), toMuxedId: muxed === null || muxed === undefined ? null : String(muxed) };
    }
    case "mint":
      return { kind: "mint", to: String(topics[1]), amount: amountOf(data) };
    case "burn":
      return { kind: "burn", from: String(topics[1]), amount: amountOf(data) };
    default:
      return null;
  }
}

/** The balances a token event moves. */
export function balanceChanges(m: TokenMove): [string, bigint][] {
  switch (m.kind) {
    case "transfer":
      return [[m.from, -m.amount], [m.to, m.amount]];
    case "mint":
      return [[m.to, m.amount]];
    case "burn":
      return [[m.from, -m.amount]];
  }
}

export type PoolEvent =
  | { kind: "reserves"; reserveToken: bigint; reserveQuote: bigint; price: string | null; depositTo: string | null }
  /** `to` got the swap's output: the trader in a buy; in a sell, the seller or the next pool of the seller's route. */
  | { kind: "swap"; to: string; side: "buy" | "sell"; tokenAmount: bigint; quoteAmount: bigint };

/** A Soroswap pair's event, decoded for its launch token: `token0IsLaunch` says which reserve is the token's. Null for
 *  any other event (skim, the LP token's own). */
export function decodePairEvent(topics: unknown[], data: unknown, token0IsLaunch: boolean): PoolEvent | null {
  if (String(topics[0]) !== "SoroswapPair") return null;
  const d = data as Record<string, unknown>;
  const name = String(topics[1]);
  if (name === "sync" || name === "deposit" || name === "withdraw") {
    const [r0, r1] = [BigInt(d.new_reserve_0 as bigint), BigInt(d.new_reserve_1 as bigint)];
    const [reserveToken, reserveQuote] = token0IsLaunch ? [r0, r1] : [r1, r0];
    return { kind: "reserves", reserveToken, reserveQuote, price: reserveToken > 0n ? ratio(reserveQuote, reserveToken) : null, depositTo: name === "deposit" ? String(d.to) : null };
  }
  if (name === "swap") {
    const [in0, out0, in1, out1] = [d.amount_0_in, d.amount_0_out, d.amount_1_in, d.amount_1_out].map((v) => BigInt(v as bigint));
    const [tokenIn, tokenOut, quoteIn, quoteOut] = token0IsLaunch ? [in0, out0, in1, out1] : [in1, out1, in0, out0];
    const tokensOut = tokenOut - tokenIn;
    const quoteNet = quoteIn - quoteOut;
    return {
      kind: "swap",
      to: String(d.to),
      side: tokensOut > 0n ? "buy" : "sell",
      tokenAmount: tokensOut < 0n ? -tokensOut : tokensOut,
      quoteAmount: quoteNet < 0n ? -quoteNet : quoteNet,
    };
  }
  return null;
}

// ------------------------------------------------------------------------------------------------ recording

type Event = rpc.Api.EventResponse;

export interface Member {
  contract: string;
  role: "token" | "pair";
  token: string;
  token0IsLaunch: boolean | null;
  /** Its first ledger: no event of it comes before. */
  fromLedger: number;
}

/** Records a token's event and the balances it moves (balanceChanges), once, in one statement: a balance read live at
 *  its ledger or later (reconcile) already counts it, and a transfer into a pair names the seller of that pair's later
 *  sells in its transaction (lite.record_token_event). Answers whether the event was new. */
export async function recordTokenEvent(token: string, m: TokenMove, e: Event): Promise<boolean> {
  const from = m.kind === "mint" ? null : m.from;
  const to = m.kind === "burn" ? null : m.to;
  const [r] = await sql()`
    select lite.record_token_event(${e.id}, ${token}, ${m.kind}, ${from}, ${to}, ${m.kind === "transfer" ? m.toMuxedId : null},
                                   ${m.amount.toString()}, ${e.txHash ?? null}, ${e.ledger}, ${new Date(e.ledgerClosedAt)}) as recorded`;
  return r?.recorded === true;
}

/** Records a pair's event: reserves move the pool and price their transaction's swap; a swap is a pool trade. */
export async function recordPoolEvent(member: Member, ev: PoolEvent, e: Event): Promise<void> {
  const ts = new Date(e.ledgerClosedAt);
  const txHash = e.txHash ?? null;
  if (ev.kind === "reserves") {
    const graduation = ev.depositTo !== null && ev.depositTo === env.network.contracts.launchpad;
    await sql().begin(async (tx) => {
      // Only a later event than the last one applied moves the pool (a group may read a page again).
      await tx`
        update lite.launches set pool_token = ${ev.reserveToken.toString()}, pool_quote = ${ev.reserveQuote.toString()},
               last_price = coalesce(${ev.price}::numeric, last_price), pool_event = ${e.id}, pool_tx = ${txHash},
               graduated_ledger = coalesce(graduated_ledger, ${graduation ? e.ledger : null}::int),
               graduated_at = coalesce(graduated_at, ${graduation ? ts : null}::timestamptz), updated_at = now()
         where token = ${member.token} and (pool_event is null or pool_event < ${e.id})`;
      if (ev.price !== null && txHash !== null) {
        await tx`update lite.pool_swaps set price = ${ev.price} where pair = ${member.contract} and tx_hash = ${txHash} and price is null`;
      }
    });
    return;
  }
  // Once, with its trader (a sell's seller from its transaction's transfer into the pair) and, when the sync of its
  // transaction was read first, its price (lite.record_pool_swap); otherwise that sync prices it.
  await sql()`
    select lite.record_pool_swap(${e.id}, ${member.token}, ${member.contract}, ${ev.to}, ${ev.side}, ${ev.quoteAmount.toString()},
                                 ${ev.tokenAmount.toString()}, ${txHash}, ${e.ledger}, ${ts}) as recorded`;
}

function contractIdOf(e: Event): string {
  const c = e.contractId as unknown;
  if (!c) return "";
  return typeof c === "string" ? c : typeof (c as { contractId?: unknown }).contractId === "function" ? (c as { contractId(): string }).contractId() : String(c);
}

/** Records one watched contract's event; answers whether it was one of the kinds watched. */
async function handleWatched(e: Event, members: Map<string, Member>): Promise<boolean> {
  const member = members.get(contractIdOf(e));
  if (!member) return false;
  const topics = e.topic.map((t) => native(t));
  const data = native(e.value);
  if (member.role === "token") {
    const move = decodeTokenEvent(topics, data);
    if (move) await recordTokenEvent(member.token, move, e);
    return move !== null;
  }
  const ev = decodePairEvent(topics, data, member.token0IsLaunch === true);
  if (ev) await recordPoolEvent(member, ev, e);
  return ev !== null;
}

// ------------------------------------------------------------------------------------------------ the job

/** Launches indexed before migration 07, or whose fee terms couldn't be read, taken up: their facts, fee terms, the pool
 *  fee and pair side once graduated, the time of their last curve trade, and their token and pair watched from their
 *  first ledgers. A launch whose reads fail waits for the next run. Also unlists the deployment's smoke launches. */
export async function takeUp(net: NetworkConfig = env.network): Promise<number> {
  const smoke = net.deployment?.smoke?.launches ?? [];
  if (smoke.length) await sql()`update lite.launches set listed = false where listed and token = any(${smoke}::text[])`;
  const rows = await sql()`
    select l.token, l.creator, l.name, l.symbol, l.uri, l.created_ledger, l.graduated, l.pair, l.graduated_ledger, l.pair_token0_is_launch,
           exists (select 1 from lite.watch_contracts w where w.contract = l.token) as watched
      from lite.launches l
     where l.fee_bps is null or not exists (select 1 from lite.watch_contracts w where w.contract = l.token)
     order by l.created_ledger limit ${ENROL_PER_RUN}`;
  let n = 0;
  for (const r of rows) {
    const token = String(r.token);
    const terms = await launchTerms(token);
    if (!terms) continue;
    const pair = r.graduated === true && r.pair ? String(r.pair) : null;
    const side = pair === null || r.pair_token0_is_launch !== null ? r.pair_token0_is_launch : await pairSide(pair, token);
    if (pair !== null && side === null) continue;
    const launch = { token, creator: String(r.creator), name: String(r.name), symbol: String(r.symbol), uri: String(r.uri ?? "") };
    const facts = r.watched ? null : await launchFacts(launch, net);
    await sql().begin(async (tx) => {
      await tx`update lite.launches set fee_bps = ${terms.feeBps}, protocol_share_bps = ${terms.protocolShareBps}, updated_at = now() where token = ${token}`;
      if (facts === null) return;
      await tx`
        update lite.launches set listed = ${facts.listed}, look_alike = ${facts.lookAlike}, image_url = ${facts.image},
               description = ${facts.description}, links = ${facts.links === null ? null : tx.json(facts.links)},
               last_trade_at = coalesce(last_trade_at, (select max(t.ts) from lite.launch_trades t where t.token = ${token})),
               pair_token0_is_launch = coalesce(pair_token0_is_launch, ${side}),
               pool_fee_bps = case when graduated then coalesce(pool_fee_bps, ${SOROSWAP_POOL_FEE_BPS}) else pool_fee_bps end
         where token = ${token}`;
      await watchContract(tx, token, "token", token, Number(r.created_ledger));
      if (pair !== null) await watchContract(tx, pair, "pair", token, Number(r.graduated_ledger ?? r.created_ledger));
    });
    n++;
  }
  return n;
}

/** Contracts without a group join new ones: by first ledger, 25 to a group, each starting at its earliest member's. */
async function group(): Promise<void> {
  const loose = await sql()`select contract, from_ledger from lite.watch_contracts where group_id is null order by from_ledger, contract limit 500`;
  for (let i = 0; i < loose.length; i += GROUP_SIZE) {
    const part = loose.slice(i, i + GROUP_SIZE);
    const start = Number(part[0].from_ledger);
    await sql().begin(async (tx) => {
      const [g] = await tx`insert into lite.watch_groups (start_ledger, ledger) values (${start}, ${start - 1}) returning id`;
      await tx`update lite.watch_contracts set group_id = ${g.id} where contract = any(${part.map((c) => String(c.contract))}::text[])`;
    });
  }
}

interface LoadedGroup extends GroupState {
  members: string[];
  watched: Member[];
}

async function groups(): Promise<LoadedGroup[]> {
  const rows = await sql()`
    select g.id, g.start_ledger, g.cursor, g.ledger, w.contract, w.role, w.token, w.from_ledger, l.pair_token0_is_launch
      from lite.watch_groups g
      join lite.watch_contracts w on w.group_id = g.id
      join lite.launches l on l.token = w.token
     order by g.id, w.contract`;
  const out = new Map<number, LoadedGroup>();
  for (const r of rows) {
    const id = Number(r.id);
    if (!out.has(id)) {
      out.set(id, { id, position: { cursor: (r.cursor as string | null) ?? null, ledger: Number(r.start_ledger) }, ledger: Number(r.ledger), members: [], watched: [] });
    }
    const g = out.get(id)!;
    g.members.push(String(r.contract));
    g.watched.push({
      contract: String(r.contract),
      role: r.role === "pair" ? "pair" : "token",
      token: String(r.token),
      token0IsLaunch: (r.pair_token0_is_launch as boolean | null) ?? null,
      fromLedger: Number(r.from_ledger),
    });
  }
  return [...out.values()];
}

async function save(id: number, p: Position, ledger: number): Promise<void> {
  await sql()`update lite.watch_groups set cursor = ${p.cursor}, start_ledger = ${p.cursor === null ? p.ledger : sql()`start_ledger`}, ledger = ${ledger}, updated_at = now() where id = ${id}`;
}

/** The launches whose tokens may have had events before `start` that the group didn't read: their holders may be
 *  missing. A token made since has none. */
async function markIncomplete(g: LoadedGroup, start: number): Promise<void> {
  const tokens = g.watched.filter((m) => m.role === "token" && m.fromLedger < start).map((m) => m.token);
  if (tokens.length) await sql()`update lite.launches set holders_complete = false where token = any(${tokens}::text[])`;
}

/** Reads a group's events from its position until it catches up, runs out of pages or `deadline` passes. `oldest` is
 *  RPC's oldest ledger when the run began: a position older than that restarts before the first request. */
async function read(g: LoadedGroup, oldest: number, deadline: number): Promise<{ events: number; gap: boolean }> {
  const members = new Map(g.watched.map((m) => [m.contract, m]));
  const filters = Array.from({ length: Math.ceil(g.members.length / PER_FILTER) }, (_, i) => ({
    type: "contract" as const,
    contractIds: g.members.slice(i * PER_FILTER, (i + 1) * PER_FILTER),
  }));
  let position = g.position;
  let gap = false;
  let retried = false;
  // From the start of the position's ledger, or, when RPC no longer keeps it, a little inside the window RPC keeps now
  // (read just before the request: it moves on while a run reads other groups): a gap then, for the tokens that existed
  // before that start.
  const restart = async () => {
    const start = (await rpcServer().getHealth()).oldestLedger + RETENTION_MARGIN;
    if (ledgerOf(position) < start) {
      gap = true;
      await markIncomplete(g, start);
    }
    position = { cursor: null, ledger: Math.max(start, ledgerOf(position)) };
  };
  if (ledgerOf(position) < oldest) await restart();
  let events = 0;
  for (let page = 0; page < PAGES && Date.now() < deadline; page++) {
    let res: rpc.Api.GetEventsResponse;
    try {
      res = await rpcServer().getEvents(position.cursor ? { filters, limit: PAGE_LIMIT, cursor: position.cursor } : { filters, limit: PAGE_LIMIT, startLedger: position.ledger });
    } catch (err) {
      // A cursor or a start RPC refuses: again from what it keeps now, once.
      if (retried) throw err;
      retried = true;
      await restart();
      continue;
    }
    for (const e of res.events) if (await handleWatched(e, members)) events++;
    if (res.cursor) position = { cursor: res.cursor, ledger: cursorLedger(res.cursor) };
    const readTo = Math.min(res.latestLedger, ledgerOf(position));
    await save(g.id, position, readTo);
    g.position = position;
    g.ledger = readTo;
    if (!res.cursor || (cursorLedger(res.cursor) >= res.latestLedger - 1 && res.events.length < PAGE_LIMIT)) break;
  }
  return { events, gap };
}

/** Folds groups that have caught up into as few as fit (mergeGroups). */
async function merge(all: LoadedGroup[], latest: number): Promise<number> {
  const merges = mergeGroups(all.filter((g) => g.ledger >= latest - CAUGHT_UP_LEDGERS));
  for (const m of merges) {
    await sql().begin(async (tx) => {
      await tx`update lite.watch_contracts set group_id = ${m.keep} where group_id = any(${m.drop}::bigint[])`;
      await tx`update lite.watch_groups set cursor = ${m.position.cursor}, start_ledger = ${m.position.cursor === null ? m.position.ledger : tx`start_ledger`},
                 ledger = ${m.ledger}, updated_at = now() where id = ${m.keep}`;
      await tx`delete from lite.watch_groups where id = any(${m.drop}::bigint[])`;
    });
  }
  return merges.reduce((n, m) => n + m.drop.length, 0);
}

export interface WatchReport {
  groups: number;
  events: number;
  /** Groups that restarted inside RPC's window. */
  gaps: number;
  /** Groups RPC wouldn't read this run: read again next run. */
  failed: number;
  /** Groups folded into others. */
  merged: number;
  /** Launches taken up. */
  takenUp: number;
  latest: number;
}

/** One run: take up older launches, group new contracts, read each group (the furthest behind first) and merge those
 *  that have caught up. A group that can't be read doesn't stop the others; when none of those tried can be, the run
 *  fails with the last error. */
export async function watchContracts(): Promise<WatchReport | { skipped: string }> {
  if (!env.network.contracts.launchpad) return { skipped: "no launchpad on this network" };
  const deadline = Date.now() + RUN_MS;
  const takenUp = await takeUp();
  await group();
  const health = await rpcServer().getHealth();
  const all = await groups();
  let events = 0;
  let gaps = 0;
  let tried = 0;
  let failed = 0;
  let lastError: unknown = null;
  for (const g of [...all].sort((a, b) => ledgerOf(a.position) - ledgerOf(b.position))) {
    if (Date.now() >= deadline) break;
    // A pair's events need its side, read once at graduation; one that couldn't be is read again first.
    for (const m of g.watched.filter((w) => w.role === "pair" && w.token0IsLaunch === null)) {
      m.token0IsLaunch = await pairSide(m.contract, m.token);
      if (m.token0IsLaunch !== null) await sql()`update lite.launches set pair_token0_is_launch = ${m.token0IsLaunch} where token = ${m.token}`;
    }
    if (g.watched.some((w) => w.role === "pair" && w.token0IsLaunch === null)) continue;
    tried++;
    try {
      const r = await read(g, health.oldestLedger, deadline);
      events += r.events;
      if (r.gap) gaps++;
    } catch (err) {
      failed++;
      lastError = err;
      console.warn(`watch: group ${g.id} not read this run`, String((err as Error).message ?? err).slice(0, 200));
    }
  }
  if (failed > 0 && failed === tried) throw lastError;
  const merged = await merge(all, health.latestLedger);
  return { groups: all.length - merged, events, gaps, failed, merged, takenUp, latest: health.latestLedger };
}

export const watch: (() => Promise<unknown>) | null = watchContracts;
