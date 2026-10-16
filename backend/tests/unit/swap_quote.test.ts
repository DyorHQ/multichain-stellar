// A swap quote offers only routes both verifiers sign (docs/DESIGN-stellar-parity.md §5.2, §6.8): a Soroswap path or an
// Aquarius chain runs the code of every token it goes through, so verify.ts (routeListed) and the phone's TxVerifier
// refuse a route through a token off the allowlist, apart from the one sold and the one bought. quote() drops such a
// route, so the best it offers is one /swap/build can build, and a route that stays on listed tokens stays offered.
import { Address, Asset, Keypair, nativeToScVal, SorobanDataBuilder, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv, USER, XLM_SAC } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { quote } = await import("../../supabase/functions/_shared/swap.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");

const PASS = TESTNET.passphrase;
const ONE = 10_000_000n;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
/** Tokens off the allowlist that testnet's Aquarius routes XLM → USDC through (AQUA, and its issuer's own USDC and USDT). */
const AQUA_ISSUER = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(21) as any).publicKey();
const AQUA = new Asset("AQUA", AQUA_ISSUER).contractId(PASS);
const OTHER_USDC = new Asset("USDC", AQUA_ISSUER).contractId(PASS);
const USDT = new Asset("USDT", AQUA_ISSUER).contractId(PASS);
const POOL_HASH = Buffer.alloc(32, 5);

/** What each venue brings for 1 XLM, in USDC base units. */
const rates = { sdex: 1_700_000n, soroswap: 1_800_000n, aquarius: 3_000_000n };
/** Set to a depth in XLM base units to give a venue a pool's curve: `amount × rate × depth / (depth + amount)`, so a
 *  bigger trade gets a worse rate. Null: the same rate at any size. */
const depths: { sdex: bigint | null; soroswap: bigint | null } = { sdex: null, soroswap: null };
/** A second Stellar DEX path, through EURC, that Horizon finds besides the direct one: its rate and depth. */
let sdexViaEurc: { rate: bigint; depth: bigint } | null = null;
const EURC_ISSUER = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(22) as any).publicKey();

function along(amount: bigint, rate: bigint, depth: bigint | null): bigint {
  return depth === null ? (amount * rate) / ONE : (amount * rate * depth) / (ONE * (depth + amount));
}

const asUnits = (out: bigint) => `${out / ONE}.${(out % ONE).toString().padStart(7, "0")}`;
/** The chain Aquarius's find-path answers with, hop by hop: the pool's tokens and the token out. */
let aquariusChain: { tokens: string[]; out: string }[] = [];
/** Set to answer find-path with this chain instead (one the router couldn't read). */
let aquariusChainXdr: string | null = null;

const addr = (c: string) => Address.fromString(c).toScVal();

function chainXdr(): string {
  const hops = aquariusChain.map((h) => xdr.ScVal.scvVec([xdr.ScVal.scvVec(h.tokens.map(addr)), xdr.ScVal.scvBytes(POOL_HASH), addr(h.out)]));
  return xdr.ScVal.scvVec(hops).toXDR("base64");
}

/** Soroswap's router_get_amounts_out: the direct XLM–USDC pair only. */
function simulate(params: { transaction: string }) {
  const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract() as xdr.InvokeContractArgs;
  const [amount, path] = call.args();
  const hops = (path.vec() ?? []).map((v) => Address.fromScAddress(v.address()).toString());
  const amountIn = BigInt(amount.i128().lo().toString());
  if (call.functionName().toString() !== "router_get_amounts_out" || hops.join() !== [XLM_SAC, USDC.contract].join()) {
    return { latestLedger: 1, error: "HostError: Error(Contract, #2)" };
  }
  const amounts = nativeToScVal([amountIn, along(amountIn, rates.soroswap, depths.soroswap)], { type: ["i128", "i128"] });
  const transactionData = new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64");
  return { latestLedger: 1, minResourceFee: "1000", transactionData, results: [{ auth: [], xdr: amounts.toXDR("base64") }], events: [] };
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === `/accounts/${USER.publicKey()}`) {
    return Response.json({
      id: USER.publicKey(),
      account_id: USER.publicKey(),
      sequence: "22096910953218048",
      subentry_count: 1,
      num_sponsoring: 0,
      num_sponsored: 0,
      signers: [],
      balances: [
        { balance: "0.0000000", limit: "922337203685.4775807", selling_liabilities: "0", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC.classic!.split(":")[1] },
        { balance: "10000.0000000", selling_liabilities: "0.0000000", asset_type: "native" },
      ],
    });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/ledgers") {
    return Response.json({ _embedded: { records: [{ base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/paths/strict-send") {
    const amount = BigInt(Math.round(Number(url.searchParams.get("source_amount")) * 1e7));
    const [code, issuer] = USDC.classic!.split(":");
    const record = (out: bigint, path: unknown[]) => ({
      source_asset_type: "native",
      source_amount: url.searchParams.get("source_amount"),
      destination_asset_type: "credit_alphanum4",
      destination_asset_code: code,
      destination_asset_issuer: issuer,
      destination_amount: asUnits(out),
      path,
    });
    const records = [record(along(amount, rates.sdex, depths.sdex), [])];
    if (sdexViaEurc) {
      const eurc = { asset_type: "credit_alphanum4", asset_code: "EURC", asset_issuer: EURC_ISSUER };
      records.push(record(along(amount, sdexViaEurc.rate, sdexViaEurc.depth), [eurc]));
    }
    return Response.json({ _links: {}, _embedded: { records } });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    const result = body.method === "simulateTransaction" ? simulate(body.params) : null;
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  if (url.host === "amm-api-testnet.aqua.network" && url.pathname.endsWith("/find-path/")) {
    const body = await req.json();
    const amount = (BigInt(body.amount) * rates.aquarius) / ONE;
    const tokens = [aquariusChain[0].tokens[0], ...aquariusChain.map((h) => h.out)];
    return Response.json({ success: true, swap_chain_xdr: aquariusChainXdr ?? chainXdr(), tokens_addresses: tokens, amount: Number(amount), amount_with_fee: Number(amount) });
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** What quote() stored, by the route it put first. */
const stored: { best: { venue: string }; alternatives: { venue: string }[] }[] = [];
replaceSql(fakeSql((q, ps) => {
  if (q.startsWith("insert into lite.swap_quotes")) {
    stored.push({ best: ps[2] as { venue: string }, alternatives: ps[3] as { venue: string }[] });
    return [{ id: "2a4e1f53-4f7a-4f0c-9d1e-6b0b7d9e7c11", expires_at: new Date(Date.now() + 60_000) }];
  }
  throw new Error(`unexpected query: ${q}`);
}));

Deno.test("a route through a token off the allowlist is never quoted, however much it brings", async () => {
  // As testnet's Aquarius answers XLM → USDC: XLM → AQUA → its issuer's USDC → USDT → Circle's USDC.
  aquariusChain = [
    { tokens: [XLM_SAC, AQUA], out: AQUA },
    { tokens: [AQUA, OTHER_USDC], out: OTHER_USDC },
    { tokens: [OTHER_USDC, USDT], out: USDT },
    { tokens: [USDT, USDC.contract], out: USDC.contract },
  ];
  const q = await quote(USER.publicKey(), "XLM", "USDC", 50n * ONE, 100);
  assertEquals(q.routes!.map((r) => r.venue), ["soroswap", "sdex"], "Aquarius's route goes through AQUA and USDT");
  assertEquals([q.best.venue, q.routes![0].best, q.best.amountOut], ["soroswap", true, (50n * rates.soroswap).toString()]);
  assertEquals(q.alternatives.map((r) => r.venue), ["sdex"]);
  assertEquals(stored.at(-1)!.best.venue, "soroswap", "the quote /swap/build redeems has no Aquarius route either");
  assertEquals(stored.at(-1)!.alternatives.map((r) => r.venue), ["sdex"]);
});

Deno.test("an Aquarius chain on listed tokens only stays quoted, and is the best when it brings the most", async () => {
  aquariusChain = [{ tokens: [XLM_SAC, USDC.contract], out: USDC.contract }];
  const q = await quote(USER.publicKey(), "XLM", "USDC", 50n * ONE, 100);
  assertEquals(q.routes!.map((r) => r.venue), ["aquarius", "soroswap", "sdex"]);
  assertEquals([q.best.venue, q.best.amountOut], ["aquarius", (50n * rates.aquarius).toString()]);
});

Deno.test("an Aquarius chain that can't be read is never quoted", async () => {
  aquariusChain = [{ tokens: [XLM_SAC, USDC.contract], out: USDC.contract }];
  // A hop that is not (tokens, pool, token out).
  aquariusChainXdr = xdr.ScVal.scvVec([xdr.ScVal.scvVec([addr(USDC.contract)])]).toXDR("base64");
  try {
    const q = await quote(USER.publicKey(), "XLM", "USDC", 50n * ONE, 100);
    assertEquals(q.routes!.map((r) => r.venue), ["soroswap", "sdex"]);
  } finally {
    aquariusChainXdr = null;
  }
});

Deno.test("with no route left to sign, the quote says there is none", async () => {
  aquariusChain = [{ tokens: [XLM_SAC, AQUA], out: AQUA }, { tokens: [AQUA, USDC.contract], out: USDC.contract }];
  const before = { ...rates };
  rates.sdex = 0n;
  rates.soroswap = 0n;
  try {
    const e = await assertRejects(() => quote(USER.publicKey(), "XLM", "USDC", 50n * ONE, 100), ApiError);
    assertEquals([e.status, e.code], [404, "no_route"]);
  } finally {
    Object.assign(rates, before);
  }
});

/** Monad's price impact (V3Router): 10,000 less the rate for `amountIn` against the rate for a thousandth of it, in
 *  basis points. */
function impactOf(out: bigint, smallOut: bigint, amountIn: bigint): number {
  const small = amountIn / 1_000n;
  return Math.max(0, 10_000 - Number((out * small * 10_000n) / (smallOut * amountIn)));
}

Deno.test("each venue's price impact is its rate for the amount against its own rate for a thousandth of it", async () => {
  aquariusChain = [{ tokens: [XLM_SAC, USDC.contract], out: USDC.contract }];
  const amountIn = 50n * ONE;
  // The Stellar DEX's book and Soroswap's pool as 1,000 and 500 XLM deep curves; Aquarius at one rate for any size.
  depths.sdex = 1_000n * ONE;
  depths.soroswap = 500n * ONE;
  try {
    const q = await quote(USER.publicKey(), "XLM", "USDC", amountIn, 100);
    const impact = Object.fromEntries(q.routes!.map((r) => [r.venue, r.priceImpactBps]));
    const expect = (rate: bigint, depth: bigint) => impactOf(along(amountIn, rate, depth), along(amountIn / 1_000n, rate, depth), amountIn);
    assertEquals(impact.sdex, expect(rates.sdex, depths.sdex));
    assertEquals(impact.soroswap, expect(rates.soroswap, depths.soroswap));
    assertEquals(impact.aquarius, 0, "the same rate at any size moves no price");
    // 50 XLM against 1,000 XLM of depth costs about 4.8%, against 500 XLM about 9.1%: what the rows show.
    assertEquals([impact.sdex! > 470 && impact.sdex! < 480, impact.soroswap! > 900 && impact.soroswap! < 915], [true, true]);
  } finally {
    depths.sdex = null;
    depths.soroswap = null;
  }
});

Deno.test("the Stellar DEX's impact is read along the path it quotes, not a better one for the small trade", async () => {
  aquariusChain = [{ tokens: [XLM_SAC, AQUA], out: AQUA }, { tokens: [AQUA, USDC.contract], out: USDC.contract }];
  const amountIn = 50n * ONE;
  // Direct: 1.7 at 1,000 XLM of depth. Through EURC: a better rate on a book so thin that 50 XLM gets less.
  depths.sdex = 1_000n * ONE;
  sdexViaEurc = { rate: 2_500_000n, depth: 20n * ONE };
  try {
    const q = await quote(USER.publicKey(), "XLM", "USDC", amountIn, 100);
    const sdex = q.routes!.find((r) => r.venue === "sdex")!;
    assertEquals(sdex.path, ["native", USDC.classic!], "50 XLM brings the most directly");
    const direct = impactOf(along(amountIn, rates.sdex, depths.sdex), along(amountIn / 1_000n, rates.sdex, depths.sdex), amountIn);
    assertEquals(sdex.priceImpactBps, direct);
  } finally {
    depths.sdex = null;
    sdexViaEurc = null;
  }
});

Deno.test("an amount whose thousandth rounds to nothing has no price impact", async () => {
  aquariusChain = [{ tokens: [XLM_SAC, USDC.contract], out: USDC.contract }];
  const q = await quote(USER.publicKey(), "XLM", "USDC", 999n, 100);
  assertEquals(q.routes!.map((r) => r.priceImpactBps), q.routes!.map(() => null));
});
