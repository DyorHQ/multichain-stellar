// The post-deploy wiring read-back (lib/wiring-v2.ts): which views it reads for each deployment, how it compares, and
// what a refusal says. Offline: views come from an in-memory table. The views and Config fields it reads are checked
// against contracts/dist's contractspecv0 (ignored before build.sh has run, as smoke-v2.test.ts does).
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Address, hash, nativeToScVal, StrKey, xdr } from "@stellar/stellar-sdk";
import type { SingletonName } from "./v2-profile.ts";
import { WASMS, type WasmKey } from "./v2-constructors.ts";
import { functionNames, readSpec, udtDefinitions } from "./wasm-spec.ts";
import {
  describeWiringCheck,
  readBackWiring,
  renderWiringRow,
  routerFactoryCheck,
  wiringChecks,
  type WiringPlan,
  wiringProblems,
  wiringVerdict,
} from "./wiring-v2.ts";

const cid = (label: string) => StrKey.encodeContract(hash(Buffer.from(label)));
const FACTORY = "CDP3HMUH6SMS3S7NPGNDJLULCOXXEPSHY4JKUKMBNQMATHDHWXRRJTBY";
const OTHER = cid("other");
const NAMES: SingletonName[] = ["exec-soroswap", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2"];
const QA_NAMES: SingletonName[] = ["qa-exec-fail", "moments-graduator-qa-fail", "moments-v2-qa-fail"];
const ids = (names: SingletonName[]) => Object.fromEntries(names.map((n) => [n, cid(n)])) as Partial<Record<SingletonName, string>>;

/** Native values to ScVals as the contracts return them (addresses, u32 numbers, maps by key). */
function sv(v: unknown): xdr.ScVal {
  if (v === null) return xdr.ScVal.scvVoid();
  if (typeof v === "boolean") return xdr.ScVal.scvBool(v);
  if (typeof v === "number") return nativeToScVal(v, { type: "u32" });
  if (typeof v === "string") return new Address(v).toScVal();
  if (Array.isArray(v)) return xdr.ScVal.scvVec(v.map(sv));
  const o = v as Record<string, unknown>;
  return xdr.ScVal.scvMap(Object.keys(o).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: sv(o[k]) })));
}

/** The views of a correctly wired deployment, as natives by "<contract id> <fn>". */
function wired(p: WiringPlan): Map<string, unknown> {
  const id = (n: SingletonName) => p.ids[n]!;
  const m = new Map<string, unknown>();
  const set = (n: SingletonName, fn: string, v: unknown) => m.set(`${id(n)} ${fn}`, v);
  set("exec-soroswap", "callers", [id("launchpad-v2"), id("moments-graduator")]);
  set("exec-soroswap", "factory", FACTORY);
  const venues = [{ id: 0, kind: 0, executor: id("exec-soroswap"), params: { fee_fraction: 0 }, enabled: true }];
  if (p.ids["exec-aquarius"]) venues.push({ id: venues.length, kind: 1, executor: id("exec-aquarius"), params: { fee_fraction: 30 }, enabled: true });
  if (p.ids["qa-exec-fail"]) venues.push({ id: venues.length, kind: 3, executor: id("qa-exec-fail"), params: { fee_fraction: 0 }, enabled: true });
  set("launchpad-v2", "config", { admin: OTHER, locker: id("lp-locker"), soroswap_factory: FACTORY, aquarius_router: OTHER });
  set("launchpad-v2", "venues", venues);
  set("lp-locker", "soroswap_factory", FACTORY);
  set("lp-locker", "owners", [id("launchpad-v2"), id("moments-v2")]);
  const stacks: [SingletonName, SingletonName, SingletonName][] = [["moments-graduator", "moments-v2", "exec-soroswap"]];
  if (p.ids["qa-exec-fail"]) {
    set("qa-exec-fail", "callers", [id("launchpad-v2"), id("moments-graduator-qa-fail")]);
    stacks.push(["moments-graduator-qa-fail", "moments-v2-qa-fail", "qa-exec-fail"]);
  }
  for (const [g, mo, ex] of stacks) {
    set(g, "moments", id(mo));
    set(g, "executor", id(ex));
    set(g, "locker", id("lp-locker"));
    set(g, "soroswap_factory", FACTORY);
    set(mo, "config", { governance: OTHER, graduator: id(g), locker: id("lp-locker"), executor: id(ex), soroswap_factory: FACTORY });
  }
  return m;
}

function viewOf(table: Map<string, unknown>, reads: string[] = []) {
  return (contract: string, fn: string, args: xdr.ScVal[]) => {
    reads.push(`${contract} ${fn}`);
    assertEquals(args, [], "the read-back's views take no argument");
    const k = `${contract} ${fn}`;
    return table.has(k) ? Promise.resolve(sv(table.get(k))) : Promise.reject(new Error(`no ${fn} on ${contract}`));
  };
}

Deno.test("wiring: testnet reads the executor, the factory everywhere, the locker and the venue table; all pass when wired", async () => {
  const p: WiringPlan = { ids: ids(NAMES), soroswapFactory: FACTORY };
  const checks = wiringChecks(p).map(describeWiringCheck);
  for (
    const c of [
      "exec-soroswap callers() is exactly launchpad-v2 and moments-graduator",
      "exec-soroswap factory() is the Soroswap factory",
      "launchpad-v2 config().soroswap_factory is the Soroswap factory",
      "moments-graduator soroswap_factory() is the Soroswap factory",
      "lp-locker soroswap_factory() is the Soroswap factory",
      "moments-graduator executor() is exec-soroswap",
      "moments-v2 config().executor is exec-soroswap",
      "launchpad-v2 venues() Soroswap venue executor is exec-soroswap",
    ]
  ) assert(checks.includes(c), c);
  assertEquals(checks.length, 15);
  assert(!checks.some((c) => c.includes("qa-") || c.includes("Aquarius")), "no testnet-qa or Aquarius check on a Soroswap-only testnet");
  const reads: string[] = [];
  const rows = await readBackWiring(p, viewOf(wired(p), reads), NO_WAIT);
  assertEquals(wiringProblems(rows), []);
  assert(rows.every((r) => r.ok && renderWiringRow(r).startsWith("✓ ")));
  assertEquals(reads.length, new Set(reads).size, "each view is read once");
  assertEquals(reads.length, 11);
});

Deno.test("wiring: each mismatch is named with the field and both values", async () => {
  const p: WiringPlan = { ids: ids(NAMES), soroswapFactory: FACTORY };
  const exec = p.ids["exec-soroswap"]!;
  const pad = p.ids["launchpad-v2"]!;
  const grad = p.ids["moments-graduator"]!;
  const mo = p.ids["moments-v2"]!;
  const lock = p.ids["lp-locker"]!;
  const cases: [string, unknown, string][] = [
    [`${exec} callers`, [pad], `exec-soroswap callers() is ["${pad}"] on chain; the plan has exactly launchpad-v2 ${pad} and moments-graduator ${grad}`],
    // Exact sets: an extra caller or owner is refused too.
    [`${exec} callers`, [OTHER, grad, pad], `exec-soroswap callers() is ["${OTHER}","${grad}","${pad}"] on chain; the plan has exactly launchpad-v2 ${pad} and moments-graduator ${grad}`],
    [`${lock} owners`, [pad, mo, OTHER], `lp-locker owners() is ["${pad}","${mo}","${OTHER}"] on chain; the plan has exactly launchpad-v2 ${pad} and moments-v2 ${mo}`],
    [`${exec} factory`, OTHER, `exec-soroswap factory() is ${OTHER} on chain; the plan has the Soroswap factory ${FACTORY}`],
    [`${pad} config`, { locker: lock, soroswap_factory: OTHER }, `launchpad-v2 config().soroswap_factory is ${OTHER} on chain; the plan has the Soroswap factory ${FACTORY}`],
    [`${lock} soroswap_factory`, OTHER, `lp-locker soroswap_factory() is ${OTHER} on chain; the plan has the Soroswap factory ${FACTORY}`],
    [`${grad} soroswap_factory`, OTHER, `moments-graduator soroswap_factory() is ${OTHER} on chain; the plan has the Soroswap factory ${FACTORY}`],
    [`${grad} executor`, OTHER, `moments-graduator executor() is ${OTHER} on chain; the plan has exec-soroswap ${exec}`],
    [`${mo} config`, { graduator: grad, locker: lock, executor: OTHER, soroswap_factory: FACTORY }, `moments-v2 config().executor is ${OTHER} on chain; the plan has exec-soroswap ${exec}`],
    [`${pad} venues`, [{ id: 0, kind: 0, executor: OTHER, params: { fee_fraction: 0 }, enabled: true }], `launchpad-v2 venues() Soroswap venue executor is ${OTHER} on chain; the plan has exec-soroswap ${exec}`],
    // No Soroswap venue at all, or two: both refused, the executors listed.
    [`${pad} venues`, [], `launchpad-v2 venues() Soroswap venue executor is [] on chain; the plan has exec-soroswap ${exec}`],
    [
      `${pad} venues`,
      [{ id: 0, kind: 0, executor: exec, params: { fee_fraction: 0 }, enabled: true }, { id: 1, kind: 0, executor: OTHER, params: { fee_fraction: 0 }, enabled: true }],
      `launchpad-v2 venues() Soroswap venue executor is ["${exec}","${OTHER}"] on chain`,
    ],
  ];
  for (const [key, value, message] of cases) {
    const table = wired(p);
    table.set(key, value);
    const rows = await readBackWiring(p, viewOf(table), NO_WAIT);
    const problems = wiringProblems(rows);
    assertEquals(problems.length, 1, `${key}: ${problems.join(" | ")}`);
    assertStringIncludes(problems[0], message);
    assertEquals(wiringVerdict(rows), "mismatch");
  }
  // In any order, the planned callers pass.
  const table = wired(p);
  table.set(`${exec} callers`, [grad, pad]);
  assertEquals(wiringVerdict(await readBackWiring(p, viewOf(table), NO_WAIT)), "ok");
});

const NO_WAIT = { retryMs: 0, sleep: () => Promise.resolve() };

Deno.test("wiring: a failed read is tried once more; one that still fails is unreadable, not a mismatch, unless a value differs too", async () => {
  const p: WiringPlan = { ids: ids(NAMES), soroswapFactory: FACTORY };
  const lock = p.ids["lp-locker"]!;
  const pad = p.ids["launchpad-v2"]!;
  const mo = p.ids["moments-v2"]!;
  const exec = p.ids["exec-soroswap"]!;
  // Fails once (a rate limit), then answers: passes, read twice.
  const table = wired(p);
  const reads: string[] = [];
  const flaky = viewOf(table, reads);
  let failed = false;
  const view = (c: string, fn: string, args: xdr.ScVal[]) => {
    if (c === lock && fn === "owners" && !failed) {
      failed = true;
      reads.push(`${c} ${fn}`);
      return Promise.reject(new Error("rate limited"));
    }
    return flaky(c, fn, args);
  };
  const waits: number[] = [];
  const ok = await readBackWiring(p, view, { retryMs: 1_500, sleep: (ms) => (waits.push(ms), Promise.resolve()) });
  assertEquals(wiringVerdict(ok), "ok");
  assertEquals(reads.filter((r) => r === `${lock} owners`).length, 2);
  assertEquals(waits, [1_500]);
  // Fails twice: one row with the error, and the verdict says to run it again.
  const down = wired(p);
  down.delete(`${lock} owners`);
  const rows = await readBackWiring(p, viewOf(down), NO_WAIT);
  assertEquals(wiringProblems(rows), [`lp-locker owners(): can't read it (no owners on ${lock}); the plan has exactly launchpad-v2 ${pad} and moments-v2 ${mo}`]);
  assertEquals(wiringVerdict(rows), "unreadable");
  // An unreadable view and a value that differs: a mismatch.
  down.set(`${exec} factory`, OTHER);
  assertEquals(wiringVerdict(await readBackWiring(p, viewOf(down), NO_WAIT)), "mismatch");
});

Deno.test("wiring: the Soroswap router's get_factory() is checked against networks.ts", async () => {
  const ROUTER = cid("router");
  const answer = (v: unknown) => () => Promise.resolve(sv(v));
  assertEquals(await routerFactoryCheck(answer(FACTORY), ROUTER, FACTORY, NO_WAIT), { ok: true, line: `✓ the Soroswap router's get_factory() is networks.ts's Soroswap factory ${FACTORY}` });
  assertEquals(await routerFactoryCheck(answer(OTHER), ROUTER, FACTORY, NO_WAIT), { ok: false, line: `✗ the Soroswap router ${ROUTER} get_factory() is ${OTHER}; networks.ts has ${FACTORY}` });
  const fail = () => Promise.reject(new Error("timeout"));
  assertEquals((await routerFactoryCheck(fail, ROUTER, FACTORY, NO_WAIT)).ok, false);
  let n = 0;
  const flaky = () => (++n === 1 ? Promise.reject(new Error("timeout")) : Promise.resolve(sv(FACTORY)));
  assertEquals((await routerFactoryCheck(flaky, ROUTER, FACTORY, NO_WAIT)).ok, true);
});

Deno.test("wiring: testnet-qa checks the failing Moments stack's own wiring, and the Aquarius venue when it is planned", async () => {
  const p: WiringPlan = { ids: { ...ids(NAMES), ...ids(QA_NAMES), "exec-aquarius": cid("exec-aquarius") }, soroswapFactory: FACTORY };
  const checks = wiringChecks(p).map(describeWiringCheck);
  for (
    const c of [
      "qa-exec-fail callers() is exactly launchpad-v2 and moments-graduator-qa-fail",
      "launchpad-v2 venues() QaFail venue executor is qa-exec-fail",
      "launchpad-v2 venues() Aquarius venue executor is exec-aquarius",
      "moments-graduator-qa-fail moments() is moments-v2-qa-fail",
      "moments-graduator-qa-fail executor() is qa-exec-fail",
      "moments-graduator-qa-fail soroswap_factory() is the Soroswap factory",
      "moments-v2-qa-fail config().executor is qa-exec-fail",
      "moments-v2-qa-fail config().graduator is moments-graduator-qa-fail",
    ]
  ) assert(checks.includes(c), c);
  assertEquals(checks.length, 26);
  assertEquals(wiringProblems(await readBackWiring(p, viewOf(wired(p)))), []);
  // The failing stack's graduator pointing at exec-soroswap instead of qa-exec-fail is refused.
  const table = wired(p);
  table.set(`${p.ids["moments-graduator-qa-fail"]} executor`, p.ids["exec-soroswap"]);
  assertEquals(wiringProblems(await readBackWiring(p, viewOf(table))), [
    `moments-graduator-qa-fail executor() is ${p.ids["exec-soroswap"]} on chain; the plan has qa-exec-fail ${p.ids["qa-exec-fail"]}`,
  ]);
});

// ------------------------------------------------------------------------------------------------ against dist

const root = new URL("../../../", import.meta.url).pathname;
const dist = (k: WasmKey) => `${root}contracts/dist/${WASMS[k].file}`;
const distPresent = (["exec-soroswap", "qa-exec-fail", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2"] as WasmKey[]).every((k) => {
  try {
    return Deno.statSync(dist(k)).isFile;
  } catch {
    return false;
  }
});

Deno.test({
  name: "wiring: every view and Config field the read-back uses is in contracts/dist's specs (ignored before build.sh has run)",
  ignore: !distPresent,
  fn() {
    const p: WiringPlan = { ids: { ...ids(NAMES), ...ids(QA_NAMES) }, soroswapFactory: FACTORY };
    const wasmOf: Record<string, WasmKey> = {
      "exec-soroswap": "exec-soroswap",
      "qa-exec-fail": "qa-exec-fail",
      "lp-locker": "lp-locker",
      "moments-graduator": "moments-graduator",
      "moments-graduator-qa-fail": "moments-graduator",
      "launchpad-v2": "launchpad-v2",
      "moments-v2": "moments-v2",
      "moments-v2-qa-fail": "moments-v2",
    };
    const structFields = (k: WasmKey, name: string) => {
      const e = udtDefinitions(readSpec(Deno.readFileSync(dist(k)))).get(name);
      assert(e && e.switch().name === "scSpecEntryUdtStructV0", `${WASMS[k].file} declares struct ${name}`);
      return e.udtStructV0().fields().map((f) => f.name().toString());
    };
    for (const c of wiringChecks(p)) {
      const k = wasmOf[c.contract];
      const fns = functionNames(readSpec(Deno.readFileSync(dist(k))));
      assert(fns.includes(c.fn), `${WASMS[k].file} has ${c.fn}()`);
      const fieldName = c.label.match(/config\(\)\.(\w+)$/)?.[1];
      if (fieldName) assert(structFields(k, "Config").includes(fieldName), `${WASMS[k].file} Config has ${fieldName}`);
    }
    for (const f of ["id", "kind", "executor", "params", "enabled"]) assert(structFields("launchpad-v2", "VenueInfo").includes(f), `VenueInfo.${f}`);
  },
});
