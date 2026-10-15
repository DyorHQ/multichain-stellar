// The v2 deployment profiles (docs/DESIGN-stellar-contracts-v2.md §14.3, §17; decisions O3, O4): what each deployment
// may deploy and with which durations, and the guards that keep testnet-qa's test-only pieces off every other
// deployment.
//
// - testnet: the owner's deployment (O5). Production durations, no QA venue, no failing Moments stack, no generated
//   keys, no smoke run.
// - testnet-qa: throwaway QA keys, the shortened durations, qa-exec-fail, the failing Moments stack (O3).
// - Everything else, mainnet included, is refused (O4).
//
// The duration sets equal dyor-common's PRODUCTION_* and TESTNET_QA_* (contracts/common/src/durations.rs), with
// fallback_delay, harvest_interval and pending_backstop (findings F6, V11); a test reads the Rust file and compares.

export type V2DeploymentName = "testnet" | "testnet-qa";

/** launchpad-v2's durations in seconds (dyor_common::LaunchDurations). */
export interface LaunchDurations {
  grace: number;
  fallback_delay: number;
  rescue_admin: number;
  rescue_public: number;
  locked_fallback: number;
  takeover_delay: number;
  takeover_window: number;
  timelock: number;
  timelock_window: number;
  harvest_interval: number;
}

/** moments-v2's durations in seconds (dyor_common::MomentsDurations). */
export interface MomentsDurations {
  vest_period: number;
  stuck_expiry: number;
  pending_backstop: number;
  timelock: number;
  timelock_window: number;
  min_window: number;
  max_window: number;
  harvest_interval: number;
}

/** TTL policy in ledgers (dyor_common::TtlPolicy). */
export interface TtlPolicy {
  threshold: number;
  extend_to: number;
}

const MINUTE = 60;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const DAY_IN_LEDGERS = 17_280;

export const PRODUCTION_LAUNCH_DURATIONS: Readonly<LaunchDurations> = Object.freeze({
  grace: HOUR,
  fallback_delay: HOUR,
  rescue_admin: 7 * DAY,
  rescue_public: 30 * DAY,
  locked_fallback: DAY,
  takeover_delay: 3 * DAY,
  takeover_window: 3 * DAY,
  timelock: 48 * HOUR,
  timelock_window: 7 * DAY,
  harvest_interval: HOUR,
});

export const PRODUCTION_MOMENTS_DURATIONS: Readonly<MomentsDurations> = Object.freeze({
  vest_period: 30 * DAY,
  stuck_expiry: 7 * DAY,
  pending_backstop: 30 * DAY,
  timelock: 48 * HOUR,
  timelock_window: 7 * DAY,
  min_window: HOUR,
  max_window: 30 * DAY,
  harvest_interval: HOUR,
});

export const TESTNET_QA_LAUNCH_DURATIONS: Readonly<LaunchDurations> = Object.freeze({
  grace: MINUTE,
  fallback_delay: MINUTE,
  rescue_admin: 5 * MINUTE,
  rescue_public: 15 * MINUTE,
  locked_fallback: 2 * MINUTE,
  takeover_delay: 2 * MINUTE,
  takeover_window: 5 * MINUTE,
  timelock: 2 * MINUTE,
  timelock_window: 10 * MINUTE,
  harvest_interval: MINUTE,
});

export const TESTNET_QA_MOMENTS_DURATIONS: Readonly<MomentsDurations> = Object.freeze({
  vest_period: 10 * MINUTE,
  stuck_expiry: 5 * MINUTE,
  pending_backstop: 30 * MINUTE,
  timelock: 2 * MINUTE,
  timelock_window: 10 * MINUTE,
  min_window: 2 * MINUTE,
  max_window: 30 * DAY,
  harvest_interval: MINUTE,
});

/** Testnet and testnet-qa (§13): bump below 7 days, to 30 days. */
export const TESTNET_TTL_POLICY: Readonly<TtlPolicy> = Object.freeze({ threshold: 7 * DAY_IN_LEDGERS, extend_to: 30 * DAY_IN_LEDGERS });

// dyor-common's bounds (§4).
export const MIN_DURATION = MINUTE;
export const MAX_DURATION = 400 * DAY;
export const MAX_HARVEST_INTERVAL = DAY;

/** The rule a launch duration set breaks, or null (dyor_common::validate_launch_durations). */
export function launchDurationsError(d: LaunchDurations): string | null {
  const all = Object.entries(d);
  const bad = all.find(([, v]) => !Number.isSafeInteger(v) || v < MIN_DURATION || v > MAX_DURATION);
  if (bad) return `${bad[0]} is outside ${MIN_DURATION} s to ${MAX_DURATION} s`;
  if (d.harvest_interval > MAX_HARVEST_INTERVAL) return "harvest_interval is above a day";
  if (d.rescue_public < d.rescue_admin) return "rescue_public is before rescue_admin";
  if (d.grace > d.rescue_admin) return "grace is after rescue_admin";
  if (d.fallback_delay > d.rescue_admin) return "fallback_delay is after rescue_admin";
  if (d.locked_fallback > d.rescue_admin) return "locked_fallback is after rescue_admin";
  return null;
}

/** The rule a Moments duration set breaks, or null (dyor_common::validate_moments_durations). */
export function momentsDurationsError(d: MomentsDurations): string | null {
  const bad = Object.entries(d).find(([, v]) => !Number.isSafeInteger(v) || v < MIN_DURATION || v > MAX_DURATION);
  if (bad) return `${bad[0]} is outside ${MIN_DURATION} s to ${MAX_DURATION} s`;
  if (d.harvest_interval > MAX_HARVEST_INTERVAL) return "harvest_interval is above a day";
  if (d.min_window > d.max_window) return "min_window is above max_window";
  if (d.pending_backstop < 4 * d.stuck_expiry) return "pending_backstop is below 4 × stuck_expiry";
  return null;
}

// ------------------------------------------------------------------------------------------------ profiles

export interface V2Profile {
  name: V2DeploymentName;
  network: "testnet";
  /** Which duration set: the production one everywhere except testnet-qa (§14.3). */
  durationSet: "production" | "testnet-qa";
  launchDurations: Readonly<LaunchDurations>;
  momentsDurations: Readonly<MomentsDurations>;
  ttl: Readonly<TtlPolicy>;
  /** testnet-qa only (O3): the failing venue, the failing Moments stack, generated keys, SMOKE=1. */
  qaExecFail: boolean;
  failingMomentsStack: boolean;
  keyGeneration: boolean;
  smoke: boolean;
  /** backend/scripts/economics/<file>. */
  economicsFile: string;
  /** backend/supabase/functions/_shared/deployments/<file>. */
  deploymentFile: string;
  /** testnet-qa's generated keys (in the secrets directory); null where keys are never generated. */
  qaKeysFile: string | null;
  /** The AQUA float's target and alert, as multiples of the router's pool payment (F11). */
  aquaFloatTargetMultiple: number;
  aquaFloatAlertMultiple: number;
  /** testnet-qa acquires the AQUA float by default; the owner's testnet only with --fund-aqua-float (V8). */
  aquaSwapByDefault: boolean;
}

const PROFILES: Record<V2DeploymentName, V2Profile> = {
  testnet: {
    name: "testnet",
    network: "testnet",
    durationSet: "production",
    launchDurations: PRODUCTION_LAUNCH_DURATIONS,
    momentsDurations: PRODUCTION_MOMENTS_DURATIONS,
    ttl: TESTNET_TTL_POLICY,
    qaExecFail: false,
    failingMomentsStack: false,
    keyGeneration: false,
    smoke: false,
    economicsFile: "testnet-v2.json",
    deploymentFile: "testnet-v2.json",
    qaKeysFile: null,
    aquaFloatTargetMultiple: 50,
    aquaFloatAlertMultiple: 5,
    aquaSwapByDefault: false,
  },
  "testnet-qa": {
    name: "testnet-qa",
    network: "testnet",
    durationSet: "testnet-qa",
    launchDurations: TESTNET_QA_LAUNCH_DURATIONS,
    momentsDurations: TESTNET_QA_MOMENTS_DURATIONS,
    ttl: TESTNET_TTL_POLICY,
    qaExecFail: true,
    failingMomentsStack: true,
    keyGeneration: true,
    smoke: true,
    economicsFile: "testnet-qa-v2.json",
    deploymentFile: "testnet-qa-v2.json",
    qaKeysFile: "testnet-qa-v2.env",
    aquaFloatTargetMultiple: 10,
    aquaFloatAlertMultiple: 5,
    aquaSwapByDefault: true,
  },
};

/** The profile of a deployment name. Mainnet and every other name are refused (O4). */
export function profileFor(name: string): V2Profile {
  if (name === "mainnet") throw new Error("mainnet is refused: v2 is testnet only for now (decision O4)");
  if (name !== "testnet" && name !== "testnet-qa") {
    throw new Error(`unknown deployment "${name}": testnet (the owner's) or testnet-qa`);
  }
  return PROFILES[name];
}

/** What a run asks for, checked against its profile by `guard`. */
export interface V2Request {
  /** "production" or "testnet-qa" durations. */
  durations?: "production" | "testnet-qa";
  qaExecFail?: boolean;
  failingMomentsStack?: boolean;
  keyGeneration?: boolean;
  /** SMOKE=1 in the environment, or a smoke flag. */
  smoke?: boolean;
}

/** Refuses test-only pieces outside testnet-qa (O3). Returns the profile when everything is allowed. */
export function guard(profile: V2Profile, req: V2Request): V2Profile {
  const refuse = (what: string) => {
    throw new Error(`${what} is refused for ${profile.name}: testnet-qa only (decision O3)`);
  };
  if (req.durations && req.durations !== profile.durationSet) {
    if (req.durations === "testnet-qa") refuse("the QA duration set");
    throw new Error(`${profile.name} deploys only the ${profile.durationSet} duration set`);
  }
  if (req.qaExecFail && !profile.qaExecFail) refuse("qa-exec-fail");
  if (req.failingMomentsStack && !profile.failingMomentsStack) refuse("the failing Moments stack");
  if (req.keyGeneration && !profile.keyGeneration) refuse("key generation");
  if (req.smoke && !profile.smoke) refuse("SMOKE=1");
  return profile;
}

/** Refuses any duration set but the profile's own, field by field (§14.3: "refuses any set other than production
 *  for every deployment except testnet-qa", harvest_interval, fallback_delay and pending_backstop included). */
export function checkDurations(profile: V2Profile, launch: LaunchDurations, moments: MomentsDurations): void {
  const diff = (want: object, got: object, what: string) => {
    for (const [k, v] of Object.entries(want)) {
      if ((got as Record<string, unknown>)[k] !== v) {
        throw new Error(`${what}.${k} must be ${v} s on ${profile.name} (the ${profile.durationSet} set)`);
      }
    }
    for (const k of Object.keys(got)) if (!(k in want)) throw new Error(`${what}.${k} is not a duration`);
  };
  diff(profile.launchDurations, launch, "launch durations");
  diff(profile.momentsDurations, moments, "Moments durations");
}

// ------------------------------------------------------------------------------------------------ roles

/** The public roles of a v2 deployment (CT-11a lead decisions L-a, L-f). */
export interface V2Roles {
  ADMIN_PUBLIC: string;
  GOVERNANCE_PUBLIC: string;
  LAUNCHPAD_GUARDIAN_PUBLIC: string;
  MOMENTS_GUARDIAN_PUBLIC: string;
  TREASURY_PUBLIC: string;
  PLATFORM_PUBLIC: string;
}

export const ROLE_NAMES: readonly (keyof V2Roles)[] = [
  "ADMIN_PUBLIC",
  "GOVERNANCE_PUBLIC",
  "LAUNCHPAD_GUARDIAN_PUBLIC",
  "MOMENTS_GUARDIAN_PUBLIC",
  "TREASURY_PUBLIC",
  "PLATFORM_PUBLIC",
];

/** The cross-role rules: the launchpad guardian differs from the admin, the Moments guardian from governance (§16,
 *  CT-11). Allowed: governance = admin, one guardian for both, platform = treasury. */
export function roleRuleErrors(r: Partial<V2Roles>): string[] {
  const errors: string[] = [];
  if (r.LAUNCHPAD_GUARDIAN_PUBLIC && r.LAUNCHPAD_GUARDIAN_PUBLIC === r.ADMIN_PUBLIC) {
    errors.push("LAUNCHPAD_GUARDIAN_PUBLIC must differ from ADMIN_PUBLIC (a guardian that is the admin can't check it)");
  }
  if (r.MOMENTS_GUARDIAN_PUBLIC && r.MOMENTS_GUARDIAN_PUBLIC === r.GOVERNANCE_PUBLIC) {
    errors.push("MOMENTS_GUARDIAN_PUBLIC must differ from GOVERNANCE_PUBLIC");
  }
  return errors;
}

// ------------------------------------------------------------------------------------------------ the contract set

/** The v2 singletons by salt name, in deploy order (§3.4: executors, the locker, the graduator, then launchpad-v2
 *  and moments-v2; the failing Moments stack last). */
export const SINGLETONS = [
  "exec-soroswap",
  "exec-aquarius",
  "qa-exec-fail",
  "lp-locker",
  "moments-graduator",
  "launchpad-v2",
  "moments-v2",
  "moments-graduator-qa-fail",
  "moments-v2-qa-fail",
] as const;
export type SingletonName = typeof SINGLETONS[number];

/** The singletons this deployment deploys. exec-aquarius only when the Aquarius venue is on. */
export function singletonsFor(profile: V2Profile, aquarius: boolean): SingletonName[] {
  return SINGLETONS.filter((n) => {
    if (n === "exec-aquarius") return aquarius;
    if (n === "qa-exec-fail") return profile.qaExecFail;
    if (n === "moments-graduator-qa-fail" || n === "moments-v2-qa-fail") return profile.failingMomentsStack;
    return true;
  });
}
