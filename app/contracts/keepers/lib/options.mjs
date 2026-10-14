// Command-line options of keeper.mjs, parsed into one plain object that lib/run.mjs takes (so a whole run can be
// tested without a process). Usage errors throw; nothing here reads the network or a key.
import { parseArgs } from "node:util";
import { parseEther } from "viem";
import { DEFAULT_RPC_URLS } from "./rpc.mjs";
import { DEFAULT_LOGS_CHUNK, DEFAULT_LOGS_MAX_BLOCKS } from "./cursor.mjs";
import { REPEAT_DEFAULTS } from "./notify.mjs";

export const JOBS = ["moments-graduation", "buybacks", "sweeps", "launchpad-graduation", "governance"];
export const ROLES = ["keeper", "watchdog"];

export const USAGE = `usage: node contracts/keepers/keeper.mjs <${JOBS.join("|")}|all>... [--send --keystore FILE|--account NAME|--ledger] [--rpc-url URL]... [--logs-cursor [--logs-from N]] [--webhook-file FILE] [--max-spend-per-day MON] [--role keeper|watchdog] [--max-runtime S]
see contracts/keepers/README.md`;

function blockNumber(name, v, { min = 0n } = {}) {
  if (v === undefined) return undefined;
  const s = String(v).replace(/[_,]/g, "");
  if (!/^\d+$/.test(s) || BigInt(s) < min) throw new Error(`--${name} must be a whole number${min > 0n ? ` of at least ${min}` : ""}, got ${JSON.stringify(v)}`);
  return BigInt(s);
}

/** Seconds, or a number with s / m / h / d. */
function duration(name, v) {
  const m = /^(\d+(?:\.\d+)?)([smhd]?)$/.exec(String(v).trim());
  const n = m ? Number(m[1]) * { "": 1, s: 1, m: 60, h: 3_600, d: 86_400 }[m[2]] : NaN;
  if (!Number.isFinite(n) || n <= 0) throw new Error(`--${name} must be a duration such as 3600, 90m or 12h, got ${JSON.stringify(v)}`);
  return n;
}

function mon(name, v) {
  if (v === undefined) return undefined;
  let wei;
  try {
    wei = parseEther(String(v));
  } catch {
    wei = -1n;
  }
  if (wei <= 0n) throw new Error(`--${name} must be a positive amount of MON, got ${JSON.stringify(v)}`);
  return wei;
}

function positiveNumber(name, v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`--${name} must be a positive number of seconds, got ${JSON.stringify(v)}`);
  return n;
}

/**
 * The RPC list when no --rpc-url is given: KEEPER_RPC_URLS (space-separated, in fallback order), else MONAD_RPC_URL,
 * else rpc3 then rpc4. The environment keeps a keyed URL (a restricted provider key) off every command line, where `ps`
 * would show it for the whole run; ops/run-keeper.sh hands the list over this way.
 */
export function defaultRpcUrls(env = process.env) {
  const listed = String(env.KEEPER_RPC_URLS ?? "").split(/\s+/).filter(Boolean);
  if (listed.length) return listed;
  return env.MONAD_RPC_URL ? [env.MONAD_RPC_URL] : [...DEFAULT_RPC_URLS];
}

/**
 * Parses keeper arguments. Returns `{ help: true, ok }` when only usage should be printed (`ok`: it was asked for),
 * else the options. Throws on a usage error.
 */
export function parseKeeperArgs(argv, env = process.env) {
  const { values: o, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      // Repeatable: reads fall back in order (rpc.mjs). rpc3 then rpc4 by default: rpc1 rate-limits a full run, and
      // rpc.monad.xyz caps eth_getLogs at 100 blocks (the scans adapt to that). Without it: defaultRpcUrls(env).
      "rpc-url": { type: "string", multiple: true, default: defaultRpcUrls(env) },
      send: { type: "boolean", default: false },
      role: { type: "string", default: "keeper" },
      keystore: { type: "string" },
      "password-file": { type: "string" },
      account: { type: "string" },
      ledger: { type: "boolean", default: false },
      "hd-path": { type: "string" },
      unlocked: { type: "string" },
      "allow-unlocked": { type: "boolean", default: false },
      "sim-from": { type: "string", default: env.KEEPER_ADDRESS },
      "state-file": { type: "string", default: env.KEEPER_STATE_FILE },
      // The webhook URL is a token: prefer --webhook-file (a 0600 file or a systemd credential) to argv or the env.
      webhook: { type: "string" },
      "webhook-file": { type: "string", default: env.KEEPER_WEBHOOK_FILE },
      "repeat-critical": { type: "string", default: String(REPEAT_DEFAULTS.critical) },
      "repeat-warning": { type: "string", default: String(REPEAT_DEFAULTS.warning) },
      "max-spend-per-day": { type: "string" },
      deployments: { type: "string" },
      "slippage-bps": { type: "string", default: "50" },
      "locker-idle-alert": { type: "string", default: "50000000" },
      "min-sweep-other": { type: "string" },
      "logs-lookback": { type: "string", default: "0" },
      "logs-chunk": { type: "string", default: String(DEFAULT_LOGS_CHUNK) },
      "logs-cursor": { type: "boolean", default: false },
      "logs-from": { type: "string" },
      "logs-max-blocks": { type: "string", default: String(DEFAULT_LOGS_MAX_BLOCKS) },
      "watch-progress-bps": { type: "string", default: "0" },
      "min-balance": { type: "string", default: "2" },
      "max-runtime": { type: "string", default: "240" },
      "only-live": { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  });
  if (o.help || positionals.length === 0) return { help: true, ok: o.help };
  const jobs = positionals.includes("all") ? [...JOBS] : positionals;
  for (const j of jobs) if (!JOBS.includes(j)) throw new Error(`unknown job ${j}`);
  if (!ROLES.includes(o.role)) throw new Error(`--role must be one of ${ROLES.join(", ")}`);
  // The watchdog is a second, key-less pair of eyes (another host, another RPC): it must never be able to send, or two
  // hosts could spend from one key.
  if (o.role === "watchdog" && o.send) throw new Error("--role watchdog never sends: drop --send");
  if (o.webhook && o["webhook-file"]) throw new Error("give --webhook or --webhook-file, not both");
  const signer = o.keystore
    ? { keystore: o.keystore, passwordFile: o["password-file"] }
    : o.account
      ? { account: o.account, passwordFile: o["password-file"] }
      : o.ledger
        ? { ledger: true, hdPath: o["hd-path"] }
        : o.unlocked
          ? { unlocked: o.unlocked }
          : {};
  return {
    help: false,
    jobs,
    send: o.send,
    role: o.role,
    rpcUrls: o["rpc-url"],
    rpcUrl: o["rpc-url"][0],
    signer,
    allowUnlocked: o["allow-unlocked"],
    simFrom: o["sim-from"] || undefined,
    stateFile: o["state-file"] || undefined,
    webhook: o.webhook || (o["webhook-file"] ? undefined : env.KEEPER_WEBHOOK_URL) || undefined,
    webhookFile: o["webhook-file"] || undefined,
    telegramChatId: env.KEEPER_TELEGRAM_CHAT_ID || undefined,
    repeat: { critical: duration("repeat-critical", o["repeat-critical"]), warning: duration("repeat-warning", o["repeat-warning"]) },
    maxSpendPerDay: mon("max-spend-per-day", o["max-spend-per-day"]),
    deployments: o.deployments,
    slippageBps: BigInt(o["slippage-bps"]),
    lockerIdleAlert: BigInt(o["locker-idle-alert"]),
    minSweepOther: o["min-sweep-other"] ? BigInt(o["min-sweep-other"]) : undefined,
    logsLookback: blockNumber("logs-lookback", o["logs-lookback"]),
    logsChunk: blockNumber("logs-chunk", o["logs-chunk"], { min: 1n }),
    logsCursor: o["logs-cursor"],
    logsFrom: blockNumber("logs-from", o["logs-from"]),
    logsMaxBlocks: blockNumber("logs-max-blocks", o["logs-max-blocks"], { min: 1n }),
    watchProgressBps: BigInt(o["watch-progress-bps"]),
    minBalance: o["min-balance"],
    maxRuntime: positiveNumber("max-runtime", o["max-runtime"]),
    onlyLive: o["only-live"],
  };
}
