// Contract ids of the v2 singletons (CT-11a lead decision L-c): the derivation, the salts per generation, and the
// re-run plan against a mocked RPC.
import { assert, assertEquals, assertNotEquals, assertThrows } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Address, Asset, nativeToScVal, xdr } from "@stellar/stellar-sdk";
import { TESTNET } from "../../supabase/functions/_shared/networks.ts";
import {
  contractIdFor,
  type ContractReader,
  planIds,
  type PlannedContract,
  reconcile,
  sacIdFor,
  saltFor,
  saltLabel,
  sameValue,
} from "./contract-ids.ts";

const TESTNET_PASSPHRASE = "Test SDF Network ; September 2015";
const MAINNET_PASSPHRASE = "Public Global Stellar Network ; September 2015";

// Printed by soroban-sdk 26.1.1 itself: `e.deployer().with_address(deployer, salt).deployed_address()`, with the
// ledger's network id set to sha256(passphrase) and salt = sha256(label) (a scratch host program, run once).
const SDK_VECTORS = [
  { passphrase: "Test SDF Network ; September 2015", deployer: "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ", label: "dyorhq/v2/testnet/g1/launchpad-v2", salt: "671c9bf9032eafe0add407a508adf96aa110308c2372c58ad529a99f9954b695", id: "CBF54QE7SALTKRNOTYE6TALYJ6LFGY7575LIAZ3EN4UH2F4MQIJ3TFQD" },
  { passphrase: "Test SDF Network ; September 2015", deployer: "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ", label: "dyorhq/v2/testnet/g2/launchpad-v2", salt: "6e964aef393c4b043bda75934e2770eb69d884136a4a2918355facb29ab450cc", id: "CD7G2R4RQICMT3YH4T6BGPBKTZPNDSR66ZPOLI33KGSP7SZU5U4IMDL2" },
  { passphrase: "Test SDF Network ; September 2015", deployer: "GAYMY43ASKVRTMJGS55BD3B3HKMHY4FETF4HUDVXRGZHMUUWFCFEINBT", label: "dyorhq/v2/testnet-qa/g1/exec-soroswap", salt: "e86c825497ae3e7a92ba2b56a0182514f25e034db8d013e9e758d3cf0d6ff7ce", id: "CCPGZJKJQAAELGATINLGWMFYVFIY34K7GG6FNJPJRSLZDTX56IVFQULH" },
  { passphrase: "Public Global Stellar Network ; September 2015", deployer: "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ", label: "dyorhq/v2/testnet/g1/launchpad-v2", salt: "671c9bf9032eafe0add407a508adf96aa110308c2372c58ad529a99f9954b695", id: "CC3TCX3YKXWH4HJSCC4RX4XHFCJJF6BDJ56L5M3AEVR4T6RXZBWYJ7N2" },
];

Deno.test("contract ids match soroban-sdk's own derivation", () => {
  for (const v of SDK_VECTORS) {
    const salt = Buffer.from(v.salt, "hex");
    assertEquals(Buffer.from(saltFor(...parseLabel(v.label))).toString("hex"), v.salt, v.label);
    assertEquals(contractIdFor(v.deployer, Uint8Array.from(salt), v.passphrase), v.id, `${v.label} on ${v.passphrase}`);
  }
});

function parseLabel(label: string): [string, number, string] {
  const m = label.match(/^dyorhq\/v2\/([a-z-]+)\/g(\d+)\/([a-z0-9-]+)$/)!;
  return [m[1], Number(m[2]), m[3]];
}

Deno.test("the same id hashing gives the SDK's Stellar Asset Contract ids (and networks.ts's XLM and USDC)", () => {
  assertEquals(sacIdFor("native", TESTNET_PASSPHRASE), Asset.native().contractId(TESTNET_PASSPHRASE));
  const xlm = TESTNET.assets.find((a) => a.id === "XLM")!;
  const usdc = TESTNET.assets.find((a) => a.id === "USDC")!;
  assertEquals(sacIdFor(xlm.classic!, TESTNET_PASSPHRASE), xlm.contract);
  assertEquals(sacIdFor(usdc.classic!, TESTNET_PASSPHRASE), usdc.contract);
});

Deno.test("salts differ per generation, contract and deployment, and are stable", () => {
  const hex = (u: Uint8Array) => Buffer.from(u).toString("hex");
  assertEquals(saltLabel("testnet", 1, "launchpad-v2"), "dyorhq/v2/testnet/g1/launchpad-v2");
  assertEquals(hex(saltFor("testnet", 1, "launchpad-v2")), hex(saltFor("testnet", 1, "launchpad-v2")));
  assertNotEquals(hex(saltFor("testnet", 1, "launchpad-v2")), hex(saltFor("testnet", 2, "launchpad-v2")));
  assertNotEquals(hex(saltFor("testnet", 1, "launchpad-v2")), hex(saltFor("testnet", 1, "moments-v2")));
  assertNotEquals(hex(saltFor("testnet", 1, "launchpad-v2")), hex(saltFor("testnet-qa", 1, "launchpad-v2")));
  assertThrows(() => saltLabel("testnet", 0, "launchpad-v2"), Error, "from 1");
  assertThrows(() => saltLabel("testnet", 1.5, "launchpad-v2"), Error, "from 1");
  assertThrows(() => saltLabel("testnet", 1, "../x"), Error, "bad contract name");

  const deployer = "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ";
  const g1 = planIds("testnet", 1, deployer, TESTNET_PASSPHRASE, ["launchpad-v2", "moments-v2", "lp-locker"]);
  const g2 = planIds("testnet", 2, deployer, TESTNET_PASSPHRASE, ["launchpad-v2", "moments-v2", "lp-locker"]);
  const ids1 = [...g1.values()].map((p) => p.id);
  const ids2 = [...g2.values()].map((p) => p.id);
  assertEquals(new Set([...ids1, ...ids2]).size, 6, "a new generation is a fresh set of ids");
  assertEquals(g1.get("launchpad-v2")!.salt, "dyorhq/v2/testnet/g1/launchpad-v2");
  assertEquals(planIds("testnet", 1, deployer, TESTNET_PASSPHRASE, ["launchpad-v2"]).get("launchpad-v2")!.id, g1.get("launchpad-v2")!.id);
  assertNotEquals(contractIdFor(deployer, saltFor("testnet", 1, "x"), MAINNET_PASSPHRASE), contractIdFor(deployer, saltFor("testnet", 1, "x"), TESTNET_PASSPHRASE));
});

// ------------------------------------------------------------------------------------------------ re-runs (L-c)

const A = "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ";
const B = "GAYMY43ASKVRTMJGS55BD3B3HKMHY4FETF4HUDVXRGZHMUUWFCFEINBT";
const FACTORY = TESTNET.contracts.soroswapFactory;
const HASH = "11".repeat(32);

/** A mocked RPC: contracts by id, each with its WASM hash and its views' answers. */
function mockChain(contracts: Record<string, { wasm: string; views: Record<string, xdr.ScVal | Error> }>): ContractReader & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    contractWasmHash: (id) => Promise.resolve(contracts[id]?.wasm ?? null),
    view(id, fn) {
      calls.push(`${id}.${fn}`);
      const v = contracts[id]?.views[fn];
      if (v === undefined) return Promise.reject(new Error(`no ${fn}`));
      return v instanceof Error ? Promise.reject(v) : Promise.resolve(v);
    },
  };
}

const ids = planIds("testnet", 1, A, TESTNET_PASSPHRASE, ["exec-soroswap", "lp-locker", "moments-graduator"]);
const execId = ids.get("exec-soroswap")!.id;
const lockerId = ids.get("lp-locker")!.id;
const gradId = ids.get("moments-graduator")!.id;
const addrs = (...as: string[]) => xdr.ScVal.scvVec(as.map((a) => new Address(a).toScVal()));

const planned: PlannedContract[] = [
  {
    name: "exec-soroswap",
    id: execId,
    wasmHash: HASH,
    views: [
      { label: "exec-soroswap factory()", fn: "factory", args: [], expected: FACTORY },
      { label: "exec-soroswap callers()", fn: "callers", args: [], expected: [lockerId, gradId] },
    ],
  },
  {
    name: "lp-locker",
    id: lockerId,
    wasmHash: HASH,
    views: [
      { label: "lp-locker harvest_interval()", fn: "harvest_interval", args: [], expected: 3_600 },
      { label: "lp-locker aquarius_router()", fn: "aquarius_router", args: [], expected: null },
    ],
  },
  { name: "moments-graduator", id: gradId, wasmHash: HASH, views: [] },
];

Deno.test("a re-run skips a deployed contract whose views match the plan and deploys what is missing", async () => {
  const chain = mockChain({
    [execId]: { wasm: HASH, views: { factory: new Address(FACTORY).toScVal(), callers: addrs(lockerId, gradId) } },
    [lockerId]: { wasm: HASH, views: { harvest_interval: nativeToScVal(3_600n, { type: "u64" }), aquarius_router: xdr.ScVal.scvVoid() } },
  });
  const r = await reconcile(planned, chain);
  assertEquals(r.map((x) => [x.name, x.state]), [["exec-soroswap", "deployed"], ["lp-locker", "deployed"], ["moments-graduator", "absent"]]);
  assertEquals(chain.calls, [`${execId}.factory`, `${execId}.callers`, `${lockerId}.harvest_interval`, `${lockerId}.aquarius_router`]);
});

Deno.test("a re-run refuses a contract at its planned id whose views or WASM differ from the plan", async () => {
  const chain = mockChain({
    // callers in another order, and a harvest interval of 60 s: both differ from the plan.
    [execId]: { wasm: HASH, views: { factory: new Address(FACTORY).toScVal(), callers: addrs(gradId, lockerId) } },
    [lockerId]: { wasm: HASH, views: { harvest_interval: nativeToScVal(60n, { type: "u64" }), aquarius_router: new Address(B).toScVal() } },
    [gradId]: { wasm: "22".repeat(32), views: {} },
  });
  const r = await reconcile(planned, chain);
  assertEquals(r.map((x) => x.state), ["conflict", "conflict", "conflict"]);
  const why = r.flatMap((x) => (x.state === "conflict" ? x.differences : []));
  assert(why.some((d) => d.startsWith("exec-soroswap callers() is [")), why.join("\n"));
  assert(why.some((d) => d === `lp-locker harvest_interval() is "60" on chain, the plan has "3600"`), why.join("\n"));
  assert(why.some((d) => d.startsWith("lp-locker aquarius_router() is")), why.join("\n"));
  assert(why.some((d) => d.startsWith(`moments-graduator runs WASM ${"22".repeat(32)}`)), why.join("\n"));
});

Deno.test("a view that can't be read is a conflict, never a skip", async () => {
  const chain = mockChain({
    [execId]: { wasm: HASH, views: { factory: new Error("simulation failed"), callers: addrs(lockerId, gradId) } },
  });
  const [r] = await reconcile([planned[0]], chain);
  assertEquals(r.state, "conflict");
});

Deno.test("values compare across their native forms", () => {
  assert(sameValue(3_600n, 3_600));
  assert(sameValue(Buffer.from("ab", "hex"), "ab"));
  assert(sameValue({ b: 1n, a: [2] }, { a: [2n], b: 1 }));
  assert(sameValue(undefined, null));
  assert(!sameValue([1, 2], [2, 1]));
  assert(!sameValue(A, B));
});
