// The watched contracts (docs/DESIGN-stellar-parity.md §6.11, §12.5), from events recorded on testnet on 2026-10-13
// (ECAT's token and its Soroswap pair) and a sell of ECAT along [ECAT, XLM, USDC] simulated there on 2026-10-15:
// - token events: transfer with an i128 and with {amount, to_muxed_id}, mint and burn, and the balances each moves,
//   recorded once through lite.record_token_event;
// - pair events: sync, deposit and swap, decoded the same whichever side of the pair the launch token is; a swap is a
//   buy when the launch token leaves the pool, and is priced by its transaction's sync whether that is read before or
//   after it; the recorded swap is Soroswap's 0.3% fee at work (SOROSWAP_POOL_FEE_BPS); on a route through two pools a
//   sell's `to` is the next pool, so its seller comes from the transfer into the pair (lite.record_pool_swap; the SQL
//   test runs both functions on Postgres);
// - groups: positions compare as RPC's cursors do, and merging caught-up groups keeps the smaller cursor, 25 contracts
//   to a group at most;
// - gaps: a group behind RPC's retention starts again inside the window RPC keeps when it asks (the window moves on
//   while a run reads), marks the holders of the tokens made before that start incomplete, and two such groups are read
//   in one run; a refused request is retried once, a group still refused is left for the next run while the others
//   are read, and a run where every group fails fails;
// - the take-up of launches indexed before migration 07, and the smoke launches unlisted;
// - reconcile: each balance read live is handed to lite.reconcile_balance with the ledger it was read at, and counted
//   by what that answers.
import { Address, Keypair, nativeToScVal, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const STORAGE = "https://example.supabase.co";
Deno.env.set("SUPABASE_URL", STORAGE);
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { native } = await import("../../supabase/functions/_shared/stellar.ts");
const { ratio, SOROSWAP_POOL_FEE_BPS } = await import("../../supabase/functions/_shared/launchpad.ts");
const w = await import("../../supabase/functions/lite-indexer/jobs/watch.ts");
const { reconcileBalances } = await import("../../supabase/functions/lite-indexer/jobs/reconcile.ts");

const PAD = "CDZD53SNMXM4H7GUHHCCMCCS3W3VRNSG63NXB4OPVK7OELYYIGKC5I6I";
const ECAT = "CBL376OVOTNZA25S3ZFHIQKPLQ3XFV5SLQTHUWZPF25W2354QY4B4ZZD";
const PAIR = "CDHZ5QEC3KLKU5BF65YXQ664UXND3Z66GW3WT7Y4JPXZOIOB3MGLLFIN";
/** Soroswap's XLM/USDC pool on testnet: where a sell of ECAT into USDC goes after ECAT's pair. */
const XLM_USDC_POOL = "CCBX3NZTCQLQFSPG7HBOKL4P2RVPOPVFHDNRTOSCCJWBTPL2GHEH7RQS";
const TRADER = "GDABJYDYBMINC3AFSTMUB3LN2E3TCENU6UCCQ6IJLF55V76A7DZJOXHG";

/** ECAT's token and pair events on testnet: topics and value as RPC's getEvents gave them. */
const RECORDED = {
  mint: { topic: ["AAAADwAAAARtaW50", "AAAAEgAAAAHyPu5NZdnD/NQ5xCYIUt23WLZG9ttw8c+qvuIvGEGULg=="], value: "AAAAEQAAAAEAAAABAAAADwAAAAZhbW91bnQAAAAAAAoAAAAAAAAAAAAjhvJvwQAA" },
  buyTransfer: {
    topic: ["AAAADwAAAAh0cmFuc2Zlcg==", "AAAAEgAAAAHyPu5NZdnD/NQ5xCYIUt23WLZG9ttw8c+qvuIvGEGULg==", "AAAAEgAAAAAAAAAAwBTgeAsQ0WwFlNlA7W3RNzERtPUEKHkJWXva/8D48pc="],
    value: "AAAACgAAAAAAAAAAAAGo1eEaGSI=",
  },
  sellTransfer: {
    topic: ["AAAADwAAAAh0cmFuc2Zlcg==", "AAAAEgAAAAAAAAAAwBTgeAsQ0WwFlNlA7W3RNzERtPUEKHkJWXva/8D48pc=", "AAAAEgAAAAHyPu5NZdnD/NQ5xCYIUt23WLZG9ttw8c+qvuIvGEGULg=="],
    value: "AAAACgAAAAAAAAAAAAAqe8m1z1A=",
  },
  burn: { topic: ["AAAADwAAAARidXJu", "AAAAEgAAAAHyPu5NZdnD/NQ5xCYIUt23WLZG9ttw8c+qvuIvGEGULg=="], value: "AAAAEQAAAAEAAAABAAAADwAAAAZhbW91bnQAAAAAAAoAAAAAAAAAAAADjX6kx/bf" },
  unlocked: { topic: ["AAAADwAAAAh1bmxvY2tlZA=="], value: "AAAAEgAAAAHyPu5NZdnD/NQ5xCYIUt23WLZG9ttw8c+qvuIvGEGULg==" },
  // Graduation (tx 8b2217f7…): the pair's sync, then its deposit by the launchpad.
  graduationSync: {
    topic: ["AAAADgAAAAxTb3Jvc3dhcFBhaXI=", "AAAADwAAAARzeW5j"],
    value: "AAAAEQAAAAEAAAACAAAADwAAAA1uZXdfcmVzZXJ2ZV8wAAAAAAAACgAAAAAAAAAAAAeulH/YbOEAAAAPAAAADW5ld19yZXNlcnZlXzEAAAAAAAAKAAAAAAAAAAAAAAAKEaLGMQ==",
  },
  deposit: {
    topic: ["AAAADgAAAAxTb3Jvc3dhcFBhaXI=", "AAAADwAAAAdkZXBvc2l0AA=="],
    value:
      "AAAAEQAAAAEAAAAGAAAADwAAAAhhbW91bnRfMAAAAAoAAAAAAAAAAAAHrpR/2GzhAAAADwAAAAhhbW91bnRfMQAAAAoAAAAAAAAAAAAAAAoRosYxAAAADwAAAAlsaXF1aWRpdHkAAAAAAAAKAAAAAAAAAAAAAAjLeOUp0QAAAA8AAAANbmV3X3Jlc2VydmVfMAAAAAAAAAoAAAAAAAAAAAAHrpR/2GzhAAAADwAAAA1uZXdfcmVzZXJ2ZV8xAAAAAAAACgAAAAAAAAAAAAAAChGixjEAAAAPAAAAAnRvAAAAAAASAAAAAfI+7k1l2cP81DnEJghS3bdYtkb223Dxz6q+4i8YQZQu",
  },
  // A 5 XLM buy through Soroswap (tx a2ef7b8c…): the sync, then the swap.
  swapSync: {
    topic: ["AAAADgAAAAxTb3Jvc3dhcFBhaXI=", "AAAADwAAAARzeW5j"],
    value: "AAAAEQAAAAEAAAACAAAADwAAAA1uZXdfcmVzZXJ2ZV8wAAAAAAAACgAAAAAAAAAAAAesUNZTDY8AAAAPAAAADW5ld19yZXNlcnZlXzEAAAAAAAAKAAAAAAAAAAAAAAAKFJ22sQ==",
  },
  swap: {
    topic: ["AAAADgAAAAxTb3Jvc3dhcFBhaXI=", "AAAADwAAAARzd2Fw"],
    value:
      "AAAAEQAAAAEAAAAFAAAADwAAAAthbW91bnRfMF9pbgAAAAAKAAAAAAAAAAAAAAAAAAAAAAAAAA8AAAAMYW1vdW50XzBfb3V0AAAACgAAAAAAAAAAAAACQ6mFX1IAAAAPAAAAC2Ftb3VudF8xX2luAAAAAAoAAAAAAAAAAAAAAAAC+vCAAAAADwAAAAxhbW91bnRfMV9vdXQAAAAKAAAAAAAAAAAAAAAAAAAAAAAAAA8AAAACdG8AAAAAABIAAAAAAAAAAMAU4HgLENFsBZTZQO1t0TcxEbT1BCh5CVl72v/A+PKX",
  },
  // A sell of 1,000,000 ECAT along [ECAT, XLM, USDC] through Soroswap's router, simulated at ledger 5203637
  // (2026-10-15): ECAT's transfer from the seller into its pair, then the pair's swap, whose `to` is the XLM/USDC pool.
  hubSellTransfer: {
    topic: ["AAAADwAAAAh0cmFuc2Zlcg==", "AAAAEgAAAAAAAAAAwBTgeAsQ0WwFlNlA7W3RNzERtPUEKHkJWXva/8D48pc=", "AAAAEgAAAAHPnsCC2paqdCX3cXh73KXaPefeNbdp/xxL75chwdsMtQ=="],
    value: "AAAACgAAAAAAAAAAAAAJGE5yoAA=",
  },
  hubSellSwap: {
    topic: ["AAAADgAAAAxTb3Jvc3dhcFBhaXI=", "AAAADwAAAARzd2Fw"],
    value:
      "AAAAEQAAAAEAAAAFAAAADwAAAAthbW91bnRfMF9pbgAAAAAKAAAAAAAAAAAAAAkYTnKgAAAAAA8AAAAMYW1vdW50XzBfb3V0AAAACgAAAAAAAAAAAAAAAAAAAAAAAAAPAAAAC2Ftb3VudF8xX2luAAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAADwAAAAxhbW91bnRfMV9vdXQAAAAKAAAAAAAAAAAAAAAAC9ueYQAAAA8AAAACdG8AAAAAABIAAAABg323MxQXAsnm+cLlL4/Uavc+pTjbGbpCEmwZvXoxyH8=",
  },
};

const topicsOf = (r: { topic: string[] }) => r.topic.map((t) => native(xdr.ScVal.fromXDR(t, "base64")));
const dataOf = (r: { value: string }) => native(xdr.ScVal.fromXDR(r.value, "base64"));

const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const struct = (fields: Record<string, xdr.ScVal>) =>
  xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));

/** The same pair event had the launch token been the pair's token_1: every _0 and _1 swapped. */
function mirrored(r: { value: string }): unknown {
  const d = dataOf(r) as Record<string, unknown>;
  const out: Record<string, xdr.ScVal> = {};
  for (const [k, v] of Object.entries(d)) {
    const key = k.replace(/_0(?=_|$)/, "_#").replace(/_1(?=_|$)/, "_0").replace("_#", "_1");
    out[key] = typeof v === "bigint" ? i128(v) : new Address(String(v)).toScVal();
  }
  return native(struct(out));
}

// ------------------------------------------------------------------------------------------------ a fake RPC

/** How the fake RPC answers a JSON-RPC method (a thrown error is RPC's error answer); every call is kept in rpcCalls. */
let rpcAnswer: (method: string, params: any) => unknown = (method) => {
  throw new Error(`no ${method} in this test`);
};
const rpcCalls: { method: string; params: any }[] = [];
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  if (new URL(req.url).host !== "soroban-testnet.stellar.org") return new Response("offline", { status: 503 });
  const body = await req.json();
  rpcCalls.push({ method: body.method, params: body.params });
  try {
    return Response.json({ jsonrpc: "2.0", id: body.id, result: rpcAnswer(body.method, body.params) });
  } catch (err) {
    return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32600, message: (err as Error).message } });
  }
}) as typeof fetch;

/** simulateTransaction answering a contract call with `answer(contract, fn, args)`, or its error. */
function simulation(params: any, answer: (contract: string, fn: string, args: xdr.ScVal[]) => xdr.ScVal | { error: string }) {
  const tx = TransactionBuilder.fromXDR(params.transaction, TESTNET.passphrase) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const a = answer(Address.fromScAddress(call.contractAddress()).toString(), call.functionName().toString(), call.args());
  if (!(a instanceof xdr.ScVal)) return { latestLedger: 5_200_000, error: a.error };
  return {
    latestLedger: 5_200_000,
    minResourceFee: "1000",
    transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
    results: [{ auth: [], xdr: a.toXDR("base64") }],
    events: [],
  };
}

/** An event cursor at the start of a ledger's events (TOID: the ledger in the high 32 bits), and an event id in it. */
const cursorAt = (ledger: number) => `${(BigInt(ledger) << 32n).toString().padStart(19, "0")}-0000000000`;
const eventId = (ledger: number, index: number) => `${(BigInt(ledger) << 32n).toString().padStart(19, "0")}-${String(index).padStart(10, "0")}`;

// ------------------------------------------------------------------------------------------------ token events

Deno.test("token events: mint and burn {amount}, transfer as an i128, the launch token's other events ignored", () => {
  assertEquals(w.decodeTokenEvent(topicsOf(RECORDED.mint), dataOf(RECORDED.mint)), { kind: "mint", to: PAD, amount: 10_000_000_000_000_000n });
  assertEquals(w.decodeTokenEvent(topicsOf(RECORDED.buyTransfer), dataOf(RECORDED.buyTransfer)), {
    kind: "transfer",
    from: PAD,
    to: TRADER,
    amount: 467_111_534_795_042n,
    toMuxedId: null,
  });
  assertEquals(w.decodeTokenEvent(topicsOf(RECORDED.sellTransfer), dataOf(RECORDED.sellTransfer)), {
    kind: "transfer",
    from: TRADER,
    to: PAD,
    amount: 46_711_153_479_504n,
    toMuxedId: null,
  });
  assertEquals(w.decodeTokenEvent(topicsOf(RECORDED.burn), dataOf(RECORDED.burn)), { kind: "burn", from: PAD, amount: 1_000_000_000_095_967n });
  assertEquals(w.decodeTokenEvent(topicsOf(RECORDED.unlocked), dataOf(RECORDED.unlocked)), null);
});

Deno.test("token events: a transfer to a muxed address carries {amount, to_muxed_id} (OpenZeppelin stellar-tokens 0.7.2)", () => {
  const data = native(struct({ amount: i128(1_000n), to_muxed_id: nativeToScVal(42n, { type: "u64" }) }));
  assertEquals(w.decodeTokenEvent(topicsOf(RECORDED.buyTransfer), data), { kind: "transfer", from: PAD, to: TRADER, amount: 1_000n, toMuxedId: "42" });
  const none = native(struct({ amount: i128(7n), to_muxed_id: xdr.ScVal.scvVoid() }));
  assertEquals(w.decodeTokenEvent(topicsOf(RECORDED.buyTransfer), none), { kind: "transfer", from: PAD, to: TRADER, amount: 7n, toMuxedId: null });
});

Deno.test("balances: a transfer moves both sides, a mint adds, a burn takes away", () => {
  assertEquals(w.balanceChanges({ kind: "transfer", from: PAD, to: TRADER, amount: 5n, toMuxedId: null }), [[PAD, -5n], [TRADER, 5n]]);
  assertEquals(w.balanceChanges({ kind: "mint", to: PAD, amount: 5n }), [[PAD, 5n]]);
  assertEquals(w.balanceChanges({ kind: "burn", from: PAD, amount: 5n }), [[PAD, -5n]]);
});

Deno.test("recording a token event: one statement, lite.record_token_event, with the event's every field; it says whether the event was new", async () => {
  const calls: unknown[][] = [];
  let recorded = true;
  replaceSql(fakeSql((q, p) => {
    if (!q.startsWith("select lite.record_token_event(")) throw new Error(`unexpected query: ${q}`);
    calls.push(p);
    return [{ recorded }];
  }));
  const e = { id: "0022221709818023936-0000000003", ledger: 5173895, ledgerClosedAt: "2026-10-13T12:04:22Z", txHash: "38dbf5ea" } as any;
  const buy = w.decodeTokenEvent(topicsOf(RECORDED.buyTransfer), dataOf(RECORDED.buyTransfer))!;
  assertEquals(await w.recordTokenEvent(ECAT, buy, e), true);
  assertEquals(calls[0], [e.id, ECAT, "transfer", PAD, TRADER, null, "467111534795042", "38dbf5ea", 5173895, new Date("2026-10-13T12:04:22Z")]);
  // A mint has no sender, a burn no recipient; a muxed recipient keeps its id.
  await w.recordTokenEvent(ECAT, { kind: "mint", to: PAD, amount: 5n }, e);
  await w.recordTokenEvent(ECAT, { kind: "burn", from: PAD, amount: 5n }, e);
  await w.recordTokenEvent(ECAT, { kind: "transfer", from: PAD, to: TRADER, amount: 5n, toMuxedId: "42" }, e);
  assertEquals(calls.slice(1).map((p) => p.slice(2, 6)), [["mint", null, PAD, null], ["burn", PAD, null, null], ["transfer", PAD, TRADER, "42"]]);
  // Read again: already there.
  recorded = false;
  assertEquals(await w.recordTokenEvent(ECAT, buy, e), false);
});

// ------------------------------------------------------------------------------------------------ pair events

Deno.test("pair events: sync, deposit and swap, the same whichever side of the pair the launch token is", () => {
  // ECAT is this pair's token_0.
  const sync = w.decodePairEvent(topicsOf(RECORDED.graduationSync), dataOf(RECORDED.graduationSync), true);
  assertEquals(sync, { kind: "reserves", reserveToken: 2_162_277_660_257_505n, reserveQuote: 43_245_553_201n, price: ratio(43_245_553_201n, 2_162_277_660_257_505n), depositTo: null });
  const deposit = w.decodePairEvent(topicsOf(RECORDED.deposit), dataOf(RECORDED.deposit), true);
  assertEquals(deposit, { ...sync!, depositTo: PAD } as any);
  const swap = w.decodePairEvent(topicsOf(RECORDED.swap), dataOf(RECORDED.swap), true);
  assertEquals(swap, { kind: "swap", to: TRADER, side: "buy", tokenAmount: 2_489_630_154_578n, quoteAmount: 50_000_000n });
  // Had ECAT been token_1: the same answers.
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.graduationSync), mirrored(RECORDED.graduationSync), false), sync);
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.deposit), mirrored(RECORDED.deposit), false), deposit);
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.swap), mirrored(RECORDED.swap), false), swap);
  // A sell: tokens into the pool, quote out.
  const sell = native(struct({ amount_0_in: i128(1_000n), amount_0_out: i128(0n), amount_1_in: i128(0n), amount_1_out: i128(20n), to: new Address(TRADER).toScVal() }));
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.swap), sell, true), { kind: "swap", to: TRADER, side: "sell", tokenAmount: 1_000n, quoteAmount: 20n });
  // Not the pair's own events: its LP token's mint, a skim.
  assertEquals(w.decodePairEvent(["mint", PAIR, PAD], 1000n, true), null);
  assertEquals(w.decodePairEvent(["SoroswapPair", "skim"], {}, true), null);
});

Deno.test("the recorded swap pays out on 997/1000 of its input: Soroswap's 0.3% pool fee", () => {
  const [reserveIn, reserveOut, amountIn] = [43_245_553_201n, 2_162_277_660_257_505n, 50_000_000n];
  const out = (amountIn * 997n * reserveOut) / (reserveIn * 1000n + amountIn * 997n);
  assertEquals(out, 2_489_630_154_578n);
  assertEquals(SOROSWAP_POOL_FEE_BPS, 30);
  // The reserves after it are the swap's sync.
  const sync = w.decodePairEvent(topicsOf(RECORDED.swapSync), dataOf(RECORDED.swapSync), true);
  assertEquals([sync!.kind === "reserves" && sync!.reserveToken, sync!.kind === "reserves" && sync!.reserveQuote], [reserveOut - out, reserveIn + amountIn]);
});

/** A database that keeps the launch's pool and the pool swaps, as the watch job's statements change them. */
function poolDatabase() {
  const state = { launch: { pool_event: null as string | null, pool_tx: null as string | null, last_price: null as string | null }, swaps: new Map<string, Row>() };
  replaceSql(fakeSql((q, p) => {
    if (q.startsWith("update lite.launches set pool_token")) {
      // [token, quote, price, event id, tx, graduated ledger, graduated at, token, event id]
      if (state.launch.pool_event === null || state.launch.pool_event < String(p[8])) {
        state.launch = { pool_event: String(p[3]), pool_tx: p[4] as string | null, last_price: (p[2] as string | null) ?? state.launch.last_price };
      }
      return [];
    }
    if (q.startsWith("update lite.pool_swaps set price")) {
      for (const s of state.swaps.values()) if (s.pair === p[1] && s.tx_hash === p[2] && s.price === null) s.price = p[0];
      return [];
    }
    if (q.startsWith("select lite.record_pool_swap(")) {
      // [id, token, pair, to, side, quote, tokens, tx, ledger, ts]: priced by the launch's pool when its sync is this tx's.
      if (state.swaps.has(String(p[0]))) return [{ recorded: false }];
      const price = state.launch.pool_tx !== null && state.launch.pool_tx === p[7] ? state.launch.last_price : null;
      state.swaps.set(String(p[0]), { pair: p[2], to: p[3], side: p[4], tx_hash: p[7], price });
      return [{ recorded: true }];
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  return state;
}

const SWAP_TX = "a2ef7b8ca2990f1e11adfeeb8a3d25e84075f7b9a32fc1e0d0108581a508fbfd";
const at = (id: string) => ({ id, ledger: 5173902, ledgerClosedAt: "2026-10-13T12:04:57Z", txHash: SWAP_TX } as any);

Deno.test("a pool swap is priced by its transaction's sync, read before it or after it", async () => {
  const member = { contract: PAIR, role: "pair" as const, token: ECAT, token0IsLaunch: true, fromLedger: 5173899 };
  const sync = w.decodePairEvent(topicsOf(RECORDED.swapSync), dataOf(RECORDED.swapSync), true)!;
  const swap = w.decodePairEvent(topicsOf(RECORDED.swap), dataOf(RECORDED.swap), true)!;
  const price = (sync as { price: string }).price;
  // As the chain emits them: the sync, then the swap.
  let db = poolDatabase();
  await w.recordPoolEvent(member, sync, at("0022221739882749952-0000000002"));
  await w.recordPoolEvent(member, swap, at("0022221739882749952-0000000003"));
  assertEquals(db.swaps.get("0022221739882749952-0000000003")!.price, price);
  // The swap first (a page split between them, or the other order): the sync prices it when it comes.
  db = poolDatabase();
  await w.recordPoolEvent(member, swap, at("0022221739882749952-0000000003"));
  assertEquals(db.swaps.get("0022221739882749952-0000000003")!.price, null);
  await w.recordPoolEvent(member, sync, at("0022221739882749952-0000000002"));
  assertEquals(db.swaps.get("0022221739882749952-0000000003")!.price, price);
  // A sync read again never moves the pool back.
  db = poolDatabase();
  await w.recordPoolEvent(member, sync, at("0022221739882749952-0000000002"));
  const older = w.decodePairEvent(topicsOf(RECORDED.graduationSync), dataOf(RECORDED.graduationSync), true)!;
  await w.recordPoolEvent(member, older, { ...at("0022221726997884928-0000000005"), txHash: "8b2217f7" });
  assertEquals(db.launch.last_price, price);
});

Deno.test("a sell along [ECAT, XLM, USDC]: the pair's swap goes to the next pool, and the seller is the one whose ECAT went into the pair", async () => {
  // Simulated on testnet: the seller's transfer into ECAT's pair, then the pair's swap to the XLM/USDC pool.
  const transfer = w.decodeTokenEvent(topicsOf(RECORDED.hubSellTransfer), dataOf(RECORDED.hubSellTransfer))!;
  assertEquals(transfer, { kind: "transfer", from: TRADER, to: PAIR, amount: 10_000_000_000_000n, toMuxedId: null });
  const swap = w.decodePairEvent(topicsOf(RECORDED.hubSellSwap), dataOf(RECORDED.hubSellSwap), true)!;
  assertEquals(swap, { kind: "swap", to: XLM_USDC_POOL, side: "sell", tokenAmount: 10_000_000_000_000n, quoteAmount: 198_942_305n });
  // Both reach the database with what it needs to name the seller (launch_test.sql's section 8 runs both functions):
  // the transfer's sender and the pair it went into, and the swap's pair, side and `to`, in one transaction.
  const calls: [string, unknown[]][] = [];
  replaceSql(fakeSql((q, p) => {
    calls.push([q.slice(0, q.indexOf("(")), p]);
    return [{ recorded: true }];
  }));
  const tx = "c0ffee";
  const member = { contract: PAIR, role: "pair" as const, token: ECAT, token0IsLaunch: true, fromLedger: 5173899 };
  await w.recordPoolEvent(member, swap, { id: "0022348464046604288-0000000004", ledger: 5203637, ledgerClosedAt: "2026-10-15T09:00:00Z", txHash: tx } as any);
  await w.recordTokenEvent(ECAT, transfer, { id: "0022348464046604288-0000000001", ledger: 5203637, ledgerClosedAt: "2026-10-15T09:00:00Z", txHash: tx } as any);
  assertEquals(calls.map(([q, p]) => [q, ...p.slice(0, 8)]), [
    ["select lite.record_pool_swap", "0022348464046604288-0000000004", ECAT, PAIR, XLM_USDC_POOL, "sell", "198942305", "10000000000000", tx],
    ["select lite.record_token_event", "0022348464046604288-0000000001", ECAT, "transfer", TRADER, PAIR, null, "10000000000000", tx],
  ]);
});

// ------------------------------------------------------------------------------------------------ groups

Deno.test("positions: cursors compare as numbers; a ledger's start comes before its events", () => {
  assertEquals(w.compareCursors("0022221739882749952-0000000002", "0022221739882749952-0000000003"), -1);
  assertEquals(w.compareCursors("0022221739882749952-0000000003", "0022221726997884928-0000000009"), 1);
  assertEquals(w.compareCursors("0022221739882749952-0000000003", "0022221739882749952-0000000003"), 0);
  const cursor = { cursor: "0022221739882749952-0000000002", ledger: 0 };
  // The cursor's ledger is 5173902.
  assertEquals(w.ledgerOf(cursor), 5173902);
  assertEquals(w.earlier(cursor, { cursor: null, ledger: 5173902 }), { cursor: null, ledger: 5173902 });
  assertEquals(w.earlier(cursor, { cursor: null, ledger: 5173903 }), cursor);
  assertEquals(w.earlier({ cursor: null, ledger: 5173901 }, cursor), { cursor: null, ledger: 5173901 });
});

Deno.test("merging caught-up groups keeps the smaller cursor, 25 contracts to a group at most", () => {
  const contracts = (n: number, tag: string) => Array.from({ length: n }, (_, i) => `${tag}${i}`);
  const groups = [
    { id: 1, position: { cursor: "0022221739882749952-0000000003", ledger: 0 }, ledger: 5173902, members: contracts(3, "a") },
    { id: 2, position: { cursor: "0022221726997884928-0000000009", ledger: 0 }, ledger: 5173899, members: contracts(2, "b") },
    { id: 3, position: { cursor: null, ledger: 5173950 }, ledger: 5173949, members: contracts(24, "c") },
    { id: 4, position: { cursor: "0022221744177741824-0000000001", ledger: 0 }, ledger: 5173903, members: contracts(1, "d") },
  ];
  const merges = w.mergeGroups(groups);
  // The 24 take the single one; the 3 and the 2 go together, at the smaller (older) of their cursors.
  assertEquals(merges.map((m) => [m.keep, m.drop, m.members.length]), [[3, [4], 25], [1, [2], 5]]);
  assertEquals(merges[0].position, { cursor: "0022221744177741824-0000000001", ledger: 0 });
  assertEquals(merges[1].position, { cursor: "0022221726997884928-0000000009", ledger: 0 });
  assertEquals(merges[1].ledger, 5173899);
  // Nothing to fold: none answered; never more than 25 to a group.
  assertEquals(w.mergeGroups([groups[2]]), []);
  assertEquals(w.mergeGroups([{ ...groups[2], members: contracts(25, "e") }, groups[3]]), []);
  assert(w.mergeGroups(Array.from({ length: 30 }, (_, i) => ({ ...groups[3], id: 100 + i }))).every((m) => m.members.length <= w.GROUP_SIZE));
});

// ------------------------------------------------------------------------------------------------ gaps

const token = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const [OLD_A, NEW_B, OLD_C] = [token(11), token(12), token(13)];

/** groups()' rows: one per watched contract, with its group's position. */
function groupRows(groups: { id: number; start: number; cursor?: string; members: { contract: string; from: number }[] }[]): Row[] {
  return groups.flatMap((g) =>
    g.members.map((m) => ({
      id: g.id,
      start_ledger: g.start,
      cursor: g.cursor ?? null,
      ledger: g.start - 1,
      contract: m.contract,
      role: "token",
      token: m.contract,
      from_ledger: m.from,
      pair_token0_is_launch: null,
    }))
  );
}

/** The watch job's database with these groups and nothing to take up or group: answers its reads, keeps its writes. */
function watchDatabase(rows: Row[]) {
  const writes: [string, unknown[]][] = [];
  replaceSql(fakeSql((q, p) => {
    if (q.startsWith("select l.token, l.creator")) return [];
    if (q.startsWith("select contract, from_ledger from lite.watch_contracts")) return [];
    if (q.startsWith("select g.id, g.start_ledger")) return rows;
    if (q.startsWith("select lite.record_token_event(")) {
      writes.push([q, p]);
      return [{ recorded: true }];
    }
    if (/^(update|insert|delete)/.test(q)) {
      writes.push([q, p]);
      return [];
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  return writes;
}

/** A transfer of a watched token in `ledger`, as getEvents answers it. */
function transferAt(contract: string, ledger: number) {
  return {
    type: "contract",
    ledger,
    ledgerClosedAt: "2026-10-15T09:00:00Z",
    contractId: contract,
    id: eventId(ledger, 1),
    inSuccessfulContractCall: true,
    txHash: `tx${ledger}`,
    topic: RECORDED.buyTransfer.topic,
    value: RECORDED.buyTransfer.value,
  };
}

/** RPC with a window of ledgers that moves on 3 ledgers with every call, as testnet's does while a run reads other
 *  groups; getEvents refuses a start (or a cursor) outside the window, as RPC does, with RPC's own words. `refuse`
 *  refuses any request for those contracts. */
function slidingChain(oldest: number, events: ReturnType<typeof transferAt>[], refuse: string[] = []) {
  let tick = 0;
  return (method: string, params: any) => {
    tick++;
    const low = oldest + 3 * tick;
    const latest = low + 120_000;
    if (method === "getHealth") return { status: "healthy", oldestLedger: low, latestLedger: latest, ledgerRetentionWindow: 120_000 };
    if (method !== "getEvents") throw new Error(`no ${method} in this test`);
    const ids: string[] = params.filters.flatMap((f: any) => f.contractIds);
    if (ids.some((id) => refuse.includes(id))) throw new Error("internal error");
    const start = params.startLedger ?? Number(BigInt(params.pagination.cursor.split("-")[0]) >> 32n);
    if (start < low) throw new Error(`startLedger must be within the ledger range: ${low} - ${latest}`);
    return { latestLedger: latest, events: events.filter((e) => ids.includes(e.contractId) && e.ledger >= start), cursor: cursorAt(latest) };
  };
}

const getEventsStarts = () => rpcCalls.filter((c) => c.method === "getEvents").map((c) => c.params.startLedger ?? c.params.pagination.cursor);
const incomplete = (writes: [string, unknown[]][]) =>
  writes.filter(([q]) => q.startsWith("update lite.launches set holders_complete = false")).map(([, p]) => p[0]);

Deno.test("gaps: two groups behind RPC's retention are both read in one run, each from inside the window RPC keeps when it asks", async () => {
  // Group 1 (tokens made at ledgers 400 and 1,100) and group 2 (made at 600), both positioned before RPC's oldest.
  const writes = watchDatabase(groupRows([
    { id: 1, start: 400, members: [{ contract: OLD_A, from: 400 }, { contract: NEW_B, from: 1_100 }] },
    { id: 2, start: 600, members: [{ contract: OLD_C, from: 600 }] },
  ]));
  rpcAnswer = slidingChain(1_000, [transferAt(OLD_A, 900), transferAt(OLD_A, 1_100), transferAt(OLD_C, 1_200)]);
  rpcCalls.length = 0;
  const report = await w.watchContracts() as { gaps: number; failed: number; events: number; groups: number; merged: number };
  // The run read health at 1,003; each group asked again just before its first request (1,006 and 1,012), and starts
  // RETENTION_MARGIN ledgers inside that: a start taken from the run's first read would already be gone (1,003 < 1,009).
  assertEquals(rpcCalls.map((c) => c.method), ["getHealth", "getHealth", "getEvents", "getHealth", "getEvents"]);
  assertEquals(getEventsStarts(), [1_006 + w.RETENTION_MARGIN, 1_012 + w.RETENTION_MARGIN]);
  assertEquals([report.gaps, report.failed, report.events], [2, 0, 2]);
  // Holders incomplete for the tokens made before the start: not for the one made since.
  assertEquals(incomplete(writes), [[OLD_A], [OLD_C]]);
  // Only events inside the window were recorded: ledgers 1,100 and 1,200.
  assertEquals(writes.filter(([q]) => q.startsWith("select lite.record_token_event(")).map(([, p]) => p[8]), [1_100, 1_200]);
  // Both caught up, and fold into one group.
  assertEquals([report.groups, report.merged], [1, 1]);
});

Deno.test("gaps: a refused request is retried once from the window RPC keeps then; a group still refused waits for the next run, the others are read", async () => {
  // A cursor RPC refuses once (it slid out of the window between the run's health read and the request).
  let writes = watchDatabase(groupRows([{ id: 1, start: 400, cursor: cursorAt(1_004), members: [{ contract: OLD_A, from: 400 }] }]));
  rpcAnswer = slidingChain(1_000, [transferAt(OLD_A, 1_100)]);
  rpcCalls.length = 0;
  let report = await w.watchContracts() as { gaps: number; failed: number; events: number };
  assertEquals(getEventsStarts(), [cursorAt(1_004), 1_009 + w.RETENTION_MARGIN]);
  assertEquals([report.gaps, report.failed, report.events], [1, 0, 1]);
  assertEquals(incomplete(writes), [[OLD_A]]);

  // A group RPC won't read at all: left for the next run, and the next group is still read.
  writes = watchDatabase(groupRows([
    { id: 1, start: 2_000, members: [{ contract: OLD_A, from: 2_000 }] },
    { id: 2, start: 2_100, members: [{ contract: OLD_C, from: 2_100 }] },
  ]));
  rpcAnswer = slidingChain(1_000, [transferAt(OLD_C, 2_200)], [OLD_A]);
  rpcCalls.length = 0;
  report = await w.watchContracts() as { gaps: number; failed: number; events: number };
  assertEquals([report.failed, report.events, report.gaps], [1, 1, 0]);
  assertEquals(getEventsStarts().slice(-1), [2_100]);
  assert(!writes.some(([q, p]) => q.startsWith("update lite.watch_groups") && p.at(-1) === 1), "the refused group keeps its position");

  // Every group refused: the run fails, with RPC's error.
  watchDatabase(groupRows([{ id: 1, start: 2_000, members: [{ contract: OLD_A, from: 2_000 }] }]));
  rpcAnswer = slidingChain(1_000, [], [OLD_A]);
  await assertRejects(async () => await w.watchContracts());
});

// ------------------------------------------------------------------------------------------------ taking up older launches

Deno.test("take-up: launches indexed before migration 07 get their terms, facts and watches; one whose reads fail waits; smoke launches are unlisted", async () => {
  const [CURVE, GRADUATED, UNREADABLE, GRAD_PAIR] = [token(21), token(22), token(23), token(24)];
  const creator = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(5) as any).publicKey();
  const uri = `${STORAGE}/storage/v1/object/public/lite-media/launches/${creator}/aef9135a-6c53-435a-a2e4-5bb339faa0e1.json`;
  const image = `${STORAGE}/storage/v1/object/public/lite-media/uploads/${creator}/b4e32bb4-0296-4ba8-a4c8-9ebd74f07d5e.png`;
  const launch = (t: string, fields: Row = {}) => ({
    token: t,
    creator,
    name: "E2E Cat",
    symbol: "ECAT",
    uri: "",
    created_ledger: 100,
    graduated: false,
    pair: null,
    graduated_ledger: null,
    pair_token0_is_launch: null,
    watched: false,
    ...fields,
  });
  const writes: [string, unknown[]][] = [];
  replaceSql(fakeSql((q, p) => {
    if (q.startsWith("select l.token, l.creator")) {
      return [launch(CURVE, { uri }), launch(GRADUATED, { graduated: true, pair: GRAD_PAIR, graduated_ledger: 300 }), launch(UNREADABLE)];
    }
    if (q.startsWith("select address, name, symbol, image, description, links from lite.launch_metadata where uri = ?")) {
      return p[0] === uri ? [{ address: creator, name: "E2E Cat", symbol: "ECAT", image, description: "A cat.", links: {} }] : [];
    }
    if (/^(update|insert)/.test(q)) {
      writes.push([q, p]);
      return [];
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  rpcAnswer = (method, params) => {
    if (method !== "simulateTransaction") throw new Error(`no ${method} in this test`);
    return simulation(params, (contract, fn, args) => {
      if (contract === PAD && fn === "get_launch" && Address.fromScVal(args[0]).toString() !== UNREADABLE) {
        return struct({ fee_bps: u32(100), protocol_share_bps: u32(5000) });
      }
      if (contract === GRAD_PAIR && fn === "token_0") return new Address(GRADUATED).toScVal();
      return { error: "HostError: Error(Contract, #1)" };
    });
  };
  const smoke = { ...TESTNET, deployment: { ...TESTNET.deployment!, smoke: { launches: [UNREADABLE], moments: [] } } };
  assertEquals(await w.takeUp(smoke), 2);
  const kinds = writes.map(([q, p]) => [q.split(" set ")[0].split(" (")[0], q.includes("listed = false") ? "unlist" : q.includes("fee_bps") ? "terms" : q.includes("listed = ?") ? "facts" : "watch", p]);
  // The smoke launch is unlisted first, then each launch whose reads answered: terms, facts, then its watches.
  assertEquals(kinds[0], ["update lite.launches", "unlist", [[UNREADABLE]]]);
  const terms = writes.filter(([q]) => q.includes("set fee_bps")).map(([, p]) => p);
  assertEquals(terms, [[100, 5000, CURVE], [100, 5000, GRADUATED]]);
  const facts = writes.filter(([q]) => q.includes("set listed = ?")).map(([, p]) => p);
  // The curve's metadata is its creator's, for its name and ticker: image, description and links; the other has none.
  assertEquals(facts[0].slice(0, 5), [true, false, image, "A cat.", { website: null, x: null, telegram: null }]);
  assertEquals(facts[1].slice(0, 5), [true, false, null, null, null]);
  // The graduated launch's pair side was read (token_0 is the launch token) and its pair is watched from graduation.
  assertEquals(facts[1].slice(6, 7), [true]);
  const watches = writes.filter(([q]) => q.startsWith("insert into lite.watch_contracts")).map(([, p]) => p);
  assertEquals(watches, [[CURVE, "token", CURVE, 100], [GRADUATED, "token", GRADUATED, 100], [GRAD_PAIR, "pair", GRADUATED, 300]]);
  assert(!writes.some(([, p]) => p.includes(UNREADABLE) && !Array.isArray(p[0])), "the launch whose terms can't be read waits");
});

// ------------------------------------------------------------------------------------------------ reconcile

Deno.test("reconcile: each balance read live goes to lite.reconcile_balance with the ledger it was read at, counted by its answer", async () => {
  const [A, B, C, D] = [1, 2, 3, 4].map((n) => Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(40 + n) as any).publicKey());
  const outcome: Record<string, string> = { [A]: "same", [B]: "corrected", [C]: "newer" };
  const handed: unknown[][] = [];
  replaceSql(fakeSql((q, p) => {
    if (q.startsWith("select token, address from lite.token_balances order by checked_at nulls first, updated_at limit ?")) {
      return [A, B, C, D].map((address) => ({ token: ECAT, address }));
    }
    if (q.startsWith("select lite.reconcile_balance(")) {
      handed.push(p);
      return [{ outcome: outcome[String(p[1])] ?? null }];
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  rpcAnswer = (method, params) => {
    if (method !== "simulateTransaction") throw new Error(`no ${method} in this test`);
    return simulation(params, (contract, fn, args) => {
      const who = Address.fromScVal(args[0]).toString();
      return contract === ECAT && fn === "balance" && who !== D ? i128(BigInt(who === A ? 7 : 9) * 10_000_000n) : { error: "HostError: Error(Storage, MissingValue)" };
    });
  };
  assertEquals(await reconcileBalances(), { checked: 2, mismatched: 1, newer: 1, failed: 1 });
  assertEquals(handed.sort((x, y) => String(x[1]).localeCompare(String(y[1]))), [
    [ECAT, A, "70000000", 5_200_000],
    [ECAT, B, "90000000", 5_200_000],
    [ECAT, C, "90000000", 5_200_000],
  ].sort((x, y) => String(x[1]).localeCompare(String(y[1]))));
});
