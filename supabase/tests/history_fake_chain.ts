// A seeded fake Monad for the history-indexer's run-loop test: a chain of logs and first transactions, and fake JSON-RPC
// endpoints that implement eth_getLogs filter semantics plus the behaviours measured on the public endpoints on
// 2026-10-08 — span limits, 429 with Retry-After, nodes behind the head that refuse (-32014) or silently clamp a range
// crossing their head, HTTP 403 to any JSON-RPC array, an answer that lies once, latency growing with the answer — and
// the failures of a broken endpoint: an HTTP refusal of everything, an error for every call, logs without
// blockTimestamp, a gateway error (HTML) for one range; and Alchemy's documented answers: a 10,000-log cap answered with
// "Log response size exceeded … this block range should work: [a, b]", the Free tier's refusal (HTTP 400), a fetch that
// fails quoting the whole URL.
// Every request is recorded (start time, range, concurrency) for the test's assertions. Not a test file itself.
import type { VirtualClock } from "./history_pglite_db.ts";

export type FakeLog = { address: string; topics: string[]; data: string; block: number; index: number; tx: string };

export const pad = (a: string) => "0x" + "0".repeat(24) + a.slice(2).toLowerCase();
const hex = (n: number) => "0x" + n.toString(16);
const word = (n: number) => "0x" + n.toString(16).padStart(64, "0");

export class FakeChain {
  logs: FakeLog[] = [];
  firstTx = new Map<string, number>();
  private sorted = true;
  private perBlock = new Map<number, number>();
  constructor(public head: number) {}

  add(log: Omit<FakeLog, "index" | "tx"> & { index?: number }): FakeLog {
    const next = this.perBlock.get(log.block) ?? 0;
    const index = log.index ?? next;
    this.perBlock.set(log.block, Math.max(next, index + 1));
    const full = { ...log, address: log.address.toLowerCase(), topics: log.topics.map((t) => t.toLowerCase()), index,
                   tx: word(log.block * 10_000 + index) };
    this.logs.push(full);
    this.sorted = false;
    return full;
  }

  timestamp(block: number) { return 1_700_000_000 + Math.floor(block * 0.4); }

  private ordered(): FakeLog[] {
    if (!this.sorted) { this.logs.sort((a, b) => a.block - b.block || a.index - b.index); this.sorted = true; }
    return this.logs;
  }

  // Logs in [from, to] (the index of the first is found by binary search), matching the filter.
  query(filter: { fromBlock: string; toBlock: string; address?: string | string[]; topics?: (string | string[] | null)[] }, upTo = this.head): FakeLog[] {
    const from = parseInt(filter.fromBlock, 16), to = Math.min(parseInt(filter.toBlock, 16), upTo);
    const logs = this.ordered();
    let lo = 0, hi = logs.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (logs[mid].block < from) lo = mid + 1; else hi = mid; }
    const addresses = filter.address === undefined ? null : new Set((Array.isArray(filter.address) ? filter.address : [filter.address]).map((a) => a.toLowerCase()));
    const topics = (filter.topics ?? []).map((t) => (t === null ? null : new Set((Array.isArray(t) ? t : [t]).map((x) => x.toLowerCase()))));
    const out: FakeLog[] = [];
    for (let k = lo; k < logs.length && logs[k].block <= to; k++) {
      const l = logs[k];
      if (addresses && !addresses.has(l.address)) continue;
      if (topics.some((t, i) => t !== null && !t.has(l.topics[i]))) continue;
      out.push(l);
    }
    return out;
  }

  nonce(wallet: string, block: number): number {
    const first = this.firstTx.get(wallet.toLowerCase());
    return first === undefined || block < first ? 0 : 1 + Math.floor((block - first) / 1_000);
  }

  rpcLog(l: FakeLog) {
    return { address: l.address, topics: l.topics, data: l.data, blockNumber: hex(l.block), transactionHash: l.tx, logIndex: hex(l.index),
             blockTimestamp: hex(this.timestamp(l.block)), blockHash: word(l.block), transactionIndex: "0x0", removed: false };
  }
}

export type FakeBehaviour = {
  url: string;
  span: number;                         // the largest range it answers
  spanMessage: string;                  // what it says to a larger one
  straddle: "refuses" | "clamps";       // what it really does with a range crossing its head
  headLag?: number;                     // its node is this far behind the chain's head
  archive: boolean;
  arrays: "ok" | "403" | "internal";    // a JSON-RPC array: answered, HTTP 403, or every item "Internal error"
  throttleEvery?: number;               // HTTP 429 (a JSON-RPC error, as rpc2 answers) on every Nth request
  throttleLogReads?: boolean;           // that 429 for every eth_getLogs request but the straddle self-test's
  throttleRetryAfter?: number;          // that 429's Retry-After, in seconds (default 2)
  behindEvery?: { n: number; lag: number; kind: "refuses" | "clamps" }; // every Nth request reaches a node behind
  lieOnce?: number;                     // on its Nth eth_getLogs answer, add a log outside the range asked
  latency: (logs: number) => number;    // virtual milliseconds
  refuse?: { status: number; body: string };                      // every request: this HTTP answer (not JSON-RPC)
  callError?: { code: number; message: string };                  // every call: this JSON-RPC error (HTTP 200)
  noTimestamps?: boolean;                                         // logs without blockTimestamp
  gatewayError?: { from: number; to: number; status: number };    // an eth_getLogs request touching [from, to]: HTML
  maxLogs?: number;                     // more logs than this: Alchemy's "Log response size exceeded" with a range that fits
  spanStatus?: number;                  // the HTTP status of its span refusal (Alchemy's Free tier: 400)
  throwFetch?: string;                  // every request: fetch throws a TypeError with this message
};

// `pieces`: the request's eth_getLogs calls, in order — the range, the filter's topics, whether it is the straddle
// self-test's filter (`nothing`), and whether a list of logs for it was delivered (`answered`: not refused, throttled,
// failed or cut off by the client's timeout; the client may still reject it). `bytes`: the size of the reply's body (0
// when none was sent), streamed to the client in one chunk.
export type Recorded = { label: string; at: number; end?: number; status: number; bytes: number;
                         pieces: { from: number; to: number; nothing: boolean; topics: (string[] | null)[]; answered: boolean }[];
                         array: boolean; throttled: boolean; methods: string[] };

export class FakeNetwork {
  readonly records: Recorded[] = [];
  readonly maxInFlight: Record<string, number> = {};
  private readonly inFlight: Record<string, number> = {};
  private readonly counts: Record<string, number> = {};
  private readonly logCounts: Record<string, number> = {};
  lies = 0;

  constructor(private readonly chain: FakeChain, private readonly clock: VirtualClock,
              private readonly endpoints: Record<string, FakeBehaviour>) {}

  fetch = (async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    const label = Object.keys(this.endpoints).find((k) => this.endpoints[k].url === url);
    if (!label) throw new TypeError("unknown host");
    const b = this.endpoints[label];
    const n = (this.counts[label] = (this.counts[label] ?? 0) + 1);
    const body = JSON.parse(String(init?.body));
    const array = Array.isArray(body);
    const calls: { id: number; method: string; params: unknown[] }[] = array ? body : [body];
    const rec: Recorded = { label, at: this.clock.now(), status: 200, bytes: 0, array, throttled: false, methods: calls.map((c) => c.method),
                            pieces: calls.filter((c) => c.method === "eth_getLogs").map((c) => {
                              const f = c.params[0] as Record<string, unknown>;
                              return { from: parseInt(String(f.fromBlock), 16), to: parseInt(String(f.toBlock), 16),
                                       nothing: JSON.stringify(f.topics ?? []).includes("f".repeat(64)),
                                       topics: (f.topics ?? []) as (string[] | null)[], answered: false };
                            }) };
    this.records.push(rec);
    this.inFlight[label] = (this.inFlight[label] ?? 0) + 1;
    this.maxInFlight[label] = Math.max(this.maxInFlight[label] ?? 0, this.inFlight[label]);
    try {
      if (b.throwFetch) throw new TypeError(b.throwFetch);
      if (b.refuse) return this.reply(rec, b.refuse.status, b.refuse.body);
      const g = b.gatewayError;
      if (g && rec.pieces.some((p) => p.from <= g.to && p.to >= g.from)) return this.reply(rec, g.status, "<html><body>502 Bad Gateway</body></html>");
      if (array && b.arrays === "403") return this.reply(rec, 403, "Restricted JSON RPC method");
      const logRead = rec.pieces.length > 0 && rec.pieces.every((p) => !p.nothing);
      if ((b.throttleEvery && n % b.throttleEvery === 0) || (b.throttleLogReads && logRead)) {
        rec.throttled = true;
        return this.reply(rec, 429, JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: 429, message: "Too Many Requests" } }),
                          { "Retry-After": String(b.throttleRetryAfter ?? 2) });
      }
      const behind = b.behindEvery && n % b.behindEvery.n === 0 ? b.behindEvery : null;
      const nodeHead = this.chain.head - (behind?.lag ?? b.headLag ?? 0);
      const straddle = behind?.kind ?? b.straddle;
      let logCount = 0;
      let status = 200;
      const answers = calls.map((c) => {
        const { status: s, ...r } = this.answer(label, b, c, nodeHead, straddle, array);
        if (s) status = Math.max(status, s);
        if (Array.isArray(r.result)) logCount += r.result.length;
        return { jsonrpc: "2.0", id: c.id, ...r };
      });
      await this.wait(b.latency(logCount), init?.signal ?? undefined);
      let k = 0;
      calls.forEach((c, i) => { if (c.method === "eth_getLogs") rec.pieces[k++].answered = Array.isArray((answers[i] as { result?: unknown }).result); });
      return this.reply(rec, status, JSON.stringify(array ? answers : answers[0]));
    } finally {
      this.inFlight[label]--;
      rec.end = this.clock.now();
    }
  }) as typeof fetch;

  private answer(label: string, b: FakeBehaviour, c: { method: string; params: unknown[] }, nodeHead: number,
                 straddle: "refuses" | "clamps", array: boolean): { result?: unknown; error?: { code: number; message: string }; status?: number } {
    if (array && b.arrays === "internal") return { error: { code: -32603, message: "Internal error" } };
    if (b.callError) return { error: b.callError };
    switch (c.method) {
      case "eth_blockNumber": return { result: hex(nodeHead) };
      case "eth_getBlockByNumber": {
        const tag = String(c.params[0]);
        const n = tag === "finalized" || tag === "latest" ? nodeHead : parseInt(tag, 16);
        if (n > nodeHead) return { result: null };
        return { result: { number: hex(n), timestamp: hex(this.chain.timestamp(n)), hash: word(n) } };
      }
      case "eth_getTransactionCount": {
        if (!b.archive) return { error: { code: -32602, message: "Block requested not found. Request might be querying historical state that is not available" } };
        const n = parseInt(String(c.params[1]), 16);
        if (n > nodeHead) return { error: { code: -32602, message: "Block requested not found." } };
        return { result: hex(this.chain.nonce(String(c.params[0]), n)) };
      }
      case "eth_getLogs": {
        const f = c.params[0] as { fromBlock: string; toBlock: string; address?: string[]; topics?: (string[] | null)[] };
        const from = parseInt(f.fromBlock, 16), to = parseInt(f.toBlock, 16);
        if (to - from + 1 > b.span) return { error: { code: b.spanStatus ? -32600 : -32602, message: b.spanMessage }, status: b.spanStatus };
        if (from > nodeHead) {
          return straddle === "refuses" ? { error: { code: -32603, message: "ErrUpstreamBlockUnavailable: requested block is not available yet" } }
                                        : { error: { code: -32602, message: "Block requested not found. Request might be querying historical state that is not available" } };
        }
        if (to > nodeHead && straddle === "refuses") {
          return { error: { code: -32014, message: `block not available: block not found for eth_getLogs, requested toBlock ${to} is not yet available on the node` } };
        }
        const found = this.chain.query(f, nodeHead);
        if (b.maxLogs !== undefined && found.length > b.maxLogs) {
          const fits = Math.max(from, found[b.maxLogs].block - 1); // [from, fits] holds at most maxLogs of them
          return { error: { code: -32602, message: "Log response size exceeded. You can make eth_getLogs requests with up to a 10,000 " +
            "block range and no limit on the response size, or you can request any block range with a cap of 10K logs in the response. " +
            `Based on your parameters and the response size limit, this block range should work: [${hex(from)}, ${hex(fits)}]` } };
        }
        const logs = found.map((l) => this.chain.rpcLog(l)) as Record<string, unknown>[];
        if (b.noTimestamps) for (const l of logs) delete l.blockTimestamp;
        const k = (this.logCounts[label] = (this.logCounts[label] ?? 0) + 1);
        if (b.lieOnce === k && logs.length >= 0) {
          this.lies++;
          const outside = { ...(logs[0] ?? this.chain.rpcLog(this.chain.logs[0])), blockNumber: hex(to + 1), logIndex: "0x63" };
          logs.push(outside);
        }
        return { result: logs };
      }
      default: return { error: { code: -32601, message: "method not found" } };
    }
  }

  private wait(ms: number, signal?: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
      if (signal?.aborted) return reject(new DOMException("aborted", "AbortError"));
      const cancel = this.clock.setTimer(ms, () => { signal?.removeEventListener("abort", onAbort); resolve(); });
      const onAbort = () => { cancel(); reject(new DOMException("aborted", "AbortError")); };
      signal?.addEventListener("abort", onAbort, { once: true });
    });
  }

  private reply(rec: Recorded, status: number, text: string, headers: Record<string, string> = {}): Response {
    rec.status = status;
    const bytes = new TextEncoder().encode(text);
    rec.bytes = bytes.byteLength;
    return new Response(new ReadableStream({ start(c) { c.enqueue(bytes); c.close(); } }), { status, headers });
  }
}
