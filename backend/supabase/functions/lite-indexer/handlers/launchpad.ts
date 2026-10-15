// The launchpad's events (docs/DESIGN-stellar-parity.md §6.11): launch, trade, complete, graduate and claim_creator.
// Decoding is pure (decode*); recording is idempotent (by event id, or as the state the event describes), so a page
// read twice changes nothing.
// - launch: the row, with the launch's fee terms (get_launch, read once), listed unless the deployment made it as a
//   smoke test, look_alike when its ticker imitates a reserved one, and the metadata joined by its URI; its token is
//   watched from the launch's ledger (jobs/watch.ts).
// - trade: the trade and the curve's new state, as before, plus the time of the last trade.
// - graduate: the burn, the pool's opening reserves and price, which side of the pair the launch token is (the pair's
//   token_0, read once) and when; the pair is watched from then on.
// - claim_creator: a creator_claims row, added to the launch's claimed fees.
// A read the launchpad or a pair doesn't answer leaves its column empty, never the event unrecorded: the watch job
// fills it in later (jobs/watch.ts).
import type postgres from "postgres";
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { metadataFor } from "../../_shared/launch_metadata.ts";
import { ratio, SOROSWAP_POOL_FEE_BPS } from "../../_shared/launchpad.ts";
import { NetworkConfig } from "../../_shared/networks.ts";
import { sv, view } from "../../_shared/stellar.ts";
import { symbolLooksReserved } from "../../_shared/symbols.ts";
import type { ContractEvent } from "../jobs/main_events.ts";

type Decodable = Pick<ContractEvent, "topics" | "data">;

export interface Launched {
  token: string;
  creator: string;
  quote: string;
  name: string;
  symbol: string;
  uri: string;
  index: number;
  supply: bigint;
  phantom: bigint;
  threshold: bigint;
  creatorFeeBps: number;
}

/** launch [launch, token, creator] {quote, name, symbol, uri, index, supply, phantom, threshold, creator_fee_bps}. */
export function decodeLaunch({ topics, data }: Decodable): Launched {
  return {
    token: String(topics[1]),
    creator: String(topics[2]),
    quote: String(data.quote),
    name: String(data.name),
    symbol: String(data.symbol),
    uri: String(data.uri ?? ""),
    index: Number(data.index),
    supply: BigInt(data.supply),
    phantom: BigInt(data.phantom),
    threshold: BigInt(data.threshold),
    creatorFeeBps: Number(data.creator_fee_bps),
  };
}

export interface Traded {
  token: string;
  trader: string;
  side: "buy" | "sell";
  quoteAmount: bigint;
  tokenAmount: bigint;
  fees: bigint;
  quoteReserve: bigint;
  tokenReserve: bigint;
  realQuote: bigint;
  /** The curve's price after the trade: quote reserve / token reserve. */
  price: string;
}

/** trade [trade, token, trader] {is_buy, quote_amount, token_amount, fees, quote_reserve, token_reserve, real_quote}. */
export function decodeTrade({ topics, data }: Decodable): Traded {
  const quoteReserve = BigInt(data.quote_reserve);
  const tokenReserve = BigInt(data.token_reserve);
  return {
    token: String(topics[1]),
    trader: String(topics[2]),
    side: data.is_buy === true ? "buy" : "sell",
    quoteAmount: BigInt(data.quote_amount),
    tokenAmount: BigInt(data.token_amount),
    fees: BigInt(data.fees),
    quoteReserve,
    tokenReserve,
    realQuote: BigInt(data.real_quote),
    price: ratio(quoteReserve, tokenReserve),
  };
}

export interface Graduated {
  token: string;
  pair: string;
  poolTokens: bigint;
  poolQuote: bigint;
  liquidity: bigint;
  burned: bigint;
  /** The pool's opening price: pool quote / pool tokens, the curve's final price. */
  price: string;
}

/** graduate [graduate, token] {pair, pool_tokens, pool_quote, liquidity, burned}. */
export function decodeGraduate({ topics, data }: Decodable): Graduated {
  const poolTokens = BigInt(data.pool_tokens);
  const poolQuote = BigInt(data.pool_quote);
  return {
    token: String(topics[1]),
    pair: String(data.pair),
    poolTokens,
    poolQuote,
    liquidity: BigInt(data.liquidity),
    burned: BigInt(data.burned),
    price: ratio(poolQuote, poolTokens),
  };
}

export interface Claimed {
  token: string;
  creator: string;
  amount: bigint;
}

/** claim_creator [claim_creator, token, creator] {amount}. */
export function decodeClaim({ topics, data }: Decodable): Claimed {
  return { token: String(topics[1]), creator: String(topics[2]), amount: BigInt(data.amount) };
}

// ------------------------------------------------------------------------------------------------ what the indexer adds

/** What a launch shows besides its event: listed (never a smoke launch of the deployment), look_alike, and the metadata
 *  joined by its URI. */
export async function launchFacts(token: string, symbol: string, uri: string, net: NetworkConfig = env.network) {
  const smoke = net.deployment?.smoke?.launches ?? [];
  const meta = await metadataFor(uri);
  return { listed: !smoke.includes(token), lookAlike: symbolLooksReserved(symbol, net), image: meta.image, description: meta.description, links: meta.links };
}

/** A launch's fee terms, fixed when it was created (its record in the launchpad); null when they can't be read. */
export async function launchTerms(token: string): Promise<{ feeBps: number; protocolShareBps: number } | null> {
  const pad = env.network.contracts.launchpad;
  if (!pad) return null;
  try {
    const l = await view(pad, "get_launch", [sv.addr(token)]);
    return { feeBps: Number(l.fee_bps), protocolShareBps: Number(l.protocol_share_bps) };
  } catch {
    return null;
  }
}

/** Whether the pair's token_0 is the launch token (Soroswap orders a pair's two tokens), read once from the pair; null
 *  when it can't be read. */
export async function pairSide(pair: string, token: string): Promise<boolean | null> {
  try {
    return String(await view(pair, "token_0")) === token;
  } catch {
    return null;
  }
}

/** Starts watching a launch token or its pair from `fromLedger` (jobs/watch.ts gives it a group). */
export async function watchContract(q: postgres.Sql, contract: string, role: "token" | "pair", token: string, fromLedger: number): Promise<void> {
  await q`insert into lite.watch_contracts (contract, role, token, from_ledger) values (${contract}, ${role}, ${token}, ${fromLedger})
          on conflict (contract) do nothing`;
}

// ------------------------------------------------------------------------------------------------ recording

async function recordLaunch(l: Launched, ledger: number, ts: Date): Promise<void> {
  const [facts, terms] = await Promise.all([launchFacts(l.token, l.symbol, l.uri), launchTerms(l.token)]);
  await sql().begin(async (tx) => {
    await tx`
      insert into lite.launches (token, creator, quote, name, symbol, uri, launch_index, supply, phantom, threshold, creator_fee_bps,
                                 quote_reserve, token_reserve, created_ledger, created_at, fee_bps, protocol_share_bps, listed,
                                 look_alike, image_url, description, links)
      values (${l.token}, ${l.creator}, ${l.quote}, ${l.name}, ${l.symbol}, ${l.uri}, ${l.index}, ${l.supply.toString()},
              ${l.phantom.toString()}, ${l.threshold.toString()}, ${l.creatorFeeBps}, ${l.phantom.toString()}, ${l.supply.toString()},
              ${ledger}, ${ts}, ${terms?.feeBps ?? null}, ${terms?.protocolShareBps ?? null}, ${facts.listed}, ${facts.lookAlike},
              ${facts.image}, ${facts.description}, ${facts.links === null ? null : tx.json(facts.links)})
      on conflict (token) do update set listed = excluded.listed, look_alike = excluded.look_alike, image_url = excluded.image_url,
        description = excluded.description, links = excluded.links,
        fee_bps = coalesce(lite.launches.fee_bps, excluded.fee_bps),
        protocol_share_bps = coalesce(lite.launches.protocol_share_bps, excluded.protocol_share_bps)`;
    await watchContract(tx, l.token, "token", l.token, ledger);
  });
}

async function recordTrade(t: Traded, e: { id: string; ledger: number; txHash?: string }, ts: Date): Promise<void> {
  await sql().begin(async (tx) => {
    const inserted = await tx`
      insert into lite.launch_trades (event_id, token, trader, side, quote_amount, token_amount, fees, price, tx_hash, ledger, ts)
      values (${e.id}, ${t.token}, ${t.trader}, ${t.side}, ${t.quoteAmount.toString()}, ${t.tokenAmount.toString()}, ${t.fees.toString()},
              ${t.price}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
      on conflict (event_id) do nothing returning event_id`;
    if (inserted.length) {
      await tx`
        update lite.launches set quote_reserve = ${t.quoteReserve.toString()}, token_reserve = ${t.tokenReserve.toString()},
               real_quote = ${t.realQuote.toString()}, last_price = ${t.price}, volume_quote = volume_quote + ${t.quoteAmount.toString()},
               trades = trades + 1, last_trade_at = greatest(last_trade_at, ${ts}), updated_at = now()
         where token = ${t.token}`;
    }
  });
}

async function recordGraduate(g: Graduated, ledger: number, ts: Date): Promise<void> {
  const side = await pairSide(g.pair, g.token);
  await sql().begin(async (tx) => {
    // The pool's reserves and price come from its own events once those are read (jobs/watch.ts): the graduation's
    // are its opening ones, and never replace a later sync's.
    await tx`
      update lite.launches set graduated = true, completed = true, pair = ${g.pair}, burned = greatest(burned, ${g.burned.toString()}),
             pool_token = coalesce(pool_token, ${g.poolTokens.toString()}), pool_quote = coalesce(pool_quote, ${g.poolQuote.toString()}),
             last_price = case when pool_token is null then ${g.price} else last_price end,
             pair_token0_is_launch = coalesce(pair_token0_is_launch, ${side}), graduated_ledger = coalesce(graduated_ledger, ${ledger}),
             graduated_at = coalesce(graduated_at, ${ts}), pool_fee_bps = coalesce(pool_fee_bps, ${SOROSWAP_POOL_FEE_BPS}), updated_at = now()
       where token = ${g.token}`;
    await watchContract(tx, g.pair, "pair", g.token, ledger);
  });
}

async function recordClaim(c: Claimed, e: { id: string; ledger: number; txHash?: string }, ts: Date): Promise<void> {
  await sql().begin(async (tx) => {
    const inserted = await tx`
      insert into lite.creator_claims (event_id, token, creator, amount, tx_hash, ledger, ts)
      values (${e.id}, ${c.token}, ${c.creator}, ${c.amount.toString()}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
      on conflict (event_id) do nothing returning event_id`;
    if (inserted.length) {
      await tx`update lite.launches set creator_fees_claimed = creator_fees_claimed + ${c.amount.toString()}, updated_at = now() where token = ${c.token}`;
    }
  });
}

export async function launchpadEvent(event: ContractEvent): Promise<void> {
  const { raw: e, kind, topics, ts } = event;
  if (kind === "launch") await recordLaunch(decodeLaunch(event), e.ledger, ts);
  else if (kind === "trade") await recordTrade(decodeTrade(event), e, ts);
  else if (kind === "complete") await sql()`update lite.launches set completed = true, updated_at = now() where token = ${String(topics[1])}`;
  else if (kind === "graduate") await recordGraduate(decodeGraduate(event), e.ledger, ts);
  else if (kind === "claim_creator") await recordClaim(decodeClaim(event), e, ts);
}
