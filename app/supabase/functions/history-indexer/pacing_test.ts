// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { alchemyEndpoint, DEFAULT_ENDPOINTS, type Endpoint } from "./endpoints.ts";
import { ByteBudget, EndpointState, followRank, minSpanFor, pickEndpoint, SIDELINE_MS, takesPriority } from "./pacing.ts";

const T0 = Date.parse("2026-10-08T12:00:00Z");
const ep = (label: string, over: Partial<Endpoint> = {}): Endpoint => ({ ...DEFAULT_ENDPOINTS.find((e) => e.label === label)!, ...over });
const H = 111_000_000;
const piece = (to: number, priority: 0 | 1 | 2 | 3 = 1, from = to - 99) => ({ from, to, priority });
// rpc2 at its measured pace (4 requests/s, 8 in flight), for the tests of the mechanisms; the default is the launch pace.
const MEASURED = { rps: 4, inFlight: 8 };

Deno.test("pace: never more than rps starts in any 1 s window, never past the in-flight cap", () => {
  const launch = new EndpointState(ep("rpc2"), undefined, T0); // the launch pace: 2 requests/s
  const launched: number[] = [];
  for (let t = T0; t < T0 + 10_000; t += 10) {
    if (launch.ready(t, piece(H - 5_000), H)) { launch.started(t); launched.push(t); launch.finished(t + 5, { kind: "answered" }); }
  }
  assert(launched.length >= 19 && launched.length <= 21, `${launched.length} starts in 10 s at the launch pace`);
  const s = new EndpointState(ep("rpc2", MEASURED), undefined, T0);
  const starts: number[] = [];
  for (let t = T0; t < T0 + 10_000; t += 10) {
    if (s.ready(t, piece(H - 5_000), H)) { s.started(t); starts.push(t); s.finished(t + 5, { kind: "answered" }); }
  }
  assert(starts.length >= 39 && starts.length <= 41, `${starts.length} starts in 10 s`);
  for (const t of starts) assert(starts.filter((x) => x >= t && x < t + 1_000).length <= 4);
  const c = new EndpointState(ep("rpc4"), undefined, T0); // inFlight 2
  c.started(T0); c.started(T0 + 300);
  assertEquals(c.ready(T0 + 2_000, piece(H - 5_000), H), false);
  assertEquals(c.nextStartAt(T0 + 2_000), Number.POSITIVE_INFINITY);
  c.finished(T0 + 2_000, { kind: "answered" });
  assertEquals(c.ready(T0 + 2_000, piece(H - 5_000), H), true);
});

Deno.test("AIMD: halve on a 429 (floor 0.25), +0.5 per minute without one, up to the configured rate", () => {
  const s = new EndpointState(ep("rpc2", MEASURED), undefined, T0);
  assertEquals(s.currentRps(T0), 4);
  for (let k = 0; k < 6; k++) { s.started(T0); s.finished(T0, { kind: "throttled" }); }
  assertEquals(s.currentRps(T0), 0.25);
  assertEquals(s.currentRps(T0 + 59_000), 0.25);
  assertEquals(s.currentRps(T0 + 60_000), 0.75);
  assertEquals(s.currentRps(T0 + 5 * 60_000), 2.75);
  assertEquals(s.currentRps(T0 + 60 * 60_000), 4);
});

Deno.test("rests: throttling 2 → 4 → 8 → 16 s or Retry-After (≤ 60 s); failures 1 → 8 s; invalid 8 s; past head 1 s", () => {
  const s = new EndpointState(ep("rpc2"), undefined, T0);
  const rests: number[] = [];
  for (let k = 0; k < 5; k++) { s.started(T0); s.finished(T0, { kind: "throttled" }); rests.push(s.restUntil - T0); }
  assertEquals(rests, [2_000, 4_000, 8_000, 16_000, 16_000]);
  s.started(T0); s.finished(T0, { kind: "answered" });
  const r = new EndpointState(ep("rpc2"), undefined, T0);
  r.finished(T0, { kind: "throttled", retryAfterMs: 30_000 });
  assertEquals(r.restUntil - T0, 30_000);
  r.finished(T0, { kind: "throttled", retryAfterMs: 600_000 });
  assertEquals(r.restUntil - T0, 60_000);
  const f = new EndpointState(ep("rpc2"), undefined, T0);
  const fails: number[] = [];
  for (let k = 0; k < 5; k++) { f.started(T0); f.finished(T0, { kind: k % 2 ? "timeout" : "unanswered" }); fails.push(f.restUntil - T0); }
  assertEquals(fails, [1_000, 2_000, 4_000, 8_000, 8_000]);
  assertEquals(f.currentBatch(), 1); // halved on each, restored by an answer
  f.finished(T0, { kind: "answered" });
  assertEquals(f.currentBatch(), 6);
  const i = new EndpointState(ep("rpc2"), undefined, T0);
  i.finished(T0, { kind: "invalid" });
  assertEquals(i.restUntil - T0, 8_000);
  const p = new EndpointState(ep("rpc2"), undefined, T0);
  p.finished(T0, { kind: "pastHead" });
  assertEquals(p.restUntil - T0, 1_000);
});

Deno.test("span and batch are learned and remembered for a day", () => {
  const s = new EndpointState(ep("rpc4", { span: 10_000 }), undefined, T0);
  s.finished(T0, { kind: "span", span: 1_000, tried: 10_000 });
  assertEquals(s.currentSpan(), 1_000);
  s.finished(T0, { kind: "span", tried: 1_000 });
  assertEquals(s.currentSpan(), 500);
  for (let k = 0; k < 10; k++) s.finished(T0, { kind: "span", tried: s.currentSpan() });
  assertEquals(s.currentSpan(), 100); // never below 100
  const one = new EndpointState(ep("rpc1", { batch: 6 }), undefined, T0);
  assertEquals(one.bare(), false);
  one.finished(T0, { kind: "batchRefused" });
  assertEquals([one.currentBatch(), one.bare()], [1, true]);
  // The memory round-trips into the next run, and expires.
  const next = new EndpointState(ep("rpc1", { batch: 6 }), one.memory(T0 + 1_000), T0 + 2_000);
  assertEquals(next.bare(), true);
  const later = new EndpointState(ep("rpc1", { batch: 6 }), one.memory(T0 + 1_000), T0 + 25 * 3_600_000);
  assertEquals(later.bare(), false);
  const spanNext = new EndpointState(ep("rpc4", { span: 10_000 }), s.memory(T0), T0 + 1);
  assertEquals(spanNext.currentSpan(), 100);
});

Deno.test("memory round-trip: rest, pace, 429 ratio, daily count, clamps", () => {
  const s = new EndpointState(ep("rpc2"), undefined, T0);
  s.started(T0); s.finished(T0, { kind: "throttled", retryAfterMs: 20_000 });
  s.markClamps(T0);
  const m = s.memory(T0 + 1_000);
  assertEquals(m.rps, 1); // the launch pace (2) halved
  assertEquals(m.used, 1);
  assertEquals(m.restUntil, T0 + 20_000);
  assertEquals(m.clampsUntil, T0 + 86_400_000);
  assert(m.r429! > 0.04 && m.r429! <= 0.05);
  assertEquals(JSON.stringify(m).includes("monad.xyz"), false);
  const n = new EndpointState(ep("rpc2"), JSON.parse(JSON.stringify(m)), T0 + 2_000);
  assertEquals([n.currentRps(T0 + 2_000), n.usedToday(T0 + 2_000), n.straddle(T0 + 2_000), n.restUntil], [1, 1, "clamps", T0 + 20_000]);
  // A UTC day later the count starts again; garbage memory is ignored.
  assertEquals(new EndpointState(ep("rpc2"), m, T0 + 86_400_000).usedToday(T0 + 86_400_000), 0);
  const junk = new EndpointState(ep("rpc2"), { rps: Number.NaN, span: -5, used: -1 } as never, T0);
  assertEquals([junk.currentRps(T0), junk.currentSpan(), junk.usedToday(T0)], [2, 10_000, 0]);
});

Deno.test("the straddle rule: a clamping endpoint is never ready for a piece ending above head − lag", () => {
  const rpc4 = new EndpointState(ep("rpc4"), undefined, T0);
  assertEquals(rpc4.ready(T0, piece(H - 600, 0), H), true);
  assertEquals(rpc4.ready(T0, piece(H - 599, 0), H), false);
  assertEquals(rpc4.ready(T0, piece(H, 0), H), false);
  assertEquals(rpc4.highestAllowed(T0, H - 1_199, H), H - 600);
  assertEquals(rpc4.highestAllowed(T0, H - 10, H), null);
  const rpc2 = new EndpointState(ep("rpc2"), undefined, T0);
  assertEquals(rpc2.ready(T0, piece(H, 0), H), true);
  rpc2.markClamps(T0); // the self-test caught it answering past its head
  assertEquals(rpc2.ready(T0, piece(H, 0), H), false);
  assertEquals(rpc2.straddle(T0 + 86_400_001), "refuses");
});

Deno.test("daily budget: below 80 % anything, then only follow and windows, at 100 % nothing until UTC midnight", () => {
  const s = new EndpointState(ep("rpc2", { maxPerDay: 10, rps: 50 }), undefined, T0);
  let t = T0;
  for (let k = 0; k < 8; k++) { s.started(t); s.finished(t, { kind: "answered" }); t += 100; }
  assertEquals([0, 1, 2, 3].map((p) => s.budgetAllows(t, p as 0)), [true, false, true, false]);
  s.started(t); s.started(t + 100);
  assertEquals([0, 1, 2, 3].map((p) => s.budgetAllows(t, p as 0)), [false, false, false, false]);
  const midnight = Date.parse("2026-10-09T00:00:00Z");
  assertEquals(s.budgetAllows(midnight, 3), true);
});

Deno.test("pickEndpoint: priority order, spans, straddle, waits and nothing", () => {
  const states = DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e }, undefined, T0));
  const [rpc2, rpc4] = states;
  assertEquals(minSpanFor(3), 10_000);
  // Deep work only on rpc2; follow at the head only on rpc2.
  const deep = pickEndpoint(states, { from: 1_000_000, to: 1_009_999, priority: 3 }, T0, H, T0 + 60_000);
  assertEquals("state" in deep! && deep.state.label, "rpc2");
  rpc2.started(T0);
  const busy = pickEndpoint(states, { from: 1_000_000, to: 1_009_999, priority: 3 }, T0, H, T0 + 60_000);
  assertEquals(busy, { waitUntil: T0 + 500 }); // 2 requests/s
  // A window piece goes to rpc4 meanwhile; a follow piece at the head goes to rpc4 only up to head − lag.
  const window = pickEndpoint(states, { from: H - 20_000, to: H - 10_001, priority: 2 }, T0, H, T0 + 60_000);
  assertEquals("state" in window! && [window.state.label, window.upTo], ["rpc4", H - 10_001]);
  const follow = pickEndpoint(states, { from: H - 1_199, to: H, priority: 0 }, T0, H, T0 + 60_000);
  assertEquals("state" in follow! && [follow.state.label, follow.upTo], ["rpc4", H - 600]);
  // Entirely above head − lag: only rpc2, which is pacing — wait for it; its next start past the deadline → too late
  // for this run (kept for the next one); no refusing endpoint at all → nothing this run.
  assertEquals(pickEndpoint(states, { from: H - 100, to: H, priority: 0 }, T0, H, T0 + 60_000), { waitUntil: T0 + 500 });
  assertEquals(pickEndpoint(states, { from: H - 100, to: H, priority: 0 }, T0, H, T0 + 100), { late: true });
  rpc2.markClamps(T0);
  assertEquals(pickEndpoint(states, { from: H - 100, to: H, priority: 0 }, T0, H, T0 + 60_000), null);
  void rpc4;
});

Deno.test("refusals: rest 2 → 8 → 30 s, the fourth in a row sidelines for 15 min (remembered); an answer resets them", () => {
  const s = new EndpointState(ep("rpc2"), undefined, T0);
  const rests: number[] = [];
  for (let k = 0; k < 3; k++) { s.started(T0); s.finished(T0, { kind: "refused" }); rests.push(s.restUntil - T0); }
  assertEquals(rests, [2_000, 8_000, 30_000]);
  assertEquals(s.sidelined(T0), false);
  s.started(T0); s.finished(T0, { kind: "refused" });
  assertEquals([s.sidelined(T0), s.sidelined(T0 + SIDELINE_MS - 1), s.sidelined(T0 + SIDELINE_MS)], [true, true, false]);
  // Remembered by the next run (capped at 15 min from its start), and forgotten once over.
  const m = s.memory(T0 + 1_000);
  assertEquals(m.sidelinedUntil, T0 + SIDELINE_MS);
  assertEquals(new EndpointState(ep("rpc2"), m, T0 + 60_000).sidelined(T0 + 60_000), true);
  assertEquals(new EndpointState(ep("rpc2"), { sidelinedUntil: T0 + 10 * SIDELINE_MS }, T0).sidelined(T0 + SIDELINE_MS), false);
  const back = new EndpointState(ep("rpc2"), m, T0 + SIDELINE_MS);
  assertEquals(back.sidelined(T0 + SIDELINE_MS), false);
  back.finished(T0 + SIDELINE_MS, { kind: "refused" }); // back from the sideline: its next refusal sidelines it again
  assertEquals(back.sidelined(T0 + SIDELINE_MS), true);
  // The streak goes on in the next run: two refusals in one run, two in the next.
  const a = new EndpointState(ep("rpc4"), undefined, T0);
  a.finished(T0, { kind: "refused" }); a.finished(T0, { kind: "refused" });
  const b = new EndpointState(ep("rpc4"), a.memory(T0 + 30_000), T0 + 30_000);
  b.finished(T0 + 30_000, { kind: "refused" });
  assertEquals(b.sidelined(T0 + 30_000), false);
  b.finished(T0 + 30_000, { kind: "refused" });
  assertEquals(b.sidelined(T0 + 30_000), true);
  // An answer with a call answered resets the streak; one whose every call failed does not.
  const r = new EndpointState(ep("rpc4"), undefined, T0);
  for (let k = 0; k < 3; k++) r.finished(T0, { kind: "refused" });
  r.finished(T0, { kind: "answered", anyOk: false });
  r.finished(T0, { kind: "refused" });
  assertEquals(r.sidelined(T0), true);
  const ok = new EndpointState(ep("rpc4"), undefined, T0);
  for (let k = 0; k < 3; k++) ok.finished(T0, { kind: "refused" });
  ok.finished(T0, { kind: "answered", anyOk: true });
  ok.finished(T0, { kind: "refused" });
  assertEquals([ok.sidelined(T0), ok.restUntil - T0], [false, 30_000]);
});

Deno.test("strikes: only the first in a row counts against the piece; three in a row are a refusal; an answer resets", () => {
  const s = new EndpointState(ep("rpc4"), undefined, T0);
  assertEquals([s.strike(T0), s.restUntil], [false, 0]);  // the first: perhaps the piece
  assertEquals([s.strike(T0), s.restUntil], [true, 0]);   // the second: the endpoint
  assertEquals([s.strike(T0), s.restUntil - T0], [true, 2_000]); // the third: a refusal (rest 2 s)
  for (let k = 0; k < 3; k++) s.strike(T0);               // three more refusals: sidelined
  assertEquals(s.sidelined(T0), true);
  const t = new EndpointState(ep("rpc4"), undefined, T0);
  t.strike(T0); t.strike(T0);
  t.finished(T0, { kind: "answered", anyOk: true });
  assertEquals(t.strike(T0), false);
});

Deno.test("pickEndpoint: a sidelined endpoint takes nothing until it is back; a refusing one still to be verified is waited for", () => {
  const states = DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e }, undefined, T0));
  const [rpc2, rpc4] = states;
  for (let k = 0; k < 4; k++) rpc2.finished(T0, { kind: "refused" });
  // Sidelined for 15 min, past this run's read deadline: deep work and the head are late for the run (left to the next
  // one), never given up; work another endpoint can do goes to it.
  assertEquals(pickEndpoint(states, { from: 1_000_000, to: 1_009_999, priority: 3 }, T0, H, T0 + 60_000), { late: true });
  const window = pickEndpoint(states, { from: H - 20_000, to: H - 10_001, priority: 2 }, T0, H, T0 + 60_000);
  assertEquals("state" in window! && window.state.label, "rpc4");
  assertEquals(pickEndpoint(states, { from: H - 100, to: H, priority: 0 }, T0, H, T0 + 60_000), { late: true });
  // Back before the read deadline: waited for, then taken.
  assertEquals(pickEndpoint(states, { from: H - 100, to: H, priority: 0 }, T0, H, T0 + SIDELINE_MS + 60_000), { waitUntil: T0 + SIDELINE_MS });
  const back = pickEndpoint(states, { from: H - 100, to: H, priority: 0 }, T0 + SIDELINE_MS, H, T0 + SIDELINE_MS + 60_000);
  assertEquals(back && "state" in back && back.state.label, "rpc2");
  // rpc2 rested at the run's start: its self-test is deferred. Until it passes, rpc2 is clamping, and a piece at the
  // head waits for it instead of being given up.
  const fresh = DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e }, undefined, T0));
  const [f2] = fresh;
  f2.finished(T0, { kind: "throttled", retryAfterMs: 30_000 });
  f2.deferProbe();
  assertEquals(f2.straddle(T0), "clamps");
  assertEquals(pickEndpoint(fresh, { from: H - 100, to: H, priority: 0 }, T0, H, T0 + 60_000), { waitUntil: T0 + 30_000 });
  assertEquals(pickEndpoint(fresh, { from: H - 100, to: H, priority: 0, refusingOnly: true }, T0, H, T0 + 60_000), { waitUntil: T0 + 30_000 });
  assertEquals(pickEndpoint(fresh, { from: H - 100, to: H, priority: 0 }, T0, H, T0 + 20_000), { late: true }); // past the deadline
  // Below head − lag the clamping endpoints take it meanwhile.
  const low = pickEndpoint(fresh, { from: H - 1_199, to: H - 600, priority: 0 }, T0, H, T0 + 60_000);
  assertEquals("state" in low! && low.state.label, "rpc4");
  f2.markVerified();
  assertEquals(f2.straddle(T0), "refuses");
  void rpc4;
});

Deno.test("pickEndpoint: too late this run is not never — an endpoint resting past the read deadline leaves the item to the next run", () => {
  const fresh = (over: Partial<Endpoint> = {}) => DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e, ...(e.label === "rpc2" ? over : {}) }, undefined, T0));
  const deep = { from: 1_000_000, to: 1_009_999, priority: 3 as const };
  const window = { from: H - 20_000, to: H - 10_001, priority: 2 as const };
  const follow = { from: H - 100, to: H, priority: 0 as const };
  // rpc2, the only endpoint wide enough for deep work (and the only one for the head), throttled four times in a row:
  // it rests 16 s. A start before the read deadline is waited for; one at or past it is late — never null, which
  // would settle the item as unreadable (dropped) and pull the next one from the planner.
  const states = fresh();
  const [rpc2] = states;
  for (let k = 0; k < 4; k++) { rpc2.started(T0); rpc2.finished(T0, { kind: "throttled" }); }
  assertEquals(rpc2.restUntil, T0 + 16_000);
  assertEquals(pickEndpoint(states, deep, T0, H, T0 + 20_000), { waitUntil: T0 + 16_000 });
  assertEquals(pickEndpoint(states, deep, T0, H, T0 + 16_000), { late: true });
  assertEquals(pickEndpoint(states, deep, T0 + 5_000, H, T0 + 10_000), { late: true });
  assertEquals(pickEndpoint(states, follow, T0, H, T0 + 10_000), { late: true });
  // Work another endpoint can do now still goes to it.
  const w = pickEndpoint(states, window, T0, H, T0 + 10_000);
  assertEquals(w && "state" in w && w.state.label, "rpc4");
  // Paced (not resting) past the deadline: late too.
  const paced = fresh();
  paced[0].started(T0);                                   // 2 requests/s: the next start at T0 + 500
  assertEquals(pickEndpoint(paced, deep, T0, H, T0 + 400), { late: true });
  // At its in-flight cap rpc2 frees when a request finishes, perhaps before the deadline: a wait, never late — also
  // when the other endpoints able to take the item rest past the deadline.
  const capped = fresh();
  for (let k = 0; k < 4; k++) capped[0].started(T0);
  assertEquals(pickEndpoint(capped, deep, T0, H, T0 + 100), { waitUntil: Number.POSITIVE_INFINITY });
  for (const s of capped.slice(1)) s.finished(T0, { kind: "throttled", retryAfterMs: 30_000 });
  assertEquals(pickEndpoint(capped, window, T0, H, T0 + 10_000), { waitUntil: Number.POSITIVE_INFINITY });
  assertEquals(pickEndpoint(capped, window, T0, H, T0 + 60_000), { waitUntil: T0 + 30_000 });
  // A sideline, a day off (spent) or a day without log reads is a rest with an end: waited for when it ends before the
  // read deadline, late when it ends at or past it — never null. A sideline the last run remembered, ending 20 s into
  // this one (the run then waits for it, rather than drop its deep plan item by item).
  const remembered = DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e }, e.label === "rpc2" ? { sidelinedUntil: T0 + 20_000 } : undefined, T0));
  assertEquals(remembered[0].sidelined(T0), true);
  assertEquals(pickEndpoint(remembered, deep, T0, H, T0 + 210_000), { waitUntil: T0 + 20_000 });
  assertEquals(pickEndpoint(remembered, follow, T0, H, T0 + 210_000), { waitUntil: T0 + 20_000 });
  assertEquals(pickEndpoint(remembered, deep, T0, H, T0 + 20_000), { late: true });
  const r = pickEndpoint(remembered, deep, T0 + 20_000, H, T0 + 210_000);
  assertEquals(r && "state" in r && r.state.label, "rpc2");
  const spent = fresh();
  spent[0].finished(T0, { kind: "spent" });                               // off until 00:00 UTC
  assertEquals(pickEndpoint(spent, deep, T0, H, T0 + 10_000), { late: true });
  const midnight = Date.parse("2026-10-09T00:00:00Z");
  assertEquals(pickEndpoint(spent, deep, midnight - 5_000, H, midnight + 60_000), { waitUntil: midnight });
  const noLogs = fresh();
  noLogs[0].finished(T0, { kind: "noLogs" });
  assertEquals(pickEndpoint(noLogs, deep, T0, H, T0 + 10_000), { late: true });
  // At its in-flight cap but sidelined past the deadline: a freed slot would not help — late.
  const cappedOff = fresh();
  for (let k = 0; k < 4; k++) cappedOff[0].started(T0);
  for (let k = 0; k < 4; k++) cappedOff[0].note(T0, { kind: "refused" });
  assertEquals([cappedOff[0].inFlight, cappedOff[0].sidelined(T0)], [4, true]);
  assertEquals(pickEndpoint(cappedOff, deep, T0, H, T0 + 10_000), { late: true });
  // Structural: no endpoint may take it this run at all — null, resting or not: its priority (takesPriority: spans,
  // daily budgets; the run holds the priority back), or the item itself (the straddle rule; the run settles it: a
  // straddle wait at the head).
  const narrow = fresh();
  narrow[0].finished(T0, { kind: "span", span: 5_000, tried: 10_000 });   // below minSpanFor(3)
  assertEquals(pickEndpoint(narrow, deep, T0, H, T0 + 10_000), null);
  const budget = fresh({ maxPerDay: 10, rps: 50 });
  for (let k = 0; k < 8; k++) { budget[0].started(T0 + k * 100); budget[0].finished(T0 + k * 100, { kind: "answered" }); }
  assertEquals(pickEndpoint(budget, deep, T0 + 1_000, H, T0 + 10_000), null);  // 80 % used: no deep work today
  const clamping = fresh();
  clamping[0].markClamps(T0);
  clamping[0].finished(T0, { kind: "throttled", retryAfterMs: 30_000 });
  assertEquals(pickEndpoint(clamping, follow, T0, H, T0 + 10_000), null);     // no refusing endpoint for the head
});

Deno.test("takesPriority: whether any endpoint's span and daily budget allow a priority at all (rests, sidelines and days off do not count)", () => {
  const fresh = (over: Partial<Endpoint> = {}) => DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e, ...(e.label === "rpc2" ? over : {}) }, undefined, T0));
  assertEquals([0, 1, 2, 3].map((p) => takesPriority(fresh(), p as 0, T0)), [true, true, true, true]);
  // rpc2 taught a span below 10,000 blocks ("invalid block range params": half the piece), remembered for a day: no
  // endpoint takes deep work until then; the 1,000-block endpoints still take the rest.
  const narrow = fresh();
  narrow[0].finished(T0, { kind: "span", tried: 10_000 });
  assertEquals(narrow[0].currentSpan(), 5_000);
  assertEquals([0, 1, 2, 3].map((p) => takesPriority(narrow, p as 0, T0)), [true, true, true, false]);
  const nextRun = DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e }, e.label === "rpc2" ? narrow[0].memory(T0 + 60_000) : undefined, T0 + 60_000));
  assertEquals(takesPriority(nextRun, 3, T0 + 60_000), false);
  // "up to a 10000 block range" for a 10,000-block piece: 9,999, just as narrow for deep work.
  const nines = fresh();
  nines[0].finished(T0, { kind: "span", span: 10_000, tried: 10_000 });
  assertEquals([nines[0].currentSpan(), takesPriority(nines, 3, T0)], [9_999, false]);
  // A daily budget at 80 %: deep work and global gaps wait for 00:00 UTC.
  const budget = fresh({ maxPerDay: 10, rps: 50 });
  for (let k = 0; k < 8; k++) { budget[0].started(T0 + k * 100); budget[0].finished(T0 + k * 100, { kind: "answered" }); }
  assertEquals(takesPriority(budget, 3, T0 + 1_000), false);
  assertEquals(takesPriority(budget, 3, Date.parse("2026-10-09T00:00:00Z")), true);
  // Resting, sidelined, off or without log reads: still able to take it (pickEndpoint waits for it, or leaves it late).
  const off = fresh();
  for (let k = 0; k < 4; k++) off[0].finished(T0, { kind: "refused" });
  off[0].finished(T0, { kind: "spent" });
  off[0].finished(T0, { kind: "noLogs" });
  assertEquals(takesPriority(off, 3, T0), true);
});

Deno.test("bytes in flight: reservations ≤ 12 MiB, at most one single block (8 MiB) at a time", () => {
  const b = new ByteBudget();
  assertEquals(b.reservation("window", false), 262_144);
  b.observe("window", 2_000_000);
  assertEquals(b.reservation("window", false), 3 * 1_048_576);
  const single = b.tryReserve("deep", true)!;
  assertEquals(single, 8 * 1_048_576);
  assertEquals(b.tryReserve("deep", true), null);
  assertEquals(b.tryReserve("window", false), 3 * 1_048_576);
  assertEquals(b.tryReserve("window", false), null); // 11 MiB + 3 MiB > 12 MiB
  assert(b.tryReserve("follow", false)! > 0);
  b.release(single, true);
  assert(b.tryReserve("window", false)! > 0);
  assert(b.inUse() <= 12 * 1_048_576);
});

// ── The keyed endpoint "alchemy" ─────────────────────────────────────────────────────────────────────────────────

const ALCHEMY = alchemyEndpoint("https://monad-mainnet.g.alchemy.test/v2/fAkEaLcHeMyKeY-0123456789").endpoint!;

Deno.test("alchemy: first for backfill (global gaps, windows, deep), last for the follow; clamping, so never at the head", () => {
  const states = [ALCHEMY, ...DEFAULT_ENDPOINTS].map((e) => new EndpointState({ ...e }, undefined, T0));
  const [alchemy, rpc2] = states;
  assertEquals([followRank(ALCHEMY), followRank(DEFAULT_ENDPOINTS[0])], [50, 10]);
  const label = (r: ReturnType<typeof pickEndpoint>) => (r && "state" in r ? [r.state.label, r.upTo] : r);
  assertEquals(label(pickEndpoint(states, { from: 0, to: 4_999_999, priority: 3 }, T0, H, T0 + 60_000)), ["alchemy", 4_999_999]);
  assertEquals(label(pickEndpoint(states, { from: H - 5_000_000, to: H - 10_000, priority: 2 }, T0, H, T0 + 60_000)), ["alchemy", H - 10_000]);
  assertEquals(label(pickEndpoint(states, { from: H - 5_000_000, to: H - 10_000, priority: 1 }, T0, H, T0 + 60_000)), ["alchemy", H - 10_000]);
  // A window piece reaching the head: alchemy reads it up to head − 600 (the lag rule); the rest waits for rpc2.
  assertEquals(label(pickEndpoint(states, { from: H - 20_000, to: H, priority: 2 }, T0, H, T0 + 60_000)), ["alchemy", H - 600]);
  // The follow goes to rpc2 (whole, to the head), and to alchemy only when no public endpoint can take it.
  assertEquals(label(pickEndpoint(states, { from: H - 1_199, to: H, priority: 0 }, T0, H, T0 + 60_000)), ["rpc2", H]);
  for (let k = 0; k < 4; k++) rpc2.started(T0);  // rpc2's in-flight cap (4) full: the clamping public endpoints first
  assertEquals(label(pickEndpoint(states, { from: H - 1_199, to: H, priority: 0 }, T0, H, T0 + 60_000)), ["rpc4", H - 600]);
  for (const s of states.slice(2)) { s.started(T0); s.started(T0); }
  assertEquals(label(pickEndpoint(states, { from: H - 1_199, to: H, priority: 0 }, T0, H, T0 + 60_000)), ["alchemy", H - 600]);
  void alchemy;
});

Deno.test("alchemy: a span refusal from 5,000,000 halves to the key's cap in ~16 requests, remembered for a day", () => {
  const s = new EndpointState({ ...ALCHEMY }, undefined, T0);
  let refusals = 0;
  while (s.currentSpan() > 100 && refusals < 30) { s.finished(T0, { kind: "span", tried: s.currentSpan() }); refusals++; }
  assertEquals(s.currentSpan(), 100);
  assert(refusals <= 16, `${refusals} refusals`);
  assertEquals(new EndpointState({ ...ALCHEMY }, s.memory(T0), T0 + 1_000).currentSpan(), 100);
  // Below 1,000 blocks it takes no backfill at all (minSpanFor), only the follow.
  const states = [s, ...DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e }, undefined, T0))];
  const deep = pickEndpoint(states, { from: 0, to: 9_999, priority: 3 }, T0, H, T0 + 60_000);
  assertEquals(deep && "state" in deep && deep.state.label, "rpc2");
});

Deno.test("keyed refusals: sidelined at once (401/403), off until the next UTC day (spent), no log reads for a day (plan)", () => {
  const now = Date.parse("2026-10-09T17:30:00Z");
  const midnight = Date.parse("2026-10-10T00:00:00Z");
  const a = new EndpointState({ ...ALCHEMY }, undefined, now);
  a.finished(now, { kind: "sideline" });
  assertEquals([a.sidelined(now), a.sidelined(now + SIDELINE_MS - 1), a.sidelined(now + SIDELINE_MS)], [true, true, false]);
  const back = new EndpointState({ ...ALCHEMY }, a.memory(now + 1_000), now + SIDELINE_MS);
  back.finished(now + SIDELINE_MS, { kind: "refused" }); // back from the sideline: the next refusal sidelines it again
  assertEquals(back.sidelined(now + SIDELINE_MS), true);

  const spent = new EndpointState({ ...ALCHEMY }, undefined, now);
  spent.finished(now, { kind: "spent" });
  assertEquals([spent.sidelined(midnight - 1), spent.sidelined(midnight)], [true, false]);
  const m = spent.memory(now + 1_000);
  assertEquals(m.offUntil, midnight);
  const next = new EndpointState({ ...ALCHEMY }, JSON.parse(JSON.stringify(m)), now + 30_000);
  assertEquals([next.sidelined(now + 30_000), next.sidelined(midnight)], [true, false]); // a next run keeps it off
  assertEquals(new EndpointState({ ...ALCHEMY }, { offUntil: now + 10 * 86_400_000 }, now).sidelined(now + 86_400_000), false); // ≤ a day

  const free = new EndpointState({ ...ALCHEMY }, undefined, now);
  free.finished(now, { kind: "noLogs" });
  assertEquals([free.logsOff(now), free.sidelined(now), free.logsOff(now + 86_400_000)], [true, false, false]);
  const kept = new EndpointState({ ...ALCHEMY }, free.memory(now + 1_000), now + 60_000);
  assertEquals(kept.logsOff(now + 60_000), true);
  const states = [kept, ...DEFAULT_ENDPOINTS.map((e) => new EndpointState({ ...e }, undefined, now))];
  const deep = pickEndpoint(states, { from: 0, to: 9_999, priority: 3 }, now + 60_000, H, now + 120_000);
  assertEquals(deep && "state" in deep && deep.state.label, "rpc2", "no log piece for an endpoint without log reads");
  assertEquals(JSON.stringify(kept.memory(now + 60_000)).includes("alchemy.test"), false);
});

Deno.test("bytes in flight: an endpoint's own response cap (8 MiB) bounds its reservation, the 12 MiB total still holds", () => {
  const b = new ByteBudget();
  b.observe("deep@alchemy", 6_300_000);
  assertEquals(b.reservation("deep@alchemy", false, 8 * 1_048_576), 8 * 1_048_576);
  assertEquals(b.reservation("deep@alchemy", false), 3 * 1_048_576); // without its cap: the run's
  assertEquals(b.tryReserve("deep@alchemy", false, 8 * 1_048_576), 8 * 1_048_576);
  assertEquals(b.tryReserve("deep@alchemy", false, 8 * 1_048_576), null); // a second would pass 12 MiB
  assert(b.tryReserve("window", false)! > 0);
});
