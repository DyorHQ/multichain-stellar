// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  ALCHEMY_LABEL, alchemyEndpoint, classifyCallError, classifyHttp, DEFAULT_ENDPOINTS, endpointRefusal, endpointsFromEnv, isKeyed,
  retryAfterMs,
} from "./endpoints.ts";
import { VERSION } from "./version.ts";

const KEYED = "https://monad.example-provider.test/v1/k3y-material-that-must-never-be-logged";

Deno.test("defaults: the four public endpoints as measured (rpc2 refuses straddles, the others clamp), rpc2 at the launch pace", () => {
  assertEquals(DEFAULT_ENDPOINTS.map((e) => [e.label, e.span, e.batch, e.rps, e.inFlight, e.archive, e.straddle, e.lag, e.priority]), [
    ["rpc2", 10_000, 6, 2, 4, true, "refuses", 600, 10],
    ["rpc4", 1_000, 1, 4, 2, true, "clamps", 600, 20],
    ["rpc3", 1_000, 1, 4, 2, false, "clamps", 600, 30],
    ["rpc1", 100, 1, 4, 2, true, "clamps", 600, 40],
  ]);
  for (const e of DEFAULT_ENDPOINTS) assert(/^https:\/\/rpc[1-4]\.monad\.xyz$/.test(e.url));
  for (const e of DEFAULT_ENDPOINTS) assertEquals(isKeyed(e), false, e.label);
  assertEquals(endpointsFromEnv(undefined), { endpoints: DEFAULT_ENDPOINTS.map((e) => ({ ...e })) });
  assertEquals(endpointsFromEnv("  ").endpoints.length, 4);
});

Deno.test("MONAD_LOGS_ENDPOINTS: an array replaces the defaults", () => {
  const { endpoints, error } = endpointsFromEnv(JSON.stringify([{ url: KEYED, span: 10_000, batch: 10, rps: 20, inFlight: 8, archive: true, straddle: "refuses" }]));
  assertEquals(error, undefined);
  assertEquals(endpoints, [{ label: "custom-1", url: KEYED, span: 10_000, batch: 10, rps: 20, inFlight: 8, archive: true, straddle: "refuses", lag: 600, priority: 0 }]);
});

Deno.test("MONAD_LOGS_ENDPOINTS: append keeps the defaults as a fallback, custom entries first by priority", () => {
  const { endpoints, error } = endpointsFromEnv(JSON.stringify({ mode: "append", endpoints: [{ label: "paid", url: KEYED, maxPerDay: 100_000 }] }));
  assertEquals(error, undefined);
  assertEquals(endpoints.map((e) => e.label), ["paid", "rpc2", "rpc4", "rpc3", "rpc1"]);
  assertEquals(endpoints[0].straddle, "clamps"); // the safe class unless declared
  assertEquals(endpoints[0].maxPerDay, 100_000);
  // The launch setting: only an override of a default, no custom entry.
  const launch = endpointsFromEnv(JSON.stringify({ mode: "append", overrides: { rpc2: { rps: 2, inFlight: 4 } } }));
  assertEquals(launch.error, undefined);
  assertEquals(launch.endpoints.map((e) => [e.label, e.rps, e.inFlight]), [["rpc2", 2, 4], ["rpc4", 4, 2], ["rpc3", 4, 2], ["rpc1", 4, 2]]);
  assertEquals(launch.endpoints[0].url, "https://rpc2.monad.xyz");
  // mode defaults to append.
  assertEquals(endpointsFromEnv(JSON.stringify({ overrides: { rpc1: { lag: 1200 } } })).endpoints.find((e) => e.label === "rpc1")!.lag, 1200);
  // replace with an object.
  assertEquals(endpointsFromEnv(JSON.stringify({ mode: "replace", endpoints: [{ url: KEYED }] })).endpoints.map((e) => e.label), ["custom-1"]);
});

Deno.test("MONAD_LOGS_ENDPOINTS: anything invalid → the defaults and an error naming the field, never the URL", () => {
  const cases: [unknown, string][] = [
    [[{ url: "http://insecure.example/" + "k".repeat(20) }], "url must be https"],
    [[{ url: KEYED, span: 50 }], "span"],
    [[{ url: KEYED, span: 20_000_000 }], "span"],
    [[{ url: KEYED, followPriority: 1.5 }], "followPriority"],
    [[{ url: KEYED, responseCap: 1_000 }], "responseCap"],
    [[{ url: KEYED, batch: 0 }], "batch"],
    [[{ url: KEYED, rps: 0.1 }], "rps"],
    [[{ url: KEYED, inFlight: 17 }], "inFlight"],
    [[{ url: KEYED, lag: 50 }], "lag"],
    [[{ url: KEYED, maxPerDay: 0 }], "maxPerDay"],
    [[{ url: KEYED, archive: "yes" }], "archive"],
    [[{ url: KEYED, straddle: "maybe" }], "straddle"],
    [[{ url: KEYED, label: "Bad Label" }], "label"],
    [[{ url: KEYED, secret: "x" }], "unknown field"],
    [[{ span: 1000 }], "url is required"],
    [[{ url: KEYED, label: "a" }, { url: KEYED, label: "a" }], "unique"],
    [{ mode: "append", endpoints: [{ url: KEYED, label: "rpc2" }] }, "unique"],
    [Array.from({ length: 9 }, () => ({ url: KEYED })), "at most 8"],
    [[], "empty"],
    [{ mode: "merge" }, "mode"],
    [{ mode: "replace" }, "at least one"],
    [{ mode: "replace", endpoints: [{ url: KEYED }], overrides: {} }, "overrides"],
    [{ overrides: { rpc9: { rps: 1 } } }, "no default endpoint"],
    [{ overrides: { rpc2: { url: KEYED } } }, "url cannot be overridden"],
    [{ overrides: { rpc2: { rps: 100 } } }, "rps"],
    [{ extra: 1 }, "unknown key"],
    [42, "must be a list or an object"],
  ];
  for (const [value, field] of cases) {
    const { endpoints, error } = endpointsFromEnv(JSON.stringify(value));
    assertEquals(endpoints, DEFAULT_ENDPOINTS.map((e) => ({ ...e })), JSON.stringify(value).slice(0, 80));
    assert(error && error.includes(field), `${error} should name ${field}`);
    assert(!error.includes("k3y") && !error.includes("example"), "the error must not contain the URL");
  }
  assertEquals(endpointsFromEnv("{not json").error, "MONAD_LOGS_ENDPOINTS is not JSON");
});

Deno.test("classifyCallError: every measured message (§2, §10.1)", () => {
  const H = 111_739_139;
  const deep = { from: 100_000_000, to: 100_009_999 };
  const top = { from: H - 10, to: H + 50 };
  const c = (code: number | undefined, message: string, piece = deep) => classifyCallError({ code, message }, piece, H);
  // Throttling.
  assertEquals(c(429, "Too Many Requests"), { kind: "throttled" });
  assertEquals(c(-32005, "limit exceeded"), { kind: "throttled" });
  assertEquals(c(-32000, "rate limit exceeded, retry later"), { kind: "throttled" });
  assertEquals(c(-32000, "You have exceeded your request limit"), { kind: "throttled" });
  assertEquals(c(-32000, "exceeded 25 requests per second"), { kind: "throttled" });
  assertEquals(c(-32000, "throughput exceeded"), { kind: "throttled" });
  // Past the head: rpc2's two codes, rpc4's two texts, and the clamping endpoints' "not found" near the head.
  assertEquals(c(-32014, "block not available: block not found for eth_getLogs, requested toBlock 111739189 is not yet available on the node", top), { kind: "pastHead" });
  assertEquals(c(-32603, "ErrUpstreamBlockUnavailable: upstream does not have the requested block yet", top), { kind: "pastHead" });
  assertEquals(c(-32602, "block range extends beyond current head block", top), { kind: "pastHead" });
  assertEquals(c(-32602, "Block requested not found. Request might be querying historical state that is not available", top), { kind: "pastHead" });
  // …but "not found" deep in history is a non-archive node, not the head.
  assertEquals(c(-32602, "Block requested not found. Request might be querying historical state that is not available"), { kind: "failed" });
  // Span limits.
  assertEquals(c(-32602, "eth_getLogs is limited to a 1,000 range"), { kind: "span", span: 1000 });
  assertEquals(c(-32602, "You can make eth_getLogs requests with up to a 10000 block range"), { kind: "span", span: 10_000 });
  assertEquals(c(-32602, "Block range is too large"), { kind: "span" });
  assertEquals(c(-32602, "invalid block range params"), { kind: "span" });
  // Too dense.
  assertEquals(c(-32005, "query returned more than 10000 results"), { kind: "dense" }); // not a rate limit, whatever the code
  assertEquals(c(-32602, "query returned more than 10000 results. Try with this block range [0x5F5E100, 0x5F5E1FF]"), { kind: "dense", cut: 0x5f5e1ff });
  assertEquals(c(-32000, "too many logs"), { kind: "dense" });
  assertEquals(c(-32000, "Log response size exceeded"), { kind: "dense" });
  assertEquals(c(-32000, "response size should not greater than 10000000 bytes"), { kind: "dense" });
  // Anything else.
  assertEquals(c(-32603, "Internal error"), { kind: "failed" });
  assertEquals(c(undefined, ""), { kind: "failed" });
});

Deno.test("classifyHttp and Retry-After (seconds and a date)", () => {
  const now = Date.parse("2026-10-08T12:00:00Z");
  assertEquals(classifyHttp(429, new Headers({ "Retry-After": "2" }), "", now), { kind: "throttled", retryAfterMs: 2000 });
  assertEquals(classifyHttp(503, new Headers({ "Retry-After": "Thu, 08 Oct 2026 12:00:05 GMT" }), "", now), { kind: "throttled", retryAfterMs: 5000 });
  assertEquals(classifyHttp(429, new Headers(), "", now), { kind: "throttled", retryAfterMs: undefined });
  assertEquals(classifyHttp(403, new Headers(), '{"error":"Restricted JSON RPC method"}', now), { kind: "batchRefused" });
  assertEquals(classifyHttp(403, new Headers(), "forbidden", now), { kind: "auth" });
  assertEquals(classifyHttp(401, new Headers(), "unauthorized", now), { kind: "auth" });
  assertEquals(classifyHttp(502, new Headers(), "", now), { kind: "unanswered" });
  assertEquals(classifyHttp(400, new Headers(), "bad", now), { kind: "callErrors" });
  assertEquals(retryAfterMs("soon", now), undefined);
  assertEquals(retryAfterMs("Thu, 08 Oct 2026 11:00:00 GMT", now), 0);
});

// ── ALCHEMY_MONAD_RPC ───────────────────────────────────────────────────────────────────────────────────────────

const ALCHEMY_URL = "https://monad-mainnet.g.alchemy.test/v2/fAkEaLcHeMyKeY-must-never-be-logged-0123";

Deno.test("alchemyEndpoint: the documented entry for an https URL; none (and a note without the value) otherwise", () => {
  const on = alchemyEndpoint(ALCHEMY_URL);
  assertEquals(on.endpoint, {
    label: "alchemy", url: ALCHEMY_URL, span: 5_000_000, batch: 1, rps: 4, inFlight: 2, archive: true, straddle: "clamps", lag: 600,
    priority: 5, followPriority: 50, maxPerDay: 12_000, responseCap: 8 * 1_048_576,
  });
  assertEquals(isKeyed(on.endpoint!), true);
  assertEquals(alchemyEndpoint(`  ${ALCHEMY_URL}\n`).endpoint?.url, ALCHEMY_URL, "a pasted value's whitespace is trimmed");
  for (const raw of [undefined, "", "   "]) {
    assertEquals(alchemyEndpoint(raw), { note: "ALCHEMY_MONAD_RPC is not set: public endpoints only" });
  }
  for (const raw of [ALCHEMY_URL.replace("https:", "http:"), "monad-mainnet.g.alchemy.test/v2/fAkEaLcHeMyKeY-0123", "https://",
                     "wss://monad-mainnet.g.alchemy.test/v2/fAkEaLcHeMyKeY-0123", "not a url fAkEaLcHeMyKeY", "https:///v2/fAkEaLcHeMyKeY"]) {
    const r = alchemyEndpoint(raw);
    assertEquals(r.endpoint, undefined, raw);
    assertEquals(r.note, "ALCHEMY_MONAD_RPC is not an https URL with a host: public endpoints only");
  }
  for (const raw of [ALCHEMY_URL, "http://x.test/fAkEaLcHeMyKeY"]) assert(!alchemyEndpoint(raw).note.includes("fAkE"));
});

Deno.test("endpointsFromEnv with alchemy: first for backfill; MONAD_LOGS_ENDPOINTS still tunes, adds or replaces", () => {
  const alchemy = alchemyEndpoint(ALCHEMY_URL).endpoint!;
  const base = endpointsFromEnv(undefined, [alchemy]);
  assertEquals(base.error, undefined);
  assertEquals(base.endpoints.map((e) => e.label), ["alchemy", "rpc2", "rpc4", "rpc3", "rpc1"]);
  // An override of alchemy (fields, never its url).
  const tuned = endpointsFromEnv(JSON.stringify({ overrides: { alchemy: { span: 10_000, straddle: "refuses", rps: 2 }, rpc2: { rps: 4, inFlight: 8 } } }), [alchemy]);
  assertEquals(tuned.error, undefined);
  const a = tuned.endpoints.find((e) => e.label === ALCHEMY_LABEL)!;
  assertEquals([a.span, a.straddle, a.rps, a.url, a.followPriority], [10_000, "refuses", 2, ALCHEMY_URL, 50]);
  assertEquals(tuned.endpoints.find((e) => e.label === "rpc2")!.rps, 4);
  const url = endpointsFromEnv(JSON.stringify({ overrides: { alchemy: { url: KEYED } } }), [alchemy]);
  assert(url.error?.includes("url cannot be overridden"));
  assertEquals(url.endpoints.map((e) => e.label), ["alchemy", "rpc2", "rpc4", "rpc3", "rpc1"], "invalid → the base, alchemy kept");
  // An override of alchemy while ALCHEMY_MONAD_RPC is unset is ignored, not an error that would drop the others.
  const absent = endpointsFromEnv(JSON.stringify({ overrides: { alchemy: { rps: 1 }, rpc2: { rps: 3 } } }));
  assertEquals(absent.error, undefined);
  assertEquals(absent.endpoints.map((e) => [e.label, e.rps]), [["rpc2", 3], ["rpc4", 4], ["rpc3", 4], ["rpc1", 4]]);
  // A custom entry may not take the label; replace mode drops the base, alchemy included.
  assert(endpointsFromEnv(JSON.stringify({ endpoints: [{ label: "alchemy", url: KEYED }] }), [alchemy]).error?.includes("unique"));
  assertEquals(endpointsFromEnv(JSON.stringify({ mode: "replace", endpoints: [{ url: KEYED }] }), [alchemy]).endpoints.map((e) => e.label), ["custom-1"]);
  // No error names the URL.
  for (const raw of [JSON.stringify({ overrides: { alchemy: { url: KEYED, span: 1 } } }), "{not json", JSON.stringify([{ url: "http://" + ALCHEMY_URL.slice(8) }])]) {
    const e = endpointsFromEnv(raw, [alchemy]).error ?? "";
    assert(!e.includes("fAkE") && !e.includes("k3y") && !e.includes("alchemy.test"), e);
  }
});

Deno.test("Alchemy's errors: the Free tier, a spent month, too dense with a suggested range, a bare range refusal", () => {
  const H = 111_888_833;
  const piece = { from: 100_000_000, to: 104_999_999 };
  const free = "Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. Based on your parameters, " +
    "this block range should work: [0x5f5e100, 0x5f5e109]. Upgrade to PAYG for expanded block range.";
  // Keyed: the plan, not a 10-block span (which the 100-block floor would retry forever).
  assertEquals(classifyCallError({ code: -32600, message: free }, piece, H, true), { kind: "plan" });
  // A public endpoint's text is read as before.
  assertEquals(classifyCallError({ code: -32600, message: free }, piece, H), { kind: "span", span: 10 });
  assertEquals(classifyCallError({ code: 429, message: "Monthly capacity limit exceeded." }, piece, H, true), { kind: "spent" });
  assertEquals(classifyCallError({ code: 429, message: "Monthly capacity limit exceeded." }, piece, H), { kind: "throttled" });
  assertEquals(classifyCallError({ code: 429, message: "Your app has exceeded its compute units per second capacity." }, piece, H, true), { kind: "throttled" });
  const dense = "Log response size exceeded. You can make eth_getLogs requests with up to a 10,000 block range and no limit on the " +
    "response size, or you can request any block range with a cap of 10K logs in the response. Based on your parameters and the " +
    `response size limit, this block range should work: [0x${piece.from.toString(16)}, 0x${(102_345_678).toString(16)}]`;
  assertEquals(classifyCallError({ code: -32602, message: dense }, piece, H, true), { kind: "dense", cut: 102_345_678 });
  assertEquals(classifyCallError({ code: -32602, message: "block range too large" }, piece, H, true), { kind: "span" });
  // Over HTTP (a body that is not JSON-RPC, or one read before the calls).
  const now = Date.parse("2026-10-09T12:00:00Z");
  assertEquals(classifyHttp(429, new Headers(), "Monthly capacity limit exceeded.", now, true), { kind: "spent" });
  assertEquals(classifyHttp(429, new Headers({ "Retry-After": "1" }), "Monthly capacity limit exceeded.", now), { kind: "throttled", retryAfterMs: 1_000 });
  assertEquals(classifyHttp(400, new Headers(), free, now, true), { kind: "plan" });
  assertEquals(classifyHttp(401, new Headers(), `{"error":"Must be authenticated! ${ALCHEMY_URL}"}`, now, true), { kind: "auth" });
  assertEquals([endpointRefusal(free), endpointRefusal("Monthly capacity limit exceeded."), endpointRefusal("rate limit")], ["plan", "spent", null]);
});

Deno.test("version: the placeholder (or the SHA that replaces it) is a version history_lease accepts", () => {
  assert(/^[0-9A-Za-z._-]{1,40}$/.test(VERSION), VERSION);
});
