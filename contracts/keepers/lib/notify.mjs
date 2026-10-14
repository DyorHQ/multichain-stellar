// Alert delivery that people can live with (build 17, K3: E3, E4).
//
// E3: every alert has a stable `key` (reasons carry changing numbers, such as seconds left). A key is posted when it is
// new or its severity rose; a standing critical is repeated every --repeat-critical (1 h), a standing warning every
// --repeat-warning (12 h); a posted key that clears is posted as "resolved", but only after a job that completed saw it
// clear (a skipped read proves nothing). One-off events (a governance log, a failed send) are posted once and never
// resolve; one whose post was not delivered is posted by the next runs from its history (the event itself is never
// raised again: its log cursor has moved on), until it is delivered or a week has passed. Info alerts are never
// posted; stdout keeps every alert. The history lives in the state file (`state.notify.keys`), so dedup needs
// --state-file.
//
// E4: the payload is chosen from the webhook URL: Slack `{text}`; Discord native `{content, allowed_mentions:{parse:[]}}`
// in chunks of at most 1,900 characters (Discord refuses more than 2,000, and `{text}` only works on its /slack URL);
// Telegram `{chat_id, text, disable_notification}` in chunks of at most 4,000 (chat id from KEEPER_TELEGRAM_CHAT_ID;
// warnings arrive silently, criticals loud); anything else the original `{text, alerts}`. Each POST is retried 3 times
// with backoff (honouring 429 retry_after). What is not delivered stays unposted, so the next run sends it again, and
// the run exits 1. The URL (a token) never appears in an error, a log line or argv: --webhook-file reads it from a file.
import { readFileSync } from "node:fs";
import { urlOrigin } from "./redact.mjs";

export const REPEAT_DEFAULTS = Object.freeze({ critical: 3_600, warning: 43_200 });
/** How long a one-off event's key is remembered (so a re-scanned log is not posted twice). */
export const ONCE_KEEP_S = 7 * 86_400;
export const LIMITS = Object.freeze({ discord: 1_900, "discord-slack": 1_900, telegram: 4_000, slack: 3_900, generic: Infinity });

const RANK = { info: 0, warning: 1, critical: 2 };
const isSerious = (a) => a.severity === "warning" || a.severity === "critical";

// ------------------------------------------------------------------------------------------------ E3: what to post

/**
 * Decides this run's posts. `alerts`: the run's alerts (with `key`); `holds`: keys a job re-confirmed without raising
 * them again (a throttled condition); `completed`: the jobs (and "keeper") that ran to the end with every read
 * answered; `history`: `state.notify.keys`, updated in place except for delivery (see `commitPosts`); `now`: unix s.
 * Returns the items to post, most urgent first.
 */
export function planPosts({ alerts, holds = new Set(), completed = new Set(), history, now, repeat = REPEAT_DEFAULTS }) {
  const current = new Map();
  for (const a of alerts) {
    if (!isSerious(a) || a.rpc) continue; // RPC-skipped items are posted as the one "RPC degraded" alert
    const prev = current.get(a.key);
    if (!prev || RANK[a.severity] > RANK[prev.severity]) current.set(a.key, a);
  }
  const items = [];
  for (const [key, a] of current) {
    let h = history[key];
    if (!h) h = history[key] = { job: a.job, target: a.target, firstSeen: now, ...(a.once ? { once: true } : {}) };
    delete h.resolving; // back before its "resolved" was delivered: it simply stands
    Object.assign(h, { job: a.job, target: a.target, severity: a.severity, reason: String(a.reason).slice(0, 500), lastSeen: now });
    const base = { key, job: a.job, target: a.target, severity: a.severity, reason: a.reason, firstSeen: h.firstSeen, alert: a };
    if (!h.posted) items.push({ ...base, kind: "new" });
    else if (RANK[a.severity] > RANK[h.posted.severity]) items.push({ ...base, kind: "escalated", was: h.posted.severity });
    else if (h.once) continue;
    else if (RANK[a.severity] < RANK[h.posted.severity]) h.posted.severity = a.severity; // quieter now: repeat on its cadence
    else if (now - h.posted.at >= repeat[a.severity]) items.push({ ...base, kind: "repeat" });
  }
  for (const [key, h] of Object.entries(history)) {
    if (current.has(key)) continue;
    if (holds.has(key)) {
      h.lastSeen = now;
      continue;
    }
    if (h.once) {
      if (now - (h.lastSeen ?? now) > ONCE_KEEP_S) {
        delete history[key];
        continue;
      }
      // A one-off event is never raised again (its log cursor moved on; a failed send's key carries its time), so one
      // whose post was not delivered is posted from its history until it is (or a week has passed).
      if (!h.posted && (h.severity === "warning" || h.severity === "critical")) {
        items.push({ key, kind: "new", late: true, job: h.job, target: h.target, severity: h.severity, reason: h.reason ?? "", firstSeen: h.firstSeen });
      }
      continue;
    }
    if (!completed.has(h.job)) continue; // not checked this run (or not fully): it may still stand
    if (!h.posted) {
      delete history[key]; // cleared before anyone was told: nothing to resolve
      continue;
    }
    h.resolving = true;
    items.push({ key, kind: "resolved", job: h.job, target: h.target, severity: "resolved", was: h.posted.severity, reason: h.reason ?? "", firstSeen: h.firstSeen });
  }
  // New and escalated criticals, then new warnings, then the repeats, then what resolved.
  const order = (i) => (i.kind === "resolved" ? 4 : (i.kind === "repeat" ? 2 : 0) + (i.severity === "critical" ? 0 : 1));
  return items.sort((x, y) => order(x) - order(y));
}

/** Writes a one-off alert into the history before the run posts (a failed send, saved with the spend it caused), so
    that a run killed before it posts still has it posted by the next run. */
export function rememberOnce(history, a, now) {
  if (history[a.key]) return;
  history[a.key] = { job: a.job, target: a.target, firstSeen: now, once: true, severity: a.severity, reason: String(a.reason).slice(0, 500), lastSeen: now };
}

/** Records what was delivered: a delivered post marks its key posted (now, at this severity); a delivered "resolved"
    forgets the key. Anything undelivered is left as it was, so the next run posts it again. */
export function commitPosts(history, items, delivered, now) {
  for (const i of items) {
    if (!delivered.has(i.key) || !history[i.key]) continue;
    if (i.kind === "resolved") delete history[i.key];
    else history[i.key].posted = { severity: i.severity, at: now };
  }
}

// ------------------------------------------------------------------------------------------------ E4: how to post

/** Which payload a webhook URL takes. */
export function webhookKind(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return "generic";
  }
  const host = u.hostname.toLowerCase();
  if (host === "hooks.slack.com") return "slack";
  if (/(^|\.)discord(app)?\.com$/.test(host) && u.pathname.startsWith("/api/webhooks/")) return /\/slack\/?$/.test(u.pathname) ? "discord-slack" : "discord";
  if (host === "api.telegram.org") return "telegram";
  return "generic";
}

/** Telegram takes the bot's sendMessage method; a bare bot URL gets it appended. */
function telegramUrl(url) {
  const u = new URL(url);
  if (!/\/sendMessage\/?$/.test(u.pathname)) u.pathname = `${u.pathname.replace(/\/$/, "")}/sendMessage`;
  return u.toString();
}

function iso(s) {
  return new Date(Number(s) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** One line per item. */
export function formatItem(i) {
  const where = `${i.job} · ${i.target}`;
  if (i.kind === "resolved") return `[resolved, was ${i.was}] ${where}: ${i.reason}`;
  const sev = i.severity === "critical" ? "CRITICAL" : "warning";
  const tag = i.kind === "escalated" ? `${sev}, was ${i.was}` : i.kind === "repeat" ? `${sev}, still, since ${iso(i.firstSeen)}` : i.late ? `${sev}, raised ${iso(i.firstSeen)}, not delivered then` : sev;
  return `[${tag}] ${where}: ${i.reason}`;
}

function summary(items) {
  const n = (k) => items.filter((i) => i.kind === k).length;
  const crit = items.filter((i) => i.kind !== "resolved" && i.severity === "critical").length;
  const parts = [];
  if (crit) parts.push(`${crit} critical`);
  if (n("new") + n("escalated")) parts.push(`${n("new") + n("escalated")} new`);
  if (n("repeat")) parts.push(`${n("repeat")} still open`);
  if (n("resolved")) parts.push(`${n("resolved")} resolved`);
  return parts.join(", ");
}

/**
 * The POST bodies for `items`, chunked to the channel's limit. Returns [{ body, keys, loud }]: the keys a payload
 * carries (marked delivered only if it is), and whether it holds a critical (Telegram notifies only then).
 */
export function buildPayloads({ kind, items, title, chatId }) {
  const limit = LIMITS[kind] ?? Infinity;
  const header = `${title}: ${summary(items)}`;
  const room = header.length + 12; // the header, plus " (n/m)" when there are several chunks
  const maxLine = Number.isFinite(limit) ? limit - room - 1 : Infinity;
  const lines = items.map((i) => {
    const text = formatItem(i);
    return { item: i, text: text.length > maxLine ? `${text.slice(0, maxLine - 1)}…` : text };
  });
  const chunks = [];
  let cur = [];
  let len = room;
  for (const l of lines) {
    if (cur.length && len + 1 + l.text.length > limit) {
      chunks.push(cur);
      cur = [];
      len = room;
    }
    cur.push(l);
    len += 1 + l.text.length;
  }
  if (cur.length) chunks.push(cur);
  return chunks.map((c, n) => {
    const text = [chunks.length > 1 ? `${header} (${n + 1}/${chunks.length})` : header, ...c.map((x) => x.text)].join("\n");
    const keys = c.map((x) => x.item.key);
    const loud = c.some((x) => x.item.kind !== "resolved" && x.item.severity === "critical");
    let body;
    if (kind === "discord") body = { content: text, allowed_mentions: { parse: [] } };
    else if (kind === "telegram") body = { chat_id: chatId, text, disable_notification: !loud };
    else if (kind === "slack" || kind === "discord-slack") body = { text };
    else body = { text, alerts: c.map((x) => ({ key: x.item.key, kind: x.item.kind, severity: x.item.severity, job: x.item.job, target: x.item.target, reason: x.item.reason })) };
    return { body, keys, loud, length: text.length };
  });
}

const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));

/** Seconds a 429 asks to wait (Discord `retry_after`, Telegram `parameters.retry_after`, or Retry-After). */
async function retryAfter(res) {
  const h = Number(res.headers?.get?.("retry-after"));
  if (Number.isFinite(h) && h > 0) return h;
  try {
    const j = await res.json();
    const v = Number(j?.retry_after ?? j?.parameters?.retry_after);
    return Number.isFinite(v) && v > 0 ? v : undefined;
  } catch {
    return undefined;
  }
}

/**
 * POSTs the payloads in order, each up to 1 + `retries` times (1 s, 2 s, 4 s backoff; a 429's own wait, at most 30 s),
 * within `budgetMs` overall. Stops at the first payload that cannot be delivered. Returns the delivered keys and, on
 * failure, an error that names the channel kind and the HTTP status, never the URL.
 */
export async function deliver(url, payloads, { kind = webhookKind(url), fetchImpl = globalThis.fetch, sleep = sleepMs, retries = 3, timeoutMs = 10_000, budgetMs = 60_000, now = Date.now } = {}) {
  const target = kind === "telegram" ? telegramUrl(url) : url;
  const delivered = new Set();
  const until = now() + budgetMs;
  for (const [n, p] of payloads.entries()) {
    let why;
    for (let attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        const wait = Math.min(why?.retryAfterS ? why.retryAfterS * 1000 : 1000 * 2 ** (attempt - 1), 30_000);
        if (now() + wait > until) break;
        await sleep(wait);
      }
      try {
        const res = await fetchImpl(target, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(p.body), signal: AbortSignal.timeout(timeoutMs) });
        if (res.ok) {
          why = undefined;
          break;
        }
        why = { text: `HTTP ${res.status}`, retryAfterS: res.status === 429 ? await retryAfter(res) : undefined };
        if (!(res.status === 408 || res.status === 429 || res.status >= 500)) break; // a bad URL or payload: retrying will not help
      } catch (e) {
        why = { text: e?.name === "TimeoutError" || e?.name === "AbortError" ? "timed out" : `network error (${e?.cause?.code ?? e?.code ?? "unreachable"})` };
      }
      if (now() >= until) break;
    }
    if (why) return { delivered, error: `${kind} webhook POST ${n + 1}/${payloads.length} to ${urlOrigin(url)} failed: ${why.text}` };
    for (const k of p.keys) delivered.add(k);
    if (n < payloads.length - 1) await sleep(kind === "discord" || kind === "discord-slack" ? 500 : 100); // Discord: 5 requests / 2 s per webhook
  }
  return { delivered };
}

/** The webhook URL from --webhook-file: its first non-empty line. The file's content is never echoed. */
export function readWebhookFile(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    throw new Error(`cannot read --webhook-file (${e.code ?? "error"})`);
  }
  const line = text.split(/\r?\n/).map((l) => l.trim()).find((l) => l.length > 0);
  let ok = false;
  try {
    ok = !!line && ["https:", "http:"].includes(new URL(line).protocol);
  } catch {
    ok = false;
  }
  if (!ok) throw new Error("--webhook-file does not hold an http(s) URL on its first line");
  return line;
}
