// The post-deploy wiring read-back of deploy-contracts-v2.ts (docs/DESIGN-stellar-contracts-v2.md §3.4, §7, §8, §12).
//
// The constructors don't check the executor's own wiring: exec-soroswap takes its callers and factory on trust, and
// launchpad-v2 takes its venue table as given. A mis-wired executor would make every graduation fail. So after the
// constructors, before any admin call, TTL step or deployment file, the deploy reads the wiring back with read-only
// views (simulation, no transaction) and refuses on any mismatch.
//
// Every expectation here comes from the planned ids and the network's Soroswap factory alone, not from the constructor
// arguments (lib/v2-constructors.ts), so a wrong constructor builder is caught too: the re-run check (contract-ids.ts
// reconcile) compares the chain with those arguments, this compares it with the design's wiring.
//
// The views, by contract (their names are the contracts' own: contracts/*/src, re-checked against dist's
// contractspecv0 by wiring-v2.test.ts):
//   exec-soroswap      callers(), factory()
//   qa-exec-fail       callers()                                    (testnet-qa)
//   lp-locker          owners(), soroswap_factory()
//   moments-graduator  moments(), executor(), locker(), soroswap_factory()   (and moments-graduator-qa-fail)
//   launchpad-v2       config().soroswap_factory, config().locker, venues() (kind, executor)
//   moments-v2         config().graduator, .executor, .locker, .soroswap_factory   (and moments-v2-qa-fail)
import { scValToNative, type xdr } from "@stellar/stellar-sdk";
import { normalize, sameValue } from "./contract-ids.ts";
import { readVenues, VENUE_KIND_VALUE, type VenueKindName } from "./v2-constructors.ts";
import type { SingletonName } from "./v2-profile.ts";

export interface WiringPlan {
  /** Planned ids of this run's singletons. */
  ids: Partial<Record<SingletonName, string>>;
  /** The network's Soroswap factory (networks.ts). */
  soroswapFactory: string;
}

export interface WiringCheck {
  /** The contract, the view and the field read: "launchpad-v2 config().soroswap_factory". */
  label: string;
  contract: SingletonName;
  fn: string;
  /** The compared value, from the view's native result. */
  pick: (native: unknown) => unknown;
  /** "equals": the value is `want`; "contains": the value is a list holding every address of `want`. */
  rule: "equals" | "contains";
  want: string | string[];
  /** What `want` is: "exec-soroswap", "the Soroswap factory", "launchpad-v2 and moments-graduator". */
  wantName: string;
}

export interface WiringRow {
  check: WiringCheck;
  ok: boolean;
  /** The value read; undefined when the view couldn't be read. */
  got?: unknown;
  /** Why the view couldn't be read. */
  error?: string;
}

export type ViewFn = (contract: string, fn: string, args: xdr.ScVal[]) => Promise<xdr.ScVal>;

/** One Moments stack: the graduator, the Moments contract and the executor its graduations call, with the launchpad
 *  venue kind that executor serves. testnet-qa's failing stack is the same wiring around qa-exec-fail (§7.3). */
interface Stack {
  graduator: SingletonName;
  moments: SingletonName;
  executor: SingletonName;
}

const MAIN_STACK: Stack = { graduator: "moments-graduator", moments: "moments-v2", executor: "exec-soroswap" };
const QA_FAIL_STACK: Stack = { graduator: "moments-graduator-qa-fail", moments: "moments-v2-qa-fail", executor: "qa-exec-fail" };

const field = (k: string) => (n: unknown) => (n as Record<string, unknown> | null)?.[k];
const same = (n: unknown) => n;
/** The executor of the one venue of this kind in venues(); every executor of the kind when there isn't exactly one. */
const venueExecutor = (kind: VenueKindName) => (n: unknown) => {
  const of = readVenues(n).filter((v) => v.kind === VENUE_KIND_VALUE[kind]);
  return of.length === 1 ? of[0].executor : of.map((v) => v.executor);
};

/** Every check for a plan: the main stack always, the Aquarius venue when exec-aquarius is planned, and testnet-qa's
 *  failing stack (qa-exec-fail, moments-graduator-qa-fail, moments-v2-qa-fail) when it is planned. */
export function wiringChecks(p: WiringPlan): WiringCheck[] {
  const id = (n: SingletonName): string => {
    const v = p.ids[n];
    if (!v) throw new Error(`the wiring read-back needs ${n}, which this plan doesn't deploy`);
    return v;
  };
  const factory = p.soroswapFactory;
  const out: WiringCheck[] = [];
  const eq = (contract: SingletonName, fn: string, label: string, pick: (n: unknown) => unknown, want: string, wantName: string) =>
    out.push({ label: `${contract} ${label}`, contract, fn, pick, rule: "equals", want, wantName });
  const contains = (contract: SingletonName, fn: string, want: SingletonName[]) =>
    out.push({ label: `${contract} ${fn}()`, contract, fn, pick: same, rule: "contains", want: want.map(id), wantName: want.join(" and ") });

  // The executor: who may call it, and the factory it swaps through.
  contains("exec-soroswap", "callers", ["launchpad-v2", "moments-graduator"]);
  eq("exec-soroswap", "factory", "factory()", same, factory, "the Soroswap factory");
  // The launchpad: its factory, its locker and its venues' executors.
  eq("launchpad-v2", "config", "config().soroswap_factory", field("soroswap_factory"), factory, "the Soroswap factory");
  eq("launchpad-v2", "config", "config().locker", field("locker"), id("lp-locker"), "lp-locker");
  eq("launchpad-v2", "venues", "venues() Soroswap venue executor", venueExecutor("Soroswap"), id("exec-soroswap"), "exec-soroswap");
  if (p.ids["exec-aquarius"]) eq("launchpad-v2", "venues", "venues() Aquarius venue executor", venueExecutor("Aquarius"), id("exec-aquarius"), "exec-aquarius");
  // The locker: its factory and its owners.
  eq("lp-locker", "soroswap_factory", "soroswap_factory()", same, factory, "the Soroswap factory");
  contains("lp-locker", "owners", ["launchpad-v2", "moments-v2"]);

  const stacks = p.ids["moments-graduator-qa-fail"] ? [MAIN_STACK, QA_FAIL_STACK] : [MAIN_STACK];
  for (const s of stacks) {
    if (s.executor === "qa-exec-fail") {
      contains("qa-exec-fail", "callers", ["launchpad-v2", "moments-graduator-qa-fail"]);
      eq("launchpad-v2", "venues", "venues() QaFail venue executor", venueExecutor("QaFail"), id("qa-exec-fail"), "qa-exec-fail");
    }
    // The graduator and its Moments contract name each other, the same executor, locker and factory.
    eq(s.graduator, "moments", "moments()", same, id(s.moments), s.moments);
    eq(s.graduator, "executor", "executor()", same, id(s.executor), s.executor);
    eq(s.graduator, "locker", "locker()", same, id("lp-locker"), "lp-locker");
    eq(s.graduator, "soroswap_factory", "soroswap_factory()", same, factory, "the Soroswap factory");
    eq(s.moments, "config", "config().graduator", field("graduator"), id(s.graduator), s.graduator);
    eq(s.moments, "config", "config().executor", field("executor"), id(s.executor), s.executor);
    eq(s.moments, "config", "config().locker", field("locker"), id("lp-locker"), "lp-locker");
    eq(s.moments, "config", "config().soroswap_factory", field("soroswap_factory"), factory, "the Soroswap factory");
  }
  return out;
}

/** What a check requires, for the dry run's list. */
export function describeWiringCheck(c: WiringCheck): string {
  return c.rule === "contains" ? `${c.label} contains ${c.wantName}` : `${c.label} is ${c.wantName}`;
}

/** Reads every check's view (each contract and view once) and compares. Never throws for a view: a view that can't
 *  be read is a failed row. */
export async function readBackWiring(p: WiringPlan, view: ViewFn): Promise<WiringRow[]> {
  const cache = new Map<string, Promise<unknown>>();
  const read = (contract: string, fn: string) => {
    const k = `${contract} ${fn}`;
    if (!cache.has(k)) cache.set(k, view(contract, fn, []).then((v) => scValToNative(v)));
    return cache.get(k)!;
  };
  const rows: WiringRow[] = [];
  for (const c of wiringChecks(p)) {
    let got: unknown;
    try {
      got = c.pick(await read(p.ids[c.contract]!, c.fn));
    } catch (e) {
      rows.push({ check: c, ok: false, error: (e as Error).message });
      continue;
    }
    const ok = c.rule === "contains"
      ? Array.isArray(got) && (c.want as string[]).every((w) => got.some((x) => sameValue(x, w)))
      : sameValue(got, c.want);
    rows.push({ check: c, ok, got });
  }
  return rows;
}

const show = (v: unknown) => {
  const n = normalize(v);
  return typeof n === "string" ? n : JSON.stringify(n);
};

function wanted(c: WiringCheck): string {
  if (c.rule === "contains") {
    const names = c.wantName.split(" and ");
    return (c.want as string[]).map((w, i) => `${names[i]} ${w}`).join(" and ");
  }
  return `${c.wantName} ${c.want}`;
}

/** One line per row: ✓ or ✗, the field, and on a mismatch both values. */
export function renderWiringRow(r: WiringRow): string {
  if (r.ok) return `✓ ${describeWiringCheck(r.check)}`;
  return `✗ ${wiringProblem(r)}`;
}

function wiringProblem(r: WiringRow): string {
  const c = r.check;
  if (r.error !== undefined) return `${c.label}: can't read it (${r.error}); the plan has ${wanted(c)}`;
  return c.rule === "contains"
    ? `${c.label} is ${show(r.got)} on chain; it must contain ${wanted(c)}`
    : `${c.label} is ${show(r.got)} on chain; the plan has ${wanted(c)}`;
}

/** The refusal lines: one per failed row, naming the field and both values (addresses are public). */
export function wiringProblems(rows: WiringRow[]): string[] {
  return rows.filter((r) => !r.ok).map(wiringProblem);
}
