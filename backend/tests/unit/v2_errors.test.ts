// The v2 error-name table (_shared/v2_errors.ts, docs/DESIGN-stellar-contracts-v2.md §4, finding V10) and the rest of
// what backend/scripts/gen-pinned.ts generates from the registry (§20.1): the v2 deployment files, the allowlist and the
// app's pins, with v1 unchanged while no v2 file exists.
import { StrKey } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertFalse, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { generateErrors, renderPins } from "../../scripts/gen-pinned.ts";
import {
  PRODUCTION_LAUNCH_DURATIONS,
  PRODUCTION_MOMENTS_DURATIONS,
  TESTNET_QA_LAUNCH_DURATIONS,
  TESTNET_QA_MOMENTS_DURATIONS,
} from "../../scripts/lib/v2-profile.ts";
import { deploymentsByName, parseDeploymentV2 } from "../../supabase/functions/_shared/deployments/index.ts";
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

Deno.test({
  name: "v2_errors.ts names the errors of the WASMs the owner's v2 deployment runs",
  ignore: !exists("backend/supabase/functions/_shared/deployments/testnet-v2.json"),
  fn() {
    const v2 = deploymentsByName("testnet").v2!;
    for (const [contract, sha256] of Object.entries(V2_ERRORS_FROM)) {
      const deployed = v2.wasmHashes[contract.replace(/-([a-z0-9])/g, (_, c: string) => c.toUpperCase())];
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
  const intervals = record("testnet");
  intervals.durations = {
    ...intervals.durations,
    moments: { ...intervals.durations.moments, harvest_interval: 7_200 },
  };
  refused("testnet-v2", intervals, "harvest_interval differ");
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

Deno.test({
  name: "the owner's testnet-v2.json is bundled with the functions (imported), not only read from disk",
  ignore: !ownerFile,
  fn() {
    const index = Deno.readTextFileSync(`${ROOT}backend/supabase/functions/_shared/deployments/index.ts`);
    assert(
      /import \w+ from "\.\/testnet-v2\.json" with \{ type: "json" \};/.test(index),
      "import testnet-v2.json in deployments/index.ts and add it to BUNDLED_V2",
    );
    assert(deploymentsByName("testnet").v2, "testnet's v2 deployment");
  },
});
