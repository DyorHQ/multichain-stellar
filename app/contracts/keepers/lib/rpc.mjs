// RPC resilience (build 17, K2 / E5). One public RPC is not enough for an unattended keeper: rpc1 rate-limits a full
// run (11 false criticals in the research run), and any endpoint blips. So:
//  - `--rpc-url` can be repeated: reads go through viem's fallback transport (rpc3, then rpc4 by default), and cast
//    sends through the first endpoint that answers as chain 143.
//  - A read that still fails is told apart from a contract answer: an HTTP error, a timeout, a rate limit or a dropped
//    connection is an RPC failure, which skips that item for this run and is collapsed into one "RPC degraded"
//    warning per run (critical after 3 runs in a row), instead of paging once per item. A revert or a malformed answer
//    is not an RPC failure and still alerts on its own.
import { createPublicClient, fallback, http } from "viem";
import { rpcLabel } from "./redact.mjs";

export const DEFAULT_RPC_URLS = Object.freeze(["https://rpc3.monad.xyz", "https://rpc4.monad.xyz"]);
export const MONAD_CHAIN_ID = 143;
/** Consecutive degraded runs after which the RPC warning becomes critical. */
export const DEGRADED_CRITICAL_RUNS = 3;
/** A latest block older than this (seconds) is a stuck or lagging RPC: its reads are stale, so nothing is sent (a
    Monad block is 0.302 s; a healthy head is a second or two old). Critical from STALE_CRITICAL_S. */
export const STALE_WARN_S = 120;
export const STALE_CRITICAL_S = 600;
/** The same age in Monad blocks, for a log cursor ahead of the head an RPC reports. */
export const STALE_BLOCKS = 400n;

const TRANSPORT_NAMES = new Set(["HttpRequestError", "TimeoutError", "WebSocketRequestError", "SocketClosedError"]);
// Phrases only: a bare number such as 429 or 503 could be a Moment id in a call's arguments.
const TRANSPORT_TEXT = /HTTP request failed|timed out|took too long to respond|fetch failed|socket hang up|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EPIPE|network error|rate.?limit|request limit reached|too many requests|status:? ?(408|429|5\d\d)\b/i;
// A backend behind the others (the public RPCs are load-balanced) asked for a block past its own head. Measured
// 2026-10-01: rpc3 and rpc4 answer -32602 "Block requested not found…"; rpc4 answers a log range past its head with
// -32602 "block range extends beyond current head block".
export const LAG_TEXT = /beyond (the )?current head|block requested not found|header not found|unknown block|block not found/i;
// A provider's quota: the RPC refusing, not the chain answering, and not a range cap.
export const QUOTA_TEXT = /quota|request count|capacity limit|credits|(daily|monthly) (request )?limit/i;
// JSON-RPC errors that are the node failing, never a contract answer (a revert is code 3 on Monad: rpc3 and rpc4).
const RPC_FAILURE_CODES = new Set([-32602, -32603]);

function textOf(x) {
  return `${x.shortMessage ?? ""} ${x.details ?? ""} ${x.message ?? ""}`;
}

/** The network or HTTP layer failing: one level of an error, without its causes. */
function networkFailure(x, text = textOf(x)) {
  if (TRANSPORT_NAMES.has(x.name)) return true;
  if (typeof x.status === "number" && (x.status === 408 || x.status === 429 || x.status >= 500)) return true;
  if (typeof x.code === "string" && /^(ECONN|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EPIPE|UND_ERR)/.test(x.code)) return true;
  // A revert is the chain answering, even when a node words it oddly.
  if (/execution reverted|revert/i.test(text)) return false;
  return TRANSPORT_TEXT.test(text);
}

/** Is `e` (or anything in its cause chain) a failure of the RPC rather than an answer from the chain? The transport
    failing, a quota, a lagging backend, or an internal / invalid-params JSON-RPC error. */
export function isTransportError(e) {
  // The node's own error decides first: viem words a -32603 from eth_call as "reverted with the following reason"
  // (some dev nodes answer reverts that way), but Monad answers a revert with code 3.
  let node;
  for (let x = e, depth = 0; x && depth < 8; x = x.cause, depth++) if (typeof x.code === "number") node = x;
  if (node) {
    const text = textOf(node);
    if (!/revert/i.test(text) && (RPC_FAILURE_CODES.has(node.code) || LAG_TEXT.test(text) || QUOTA_TEXT.test(text))) return true;
  }
  for (let x = e, depth = 0; x && depth < 8; x = x.cause, depth++) {
    const text = textOf(x);
    if (networkFailure(x, text)) return true;
    if (/execution reverted|revert/i.test(text)) return false;
    if (LAG_TEXT.test(text) || QUOTA_TEXT.test(text)) return true;
    if (typeof x.code === "number" && RPC_FAILURE_CODES.has(x.code)) return true;
  }
  return false;
}

/**
 * Is `e` an RPC refusing an eth_getLogs block range (so a smaller range will do), rather than failing? Measured
 * 2026-10-01: rpc3 answers a span of more than 1,000 blocks (inclusive) with -32062 "Block range is too large" in an
 * HTTP 200; rpc4 (some of its backends, above 1,001 blocks) and rpc.monad.xyz (above 101) answer HTTP 413 with -32614
 * "eth_getLogs is limited to a 1,000 range" / "a 100 range", which viem raises as an RPC error; a proxy in front of
 * an RPC can answer a bare HTTP 413, which viem raises as an HttpRequestError (a transport error by name). A rate
 * limit, a quota, or a range past a lagging backend's head is never a range refusal.
 */
export function isRangeRefusal(e) {
  for (let x = e, depth = 0; x && depth < 8; x = x.cause, depth++) {
    const text = textOf(x);
    if (x.status === 429 || /rate.?limit|too many requests|request limit reached/i.test(text) || QUOTA_TEXT.test(text)) return false;
    if (x.status === 413 || x.code === -32062 || x.code === -32614) return true;
    // A range past a lagging backend's head says "range" too, but no smaller range will do.
    if (LAG_TEXT.test(text)) return false;
    if (!networkFailure(x, text) && /range|limit|too many|exceed/i.test(text)) return true;
  }
  return false;
}

/**
 * A viem public client over `urls` (in order). `stats` counts, per endpoint label, the requests that failed on it
 * (whether or not the next endpoint then answered), for the run summary.
 */
export function makeRpcClient(urls, { timeoutMs = 15_000 } = {}) {
  if (!urls?.length) throw new Error("no --rpc-url");
  const stats = Object.fromEntries(urls.map((u) => [rpcLabel(u), { failed: 0, served: 0 }]));
  const byUrl = new Map(urls.map((u) => [u, rpcLabel(u)]));
  const client = createPublicClient({
    transport: fallback(
      urls.map((u) => http(u, { timeout: timeoutMs })),
      { retryCount: 2, retryDelay: 400 },
    ),
  });
  client.transport.onResponse?.(({ status, transport, error }) => {
    const label = byUrl.get(transport?.value?.url);
    if (!label) return;
    // A revert (an optional read the bytecode lacks) is the endpoint answering, not failing.
    if (status === "success" || !isTransportError(error)) stats[label].served++;
    else stats[label].failed++;
  });
  return { client, stats };
}

/**
 * The first endpoint that answers eth_chainId with Monad's chain id and whose latest block is fresh (at most
 * `staleAfterS` old), for cast (which takes one URL) and to be read first. Falls back to the first URL when none
 * does: the run's stale-head check then holds the sends, or they fail on their own and alert.
 */
export async function firstHealthy(urls, { fetchImpl = globalThis.fetch, timeoutMs = 5_000, chainId = MONAD_CHAIN_ID, now = Date.now, staleAfterS = STALE_WARN_S } = {}) {
  const call = async (url, method, params) => {
    const res = await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return (await res.json())?.result;
  };
  for (const url of urls) {
    try {
      const id = await call(url, "eth_chainId", []);
      if (typeof id !== "string" || BigInt(id) !== BigInt(chainId)) continue;
      const block = await call(url, "eth_getBlockByNumber", ["latest", false]);
      const age = Math.floor(now() / 1000) - Number(BigInt(block?.timestamp));
      if (age <= staleAfterS) return { url, healthy: true };
    } catch {
      // next endpoint
    }
  }
  return { url: urls[0], healthy: false };
}

/**
 * Collapses this run's RPC read failures into one alert and keeps the consecutive-run counter in `state.rpc`.
 * Returns the alert to raise, or null for a clean run (which resets the counter).
 */
export function rpcDegradedAlert(state, { failures, skipped = [], stats = {} }) {
  state.rpc ??= {};
  if (failures <= 0) {
    state.rpc.degradedRuns = 0;
    return null;
  }
  const runs = (state.rpc.degradedRuns ?? 0) + 1;
  state.rpc.degradedRuns = runs;
  const endpoints = Object.entries(stats)
    .map(([label, s]) => `${label} failed ${s.failed}, served ${s.served}`) // no ":" right after a URL: redact would eat it
    .join("; ");
  const list = skipped.length ? `; skipped this run: ${skipped.slice(0, 5).join(", ")}${skipped.length > 5 ? ` and ${skipped.length - 5} more` : ""}` : "";
  return {
    job: "keeper",
    target: "rpc",
    key: "rpc:degraded",
    severity: runs >= DEGRADED_CRITICAL_RUNS ? "critical" : "warning",
    reason: `RPC degraded: ${failures} read(s) failed after retries and fallback${endpoints ? ` (${endpoints})` : ""}${list}. ${runs} run(s) in a row${runs >= DEGRADED_CRITICAL_RUNS ? ": the keeper is effectively blind" : ""}`,
  };
}
