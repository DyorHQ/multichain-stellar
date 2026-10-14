// End-to-end journey against Stellar testnet, acting as the phone: the same verify → sign → submit → poll loop
// StellarKit's PlanRunner runs. Needs the lite API running (LITE_API, default http://127.0.0.1:8000/lite) and a
// database the test can write an invite into (LITE_DB_URL; by default the local stack's own, behind LITE_API).
//
//   deno run -A --config backend/supabase/functions/deno.json backend/tests/e2e/lite_e2e.ts [phases...]
//
// Phases run in the order of docs/DESIGN-stellar-parity.md §12.6, each from phases/<name>.ts; name some to run only
// those (default: all). A phase with no checks yet is reported as skipped.
import { Keypair, Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import postgres from "postgres";
import { verifyTransaction } from "../../supabase/functions/_shared/verify.ts";
import activity from "./phases/activity.ts";
import anchor from "./phases/anchor.ts";
import auth from "./phases/auth.ts";
import bridge from "./phases/bridge.ts";
import earn from "./phases/earn.ts";
import fees from "./phases/fees.ts";
import holdings from "./phases/holdings.ts";
import launch from "./phases/launch.ts";
import markets from "./phases/markets.ts";
import moments from "./phases/moments.ts";
import portfolio from "./phases/portfolio.ts";
import prices from "./phases/prices.ts";
import send from "./phases/send.ts";
import session from "./phases/session.ts";
import starter from "./phases/starter.ts";
import swap from "./phases/swap.ts";

/** What every phase gets: the API, the test's account, and the session the auth phase opens. */
export interface E2E {
  API: string;
  db: postgres.Sql;
  user: Keypair;
  /** One unit of a 7-decimal asset, in base units. */
  ONE: bigint;
  /** Set by the auth phase. */
  token: string;
  config: any;
  api(method: string, path: string, body?: unknown): Promise<any>;
  runPlan(plan: any, extraContracts?: string[]): Promise<any[]>;
  indexer(): Promise<{ events: unknown; settled: number; graduated: number }>;
  bal(acct: any, id: string): bigint;
}

/** A phase answers a one-line summary of what it checked, or null when it has no checks yet. */
export type Phase = (t: E2E) => Promise<string | null>;

export const PHASES: [string, Phase][] = [
  ["auth", auth],
  ["session", session],
  ["fees", fees],
  ["starter", starter],
  ["send", send],
  ["swap", swap],
  ["earn", earn],
  ["launch", launch],
  ["moments", moments],
  ["bridge", bridge],
  ["anchor", anchor],
  ["markets", markets],
  ["prices", prices],
  ["holdings", holdings],
  ["portfolio", portfolio],
  ["activity", activity],
];

const API = Deno.env.get("LITE_API") ?? "http://127.0.0.1:8000/lite";

/** LITE_DB_URL, or the local stack's database behind a loopback LITE_API (§6.17): the default stack's Postgres is on
 *  54329 (API on 8000); a stack started with PORT_BASE has it on PORT_BASE + 2 (API on PORT_BASE). A derived URL is
 *  set as LITE_DB_URL too, so the indexer jobs this test runs in-process (indexer()) use the same database. */
function dbUrl(): string {
  const set = Deno.env.get("LITE_DB_URL");
  if (set) return set;
  const api = new URL(API);
  if (api.hostname !== "127.0.0.1" && api.hostname !== "localhost") throw new Error("set LITE_DB_URL: the test writes its invite into the API's database");
  const port = Number(api.port);
  const url = `postgresql://lite_api@127.0.0.1:${port === 8000 ? 54329 : port + 2}/lite`;
  Deno.env.set("LITE_DB_URL", url);
  return url;
}

const only = Deno.args.length ? new Set(Deno.args) : null;
const unknown = Deno.args.filter((a) => !PHASES.some(([name]) => name === a));
if (unknown.length) {
  console.error(`unknown phase ${unknown.join(", ")}; phases: ${PHASES.map(([name]) => name).join(" ")}`);
  Deno.exit(2);
}

const t: E2E = {
  API,
  db: postgres(dbUrl(), { onnotice: () => {} }),
  user: Keypair.random(),
  ONE: 10_000_000n,
  token: "",
  config: undefined,

  async api(method: string, path: string, body?: unknown): Promise<any> {
    const res = await fetch(`${API}/v1${path}`, {
      method,
      headers: { "content-type": "application/json", ...(t.token ? { authorization: `Bearer ${t.token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const json = await res.json();
    if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${JSON.stringify(json.error ?? json)}`);
    return json;
  },

  /** The phone's loop: for each step, build if needed, verify against the pinned allowlist, sign, submit, wait. */
  async runPlan(plan: any, extraContracts: string[] = []): Promise<any[]> {
    const outs: any[] = [];
    for (let i = 0; i < plan.steps.length; i++) {
      let step = plan.steps[i];
      if (!step.xdr) {
        const rebuilt = await t.api("POST", `/plans/${plan.planId}/steps/${step.id}/build`);
        step = rebuilt.steps[i];
      }
      const tx = TransactionBuilder.fromXDR(step.xdr, t.config.passphrase) as Transaction;
      const allowed = new Set<string>([...Object.values(t.config.allowlist as Record<string, string[]>).flat(), ...extraContracts]);
      verifyTransaction(tx, step.intent, { user: t.user.publicKey(), sponsor: t.config.sponsor, passphrase: t.config.passphrase, allowedContracts: allowed });
      tx.sign(t.user);
      const sent = await t.api("POST", "/tx/submit", { planId: plan.planId, stepId: step.id, signedXdr: tx.toEnvelope().toXDR("base64") });
      let status = sent;
      for (let k = 0; k < 40 && status.status === "pending"; k++) {
        await new Promise((r) => setTimeout(r, 1_500));
        status = await t.api("GET", `/tx/${sent.hash}`);
      }
      if (status.status !== "success") throw new Error(`step ${step.id} (${step.label}) ${status.status} ${status.error ?? ""}`);
      outs.push(status);
      console.log(`    ✓ ${step.label} ${sent.hash.slice(0, 12)}…`);
    }
    return outs;
  },

  async indexer() {
    const { indexEvents } = await import("../../supabase/functions/lite-indexer/jobs/main_events.ts");
    const { settlePending } = await import("../../supabase/functions/lite-indexer/jobs/settle.ts");
    const { graduate } = await import("../../supabase/functions/lite-indexer/jobs/graduate.ts");
    return { events: await indexEvents(), settled: await settlePending(), graduated: await graduate() };
  },

  bal(acct: any, id: string): bigint {
    return BigInt(acct.balances.find((b: any) => b.asset === id)?.balance ?? "0");
  },
};

const results: { phase: string; outcome: "PASS" | "FAIL" | "SKIP"; detail: string }[] = [];

for (const [name, run] of PHASES) {
  if (only && !only.has(name)) continue;
  console.log(`▶ ${name}`);
  try {
    const detail = await run(t);
    results.push({ phase: name, outcome: detail === null ? "SKIP" : "PASS", detail: detail ?? "no checks yet" });
    console.log(`  ${detail === null ? "SKIP no checks yet" : `PASS ${detail}`}`);
  } catch (err) {
    results.push({ phase: name, outcome: "FAIL", detail: String((err as Error).message ?? err) });
    console.log(`  FAIL ${(err as Error).message}`);
  }
}

console.log("\n" + results.map((r) => `${r.outcome}  ${r.phase.padEnd(9)} ${r.detail}`).join("\n"));
await t.db.end();
Deno.exit(results.every((r) => r.outcome !== "FAIL") ? 0 : 1);
