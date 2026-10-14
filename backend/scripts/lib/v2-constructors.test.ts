// The v2 interfaces the deploy kit builds against: the constructors (checked against the merged contracts' real
// constructor specs and the lead's pinned signatures), the economics files (spec §14.1–14.2), venue ids read back
// from venues() (F8) and the admin calls after the constructors. No network.
import { assert, assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Keypair, nativeToScVal, scValToNative, xdr } from "@stellar/stellar-sdk";
import { planIds, sacIdFor } from "./contract-ids.ts";
import {
  type ConstructorPlan,
  constructors,
  type EconomicsV2,
  encodeArgs,
  initialVenues,
  launchpadCalls,
  type LaunchpadState,
  parseEconomics,
  plannedContracts,
  readLaunchpadState,
  readVenues,
  RUNTIME_CONSTRUCTORS,
  thresholdOf,
  venueIds,
  WASMS,
  type WasmKey,
} from "./v2-constructors.ts";
import { profileFor, type SingletonName, singletonsFor, type V2Profile, type V2Roles } from "./v2-profile.ts";
import { constructorGuard, renderParams, wasmWithSections } from "./wasm-spec.ts";

const root = new URL("../../../", import.meta.url).pathname;
const econ = (name: string) => JSON.parse(Deno.readTextFileSync(`${root}backend/scripts/economics/${name}`));
const TESTNET = profileFor("testnet");
const QA = profileFor("testnet-qa");
const XLM = 10_000_000n;

// ------------------------------------------------------------------------------------------------ economics (§14)

Deno.test("economics/testnet-v2.json is spec §14.1–14.2 exactly", () => {
  const e = parseEconomics(econ("testnet-v2.json"), TESTNET);
  const lp = e.launchpad;
  assertEquals(lp.launchFee, "100000000", "10 XLM = 100,000,000 stroops (O6)");
  assertEquals(lp.supply, (1_000_000_000n * XLM).toString(), "1,000,000,000 at 7 dp");
  assertEquals([lp.feeBps, lp.protocolShareBps, lp.maxCreatorFeeBps], [100, 5000, 1000]);
  assertEquals([lp.snipeSchedule, lp.snipeStepSecs, lp.maxExemptions], [[9800, 2500, 300, 30], 5, 32]);
  const xlm = lp.quotes.find((q) => q.asset === "XLM")!;
  const usdc = lp.quotes.find((q) => q.asset === "USDC")!;
  assertEquals([xlm.phantom, xlm.threshold], [(2_000n * XLM).toString(), "43245553200"], "XLM phantom 2,000 → 4,324.5553200");
  assertEquals([usdc.phantom, usdc.threshold], [(20n * XLM).toString(), "432455532"], "USDC phantom 20 → 43.2455532 (L10)");
  for (const q of [xlm, usdc]) assertEquals([q.enabled, q.venuesAllowed, q.fallback], [true, [], "soroswap"]);
  assertEquals(lp.quotes.length, 2);
  assertEquals(lp.venues, [
    { key: "soroswap", kind: "Soroswap", feeFraction: 0, enabled: true },
    { key: "aquarius", kind: "Aquarius", feeFraction: 30, enabled: true },
  ]);
  assertEquals(lp.aquarius, { maxPoolPayment: "100000000", floatTargetMultiple: 50, alertBelowMultiple: 5, maxSwapXlm: "20000000000" });
  const m = e.moments;
  assertEquals([m.quote, m.supply, m.batch], ["USDC", (100_000_000n * XLM).toString(), 20]);
  assertEquals(m.policy, {
    threshold: "100000000",
    minPrice: "1000000",
    creatorBps: 2000,
    platformBps: 500,
    reserveBps: 7500,
    maxCreatorAllocBps: 1000,
    expiryCreatorBps: 7000,
    royaltyBps: 500,
  });
  assertEquals([m.harvestBps, m.harvestCreatorBps], [6667, 4000]);
  assertEquals(e.qaAsset, undefined);
});

Deno.test("economics/testnet-qa-v2.json adds the venue-locked QA quote and the qa-exec-fail venue, and nothing else", () => {
  const t = parseEconomics(econ("testnet-v2.json"), TESTNET);
  const q = parseEconomics(econ("testnet-qa-v2.json"), QA);
  assertEquals(q.moments, t.moments);
  assertEquals(q.launchpad.quotes.slice(0, 2), t.launchpad.quotes);
  assertEquals(q.launchpad.quotes[2], {
    asset: "QA",
    phantom: (2_000n * XLM).toString(),
    threshold: "43245553200",
    enabled: true,
    venuesAllowed: ["qa-exec-fail"],
    fallback: "soroswap",
  });
  assertEquals(q.launchpad.venues.map((v) => v.kind), ["Soroswap", "Aquarius", "QaFail"]);
  assertEquals(q.launchpad.aquarius.floatTargetMultiple, 10);
  const { venues: _v, quotes: _q, aquarius: _a, ...restQ } = q.launchpad;
  const { venues: _v2, quotes: _q2, aquarius: _a2, ...restT } = t.launchpad;
  assertEquals(restQ, restT);
  assertEquals(q.qaAsset, { code: "DYORQA" });
});

Deno.test("an economics file is refused when it doesn't fit its deployment", () => {
  assertThrows(() => parseEconomics(econ("testnet-qa-v2.json"), TESTNET), Error, "it is for testnet-qa");
  const qaOnTestnet = { ...econ("testnet-qa-v2.json"), deployment: "testnet" };
  assertThrows(() => parseEconomics(qaOnTestnet, TESTNET), Error, "testnet-qa only");
  const wrongThreshold = econ("testnet-v2.json");
  wrongThreshold.launchpad.quotes[1].threshold = "432455533";
  assertThrows(() => parseEconomics(wrongThreshold, TESTNET), Error, "√10");
  const badSplit = econ("testnet-v2.json");
  badSplit.moments.policy.platformBps = 600;
  assertThrows(() => parseEconomics(badSplit, TESTNET), Error, "sum to 10,000");
  const badTier = econ("testnet-v2.json");
  badTier.launchpad.venues[1].feeFraction = 25;
  assertThrows(() => parseEconomics(badTier, TESTNET), Error, "10, 30 or 100");
  assertEquals(thresholdOf(2_000n * XLM), 43_245_553_200n);
});

// ------------------------------------------------------------------------------------------------ constructors

const roles: V2Roles = {
  ADMIN_PUBLIC: "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ",
  GOVERNANCE_PUBLIC: "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ",
  LAUNCHPAD_GUARDIAN_PUBLIC: "GAYMY43ASKVRTMJGS55BD3B3HKMHY4FETF4HUDVXRGZHMUUWFCFEINBT",
  MOMENTS_GUARDIAN_PUBLIC: "GAYMY43ASKVRTMJGS55BD3B3HKMHY4FETF4HUDVXRGZHMUUWFCFEINBT",
  TREASURY_PUBLIC: "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5",
  PLATFORM_PUBLIC: "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5",
};
const net = {
  xlmSac: "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
  usdcSac: "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA",
  soroswapFactory: "CDP3HMUH6SMS3S7NPGNDJLULCOXXEPSHY4JKUKMBNQMATHDHWXRRJTBY",
  aquariusRouter: "CBCFTQSPDBAIZ6R6PJQKSQWKNKWH2QIV3I4J72SHWBIK3ADRRAM5A6GD",
};
const AQUA_SAC = "CDNVQW44C3HALYNVQ4SOBXY5EWYTGVYXX6JPESOLQDABJI5FC5LTRRUE";
const QA_ADMIN = Keypair.fromRawEd25519Seed(Buffer.alloc(32, 8)).publicKey();
const hashes = Object.fromEntries((Object.keys(WASMS) as WasmKey[]).map((k, i) => [k, String(i).padStart(2, "0").repeat(32)])) as Record<WasmKey, string>;

function plan(profile: V2Profile, aquarius: boolean, withHashes = true): ConstructorPlan {
  const ids = planIds(profile.name, 1, roles.ADMIN_PUBLIC, "Test SDF Network ; September 2015", singletonsFor(profile, aquarius));
  return {
    profile,
    roles,
    ids: Object.fromEntries([...ids.values()].map((p) => [p.name, p.id])) as Partial<Record<SingletonName, string>>,
    wasmHashes: withHashes ? hashes : {},
    network: net,
    economics: parseEconomics(econ(profile.economicsFile), profile),
    aquarius: { enabled: aquarius, paymentAsset: AQUA_SAC },
    qaAdmin: profile.qaExecFail ? QA_ADMIN : undefined,
  };
}

// The `__constructor` entries (and the user-defined types they use) of the merged contracts, cut byte for byte from
// the contractspecv0 sections of their release WASMs (main 9354d56, cargo build --target wasm32v1-none --release).
const MERGED_CTOR_SPECS: Partial<Record<WasmKey, string>> = {
  "exec-soroswap":
    "AAAAAAAAAGNgY2FsbGVyc2AgYXJlIGxhdW5jaHBhZC12MiBhbmQgbW9tZW50cy1ncmFkdWF0b3IsIGJ5IHRoZSBpZHMgdGhlIGRlcGxveSBzY3JpcHQgcHJlY29tcHV0ZXMgKMKnMy40KS4AAAAADV9fY29uc3RydWN0b3IAAAAAAAACAAAAAAAAAAdmYWN0b3J5AAAAABMAAAAAAAAAB2NhbGxlcnMAAAAD6gAAABMAAAAA",
  "exec-aquarius":
    "AAAAAAAAAAAAAAANX19jb25zdHJ1Y3RvcgAAAAAAAAQAAAAAAAAABnJvdXRlcgAAAAAAEwAAAAAAAAANcGF5bWVudF9hc3NldAAAAAAAABMAAAAAAAAAEG1heF9wb29sX3BheW1lbnQAAAALAAAAAAAAAAdjYWxsZXJzAAAAA+oAAAATAAAAAA==",
  "qa-exec-fail":
    "AAAAAAAAAG9gY2FsbGVyc2AgYXJlIGxhdW5jaHBhZC12MiBhbmQgdGhlIGZhaWxpbmcgTW9tZW50cyBzdGFjaydzIGdyYWR1YXRvcjsgYHFhX2FkbWluYCBpcyBhIHRocm93YXdheSB0ZXN0bmV0LXFhIGtleS4AAAAADV9fY29uc3RydWN0b3IAAAAAAAADAAAAAAAAAAdjYWxsZXJzAAAAA+oAAAATAAAAAAAAAAhxYV9hZG1pbgAAABMAAAAAAAAADGRlZmF1bHRfbW9kZQAAB9AAAAAETW9kZQAAAAAAAAADAAAAZkhvdyBgZ3JhZHVhdGVgIGZhaWxzIGZvciBhIHRva2VuLiBPbiB0aGUgd2lyZSBpdCBpcyB0aGUgdTMyIG9mIMKnNy4zOyBhbnkgb3RoZXIgdmFsdWUgZmFpbHMgdG8gZGVjb2RlLgAAAAAAAAAAAARNb2RlAAAAAwAAAAAAAAAERmFpbAAAAAAAAAAAAAAADUV4aGF1c3RCdWRnZXQAAAAAAAABAAAAAAAAAAxCb2d1c1N1Y2Nlc3MAAAAC",
  "lp-locker":
    "AAAAAAAAAZtgb3duZXJzYCBhcmUgbGF1bmNocGFkLXYyIGFuZCBtb21lbnRzLXYyOyBgYXF1YXJpdXNfcm91dGVyYCBpcyBgTm9uZWAgd2hlcmUgQXF1YXJpdXMgaXMgbm8gdmVudWUuCmBoYXJ2ZXN0X2ludGVydmFsYCBtdXN0IGxpZSBpbiBbYE1JTl9EVVJBVElPTmAsIGBNQVhfSEFSVkVTVF9JTlRFUlZBTGBdICg2MCBzIHRvIDEgZGF5OyAzLDYwMCBpbiBwcm9kdWN0aW9uLAo2MCBvbiB0ZXN0bmV0LXFhKSwgYW5kIGJvdGggb3duZXJzIHJlcXVpcmUgaXQgdG8gZXF1YWwgdGhlaXIgb3duIGBkdXJhdGlvbnMuaGFydmVzdF9pbnRlcnZhbGAgKEY2KS4KCltgTUlOX0RVUkFUSU9OYF06IGR5b3JfY29tbW9uOjpNSU5fRFVSQVRJT04KW2BNQVhfSEFSVkVTVF9JTlRFUlZBTGBdOiBkeW9yX2NvbW1vbjo6TUFYX0hBUlZFU1RfSU5URVJWQUwAAAAADV9fY29uc3RydWN0b3IAAAAAAAAEAAAAAAAAAAZvd25lcnMAAAAAA+oAAAATAAAAAAAAABBzb3Jvc3dhcF9mYWN0b3J5AAAAEwAAAAAAAAAPYXF1YXJpdXNfcm91dGVyAAAAA+gAAAATAAAAAAAAABBoYXJ2ZXN0X2ludGVydmFsAAAABgAAAAA=",
  "launch-token-v2":
    "AAAAAAAAArdNaW50cyBgc3VwcGx5YCB0byBgbGF1bmNocGFkYC4KCi0gYGxvY2tfZnJvbWA6IHRoaXMgbGF1bmNoJ3MgdmVudWUgYW5kIGZhbGxiYWNrIGV4ZWN1dG9ycywgdGhlIG9ubHkgc2VuZGVycyBiZXNpZGVzIHRoZSBsYXVuY2hwYWQgYmVmb3JlCnVubG9jay4KLSBgZml4ZWRfZXhjbHVkZWRgOiB3aGF0IG5ldmVyIGVhcm5zIHJld2FyZHMuIFRoZSB0b2tlbiBrZWVwcyB0aGUgZ2l2ZW4gc2V0IHBsdXMgdGhlIGxhdW5jaHBhZCwgdGhlIGxvY2tlciwKYGxvY2tfZnJvbWAgYW5kIGl0c2VsZjsgbGF1bmNocGFkLXYyIHBhc3NlcyB0aGUgZmlyc3QgZm91ciBhbHJlYWR5LCBhbmQgYWRkaW5nIHRoZW0gaGVyZSBrZWVwcyB0aGVtIG91dCBvZgp0aGUgcmV3YXJkcyB3aGF0ZXZlciBhIGRlcGxveWVyIHBhc3NlcyAoSS1UMTApLgotIGBzaGFyaW5nX3F1b3RlYDogdGhlIHF1b3RlIHdoZW4gdGhlIGxhdW5jaCBzaGFyZXMgZmVlcyB3aXRoIGl0cyBob2xkZXJzLCBlbHNlIGBOb25lYC4KLSBgc29yb3N3YXBfZmFjdG9yeWAgYW5kIGBhcXVhcml1c19yb3V0ZXJgOiB0aGUgdmVudWVzIGBleGNsdWRlX3Bvb2xgIGNoZWNrcyBhIHBvb2wgYWdhaW5zdCAoRjIpLgotIGB0cmVhc3VyeWA6IHRoZSBsYXVuY2hwYWQncyB0cmVhc3VyeSBvZiB0aGUgbW9tZW50OyB3aXRoIHNoYXJpbmcgb24gaXQgaXMgZXhjbHVkZWQgZnJvbSBiaXJ0aCAoVjIpLgAAAAANX19jb25zdHJ1Y3RvcgAAAAAAAAsAAAAAAAAACWxhdW5jaHBhZAAAAAAAABMAAAAAAAAABmxvY2tlcgAAAAAAEwAAAAAAAAAEbmFtZQAAABAAAAAAAAAABnN5bWJvbAAAAAAAEAAAAAAAAAAGc3VwcGx5AAAAAAALAAAAAAAAAAlsb2NrX2Zyb20AAAAAAAPqAAAAEwAAAAAAAAAOZml4ZWRfZXhjbHVkZWQAAAAAA+oAAAATAAAAAAAAAA1zaGFyaW5nX3F1b3RlAAAAAAAD6AAAABMAAAAAAAAAEHNvcm9zd2FwX2ZhY3RvcnkAAAATAAAAAAAAAA9hcXVhcml1c19yb3V0ZXIAAAAAEwAAAAAAAAAIdHJlYXN1cnkAAAATAAAAAA==",
  "moment-nft":
    "AAAAAAAAAL5tb21lbnRzLXYyIGRlcGxveXMgdGhpcyBhdCBwdWJsaXNoIHdpdGggaXRzZWxmIGFzIGBtaW50ZXJgLiBgcm95YWx0eV9icHNgIG9mIGV2ZXJ5IHNhbGUgaXMgc3VnZ2VzdGVkIHRvIHRoZQpjcmVhdG9yOyBPcGVuWmVwcGVsaW4gcmVmdXNlcyBtb3JlIHRoYW4gMTAwJSAobW9tZW50cy12MidzIHBvbGljeSBjYXBzIGl0IGF0IDEwJSkuAAAAAAANX19jb25zdHJ1Y3RvcgAAAAAAAAoAAAAAAAAABm1pbnRlcgAAAAAAEwAAAAAAAAAEbmFtZQAAABAAAAAAAAAABnN5bWJvbAAAAAAAEAAAAAAAAAAMbWV0YWRhdGFfdXJpAAAAEAAAAAAAAAAHY3JlYXRvcgAAAAATAAAAAAAAAAtyb3lhbHR5X2JwcwAAAAAEAAAAAAAAAAptZWRpYV9oYXNoAAAAAAPuAAAAIAAAAAAAAAAFcGxhY2UAAAAAAAAQAAAAAAAAAARkYXRlAAAAEAAAAAAAAAAMZXh0ZXJuYWxfdXJsAAAAEAAAAAA=",
  "moment-coin":
    "AAAAAAAAAQFSZWNvcmRzIGBtaW50ZXJgIGFuZCB0aGUgY2FwLCB0aGVuIG1pbnRzIGBpbml0aWFsX2Ftb3VudGAgdG8gYGluaXRpYWxfdG9gIHdpdGhpbiB0aGUgY2FwLiBBbiBpbml0aWFsIGFtb3VudCBvZgowIG1pbnRzIG5vdGhpbmc7IGEgbmVnYXRpdmUgb25lIGZhaWxzIGBaZXJvQW1vdW50YCwgbGlrZSBgbWludGAuIG1vbWVudHMtZ3JhZHVhdG9yIHBhc3NlcwpgKG1vbWVudHMsIG5hbWUsIHN5bWJvbCwgUywgaXRzZWxmLCBwb29sX2NvaW5zKWAgKMKnMTIpLgAAAAAAAA1fX2NvbnN0cnVjdG9yAAAAAAAABgAAAAAAAAAGbWludGVyAAAAAAATAAAAAAAAAARuYW1lAAAAEAAAAAAAAAAGc3ltYm9sAAAAAAAQAAAAAAAAAANjYXAAAAAACwAAAAAAAAAKaW5pdGlhbF90bwAAAAAAEwAAAAAAAAAOaW5pdGlhbF9hbW91bnQAAAAAAAsAAAAA",
};

Deno.test("the builders pass the constructor guard against every merged contract's real constructor", () => {
  const p = plan(QA, true);
  const byWasm = new Map<WasmKey, ReturnType<typeof constructors>[number]["params"]>();
  for (const c of constructors(p)) if (!byWasm.has(c.wasm)) byWasm.set(c.wasm, c.params);
  for (const [k, v] of Object.entries(RUNTIME_CONSTRUCTORS)) byWasm.set(k as WasmKey, v);
  const merged = (Object.keys(WASMS) as WasmKey[]).filter((k) => WASMS[k].binding === "merged");
  assertEquals(merged.sort(), Object.keys(MERGED_CTOR_SPECS).sort());
  for (const k of merged) {
    const wasm = wasmWithSections([["contractspecv0", Uint8Array.from(Buffer.from(MERGED_CTOR_SPECS[k]!, "base64"))]]);
    const r = constructorGuard(wasm, byWasm.get(k)!);
    assertEquals(r.differences, [], k);
  }
});

Deno.test("launchpad-v2, moments-v2 and moments-graduator are built exactly as the lead pinned them", () => {
  const p = (name: SingletonName) => renderParams(constructors(plan(TESTNET, true)).find((c) => c.contract === name)!.params);
  assertEquals(
    p("launchpad-v2"),
    "(admin: Address, guardian: Option<Address>, treasury: Address, xlm: Address, token_wasm_hash: BytesN<32>, locker: Address, " +
      "soroswap_factory: Address, aquarius_router: Address, launch_fee: i128, venues: Vec<VenueInit>, durations: LaunchDurations, ttl: TtlPolicy)",
  );
  assertEquals(
    p("moments-v2"),
    "(governance: Address, guardian: Option<Address>, usdc: Address, nft_wasm_hash: BytesN<32>, graduator: Address, locker: Address, " +
      "executor: Address, soroswap_factory: Address, external_base: String, policy: Policy, durations: MomentsDurations, ttl: TtlPolicy)",
  );
  assertEquals(p("moments-graduator"), "(moments: Address, coin_wasm_hash: BytesN<32>, executor: Address, locker: Address, soroswap_factory: Address)");
  assertEquals(p("lp-locker"), "(owners: Vec<Address>, soroswap_factory: Address, aquarius_router: Option<Address>, harvest_interval: u64)");
});

Deno.test("constructor values wire the peers by their planned ids and follow the economics (L-f)", () => {
  const p = plan(TESTNET, true);
  const id = (n: SingletonName) => p.ids[n]!;
  const ctors = constructors(p);
  assertEquals(ctors.map((c) => c.contract), ["exec-soroswap", "exec-aquarius", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2"]);
  const v = (n: SingletonName) => Object.fromEntries(ctors.find((c) => c.contract === n)!.params.map((x, i) => [x.name, ctors.find((c) => c.contract === n)!.values[i]]));
  assertEquals(v("exec-soroswap"), { factory: net.soroswapFactory, callers: [id("launchpad-v2"), id("moments-graduator")] });
  assertEquals(v("exec-aquarius"), { router: net.aquariusRouter, payment_asset: AQUA_SAC, max_pool_payment: 100_000_000n, callers: [id("launchpad-v2"), id("moments-graduator")] });
  assertEquals(v("lp-locker"), { owners: [id("launchpad-v2"), id("moments-v2")], soroswap_factory: net.soroswapFactory, aquarius_router: net.aquariusRouter, harvest_interval: 3_600 });
  assertEquals(v("moments-graduator"), { moments: id("moments-v2"), coin_wasm_hash: hashes["moment-coin"], executor: id("exec-soroswap"), locker: id("lp-locker"), soroswap_factory: net.soroswapFactory });
  const lp = v("launchpad-v2");
  assertEquals([lp.admin, lp.guardian, lp.treasury, lp.xlm], [roles.ADMIN_PUBLIC, roles.LAUNCHPAD_GUARDIAN_PUBLIC, roles.TREASURY_PUBLIC, net.xlmSac]);
  assertEquals([lp.token_wasm_hash, lp.locker, lp.aquarius_router, lp.launch_fee], [hashes["launch-token-v2"], id("lp-locker"), net.aquariusRouter, 100_000_000n]);
  assertEquals(lp.venues, [
    { kind: "Soroswap", executor: id("exec-soroswap"), params: { fee_fraction: 0 } },
    { kind: "Aquarius", executor: id("exec-aquarius"), params: { fee_fraction: 30 } },
  ]);
  assertEquals(lp.durations, { ...TESTNET.launchDurations });
  assertEquals(lp.ttl, { threshold: 120_960, extend_to: 518_400 });
  const mo = v("moments-v2");
  assertEquals([mo.governance, mo.guardian, mo.usdc, mo.nft_wasm_hash], [roles.GOVERNANCE_PUBLIC, roles.MOMENTS_GUARDIAN_PUBLIC, net.usdcSac, hashes["moment-nft"]]);
  assertEquals([mo.graduator, mo.locker, mo.executor, mo.external_base], [id("moments-graduator"), id("lp-locker"), id("exec-soroswap"), "https://dyorhq.fun/moments/"]);
  assertEquals((mo.policy as Record<string, unknown>).platform, roles.PLATFORM_PUBLIC);
  assertEquals((mo.policy as Record<string, unknown>).treasury, roles.TREASURY_PUBLIC);
  assertEquals((mo.policy as Record<string, unknown>).threshold, 100_000_000n);
  // Without Aquarius: no exec-aquarius, no venue, and the locker gets no router; the launchpad still gets it (F2).
  const off = constructors(plan(TESTNET, false));
  assertEquals(off.map((c) => c.contract).includes("exec-aquarius"), false);
  const lpOff = off.find((c) => c.contract === "launchpad-v2")!;
  assertEquals((lpOff.values[9] as unknown[]).length, 1);
  assertEquals(lpOff.values[7], net.aquariusRouter);
  assertEquals(off.find((c) => c.contract === "lp-locker")!.values[2], null);
});

Deno.test("testnet-qa adds qa-exec-fail and the failing Moments stack on it, with the QA durations", () => {
  const p = plan(QA, false);
  const ctors = constructors(p);
  assertEquals(ctors.map((c) => c.contract), ["exec-soroswap", "qa-exec-fail", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2", "moments-graduator-qa-fail", "moments-v2-qa-fail"]);
  const get = (n: SingletonName) => ctors.find((c) => c.contract === n)!;
  assertEquals(get("qa-exec-fail").values, [[p.ids["launchpad-v2"], p.ids["moments-graduator-qa-fail"]], QA_ADMIN, "Fail"]);
  assertEquals(get("moments-graduator-qa-fail").values.slice(0, 4), [p.ids["moments-v2-qa-fail"], hashes["moment-coin"], p.ids["qa-exec-fail"], p.ids["lp-locker"]]);
  assertEquals(get("moments-v2-qa-fail").values[4], p.ids["moments-graduator-qa-fail"]);
  assertEquals(get("moments-v2-qa-fail").values[6], p.ids["qa-exec-fail"]);
  assertEquals((get("launchpad-v2").values[9] as { kind: string }[]).map((x) => x.kind), ["Soroswap", "QaFail"]);
  assertEquals(get("lp-locker").values[3], 60);
  assertEquals(get("launchpad-v2").values[10], { ...QA.launchDurations });
  assertEquals(get("moments-v2").values[10], { ...QA.momentsDurations });
});

Deno.test("constructor arguments encode to the types the contracts declare", () => {
  for (const c of constructors(plan(QA, true))) {
    const args = encodeArgs(c);
    assertEquals(args.length, c.params.length, c.contract);
  }
  const lp = constructors(plan(TESTNET, true)).find((c) => c.contract === "launchpad-v2")!;
  const args = encodeArgs(lp);
  assertEquals(args[8].switch().name, "scvI128");
  const venues = scValToNative(args[9]);
  assertEquals(venues[1], { executor: lp.values[9] && (lp.values[9] as { executor: string }[])[1].executor, kind: 1, params: { fee_fraction: 30 } });
  assertEquals(args[1].switch().name, "scvAddress", "guardian Some(…) is the address itself");
  // A WASM hash that isn't known (dist absent) can't be encoded: a real run refuses before it gets here.
  const noHashes = constructors(plan(TESTNET, true, false)).find((c) => c.contract === "launchpad-v2")!;
  assertThrows(() => encodeArgs(noHashes), Error, "launchpad-v2.token_wasm_hash");
});

// ------------------------------------------------------------------------------------------------ venues and admin calls (F8)

/** venues() as the chain would return it, in ScVal. */
function venuesReply(list: { kind: number; executor: string; fee: number; enabled: boolean }[]): xdr.ScVal {
  const entry = (v: typeof list[number], id: number) =>
    xdr.ScVal.scvMap([
      new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("enabled"), val: xdr.ScVal.scvBool(v.enabled) }),
      new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("executor"), val: nativeToScVal(v.executor, { type: "address" }) }),
      new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("id"), val: nativeToScVal(id, { type: "u32" }) }),
      new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("kind"), val: nativeToScVal(v.kind, { type: "u32" }) }),
      new xdr.ScMapEntry({
        key: xdr.ScVal.scvSymbol("params"),
        val: xdr.ScVal.scvMap([new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("fee_fraction"), val: nativeToScVal(v.fee, { type: "u32" }) })]),
      }),
    ]);
  return xdr.ScVal.scvVec(list.map(entry));
}

function stateFor(p: ConstructorPlan, e: EconomicsV2, venues: xdr.ScVal, overrides: Record<string, unknown> = {}): LaunchpadState {
  return {
    config: {
      launch_fee: BigInt(e.launchpad.launchFee),
      fee_bps: 100,
      protocol_share_bps: 5000,
      max_creator_fee_bps: 1000,
      snipe_schedule: [9800, 2500, 300, 30],
      snipe_step_secs: 5,
      ...overrides,
    },
    venues: readVenues(scValToNative(venues)),
    quotes: new Map(),
  };
}

const QA_SAC = sacIdFor(`DYORQA:${Keypair.fromRawEd25519Seed(Buffer.alloc(32, 9)).publicKey()}`, "Test SDF Network ; September 2015");

Deno.test("with Aquarius absent, the qa-exec-fail venue gets the next id and the venue-locked quote uses it (mocked venues())", async () => {
  const p = plan(QA, false);
  const e = p.economics;
  const planned = initialVenues(p);
  assertEquals(planned.map((v) => v.key), ["soroswap", "qa-exec-fail"]);
  const reply = venuesReply([
    { kind: 0, executor: p.ids["exec-soroswap"]!, fee: 0, enabled: true },
    { kind: 3, executor: p.ids["qa-exec-fail"]!, fee: 0, enabled: true },
  ]);
  // Read the way the deploy reads it.
  const state = await readLaunchpadState((fn) => Promise.resolve(fn === "venues" ? reply : fn === "config" ? xdr.ScVal.scvMap([]) : xdr.ScVal.scvVoid()), [net.xlmSac]);
  assertEquals(state.venues.map((v) => [v.id, v.kind]), [[0, 0], [1, 3]]);
  const ids = venueIds(planned, state.venues);
  assertEquals([ids.get("soroswap"), ids.get("qa-exec-fail")], [0, 1]);

  const calls = launchpadCalls("CLAUNCHPAD", e, planned, stateFor(p, e, reply), new Map([["XLM", net.xlmSac], ["USDC", net.usdcSac], ["QA", QA_SAC]]));
  const qaQuote = calls.find((c) => c.fn === "set_quote" && scValToNative(c.args[0]) === QA_SAC)!;
  assertEquals(scValToNative(qaQuote.args[4]), [1], "venues_allowed = [the qa-exec-fail id as read]");
  assertEquals(scValToNative(qaQuote.args[5]), 0, "fallback = the Soroswap id as read");
  const xlmQuote = calls.find((c) => c.fn === "set_quote" && scValToNative(c.args[0]) === net.xlmSac)!;
  assertEquals(scValToNative(xlmQuote.args[4]), []);

  // With Aquarius present, qa-exec-fail is id 2, and the ids still come from the chain, not the economics order.
  const p2 = plan(QA, true);
  const reply2 = venuesReply([
    { kind: 0, executor: p2.ids["exec-soroswap"]!, fee: 0, enabled: true },
    { kind: 3, executor: p2.ids["qa-exec-fail"]!, fee: 0, enabled: true },
    { kind: 1, executor: p2.ids["exec-aquarius"]!, fee: 30, enabled: true },
  ]);
  const calls2 = launchpadCalls("CLAUNCHPAD", p2.economics, initialVenues(p2), stateFor(p2, p2.economics, reply2), new Map([["XLM", net.xlmSac], ["USDC", net.usdcSac], ["QA", QA_SAC]]));
  assertEquals(scValToNative(calls2.find((c) => scValToNative(c.args[0]) === QA_SAC)!.args[4]), [1]);
  // A venue missing from venues() is an error, never a guess.
  assertThrows(() => venueIds(initialVenues(p2), readVenues(scValToNative(reply))), Error, "no Aquarius venue");
});

Deno.test("the admin calls cover only what differs on chain, so a re-run sends nothing new", () => {
  const p = plan(TESTNET, true);
  const e = p.economics;
  const planned = initialVenues(p);
  const reply = venuesReply([
    { kind: 0, executor: p.ids["exec-soroswap"]!, fee: 0, enabled: true },
    { kind: 1, executor: p.ids["exec-aquarius"]!, fee: 30, enabled: true },
  ]);
  const assets = new Map<"XLM" | "USDC" | "QA", string>([["XLM", net.xlmSac], ["USDC", net.usdcSac]]);
  // Fresh: the constructor set the fee, the fees and the venues; only the two quotes are missing.
  const fresh = launchpadCalls("CLAUNCHPAD", e, planned, stateFor(p, e, reply), assets);
  assertEquals(fresh.map((c) => c.fn), ["set_quote", "set_quote"]);
  assertStringIncludes(fresh[1].describe, "set_quote(USDC, phantom 200000000, threshold 432455532, enabled, venues [], fallback 0)");
  // Everything already there: nothing.
  const done = stateFor(p, e, reply);
  for (const q of e.launchpad.quotes) {
    done.quotes.set(assets.get(q.asset)!, { phantom: BigInt(q.phantom), threshold: BigInt(q.threshold), enabled: true, venues_allowed: [], fallback_venue: 0 });
  }
  assertEquals(launchpadCalls("CLAUNCHPAD", e, planned, done, assets), []);
  // A different launch fee, other fees and a disabled venue are each set back.
  const drift = stateFor(p, e, venuesReply([
    { kind: 0, executor: p.ids["exec-soroswap"]!, fee: 0, enabled: true },
    { kind: 1, executor: p.ids["exec-aquarius"]!, fee: 30, enabled: false },
  ]), { launch_fee: 0n, snipe_step_secs: 1 });
  drift.quotes = done.quotes;
  assertEquals(launchpadCalls("CLAUNCHPAD", e, planned, drift, assets).map((c) => c.describe), [
    "set_launch_fee(100000000)",
    "set_fees(100, 5000, 1000, [9800, 2500, 300, 30], 5)",
    "set_venue_enabled(1 aquarius, true)",
  ]);
});

Deno.test("a re-run compares each contract's config views with the plan", () => {
  const p = plan(TESTNET, true);
  const planned = plannedContracts(p, constructors(p));
  const views = Object.fromEntries(planned.map((c) => [c.name, c.views.map((v) => v.label)]));
  assertEquals(views["exec-soroswap"], ["exec-soroswap factory()", "exec-soroswap callers()"]);
  assertEquals(views["lp-locker"], ["lp-locker owners()", "lp-locker soroswap_factory()", "lp-locker aquarius_router()", "lp-locker harvest_interval()"]);
  assert(views["launchpad-v2"].includes("launchpad-v2 config().treasury"));
  assert(views["launchpad-v2"].includes("launchpad-v2 venues() (kind, executor, params)"));
  assert(views["moments-v2"].includes("moments-v2 policy()"));
  assertEquals(planned.find((c) => c.name === "launchpad-v2")!.wasmHash, hashes["launchpad-v2"]);
  assertThrows(() => plannedContracts(plan(TESTNET, true, false), constructors(plan(TESTNET, true, false))), Error, "absent from dist");
});
