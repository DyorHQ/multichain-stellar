// The watched contracts (docs/DESIGN-stellar-parity.md §6.11, §12.5), from events recorded on testnet on 2026-10-13
// (ECAT's token and its Soroswap pair):
// - token events: transfer with an i128 and with {amount, to_muxed_id}, mint and burn, and the balances each moves;
// - pair events: sync, deposit and swap, decoded the same whichever side of the pair the launch token is; a swap is a
//   buy when the launch token leaves the pool, and is priced by its transaction's sync whether that is read before or
//   after it; the recorded swap is Soroswap's 0.3% fee at work (SOROSWAP_POOL_FEE_BPS);
// - groups: positions compare as RPC's cursors do, and merging caught-up groups keeps the smaller cursor, 25 contracts
//   to a group at most.
import { Address, nativeToScVal, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { native } = await import("../../supabase/functions/_shared/stellar.ts");
const { ratio, SOROSWAP_POOL_FEE_BPS } = await import("../../supabase/functions/_shared/launchpad.ts");
const w = await import("../../supabase/functions/lite-indexer/jobs/watch.ts");

const PAD = "CDZD53SNMXM4H7GUHHCCMCCS3W3VRNSG63NXB4OPVK7OELYYIGKC5I6I";
const ECAT = "CBL376OVOTNZA25S3ZFHIQKPLQ3XFV5SLQTHUWZPF25W2354QY4B4ZZD";
const PAIR = "CDHZ5QEC3KLKU5BF65YXQ664UXND3Z66GW3WT7Y4JPXZOIOB3MGLLFIN";
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
};

const topicsOf = (r: { topic: string[] }) => r.topic.map((t) => native(xdr.ScVal.fromXDR(t, "base64")));
const dataOf = (r: { value: string }) => native(xdr.ScVal.fromXDR(r.value, "base64"));

const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
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

// ------------------------------------------------------------------------------------------------ pair events

Deno.test("pair events: sync, deposit and swap, the same whichever side of the pair the launch token is", () => {
  // ECAT is this pair's token_0.
  const sync = w.decodePairEvent(topicsOf(RECORDED.graduationSync), dataOf(RECORDED.graduationSync), true);
  assertEquals(sync, { kind: "reserves", reserveToken: 2_162_277_660_257_505n, reserveQuote: 43_245_553_201n, price: ratio(43_245_553_201n, 2_162_277_660_257_505n), depositTo: null });
  const deposit = w.decodePairEvent(topicsOf(RECORDED.deposit), dataOf(RECORDED.deposit), true);
  assertEquals(deposit, { ...sync!, depositTo: PAD } as any);
  const swap = w.decodePairEvent(topicsOf(RECORDED.swap), dataOf(RECORDED.swap), true);
  assertEquals(swap, { kind: "swap", trader: TRADER, side: "buy", tokenAmount: 2_489_630_154_578n, quoteAmount: 50_000_000n });
  // Had ECAT been token_1: the same answers.
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.graduationSync), mirrored(RECORDED.graduationSync), false), sync);
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.deposit), mirrored(RECORDED.deposit), false), deposit);
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.swap), mirrored(RECORDED.swap), false), swap);
  // A sell: tokens into the pool, quote out.
  const sell = native(struct({ amount_0_in: i128(1_000n), amount_0_out: i128(0n), amount_1_in: i128(0n), amount_1_out: i128(20n), to: new Address(TRADER).toScVal() }));
  assertEquals(w.decodePairEvent(topicsOf(RECORDED.swap), sell, true), { kind: "swap", trader: TRADER, side: "sell", tokenAmount: 1_000n, quoteAmount: 20n });
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
    if (q.startsWith("insert into lite.pool_swaps")) {
      // [id, token, pair, trader, side, quote, tokens, (token, tx), tx, ledger, ts]
      if (state.swaps.has(String(p[0]))) return [];
      const price = state.launch.pool_tx !== null && state.launch.pool_tx === p[8] ? state.launch.last_price : null;
      state.swaps.set(String(p[0]), { pair: p[2], tx_hash: p[9], price });
      return [{ event_id: p[0] }];
    }
    if (q.startsWith("update lite.launches set last_trade_at")) return [];
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
