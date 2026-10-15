// The v2 error-name table (_shared/v2_errors.ts, docs/DESIGN-stellar-contracts-v2.md §4, finding V10) and the rest of
// what backend/scripts/gen-pinned.ts generates from the registry (§20.1): the v2 deployment files, the allowlist and the
// app's pins, with v1 unchanged while no v2 file exists.
import { StrKey } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertFalse, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import {
  distMismatch,
  type DistWasm,
  type ErrorEnum,
  errorEnums,
  errorTable,
  generateErrors,
  renderErrors,
  renderPins,
  SOROSWAP_FIXTURES,
  unbundledV2,
} from "../../scripts/gen-pinned.ts";
import type { WasmKey } from "../../scripts/lib/v2-constructors.ts";
import {
  PRODUCTION_LAUNCH_DURATIONS,
  PRODUCTION_MOMENTS_DURATIONS,
  TESTNET_QA_LAUNCH_DURATIONS,
  TESTNET_QA_MOMENTS_DURATIONS,
} from "../../scripts/lib/v2-profile.ts";
import {
  BUNDLED_V2,
  deploymentsByName,
  DURATION_SETS_V2,
  parseDeploymentV2,
} from "../../supabase/functions/_shared/deployments/index.ts";
import {
  contractAllowlist,
  MAINNET,
  TESTNET,
  withDeployment,
  withDeploymentV2,
} from "../../supabase/functions/_shared/networks.ts";
import {
  describeError,
  ERR_BASE,
  errorName,
  errorsFor,
  FOREIGN_ERRORS,
  HOST_ERRORS,
  type NamedError,
  V2_CONTRACT_TAGS,
  V2_ERRORS,
  V2_ERRORS_FROM,
} from "../../supabase/functions/_shared/v2_errors.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const exists = (path: string) => {
  try {
    Deno.statSync(`${ROOT}${path}`);
    return true;
  } catch {
    return false;
  }
};
const V2_WASMS = Object.keys(V2_CONTRACT_TAGS).map((k) => `contracts/dist/dyor_${k.replace(/-/g, "_")}.wasm`);
const DIST = V2_WASMS.every(exists);

// ------------------------------------------------------------------------------------------------ the error table

Deno.test("v2_errors: one entry per error of every v2 contract, each inside its tag's namespace, no code twice", () => {
  const codes = new Set<number>();
  for (const e of V2_ERRORS) {
    const tag = V2_CONTRACT_TAGS[e.source as keyof typeof V2_CONTRACT_TAGS];
    assertEquals(e.origin, tag, `${e.source} ${e.name}`);
    assert(
      e.code >= ERR_BASE + tag * 100 + 1 && e.code <= ERR_BASE + tag * 100 + 99,
      `${e.source} ${e.name} = ${e.code}`,
    );
    assertFalse(codes.has(e.code), `code ${e.code} twice`);
    codes.add(e.code);
    assert(/^[A-Z][A-Za-z0-9]*$/.test(e.name), e.name);
  }
  for (const contract of Object.keys(V2_CONTRACT_TAGS)) {
    assert(V2_ERRORS.some((e) => e.source === contract), `${contract} has errors`);
  }
  assertEquals(V2_ERRORS.map((e) => e.code), [...codes].sort((a, b) => a - b), "in code order");
  for (const contract of Object.keys(V2_CONTRACT_TAGS)) {
    assert(/^[0-9a-f]{64}$/.test(V2_ERRORS_FROM[contract as keyof typeof V2_ERRORS_FROM]));
  }
});

Deno.test("v2_errors names a failure by its namespaced pair, never by a bare code (finding V10)", () => {
  assertEquals(errorName(4, 10_404), "PaymentUnavailable");
  assertEquals(errorName(4, 10_405), "PaymentTooHigh");
  assertEquals(errorName(3, 10_304), "LiquidityTooLow");
  assertEquals(errorName(10, 11_003), "GraduationInvalid");
  assertEquals(describeError(4, 10_404), "exec-aquarius PaymentUnavailable (4, 10404)");
  // The same code under another origin, or a bare local code, names nothing.
  assertEquals([errorName(3, 10_404), errorName(0, 10_404), errorName(4, 4), errorName(7, 11_003)], [
    null,
    null,
    null,
    null,
  ]);
  assertEquals(describeError(1, 10_199), "unknown error (1, 10199)");
  // As built after CT-09 (lead notes, 2026-10-15): moments-v2's 10_732 and 10_733 (10_726 unused) and the graduator's.
  assertEquals([errorName(7, 10_732), errorName(7, 10_733), errorName(7, 10_726)], [
    "InvalidConfig",
    "WrongReference",
    null,
  ]);
  assertEquals([errorName(10, 11_001), errorName(10, 11_002)], ["NotMoments", "InvalidAmounts"]);
  assertEquals([errorName(5, 10_502), errorName(1, 10_137)], ["ForcedFailure", "FallbackTooEarly"]);
});

Deno.test("v2_errors: origin 0 has OpenZeppelin's, the SAC's and Soroswap's codes, every name where they share one; 99 is the host's", () => {
  assertEquals(errorName(0, 10), "BalanceError");
  assertEquals(errorName(0, 13), "TrustlineMissingError");
  assertEquals(errorName(0, 100), "InsufficientBalance");
  assertEquals(errorName(0, 212), "InvalidRoyaltyAmount");
  assertEquals(errorName(0, 409), "PairDoesNotExist");
  // Soroswap's pair and OpenZeppelin's fungible token both use 104.
  assertEquals(errorName(0, 104), "MathOverflow or DepositInsufficientAmountToken0");
  assertEquals(
    describeError(0, 104),
    "OpenZeppelin fungible MathOverflow or Soroswap DepositInsufficientAmountToken0 (0, 104)",
  );
  assertEquals(errorsFor(0, 104).length, 2);
  assertEquals([errorName(99, 5), errorName(99, 7)], ["ExceededLimit", "InternalError"]);
  for (const e of FOREIGN_ERRORS) {
    assert(e.origin === 0 && (e.code < ERR_BASE + 100 || e.code > ERR_BASE + 1_099), `${e.source} ${e.name}`);
  }
  for (const e of HOST_ERRORS) assertEquals(e.origin, 99);
});

Deno.test("v2_errors: the tags and the namespace are dyor-common's", () => {
  const src = Deno.readTextFileSync(`${ROOT}contracts/common/src/lib.rs`);
  const tags = Object.fromEntries(
    [...src.matchAll(/pub const TAG_([A-Z0-9_]+): u32 = (\d+);/g)].map((
      [, name, n],
    ) => [name.toLowerCase().replace(/_/g, "-"), Number(n)]),
  );
  assertEquals(tags, { ...V2_CONTRACT_TAGS });
  assertEquals(Number(/pub const ERR_BASE: u32 = ([\d_]+);/.exec(src)![1].replace(/_/g, "")), ERR_BASE);
});

Deno.test({
  name: "v2_errors.ts is what gen-pinned.ts generates from contracts/dist's v2 WASMs",
  ignore: !DIST,
  async fn() {
    const { text } = await generateErrors(ROOT);
    assertEquals(
      Deno.readTextFileSync(`${ROOT}backend/supabase/functions/_shared/v2_errors.ts`),
      text,
      "run gen-pinned.ts --errors",
    );
  },
});

/** The v2 contracts' error enums as v2_errors.ts lists them, with OpenZeppelin's beside the token contracts' own as
 *  their specs carry them: what errorTable reads from contracts/dist, without contracts/dist. */
function specEnums(): { key: WasmKey; enums: ErrorEnum[] }[] {
  const cases = (errors: readonly NamedError[]) => errors.map((e) => ({ name: e.name, value: e.code }));
  const openZeppelin = (name: string, source: string): ErrorEnum => ({
    name,
    cases: cases(FOREIGN_ERRORS.filter((e) => e.source === source)),
  });
  return (Object.keys(V2_CONTRACT_TAGS) as WasmKey[]).map((key) => ({
    key,
    enums: [
      { name: "Error", cases: cases(V2_ERRORS.filter((e) => e.source === key)) },
      ...(key === "launch-token-v2" || key === "moment-coin"
        ? [openZeppelin("FungibleTokenError", "OpenZeppelin fungible")]
        : key === "moment-nft"
        ? [openZeppelin("NonFungibleTokenError", "OpenZeppelin non-fungible")]
        : []),
    ],
  }));
}

const SOROSWAP_ENUMS = SOROSWAP_FIXTURES.flatMap((f) =>
  errorEnums(Deno.readFileSync(`${ROOT}contracts/testdata/${f}`))
);

Deno.test("gen-pinned.ts renders v2_errors.ts as committed from its table and Soroswap's fixture WASMs, without contracts/dist", () => {
  assertEquals(
    renderErrors(errorTable(specEnums(), SOROSWAP_ENUMS), V2_ERRORS_FROM),
    Deno.readTextFileSync(`${ROOT}backend/supabase/functions/_shared/v2_errors.ts`),
  );
});

Deno.test("errorTable refuses a code outside its tag's range or twice, a contract without errors, an unknown enum and a foreign code in the namespace", () => {
  type Contracts = { key: WasmKey; enums: ErrorEnum[] }[];
  const refused = (change: (contracts: Contracts, soroswap: ErrorEnum[]) => void, message: string) => {
    const contracts = specEnums();
    const soroswap = structuredClone(SOROSWAP_ENUMS);
    change(contracts, soroswap);
    assertThrows(() => errorTable(contracts, soroswap), Error, message);
  };
  const enumsOf = (contracts: Contracts, key: WasmKey) => contracts.find((c) => c.key === key)!.enums;
  // launchpad-v2's first error numbered in launch-token-v2's range, or a bare local code beside namespaced ones.
  refused(
    (cs) => (enumsOf(cs, "launchpad-v2")[0].cases[0].value = 10_201),
    "= 10201 is outside its namespace 10101–10199",
  );
  refused(
    (cs) => enumsOf(cs, "lp-locker")[0].cases.push({ name: "Bare", value: 3 }),
    "lp-locker: Error::Bare = 3 is outside",
  );
  // One code in two of a contract's enums.
  refused((cs) => {
    const own = enumsOf(cs, "lp-locker");
    own.push({ name: "Again", cases: [{ ...own[0].cases[0] }] });
  }, `lp-locker: code ${V2_ERRORS.find((e) => e.source === "lp-locker")!.code} repeats`);
  // A contract whose spec has no error enum, or only OpenZeppelin's.
  refused((cs) => enumsOf(cs, "moments-graduator").splice(0), "moments-graduator: its contract spec has no error enum");
  refused((cs) => enumsOf(cs, "moment-nft").shift(), "moment-nft: its contract spec has no error enum");
  // An enum outside the namespace that isn't OpenZeppelin's, or is OpenZeppelin's with other cases.
  refused(
    (cs) => enumsOf(cs, "exec-soroswap").push({ name: "Strange", cases: [{ name: "Oops", value: 7 }] }),
    "exec-soroswap: error enum Strange is outside the v2 namespace and isn't OpenZeppelin's",
  );
  refused(
    (cs) => enumsOf(cs, "moment-coin")[1].cases.pop(),
    "moment-coin: error enum FungibleTokenError is outside the v2 namespace and isn't OpenZeppelin's",
  );
  // A v2 contract not read at all.
  refused((cs) => cs.splice(cs.findIndex((c) => c.key === "qa-exec-fail"), 1), "no errors read for qa-exec-fail");
  // An origin-0 code inside the namespace, which a v2 code's name could be mistaken for.
  refused(
    (_, soroswap) => soroswap.push({ name: "PairError", cases: [{ name: "Shadow", value: 10_404 }] }),
    "a foreign code is inside the v2 namespace: Soroswap Shadow",
  );
});

const camel = (key: string) => key.replace(/-([a-z0-9])/g, (_, c: string) => c.toUpperCase());

Deno.test({
  name: "v2_errors.ts names the errors of the WASMs the owner's v2 deployment runs",
  ignore: !exists("backend/supabase/functions/_shared/deployments/testnet-v2.json"),
  fn() {
    const v2 = deploymentsByName("testnet").v2;
    assert(v2, "testnet-v2.json isn't bundled: import it in deployments/index.ts and add it to BUNDLED_V2");
    for (const [contract, sha256] of Object.entries(V2_ERRORS_FROM)) {
      const deployed = v2.wasmHashes[camel(contract)];
      if (deployed) assertEquals(sha256, deployed, `${contract}: regenerate v2_errors.ts from the deployed dist`);
    }
  },
});

// ------------------------------------------------------------------------------------------------ deployments and pins

const C = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const G = (n: number) => StrKey.encodeEd25519PublicKey(new Uint8Array(32).fill(n) as any);
const H = (n: number) => n.toString(16).padStart(2, "0").repeat(32);

/** A v2 deployment file as deploy-contracts-v2.ts's deploymentRecord() writes it. */
function record(deployment: "testnet" | "testnet-qa", aquarius = false): Record<string, any> {
  const qa = deployment === "testnet-qa";
  return {
    network: "testnet",
    deployment,
    name: qa ? "testnet-qa-v2" : "testnet-v2",
    generation: 1,
    salts: `sha256("dyorhq/v2/${deployment}/g1/<contract>")`,
    deployer: G(1),
    contracts: {
      execSoroswap: C(1),
      ...(aquarius ? { execAquarius: C(10) } : {}),
      ...(qa ? { qaExecFail: C(6) } : {}),
      lpLocker: C(2),
      momentsGraduator: C(3),
      launchpadV2: C(4),
      momentsV2: C(5),
      ...(qa ? { momentsGraduatorQaFail: C(7), momentsV2QaFail: C(8) } : {}),
    },
    wasmHashes: {
      launchpadV2: H(1),
      launchTokenV2: H(2),
      execSoroswap: H(3),
      ...(aquarius ? { execAquarius: H(10) } : {}),
      ...(qa ? { qaExecFail: H(9) } : {}),
      lpLocker: H(4),
      momentsV2: H(5),
      momentNft: H(6),
      momentCoin: H(7),
      momentsGraduator: H(8),
    },
    venues: [
      { id: 0, kind: "Soroswap", executor: C(1), feeFraction: 0, enabled: true },
      ...(aquarius ? [{ id: 1, kind: "Aquarius", executor: C(10), feeFraction: 30, enabled: true }] : []),
      ...(qa ? [{ id: 2, kind: "QaFail", executor: C(6), feeFraction: 0, enabled: true }] : []),
    ],
    quotes: {
      XLM: { phantom: "300000000000", threshold: "800000000000", enabled: true, venues_allowed: [], fallback_venue: 0 },
    },
    aquarius: {
      enabled: aquarius,
      reason: aquarius ? null : "--aquarius off",
      router: TESTNET.contracts.aquariusRouter,
      target: null,
    },
    roles: {
      admin: G(2),
      governance: G(2),
      launchpadGuardian: G(3),
      momentsGuardian: G(4),
      treasury: G(5),
      platform: G(5),
      ...(qa ? { qaAdmin: G(6), qaIssuer: G(7) } : {}),
    },
    ...(qa ? { qaAsset: { code: "DYORQA", issuer: G(7), sac: C(9) } } : {}),
    durations: {
      set: qa ? "testnet-qa" : "production",
      launch: qa ? TESTNET_QA_LAUNCH_DURATIONS : PRODUCTION_LAUNCH_DURATIONS,
      moments: qa ? TESTNET_QA_MOMENTS_DURATIONS : PRODUCTION_MOMENTS_DURATIONS,
    },
    ttl: { threshold: 120_960, extend_to: 518_400 },
    economics: `backend/scripts/economics/${qa ? "testnet-qa-v2" : "testnet-v2"}.json`,
    deployLedger: 5_300_000,
    deployedAt: "2026-10-15T18:00:00.000Z",
  };
}

const PINS = "ios/Packages/StellarKit/Sources/StellarCore/Network/PinnedContracts+Testnet.swift";
const SPONSOR = /sponsor: "(G[A-Z2-7]{55})"/.exec(Deno.readTextFileSync(`${ROOT}${PINS}`))![1];
const V1_ROLES = [
  "launchpad",
  "moments",
  "soroswapRouter",
  "aquariusRouter",
  "blendPool",
  "cctpTokenMessenger",
  "token",
];
const ownerFile = exists("backend/supabase/functions/_shared/deployments/testnet-v2.json");

Deno.test("PinnedContracts+Testnet.swift is what gen-pinned.ts generates for testnet", () => {
  assertEquals(
    renderPins(withDeployment(TESTNET, "testnet"), "testnet", SPONSOR),
    Deno.readTextFileSync(`${ROOT}${PINS}`),
  );
});

Deno.test({
  name: "without a v2 deployment file nothing is pinned for v2, and v1's pins and allowlist are unchanged",
  ignore: ownerFile,
  fn() {
    const net = withDeployment(TESTNET, "testnet");
    assertEquals(net.deploymentV2, null);
    assertEquals([
      net.contracts.launchpadV2,
      net.contracts.momentsV2,
      net.contracts.lpLocker,
      net.contracts.execSoroswap,
      net.contracts.momentsGraduator,
    ], [null, null, null, null, null]);
    assertEquals([net.contracts.launchpad, net.contracts.moments], [
      TESTNET.deployment!.launchpad,
      TESTNET.deployment!.moments,
    ]);
    assertEquals(Object.keys(contractAllowlist(net)), V1_ROLES);
    const pins = renderPins(net, "testnet", SPONSOR);
    for (const v2Only of ["launchpadV2", "runtimeWasmHashes", "durations", "maxLaunchFeeStroops", "testnet-v2"]) {
      assertFalse(pins.includes(v2Only), v2Only);
    }
  },
});

Deno.test("a v2 deployment pins its roles, runtime WASM hashes, both duration sets and the 10 XLM bound, and nothing secret", () => {
  const raw = record("testnet");
  const v2 = parseDeploymentV2("testnet-v2", raw);
  assertEquals(v2.runtimeWasmHashes, { launchTokenV2: H(2), momentNft: H(6), momentCoin: H(7) });
  assertEquals([v2.contracts.execAquarius, v2.qa, v2.qaAsset, v2.saltGeneration], [null, null, null, 1]);
  const net = withDeploymentV2(TESTNET, v2);
  assertEquals(net.contracts.launchpadV2, C(4));
  const allow = contractAllowlist(net);
  assertEquals(Object.keys(allow), [
    "launchpad",
    "moments",
    "launchpadV2",
    "momentsV2",
    "lpLocker",
    "execSoroswap",
    "momentsGraduator",
    ...V1_ROLES.slice(2),
  ]);
  assertEquals([allow.launchpadV2, allow.lpLocker, allow.execSoroswap, allow.momentsGraduator], [
    [C(4)],
    [C(2)],
    [C(1)],
    [C(3)],
  ]);
  assertEquals(net.maxLaunchFeeStroops, 100_000_000n);

  const pins = renderPins(net, "testnet", SPONSOR);
  assertStringIncludes(
    pins,
    "from networks.ts and deployments/testnet.json and deployments/testnet-v2.json — do not edit.",
  );
  assertStringIncludes(pins, `            "launchpadV2": ["${C(4)}"],\n            "momentsV2": ["${C(5)}"],`);
  assertStringIncludes(
    pins,
    `            "launchTokenV2": "${H(2)}",\n            "momentNft": "${H(6)}",\n            "momentCoin": "${
      H(7)
    }",`,
  );
  for (
    const line of [
      "fallbackDelay: 3_600,",
      "rescuePublic: 2_592_000,",
      "harvestInterval: 3_600",
      "pendingBackstop: 2_592_000,",
      "vestPeriod: 2_592_000,",
    ]
  ) {
    assertStringIncludes(pins, line);
  }
  assertStringIncludes(pins, "        maxLaunchFeeStroops: 100_000_000\n    )\n}\n");
  // v1 stays pinned beside it.
  assertStringIncludes(pins, `launchTokenWasmHash: "${TESTNET.deployment!.launchTokenWasmHash}",`);
  // No Aquarius executor on a deployment without it, and none of the deployment's accounts: no treasury, no admin.
  assertFalse(pins.includes("execAquarius"));
  for (const account of Object.values(raw.roles as Record<string, string>).concat(raw.deployer)) {
    assertFalse(pins.includes(account), account);
  }
  assertFalse(/S[A-Z2-7]{55}/.test(pins), "no secret key");
});

Deno.test("execAquarius is a role only where the deployment has the Aquarius venue", () => {
  const v2 = parseDeploymentV2("testnet-v2", record("testnet", true));
  assertEquals(v2.contracts.execAquarius, C(10));
  const allow = contractAllowlist(withDeploymentV2(TESTNET, v2));
  assertEquals(allow.execAquarius, [C(10)]);
  assertStringIncludes(renderPins(withDeploymentV2(TESTNET, v2), "testnet", SPONSOR), `"execAquarius": ["${C(10)}"],`);
});

Deno.test("testnet-qa's qa-exec-fail and failing Moments stack are parsed for the indexer and the e2e, never pinned (finding F4)", () => {
  const v2 = parseDeploymentV2("testnet-qa-v2", record("testnet-qa"));
  assertEquals(v2.qa, { qaExecFail: C(6), momentsV2QaFail: C(8), momentsGraduatorQaFail: C(7) });
  assertEquals(v2.qaAsset, { code: "DYORQA", issuer: G(7), sac: C(9) });
  assertEquals(v2.venues.map((v) => v.kind), ["Soroswap", "QaFail"]);
  const net = withDeploymentV2({
    ...TESTNET,
    deployment: null,
    contracts: { ...TESTNET.contracts, launchpad: null, moments: null },
  }, v2);
  const pinned = Object.values(contractAllowlist(net)).flat();
  for (const id of [C(6), C(7), C(8)]) assertFalse(pinned.includes(id), id);
  const pins = renderPins(net, "testnet-qa", SPONSOR);
  assertStringIncludes(pins, "static let testnetQA = PinnedContracts(");
  assertStringIncludes(pins, "from networks.ts and deployments/testnet-qa-v2.json — do not edit.");
  assertStringIncludes(pins, 'launchTokenWasmHash: "",');
  assertStringIncludes(pins, "fallbackDelay: 60,");
  for (const id of [C(6), C(7), C(8), C(9)]) assertFalse(pins.includes(id), id);
  for (const word of ["qaExecFail", "QaFail", "DYORQA"]) assertFalse(pins.includes(word), word);
  // A QA contract that reached the roles anyway is refused.
  const leaked = { ...net, contracts: { ...net.contracts, lpLocker: C(6) } };
  assertThrows(() => renderPins(leaked, "testnet-qa", SPONSOR), Error, "finding F4");
});

Deno.test("a v2 deployment file is refused when it holds what the deploy wouldn't have written", () => {
  const refused = (id: string, raw: Record<string, any>, message: string) =>
    assertThrows(() => parseDeploymentV2(id, raw), Error, message);
  const qaOnTestnet = record("testnet");
  qaOnTestnet.contracts.qaExecFail = C(6);
  refused("testnet-v2", qaOnTestnet, "testnet-qa only");
  const qaDurations = record("testnet");
  qaDurations.durations = record("testnet-qa").durations;
  refused("testnet-v2", qaDurations, "deploys the production set");
  const noFailingStack = record("testnet-qa");
  delete noFailingStack.contracts.momentsV2QaFail;
  refused("testnet-qa-v2", noFailingStack, "finding F5");
  const aquariusOff = record("testnet");
  aquariusOff.contracts.execAquarius = C(10);
  refused("testnet-v2", aquariusOff, "exactly when aquarius.enabled");
  const strangeExecutor = record("testnet");
  strangeExecutor.venues[0].executor = C(11);
  refused("testnet-v2", strangeExecutor, "isn't this deployment's");
  const noRuntimeHash = record("testnet");
  delete noRuntimeHash.wasmHashes.momentCoin;
  refused("testnet-v2", noRuntimeHash, "wasmHashes.momentCoin");
  const moments = (id: "testnet" | "testnet-qa", change: Record<string, number>) => {
    const raw = record(id);
    raw.durations = { ...raw.durations, moments: { ...raw.durations.moments, ...change } };
    return raw;
  };
  refused(
    "testnet-v2",
    moments("testnet", { harvest_interval: 7_200 }),
    "durations.moments.harvest_interval is 7200 s",
  );
  // The values are checked, not only the label: the QA values called production, values dyor-common refuses (a
  // backstop under 4 × stuck_expiry, a duration over 400 days), and production values called testnet-qa.
  refused(
    "testnet-v2",
    { ...record("testnet"), durations: { ...record("testnet-qa").durations, set: "production" } },
    "durations.launch.grace is 60 s: the production set has 3600 s (§14.3)",
  );
  refused(
    "testnet-v2",
    moments("testnet", { pending_backstop: 86_400 }),
    "durations.moments.pending_backstop is 86400 s",
  );
  refused("testnet-v2", moments("testnet", { max_window: 401 * 86_400 }), "durations.moments.max_window is 34646400 s");
  refused(
    "testnet-qa-v2",
    { ...record("testnet-qa"), durations: { ...record("testnet").durations, set: "testnet-qa" } },
    "durations.launch.grace is 3600 s: the testnet-qa set has 60 s",
  );
  const noBackstop = record("testnet");
  const { pending_backstop: _, ...rest } = noBackstop.durations.moments;
  noBackstop.durations = { ...noBackstop.durations, moments: rest };
  refused("testnet-v2", noBackstop, "durations.moments.pending_backstop");
  refused("testnet-qa-v2", record("testnet"), "it is testnet's v2 deployment, not testnet-qa-v2");
  refused("testnet-v2", { ...record("testnet"), network: "mainnet" }, "testnet only (decision O4)");
  const unknownContract = record("testnet");
  unknownContract.contracts.treasury = C(12);
  refused("testnet-v2", unknownContract, "contracts: unknown treasury");
});

Deno.test("LITE_DEPLOYMENT names both generations; withDeploymentV2 attaches or clears v2", () => {
  assertThrows(() => deploymentsByName("staging"), Error, 'Unknown deployment "staging"');
  assertThrows(() => deploymentsByName("testnet-v2"), Error, "Unknown deployment");
  assertEquals(deploymentsByName("mainnet"), { v1: null, v2: null });
  assertEquals(withDeployment(MAINNET, "mainnet").deploymentV2, null);
  if (
    !exists("backend/supabase/functions/_shared/deployments/testnet-qa.json") &&
    !exists("backend/supabase/functions/_shared/deployments/testnet-qa-v2.json")
  ) {
    assertThrows(() => deploymentsByName("testnet-qa"), Error, "exist only where they were made");
  }
  const v2 = withDeploymentV2(TESTNET, parseDeploymentV2("testnet-v2", record("testnet")));
  const cleared = withDeploymentV2(v2, null);
  assertEquals([cleared.deploymentV2, cleared.contracts.launchpadV2, cleared.contracts.momentsGraduator], [
    null,
    null,
    null,
  ]);
  assertEquals(contractAllowlist(cleared), contractAllowlist(TESTNET));
});

Deno.test("a v2 file's durations are held to the deploy profile's sets, which are dyor-common's", () => {
  assertEquals(DURATION_SETS_V2, {
    production: { launch: PRODUCTION_LAUNCH_DURATIONS, moments: PRODUCTION_MOMENTS_DURATIONS },
    "testnet-qa": { launch: TESTNET_QA_LAUNCH_DURATIONS, moments: TESTNET_QA_MOMENTS_DURATIONS },
  });
});

// ------------------------------------------------------------------------------------------------ the hosted functions

const DEPLOYMENTS_DIR = "backend/supabase/functions/_shared/deployments";

Deno.test("testnet's deployments are served without reading a file, as a hosted function must (no sync reads in a handler)", async () => {
  // A fresh copy of the module, loaded as a hosted function loads it. Supabase then refuses synchronous file reads,
  // inside Deno.serve's handler, where env.network first selects a deployment.
  const fresh: typeof import("../../supabase/functions/_shared/deployments/index.ts") = await import(
    new URL("../../supabase/functions/_shared/deployments/index.ts?hosted", import.meta.url).href
  );
  const blocked = ["readTextFileSync", "readFileSync", "statSync", "lstatSync", "openSync", "readDirSync"] as const;
  const deno = Deno as unknown as Record<string, unknown>;
  const saved = blocked.map((fn) => [fn, deno[fn]] as const);
  for (const fn of blocked) {
    deno[fn] = () => {
      throw new Error(`Deno.${fn} is blocklisted on the current context`);
    };
  }
  try {
    const { v1, v2 } = fresh.deploymentsByName("testnet");
    assertEquals(v1, TESTNET.deployment);
    assertEquals(v2 === null, !Object.hasOwn(fresh.BUNDLED_V2, "testnet-v2"));
    assertEquals(fresh.deploymentV2ByName("testnet"), v2, "and again, from the cache");
    assertEquals(fresh.deploymentsByName("mainnet"), { v1: null, v2: null });
    // testnet-qa is served only where it was made (local-stack.sh), from its files.
    assertThrows(() => fresh.deploymentsByName("testnet-qa"), Error, "blocklisted");
  } finally {
    for (const [fn, original] of saved) deno[fn] = original;
  }
});

Deno.test("testnet's v2 file is served only from BUNDLED_V2, and gen-pinned.ts refuses one that isn't bundled", async () => {
  assertEquals(Object.keys(BUNDLED_V2).filter((f) => f !== "testnet-v2"), [], "testnet-qa-v2.json is never bundled");
  // Here: a testnet-v2.json that is there is bundled.
  assertEquals(unbundledV2("testnet", withDeployment(TESTNET, "testnet")), null);
  const root = await Deno.makeTempDir();
  try {
    const v1Only = withDeploymentV2(TESTNET, null);
    assertEquals(unbundledV2("testnet", v1Only, `${root}/`), null, "no file yet");
    await Deno.mkdir(`${root}/${DEPLOYMENTS_DIR}`, { recursive: true });
    await Deno.writeTextFile(`${root}/${DEPLOYMENTS_DIR}/testnet-v2.json`, JSON.stringify(record("testnet")));
    assertStringIncludes(
      unbundledV2("testnet", v1Only, `${root}/`)!,
      "deployments/testnet-v2.json is there but the functions don't serve it: import it in deployments/index.ts",
    );
    const bundled = withDeploymentV2(TESTNET, parseDeploymentV2("testnet-v2", record("testnet")));
    assertEquals(unbundledV2("testnet", bundled, `${root}/`), null);
    assertEquals(unbundledV2("mainnet", MAINNET, `${root}/`), null);
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});

Deno.test({
  name: "the owner's testnet-v2.json is bundled with the functions (BUNDLED_V2), and it is testnet's v2 deployment",
  ignore: !ownerFile,
  fn() {
    const file = JSON.parse(Deno.readTextFileSync(`${ROOT}${DEPLOYMENTS_DIR}/testnet-v2.json`));
    assertEquals(
      BUNDLED_V2["testnet-v2"],
      file,
      "import testnet-v2.json in deployments/index.ts and add it to BUNDLED_V2",
    );
    assertEquals(deploymentsByName("testnet").v2, parseDeploymentV2("testnet-v2", BUNDLED_V2["testnet-v2"]));
  },
});

// ------------------------------------------------------------------------------------------------ gen-pinned's dist check

Deno.test("with v2 pinned, gen-pinned.ts refuses a contracts/dist that lacks a v2 WASM or isn't what the deployment uploaded", () => {
  const v2 = parseDeploymentV2("testnet-v2", record("testnet"));
  // The deployed WASMs; qa-exec-fail and exec-aquarius, which this deployment didn't upload, as the build left them.
  const dist = (Object.keys(V2_CONTRACT_TAGS) as WasmKey[]).map((key): DistWasm => ({
    key,
    file: `contracts/dist/dyor_${key.replace(/-/g, "_")}.wasm`,
    bytes: new Uint8Array([0]),
    sha256: v2.wasmHashes[camel(key)] ?? H(99),
  }));
  assertEquals(distMismatch(v2, dist), null);
  assertEquals(
    distMismatch(null, dist.map((w) => ({ ...w, bytes: null, sha256: null }))),
    null,
    "no v2: anything goes",
  );
  const rebuilt = dist.map((w) => (w.key === "lp-locker" ? { ...w, sha256: H(98) } : w));
  assertStringIncludes(
    distMismatch(v2, rebuilt)!,
    "contracts/dist isn't what deployments/testnet-v2.json deployed (lp-locker)",
  );
  const absent = dist.map((w) => (w.key === "moment-coin" ? { ...w, bytes: null, sha256: null } : w));
  assertStringIncludes(distMismatch(v2, absent)!, "contracts/dist lacks contracts/dist/dyor_moment_coin.wasm");
  // An Aquarius executor the deployment uploaded is held to its hash too.
  const withAquarius = parseDeploymentV2("testnet-v2", record("testnet", true));
  assertStringIncludes(distMismatch(withAquarius, dist)!, "deployed (exec-aquarius)");
});
