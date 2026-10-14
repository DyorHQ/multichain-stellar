// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Call, exchange, mapResults } from "./rpc.ts";

const calls: Call[] = [{ method: "eth_blockNumber", params: [] }, { method: "eth_getLogs", params: [{}] }];
const opts = { timeoutMs: 1_000, maxBytes: 10_000, bare: false };

function stub(respond: (body: unknown, signal: AbortSignal) => Response | Promise<Response>) {
  const seen: unknown[] = [];
  const fn = (async (_url: string | URL | Request, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    seen.push(body);
    return await respond(body, init!.signal!);
  }) as typeof fetch;
  return { fn, seen };
}
const json = (value: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json", ...headers } });

Deno.test("exchange: a batch is an array with ids 1…n, answered out of order", async () => {
  const s = stub(() => json([{ jsonrpc: "2.0", id: 2, result: [] }, { jsonrpc: "2.0", id: 1, result: "0x10" }]));
  const out = await exchange(s.fn, "https://x.test", calls, opts);
  assertEquals(out.kind, "answered");
  if (out.kind !== "answered") return;
  assertEquals(out.results, [{ ok: true, result: "0x10" }, { ok: true, result: [] }]);
  assert(out.bytes > 0 && out.parseMs >= 0);
  assertEquals((s.seen[0] as { id: number }[]).map((c) => c.id), [1, 2]);
});

Deno.test("exchange: bare sends one call as an object (rpc1 answers 403 to any array)", async () => {
  const s = stub(() => json({ jsonrpc: "2.0", id: 1, result: "0x1" }));
  const out = await exchange(s.fn, "https://x.test", [calls[0]], { ...opts, bare: true });
  assertEquals(Array.isArray(s.seen[0]), false);
  assertEquals((s.seen[0] as { method: string }).method, "eth_blockNumber");
  assertEquals(out.kind === "answered" && out.results, [{ ok: true, result: "0x1" }]);
  // Not bare: even one call goes as an array.
  const t = stub(() => json([{ jsonrpc: "2.0", id: 1, result: "0x1" }]));
  await exchange(t.fn, "https://x.test", [calls[0]], opts);
  assertEquals(Array.isArray(t.seen[0]), true);
});

Deno.test("exchange: per-call errors are answers; a 4xx whose body is per-call errors too", async () => {
  const s = stub(() => json([{ id: 1, error: { code: -32602, message: "eth_getLogs is limited to a 1,000 range" } }, { id: 2, result: [] }], 400));
  const out = await exchange(s.fn, "https://x.test", calls, opts);
  assertEquals(out.kind === "answered" && out.results[0], { ok: false, code: -32602, message: "eth_getLogs is limited to a 1,000 range" });
  // One error object for the whole batch answers every call.
  const g = stub(() => json({ jsonrpc: "2.0", id: null, error: { code: -32005, message: "rate limit" } }, 429));
  const all = await exchange(g.fn, "https://x.test", calls, opts);
  assertEquals(all.kind === "answered" && all.results.map((r) => !r.ok && r.code), [-32005, -32005]);
});

Deno.test("exchange: 403 that is not JSON-RPC → http (classified by the caller)", async () => {
  const s = stub(() => new Response("Restricted JSON RPC method", { status: 403 }));
  const out = await exchange(s.fn, "https://x.test", calls, opts);
  assertEquals(out.kind, "http");
  assertEquals(out.kind === "http" && [out.status, out.body], [403, "Restricted JSON RPC method"]);
});

Deno.test("exchange: the byte cap aborts a streamed body (tooLarge)", async () => {
  let cancelled = false;
  const s = stub(() => new Response(new ReadableStream({
    pull(c) { c.enqueue(new Uint8Array(4_096).fill(32)); },
    cancel() { cancelled = true; },
  }), { status: 200 }));
  const out = await exchange(s.fn, "https://x.test", calls, opts);
  assertEquals(out.kind === "unanswered" && out.reason, "tooLarge");
  assert(out.kind === "unanswered" && out.bytes > 10_000 && out.bytes <= 10_000 + 4_096);
  assert(cancelled, "the stream must be cancelled");
});

Deno.test("exchange: a timeout, a network error, non-JSON, missing ids", async () => {
  const hang = stub((_b, signal) => new Promise((_, reject) => signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))));
  assertEquals(await exchange(hang.fn, "https://x.test", calls, { ...opts, timeoutMs: 20 }), { kind: "unanswered", reason: "timeout", bytes: 0 });
  const down = stub(() => { throw new TypeError("connection refused"); });
  assertEquals(await exchange(down.fn, "https://x.test", calls, opts), { kind: "unanswered", reason: "network", bytes: 0 });
  const html = stub(() => new Response("<html>gateway</html>", { status: 200 }));
  assertEquals((await exchange(html.fn, "https://x.test", calls, opts)).kind, "unanswered");
  const missing = stub(() => json([{ id: 1, result: "0x1" }]));
  const m = await exchange(missing.fn, "https://x.test", calls, opts);
  assertEquals(m.kind === "unanswered" && m.reason, "malformed");
  // An injected timer (a test's virtual clock) arms the timeout.
  let fire: (() => void) | null = null;
  const pending = exchange(hang.fn, "https://x.test", calls, { ...opts, setTimer: (_ms, fn) => { fire = fn; return () => {}; } });
  await Promise.resolve();
  (fire as unknown as () => void)();
  assertEquals((await pending), { kind: "unanswered", reason: "timeout", bytes: 0 });
});

Deno.test("mapResults: duplicates and unknown ids are not an answer", () => {
  assertEquals(mapResults([{ id: 1, result: 1 }, { id: 1, result: 2 }], 2), null);
  assertEquals(mapResults([{ id: 3, result: 1 }], 1), null);
  assertEquals(mapResults([{ id: "1", result: 1 }], 1), [{ ok: true, result: 1 }]);
  assertEquals(mapResults({ id: 1, result: 5 }, 1), [{ ok: true, result: 5 }]);
  assertEquals(mapResults({ id: 7, result: 5 }, 1), null);
  assertEquals(mapResults("x", 1), null);
});

Deno.test("exchange: a non-2xx JSON-RPC answer keeps its Retry-After (rpc2's HTTP 429 is a JSON-RPC error); a 200 has none", async () => {
  const g = stub(() => json({ jsonrpc: "2.0", id: null, error: { code: 429, message: "Too Many Requests" } }, 429, { "Retry-After": "60" }));
  const out = await exchange(g.fn, "https://x.test", calls, opts);
  assertEquals(out.kind === "answered" && [out.status, out.retryAfter, out.results.map((r) => !r.ok && r.code)], [429, "60", [429, 429]]);
  const ok = stub(() => json([{ jsonrpc: "2.0", id: 1, result: "0x1" }, { jsonrpc: "2.0", id: 2, result: [] }], 200, { "Retry-After": "5" }));
  const answered = await exchange(ok.fn, "https://x.test", calls, opts);
  assertEquals(answered.kind === "answered" && "retryAfter" in answered, false);
  const none = stub(() => json({ jsonrpc: "2.0", id: null, error: { code: -32005, message: "rate limit" } }, 429));
  const bare = await exchange(none.fn, "https://x.test", calls, opts);
  assertEquals(bare.kind === "answered" && "retryAfter" in bare, false);
});
