// Launchpad: create a launch, trade on its curve, graduate, claim creator fees. Lists come from the indexer; curve
// state and quotes are read live from the contract.
import { sql, num } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { assetById } from "./networks.ts";
import { createPlan, PlanView, registerBuilder } from "./plans.ts";
import { fromStroops, invoke, requireAccount, sv, view } from "./stellar.ts";
import { Intent } from "./verify.ts";

function launchpadId(): string {
  const id = env.network.contracts.launchpad;
  if (!id) throw new ApiError(503, "not_deployed", "The launchpad isn't deployed on this network yet.");
  return id;
}

function quoteAsset(id: string) {
  const a = assetById(env.network, id);
  if (!a || !["XLM", "USDC"].includes(a.id)) throw bad("bad_quote", "Launches are quoted in XLM or USDC.");
  return a;
}

export async function listLaunches(sort: string, limit: number) {
  const order = sort === "hot" ? sql()`volume_quote desc` : sort === "graduated" ? sql()`updated_at desc` : sql()`created_at desc`;
  const where = sort === "graduated" ? sql()`where graduated` : sort === "hot" ? sql()`where not graduated` : sql()``;
  const rows = await sql()`select * from lite.launches ${where} order by ${order} limit ${limit}`;
  return rows.map(launchRow);
}

function launchRow(r: Record<string, unknown>) {
  const threshold = BigInt(num(r.threshold).split(".")[0]);
  const real = BigInt(num(r.real_quote).split(".")[0]);
  return {
    token: r.token,
    creator: r.creator,
    quote: r.quote,
    name: r.name,
    symbol: r.symbol,
    uri: r.uri,
    supply: num(r.supply),
    quoteReserve: num(r.quote_reserve),
    tokenReserve: num(r.token_reserve),
    realQuote: num(r.real_quote),
    threshold: num(r.threshold),
    progress: r.graduated ? 1 : threshold > 0n ? Number((real * 10_000n) / threshold) / 10_000 : 0,
    completed: r.completed,
    graduated: r.graduated,
    pair: r.pair,
    lastPrice: r.last_price === null ? null : num(r.last_price),
    volume: num(r.volume_quote),
    trades: r.trades,
    createdAt: r.created_at,
  };
}

export async function launchDetail(token: string, candleInterval?: string) {
  const rows = await sql()`select * from lite.launches where token = ${token}`;
  if (rows.length === 0) throw notFound("Launch");
  const live = await view(launchpadId(), "get_curve", [sv.addr(token)]).catch(() => null);
  const trades = await sql()`select trader, side, quote_amount, token_amount, price, tx_hash, ts from lite.launch_trades where token = ${token} order by ts desc limit 50`;
  const intervals: Record<string, string> = { "1m": "1 minute", "5m": "5 minutes", "1h": "1 hour", "1d": "1 day" };
  const candles = candleInterval && intervals[candleInterval] ? await sql()`select * from lite.candles(${token}, ${intervals[candleInterval]}, 300)` : [];
  return {
    launch: launchRow(rows[0]),
    curve: live
      ? {
        quoteReserve: String(live.quote_reserve),
        tokenReserve: String(live.token_reserve),
        realQuote: String(live.real_quote),
        threshold: String(live.threshold),
        creatorFees: String(live.creator_fees),
        completed: live.completed,
        graduated: live.graduated,
        pair: live.pair ?? null,
      }
      : null,
    trades: trades.map((t) => ({ trader: t.trader, side: t.side, quoteAmount: num(t.quote_amount), tokenAmount: num(t.token_amount), price: num(t.price), txHash: t.tx_hash, ts: t.ts })),
    candles: candles.map((c) => ({ t: c.bucket, o: num(c.open), h: num(c.high), l: num(c.low), c: num(c.close), v: num(c.volume) })),
  };
}

export async function quoteTrade(user: string, token: string, side: "buy" | "sell", amount: bigint) {
  const pad = launchpadId();
  if (side === "buy") {
    const q = await view(pad, "quote_buy", [sv.addr(token), sv.addr(user), sv.i128(amount)]);
    return { side, used: String(q.used), tokensOut: String(q.tokens_out), fees: String(BigInt(q.base_fee) + BigInt(q.creator_fee) + BigInt(q.snipe_fee)), snipeFee: String(q.snipe_fee) };
  }
  const q = await view(pad, "quote_sell", [sv.addr(token), sv.i128(amount)]);
  return { side, quoteOut: String(q.quote_out), fees: String(BigInt(q.base_fee) + BigInt(q.creator_fee)) };
}

export interface LaunchBuildInput {
  action: "create" | "buy" | "sell" | "graduate" | "claim";
  token?: string;
  quote?: string;
  name?: string;
  symbol?: string;
  uri?: string;
  creatorFeeBps?: number;
  amount?: string;
  minOut?: string;
}

export async function buildLaunch(user: string, input: LaunchBuildInput): Promise<PlanView> {
  launchpadId();
  switch (input.action) {
    case "create": {
      const quote = quoteAsset(String(input.quote ?? "XLM"));
      const name = String(input.name ?? "").trim();
      const symbol = String(input.symbol ?? "").trim().toUpperCase();
      if (!name || name.length > 32) throw bad("bad_name", "Name: 1–32 characters.");
      if (!/^[A-Z0-9]{1,12}$/.test(symbol)) throw bad("bad_symbol", "Ticker: 1–12 letters or digits.");
      const fee = Number(input.creatorFeeBps ?? 0);
      if (!Number.isInteger(fee) || fee < 0 || fee > 1_000) throw bad("bad_fee", "Creator fee: 0–10%.");
      const uri = String(input.uri ?? "");
      if (uri.length > 256) throw bad("bad_uri", "Metadata link is too long.");
      return await createPlan(user, "launch_create", [{
        label: `Launch ${symbol}`,
        spec: { kind: "launch_create", quote: quote.contract, name, symbol, uri, creatorFeeBps: fee, initialBuy: input.amount ?? "0", minOut: input.minOut ?? "0" },
      }]);
    }
    case "buy":
    case "sell": {
      if (!input.token || !input.amount) throw bad("bad_arg", "token and amount are required.");
      return await createPlan(user, `launch_${input.action}`, [{
        label: input.action === "buy" ? "Buy" : "Sell",
        spec: { kind: `launch_${input.action}`, token: input.token, amount: input.amount, minOut: input.minOut ?? "0" },
      }]);
    }
    case "graduate":
      if (!input.token) throw bad("bad_arg", "token is required.");
      return await createPlan(user, "launch_graduate", [{ label: "Graduate to Soroswap", spec: { kind: "launch_graduate", token: input.token } }]);
    case "claim":
      if (!input.token) throw bad("bad_arg", "token is required.");
      return await createPlan(user, "launch_claim", [{ label: "Claim creator fees", spec: { kind: "launch_claim", token: input.token } }]);
    default:
      throw bad("bad_action", "Unknown action.");
  }
}

async function launchQuote(token: string): Promise<{ quote: string; symbol: string }> {
  const rows = await sql()`select quote, symbol from lite.launches where token = ${token}`;
  if (rows.length) return { quote: rows[0].quote as string, symbol: rows[0].symbol as string };
  const l = await view(launchpadId(), "get_launch", [sv.addr(token)]);
  return { quote: String(l.quote), symbol: String(l.symbol) };
}

registerBuilder("launch_create", async (user, spec) => {
  const pad = launchpadId();
  const acct = await requireAccount(user);
  const initialBuy = String(spec.initialBuy ?? "0");
  const tx = await invoke(acct, pad, "launch", [
    sv.addr(user),
    sv.addr(String(spec.quote)),
    sv.str(String(spec.name)),
    sv.str(String(spec.symbol)),
    sv.str(String(spec.uri ?? "")),
    sv.u32(Number(spec.creatorFeeBps ?? 0)),
    sv.i128(initialBuy),
    sv.i128(String(spec.minOut ?? "0")),
  ]);
  const q = assetById(env.network, String(spec.quote));
  const intent: Intent = {
    kind: "launch_create",
    summary: `Launch ${spec.symbol}${initialBuy !== "0" ? ` and buy with ${fromStroops(initialBuy)} ${q?.code}` : ""}`,
    spend: initialBuy !== "0" ? { [String(spec.quote)]: initialBuy } : {},
    calls: [{ contract: pad, fn: "launch" }],
    display: { symbol: String(spec.symbol), name: String(spec.name), quote: q?.code ?? "", initialBuy },
  };
  return { tx, intent };
});

registerBuilder("launch_buy", async (user, spec) => {
  const pad = launchpadId();
  const token = String(spec.token);
  const { quote, symbol } = await launchQuote(token);
  const acct = await requireAccount(user);
  const tx = await invoke(acct, pad, "buy", [sv.addr(user), sv.addr(token), sv.i128(String(spec.amount)), sv.i128(String(spec.minOut ?? "0"))]);
  const q = assetById(env.network, quote);
  return {
    tx,
    intent: {
      kind: "launch_buy",
      summary: `Buy ${symbol} with ${fromStroops(String(spec.amount))} ${q?.code ?? ""}`,
      spend: { [quote]: String(spec.amount) },
      receive: { [token]: String(spec.minOut ?? "0") },
      calls: [{ contract: pad, fn: "buy" }],
      display: { symbol, quote: q?.code ?? "", amount: String(spec.amount), minOut: String(spec.minOut ?? "0") },
    },
  };
});

registerBuilder("launch_sell", async (user, spec) => {
  const pad = launchpadId();
  const token = String(spec.token);
  const { quote, symbol } = await launchQuote(token);
  const acct = await requireAccount(user);
  const tx = await invoke(acct, pad, "sell", [sv.addr(user), sv.addr(token), sv.i128(String(spec.amount)), sv.i128(String(spec.minOut ?? "0"))]);
  const q = assetById(env.network, quote);
  return {
    tx,
    intent: {
      kind: "launch_sell",
      summary: `Sell ${fromStroops(String(spec.amount))} ${symbol}`,
      spend: { [token]: String(spec.amount) },
      receive: { [quote]: String(spec.minOut ?? "0") },
      calls: [{ contract: pad, fn: "sell" }],
      display: { symbol, quote: q?.code ?? "", amount: String(spec.amount), minOut: String(spec.minOut ?? "0") },
    },
  };
});

registerBuilder("launch_graduate", async (user, spec) => {
  const pad = launchpadId();
  const acct = await requireAccount(user);
  const tx = await invoke(acct, pad, "graduate", [sv.addr(String(spec.token))]);
  return { tx, intent: { kind: "launch_graduate", summary: "Move this launch to Soroswap", spend: {}, calls: [{ contract: pad, fn: "graduate" }] } };
});

registerBuilder("launch_claim", async (user, spec) => {
  const pad = launchpadId();
  const acct = await requireAccount(user);
  const tx = await invoke(acct, pad, "claim_creator_fees", [sv.addr(String(spec.token))]);
  return { tx, intent: { kind: "launch_claim", summary: "Claim your creator fees", spend: {}, calls: [{ contract: pad, fn: "claim_creator_fees" }] } };
});
