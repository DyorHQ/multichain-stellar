// The smoke's calls against the real contract specs: every function lib/smoke-v2.ts calls, with the parameter names
// and types it passes, must be what the WASM declares. Soroswap's router is checked against its testnet fixture
// (always present). The v2 contracts are checked against contracts/dist, which build.sh writes and CT-10 commits:
// those tests say they are ignored when dist isn't there, and fail on a dist that no longer matches. The smoke itself
// runs end to end against the in-memory ledger in owner-v2.test.ts.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { SMOKE_CALLS, snipeWindowOver } from "./smoke-v2.ts";
import { RUNTIME_CONSTRUCTORS, WASMS, type WasmKey } from "./v2-constructors.ts";
import { compareParams, constructorGuard, functionParams, readSpec } from "./wasm-spec.ts";
import { constructors, parseEconomics } from "./v2-constructors.ts";
import { profileFor } from "./v2-profile.ts";

const root = new URL("../../../", import.meta.url).pathname;
const dist = (k: WasmKey) => `${root}contracts/dist/${WASMS[k].file}`;
const distPresent = (Object.keys(WASMS) as WasmKey[]).every((k) => {
  try {
    return Deno.statSync(dist(k)).isFile;
  } catch {
    return false;
  }
});

/** The smoke's parameters against a spec; the terms structs are passed through as the views returned them, so only
 *  their names are compared. */
function differences(wasm: Uint8Array, calls: typeof SMOKE_CALLS): string[] {
  const entries = readSpec(wasm);
  const out: string[] = [];
  for (const c of calls) {
    const actual = functionParams(entries, c.fn);
    if (!actual) {
      out.push(`${c.wasm}.${c.fn} is not in the WASM`);
      continue;
    }
    const opaque = c.params.map((p, i) => (p.type.kind === "udt" && p.type.def === null ? i : -1)).filter((i) => i >= 0);
    for (const i of opaque) {
      const t = actual[i]?.type;
      if (actual[i]?.name !== c.params[i].name || t?.kind !== "udt" || t.name !== (c.params[i].type as { name: string }).name) {
        out.push(`${c.wasm}.${c.fn} parameter ${i + 1} isn't ${c.params[i].name}: ${(c.params[i].type as { name: string }).name}`);
      }
    }
    const keep = (_: unknown, i: number) => !opaque.includes(i);
    out.push(...compareParams(actual.filter(keep), c.params.filter(keep), c.fn).map((d) => `${c.wasm}: ${d}`));
  }
  return out;
}

Deno.test("the smoke's Soroswap router calls match the router's spec (testnet fixture)", () => {
  const wasm = Deno.readFileSync(`${root}contracts/testdata/soroswap_router.wasm`);
  assertEquals(differences(wasm, SMOKE_CALLS.filter((c) => c.wasm === "soroswap-router")), []);
});

Deno.test({
  name: "the smoke's v2 calls match the contract specs of contracts/dist (ignored before build.sh has run)",
  ignore: !distPresent,
  fn() {
    const keys = [...new Set(SMOKE_CALLS.map((c) => c.wasm))].filter((k): k is WasmKey => k !== "soroswap-router");
    assert(keys.length >= 5);
    for (const k of keys) assertEquals(differences(Deno.readFileSync(dist(k)), SMOKE_CALLS.filter((c) => c.wasm === k)), [], k);
  },
});

Deno.test({
  name: "the constructor guard passes for all ten v2 WASMs of contracts/dist (ignored before build.sh has run)",
  ignore: !distPresent,
  fn() {
    // testnet-qa with Aquarius on plans every v2 constructor; the runtime ones (token, NFT, coin) are compared too.
    const qa = profileFor("testnet-qa");
    const id = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC";
    const g = "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ";
    const ctors = constructors({
      profile: qa,
      roles: { ADMIN_PUBLIC: g, GOVERNANCE_PUBLIC: g, LAUNCHPAD_GUARDIAN_PUBLIC: g, MOMENTS_GUARDIAN_PUBLIC: g, TREASURY_PUBLIC: g, PLATFORM_PUBLIC: g },
      ids: Object.fromEntries(["exec-soroswap", "exec-aquarius", "qa-exec-fail", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2", "moments-graduator-qa-fail", "moments-v2-qa-fail"].map((n) => [n, id])),
      wasmHashes: {},
      network: { xlmSac: id, usdcSac: id, soroswapFactory: id, aquariusRouter: id },
      economics: parseEconomics(JSON.parse(Deno.readTextFileSync(`${root}backend/scripts/economics/testnet-qa-v2.json`)), qa),
      aquarius: { enabled: true, paymentAsset: id },
      qaAdmin: g,
    });
    const byWasm = new Map<WasmKey, (typeof ctors)[number]["params"]>();
    for (const c of ctors) if (!byWasm.has(c.wasm)) byWasm.set(c.wasm, c.params);
    for (const [k, v] of Object.entries(RUNTIME_CONSTRUCTORS)) byWasm.set(k as WasmKey, v);
    assertEquals([...byWasm.keys()].sort(), (Object.keys(WASMS) as WasmKey[]).sort());
    for (const [k, params] of byWasm) assertEquals(constructorGuard(Deno.readFileSync(dist(k)), params).differences, [], k);
  },
});

Deno.test({
  name: "admin-v2's launchpad-v2 and moments-v2 calls (ADMIN_FNS) match the contract specs of contracts/dist (ignored before build.sh has run)",
  ignore: !distPresent,
  async fn() {
    const { ADMIN_FNS } = await import("../admin-v2.ts");
    const { renderType } = await import("./wasm-spec.ts");
    const TYPE: Record<string, string> = {
      false: "bool",
      bool: "bool",
      u32: "u32",
      i128: "i128",
      contract: "Address",
      asset: "Address",
      account: "Address",
      caller: "Address",
      "account or none": "Option<Address>",
      "venue kind": "VenueKind",
      "venue params": "VenueParams",
      "venue ids": "Vec<u32>",
      policy: "Policy",
    };
    const specs = { "launchpad-v2": readSpec(Deno.readFileSync(dist("launchpad-v2"))), "moments-v2": readSpec(Deno.readFileSync(dist("moments-v2"))) };
    const problems: string[] = [];
    for (const f of ADMIN_FNS.filter((x) => x.target === "launchpad-v2" || x.target === "moments-v2")) {
      const actual = functionParams(specs[f.target as "launchpad-v2" | "moments-v2"], f.fn);
      if (!actual) {
        problems.push(`${f.target} has no ${f.fn}`);
        continue;
      }
      const got = actual.map((p) => renderType(p.type));
      const want = f.args.map((a) => TYPE[a]);
      if (JSON.stringify(got) !== JSON.stringify(want)) problems.push(`${f.target} ${f.fn}(${got.join(", ")}), admin-v2 encodes (${want.join(", ")})`);
    }
    assertEquals(problems, []);
  },
});

Deno.test("the smoke's buy waits for the snipe window by size, not for a zero snipe fee", () => {
  // The completing buy on the XLM curve: 4,324.55532 XLM of net plus 2% fees.
  const used = 44_128_115_511n;
  // Inside the window the last step is 30 bps of what the buy spends.
  assert(!snipeWindowOver((used * 30n) / 10_000n, used));
  assert(!snipeWindowOver((used * 9_800n) / 10_000n, used));
  // After it, quote_buy's snipe_fee holds only the floored fees' and the clamp's rounding.
  assert(snipeWindowOver(0n, used));
  assert(snipeWindowOver(3n, used));
  assert(snipeWindowOver(used / 10_000n, used));
});
