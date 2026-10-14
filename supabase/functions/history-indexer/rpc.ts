// One JSON-RPC exchange: a batch (or, for an endpoint that refuses arrays, a bare object), read as a stream with a byte
// cap so a dense answer (a busy address returned 259k logs in one batch) is cut off long before it costs the isolate's
// memory or CPU. `parseMs` is the JSON.parse time and `bytes` what was streamed (every kind: a tooLarge answer up to its
// cut), both fed to the run's CPU meter.
export type Call = { method: string; params: unknown[] };
export type CallResult = { ok: true; result: unknown } | { ok: false; code?: number; message: string };
// `retryAfter`: a non-2xx JSON-RPC answer's Retry-After header (rpc2 answers HTTP 429 with a JSON-RPC error), as sent.
export type Exchange =
  | { kind: "answered"; results: CallResult[]; bytes: number; parseMs: number; status: number; retryAfter?: string }
  | { kind: "http"; status: number; headers: Headers; body: string; bytes: number } // non-2xx and not JSON-RPC; body ≤ 2 KB kept
  | { kind: "unanswered"; reason: "timeout" | "network" | "malformed" | "tooLarge"; bytes: number };

// `setTimer` (default setTimeout) arms the timeout and returns its cancel: tests pass a virtual clock's.
export type ExchangeOptions = { timeoutMs: number; maxBytes: number; bare: boolean; cpuNow?: () => number;
                                setTimer?: (ms: number, fn: () => void) => () => void };
const realTimer = (ms: number, fn: () => void) => { const t = setTimeout(fn, ms); return () => clearTimeout(t); };
const KEEP_BODY = 2_048;

function callResult(item: unknown): CallResult | null {
  if (!item || typeof item !== "object") return null;
  const r = item as Record<string, unknown>;
  if ("error" in r && r.error && typeof r.error === "object") {
    const e = r.error as Record<string, unknown>;
    return { ok: false, code: typeof e.code === "number" ? e.code : undefined, message: String(e.message ?? "").slice(0, 500) };
  }
  if ("result" in r) return { ok: true, result: r.result };
  return null;
}

// Maps a parsed body onto the calls by id. An array answers each call by its id (in any order); a single error object
// with no usable id (a gateway refusing the whole batch) answers every call with that error. null: not JSON-RPC.
export function mapResults(parsed: unknown, count: number): CallResult[] | null {
  if (Array.isArray(parsed)) {
    const out: (CallResult | null)[] = new Array(count).fill(null);
    for (const item of parsed) {
      const id = (item as { id?: unknown } | null)?.id;
      const index = typeof id === "number" ? id - 1 : typeof id === "string" && /^[0-9]+$/.test(id) ? Number(id) - 1 : -1;
      if (index < 0 || index >= count || out[index]) return null;
      out[index] = callResult(item);
      if (!out[index]) return null;
    }
    return out.every((x) => x !== null) ? out as CallResult[] : null;
  }
  const single = callResult(parsed);
  if (!single) return null;
  const id = (parsed as { id?: unknown }).id;
  if (count === 1 && (id === 1 || id === "1" || (!single.ok && (id === null || id === undefined)))) return [single];
  if (!single.ok && (id === null || id === undefined)) return new Array(count).fill(single);
  return null;
}

export async function exchange(fetchFn: typeof fetch, url: string, calls: Call[], opts: ExchangeOptions): Promise<Exchange> {
  const cpuNow = opts.cpuNow ?? (() => performance.now());
  const payload = opts.bare && calls.length === 1
    ? { jsonrpc: "2.0", id: 1, method: calls[0].method, params: calls[0].params }
    : calls.map((c, i) => ({ jsonrpc: "2.0", id: i + 1, method: c.method, params: c.params }));
  const controller = new AbortController();
  let timedOut = false;
  const cancelTimer = (opts.setTimer ?? realTimer)(opts.timeoutMs, () => { timedOut = true; controller.abort(); });
  let bytes = 0;
  try {
    let res: Response;
    try {
      res = await fetchFn(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept-Encoding": "gzip" },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
    } catch {
      return { kind: "unanswered", reason: timedOut ? "timeout" : "network", bytes: 0 };
    }
    const chunks: Uint8Array[] = [];
    try {
      if (res.body) {
        const reader = res.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          bytes += value.byteLength;
          if (bytes > opts.maxBytes) {
            controller.abort();
            await reader.cancel().catch(() => {});
            return { kind: "unanswered", reason: "tooLarge", bytes };
          }
          chunks.push(value);
        }
      }
    } catch {
      return { kind: "unanswered", reason: timedOut ? "timeout" : "network", bytes };
    }
    const all = new Uint8Array(bytes);
    let at = 0;
    for (const c of chunks) { all.set(c, at); at += c.byteLength; }
    const text = new TextDecoder().decode(all);
    const started = cpuNow();
    let parsed: unknown = undefined;
    let parsedOk = true;
    try { parsed = JSON.parse(text); } catch { parsedOk = false; }
    const parseMs = Math.max(0, cpuNow() - started);
    const results = parsedOk ? mapResults(parsed, calls.length) : null;
    if (results) {
      const retryAfter = res.ok ? null : res.headers.get("retry-after");
      return { kind: "answered", results, bytes, parseMs, status: res.status, ...(retryAfter ? { retryAfter } : {}) };
    }
    if (!res.ok) return { kind: "http", status: res.status, headers: res.headers, body: text.slice(0, KEEP_BODY), bytes };
    return { kind: "unanswered", reason: "malformed", bytes };
  } finally {
    cancelTimer();
  }
}
