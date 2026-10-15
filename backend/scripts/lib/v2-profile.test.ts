// The deployment profiles (decisions O3, O4): the duration sets equal dyor-common's, and testnet-qa's pieces are refused
// everywhere else.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  checkDurations,
  guard,
  launchDurationsError,
  momentsDurationsError,
  PRODUCTION_LAUNCH_DURATIONS,
  PRODUCTION_MOMENTS_DURATIONS,
  profileFor,
  roleRuleErrors,
  singletonsFor,
  TESTNET_QA_LAUNCH_DURATIONS,
  TESTNET_QA_MOMENTS_DURATIONS,
  TESTNET_TTL_POLICY,
} from "./v2-profile.ts";

const root = new URL("../../../", import.meta.url).pathname;

/** The duration sets as contracts/common/src/durations.rs defines them, evaluated from the Rust source. */
function rustSets(): Record<string, Record<string, number>> {
  const src = Deno.readTextFileSync(`${root}contracts/common/src/durations.rs`);
  const units: Record<string, number> = { MINUTE: 60, HOUR: 3_600, DAY: 86_400 };
  const out: Record<string, Record<string, number>> = {};
  for (const m of src.matchAll(/pub const (\w+): (?:LaunchDurations|MomentsDurations) = \w+ \{([^}]*)\};/g)) {
    const fields: Record<string, number> = {};
    for (const f of m[2].matchAll(/(\w+):\s*([^,\n]+),/g)) {
      const expr = f[2].trim();
      const parts = expr.split("*").map((p) => p.trim());
      fields[f[1]] = parts.reduce((acc, p) => acc * (units[p] ?? Number(p)), 1);
      assert(Number.isFinite(fields[f[1]]), `can't evaluate ${f[1]}: ${expr}`);
    }
    out[m[1]] = fields;
  }
  return out;
}

Deno.test("the production and testnet-qa sets equal dyor-common's, fallback_delay, harvest_interval and pending_backstop included", () => {
  const rust = rustSets();
  assertEquals(Object.keys(rust).sort(), ["PRODUCTION_LAUNCH_DURATIONS", "PRODUCTION_MOMENTS_DURATIONS", "TESTNET_QA_LAUNCH_DURATIONS", "TESTNET_QA_MOMENTS_DURATIONS"]);
  assertEquals({ ...PRODUCTION_LAUNCH_DURATIONS }, rust.PRODUCTION_LAUNCH_DURATIONS);
  assertEquals({ ...PRODUCTION_MOMENTS_DURATIONS }, rust.PRODUCTION_MOMENTS_DURATIONS);
  assertEquals({ ...TESTNET_QA_LAUNCH_DURATIONS }, rust.TESTNET_QA_LAUNCH_DURATIONS);
  assertEquals({ ...TESTNET_QA_MOMENTS_DURATIONS }, rust.TESTNET_QA_MOMENTS_DURATIONS);
  for (const k of ["fallback_delay", "harvest_interval"]) assert(k in rust.PRODUCTION_LAUNCH_DURATIONS, k);
  for (const k of ["pending_backstop", "harvest_interval"]) assert(k in rust.PRODUCTION_MOMENTS_DURATIONS, k);
  // §14.3, spot checks.
  assertEquals([PRODUCTION_LAUNCH_DURATIONS.fallback_delay, PRODUCTION_LAUNCH_DURATIONS.harvest_interval], [3_600, 3_600]);
  assertEquals(PRODUCTION_MOMENTS_DURATIONS.pending_backstop, 30 * 86_400);
  assertEquals([TESTNET_QA_LAUNCH_DURATIONS.fallback_delay, TESTNET_QA_MOMENTS_DURATIONS.pending_backstop], [60, 1_800]);
});

Deno.test("the TTL policy equals dyor-common's TESTNET_TTL_POLICY", () => {
  const src = Deno.readTextFileSync(`${root}contracts/common/src/ttl.rs`);
  const m = src.match(/TESTNET_TTL_POLICY: TtlPolicy = TtlPolicy \{ threshold: (\d+) \* DAY_IN_LEDGERS, extend_to: (\d+) \* DAY_IN_LEDGERS \}/)!;
  assertEquals({ ...TESTNET_TTL_POLICY }, { threshold: Number(m[1]) * 17_280, extend_to: Number(m[2]) * 17_280 });
});

Deno.test("both sets pass dyor-common's rules, and a broken set is named", () => {
  for (const d of [PRODUCTION_LAUNCH_DURATIONS, TESTNET_QA_LAUNCH_DURATIONS]) assertEquals(launchDurationsError(d), null);
  for (const d of [PRODUCTION_MOMENTS_DURATIONS, TESTNET_QA_MOMENTS_DURATIONS]) assertEquals(momentsDurationsError(d), null);
  assertEquals(launchDurationsError({ ...PRODUCTION_LAUNCH_DURATIONS, fallback_delay: 8 * 86_400 }), "fallback_delay is after rescue_admin");
  assertEquals(launchDurationsError({ ...PRODUCTION_LAUNCH_DURATIONS, harvest_interval: 86_401 }), "harvest_interval is above a day");
  assertEquals(momentsDurationsError({ ...PRODUCTION_MOMENTS_DURATIONS, pending_backstop: 4 * 604_800 - 1 }), "pending_backstop is below 4 × stuck_expiry");
});

Deno.test("mainnet and unknown deployment names are refused", () => {
  assertThrows(() => profileFor("mainnet"), Error, "decision O4");
  for (const n of ["", "testnet-v2", "futurenet", "Testnet"]) assertThrows(() => profileFor(n), Error, "unknown deployment");
  assertEquals(profileFor("testnet").name, "testnet");
  assertEquals(profileFor("testnet-qa").name, "testnet-qa");
});

Deno.test("QA durations, qa-exec-fail, the failing Moments stack, key generation and SMOKE=1 are refused for testnet", () => {
  const t = profileFor("testnet");
  assertThrows(() => guard(t, { durations: "testnet-qa" }), Error, "the QA duration set is refused for testnet");
  assertThrows(() => guard(t, { qaExecFail: true }), Error, "qa-exec-fail is refused for testnet");
  assertThrows(() => guard(t, { failingMomentsStack: true }), Error, "the failing Moments stack is refused for testnet");
  assertThrows(() => guard(t, { keyGeneration: true }), Error, "key generation is refused for testnet");
  assertThrows(() => guard(t, { smoke: true }), Error, "SMOKE=1 is refused for testnet");
  assertEquals(guard(t, { durations: "production" }), t);
  const qa = profileFor("testnet-qa");
  assertEquals(guard(qa, { durations: "testnet-qa", qaExecFail: true, failingMomentsStack: true, keyGeneration: true, smoke: true }), qa);
  assertThrows(() => guard(qa, { durations: "production" }), Error, "only the testnet-qa duration set");
});

Deno.test("any duration set but the profile's own is refused, field by field", () => {
  const t = profileFor("testnet");
  checkDurations(t, { ...PRODUCTION_LAUNCH_DURATIONS }, { ...PRODUCTION_MOMENTS_DURATIONS });
  assertThrows(() => checkDurations(t, { ...TESTNET_QA_LAUNCH_DURATIONS }, { ...PRODUCTION_MOMENTS_DURATIONS }), Error, "launch durations.grace");
  assertThrows(() => checkDurations(t, { ...PRODUCTION_LAUNCH_DURATIONS, harvest_interval: 60 }, { ...PRODUCTION_MOMENTS_DURATIONS }), Error, "harvest_interval");
  assertThrows(() => checkDurations(t, { ...PRODUCTION_LAUNCH_DURATIONS, fallback_delay: 60 }, { ...PRODUCTION_MOMENTS_DURATIONS }), Error, "fallback_delay");
  assertThrows(() => checkDurations(t, { ...PRODUCTION_LAUNCH_DURATIONS }, { ...PRODUCTION_MOMENTS_DURATIONS, pending_backstop: 1_800 }), Error, "pending_backstop");
  const qa = profileFor("testnet-qa");
  checkDurations(qa, { ...TESTNET_QA_LAUNCH_DURATIONS }, { ...TESTNET_QA_MOMENTS_DURATIONS });
  assertThrows(() => checkDurations(qa, { ...PRODUCTION_LAUNCH_DURATIONS }, { ...TESTNET_QA_MOMENTS_DURATIONS }), Error, "testnet-qa set");
});

Deno.test("a launchpad guardian equal to the admin, or a Moments guardian equal to governance, is refused", () => {
  const A = "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ";
  const B = "GAYMY43ASKVRTMJGS55BD3B3HKMHY4FETF4HUDVXRGZHMUUWFCFEINBT";
  assertEquals(roleRuleErrors({ ADMIN_PUBLIC: A, LAUNCHPAD_GUARDIAN_PUBLIC: A }).length, 1);
  assertEquals(roleRuleErrors({ GOVERNANCE_PUBLIC: A, MOMENTS_GUARDIAN_PUBLIC: A }).length, 1);
  // Allowed: governance = admin, one guardian for both roles, platform = treasury.
  assertEquals(
    roleRuleErrors({
      ADMIN_PUBLIC: A,
      GOVERNANCE_PUBLIC: A,
      LAUNCHPAD_GUARDIAN_PUBLIC: B,
      MOMENTS_GUARDIAN_PUBLIC: B,
      TREASURY_PUBLIC: B,
      PLATFORM_PUBLIC: B,
    }),
    [],
  );
});

Deno.test("testnet deploys no QA piece; testnet-qa adds qa-exec-fail and the failing Moments stack", () => {
  assertEquals(singletonsFor(profileFor("testnet"), true), ["exec-soroswap", "exec-aquarius", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2"]);
  assertEquals(singletonsFor(profileFor("testnet"), false), ["exec-soroswap", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2"]);
  assertEquals(singletonsFor(profileFor("testnet-qa"), false), [
    "exec-soroswap",
    "qa-exec-fail",
    "lp-locker",
    "moments-graduator",
    "launchpad-v2",
    "moments-v2",
    "moments-graduator-qa-fail",
    "moments-v2-qa-fail",
  ]);
  const t = profileFor("testnet");
  assertEquals([t.qaExecFail, t.failingMomentsStack, t.keyGeneration, t.smoke, t.qaKeysFile], [false, false, false, false, null]);
  assertEquals([t.aquaFloatTargetMultiple, profileFor("testnet-qa").aquaFloatTargetMultiple], [50, 10]);
});
