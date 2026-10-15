// auth (docs/DESIGN-stellar-parity.md §1.1 item 6, §4.3, §12.6): sign in, with an invite only where
// config.inviteRequired: on testnet a first sign-in registers the tester, and with LITE_INVITE_REQUIRED=1 one without an
// invite is refused (403) and one with it succeeds; a nonce can't be replayed. Then the account's setup: Friendbot, and
// USDC enabled by a trust step the user pays for (feePayer user, one new reserve), so the account's XLM falls by the fee
// charged and its spendable XLM by that plus the 0.5 XLM reserve, and Horizon names the user as the fee account.
//
// The helpers below are shared by the fee phases (fees, starter, send, swap).
import { Keypair, Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import { hex, SEP53_PREFIX, sha256 } from "../../../supabase/functions/_shared/auth.ts";
import { verifyTransaction } from "../../../supabase/functions/_shared/verify.ts";
import type { E2E } from "../lite_e2e.ts";

/** An answer whatever its status. */
export interface Answer {
  status: number;
  body: any;
  headers: Headers;
}

/** Requests as the holder of `token` (none: no Authorization header), with any `headers` besides. `api` throws unless
 *  the answer is 2xx. */
export function client(t: E2E, token: string | null, headers: Record<string, string> = {}) {
  async function call(method: string, path: string, body?: unknown): Promise<Answer> {
    const res = await fetch(`${t.API}/v1${path}`, {
      method,
      headers: { "content-type": "application/json", ...headers, ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null, headers: res.headers };
  }
  async function api(method: string, path: string, body?: unknown): Promise<any> {
    const a = await call(method, path, body);
    if (a.status < 200 || a.status > 299) throw new Error(`${method} ${path} → ${a.status} ${JSON.stringify(a.body?.error ?? a.body)}`);
    return a.body;
  }
  return { call, api };
}

/** Throws unless `a` is the refusal `status` `code`. */
export function expectRefusal(a: Answer, status: number, code: string, what: string): void {
  if (a.status !== status || a.body?.error?.code !== code) throw new Error(`${what}: expected ${status} ${code}, got ${a.status} ${JSON.stringify(a.body)}`);
}

/** Signs `kp` in (SEP-53) and answers the access token. Where config.inviteRequired, a single-use invite is written into
 *  the database first. */
export async function signIn(t: E2E, kp: Keypair): Promise<string> {
  t.config ??= await client(t, null).api("GET", "/config");
  const { api } = client(t, null);
  let inviteCode: string | undefined;
  if (t.config.inviteRequired !== false) {
    inviteCode = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
    await t.db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(inviteCode))}, 'e2e', 1)`;
  }
  const ch = await api("POST", "/auth/challenge", { address: kp.publicKey() });
  const signature = kp.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message))).toString("base64");
  const v = await api("POST", "/auth/verify", { address: kp.publicKey(), nonce: ch.nonce, signature, ...(inviteCode ? { inviteCode } : {}) });
  return v.token;
}

/** The phone's loop, as `kp` with `token` (and any `headers`): for each step, build if needed, verify against the
 *  pinned allowlist, sign, submit, wait. Answers each step's settled status. */
export async function runAs(t: E2E, kp: Keypair, token: string, plan: any, extraContracts: string[] = [], headers: Record<string, string> = {}): Promise<any[]> {
  const { api } = client(t, token, headers);
  const outs: any[] = [];
  for (let i = 0; i < plan.steps.length; i++) {
    let step = plan.steps[i];
    if (!step.xdr) step = (await api("POST", `/plans/${plan.planId}/steps/${step.id}/build`)).steps[i];
    const tx = TransactionBuilder.fromXDR(step.xdr, t.config.passphrase) as Transaction;
    const allowed = new Set<string>([...Object.values(t.config.allowlist as Record<string, string[]>).flat(), ...extraContracts]);
    verifyTransaction(tx, step.intent, { user: kp.publicKey(), sponsor: t.config.sponsor, passphrase: t.config.passphrase, allowedContracts: allowed });
    tx.sign(kp);
    const sent = await api("POST", "/tx/submit", { planId: plan.planId, stepId: step.id, signedXdr: tx.toEnvelope().toXDR("base64") });
    let status = sent;
    for (let k = 0; k < 40 && status.status === "pending"; k++) {
      await new Promise((r) => setTimeout(r, 1_500));
      status = await api("GET", `/tx/${sent.hash}`);
    }
    if (status.status !== "success") throw new Error(`step ${step.id} (${step.label}) ${status.status} ${status.error ?? ""}`);
    outs.push(status);
    console.log(`    ✓ ${step.label} ${sent.hash.slice(0, 12)}…`);
  }
  return outs;
}

/** A transaction as Horizon reports it (it may trail RPC by a few seconds). */
export async function horizonTx(t: E2E, hash: string): Promise<{ feeAccount: string; feeCharged: bigint; memoType: string; memo: string | null }> {
  for (let i = 0; i < 20; i++) {
    const res = await fetch(`${t.config.horizonUrl}/transactions/${hash}`);
    if (res.ok) {
      const tx = await res.json();
      return { feeAccount: tx.fee_account, feeCharged: BigInt(tx.fee_charged), memoType: tx.memo_type, memo: tx.memo ?? null };
    }
    await res.body?.cancel();
    await new Promise((r) => setTimeout(r, 1_500));
  }
  throw new Error(`Horizon doesn't know ${hash}`);
}

/** Throws unless Horizon says `payer` paid `hash`'s fee, `fee` stroops of it when given. */
export async function expectFeePaidBy(t: E2E, hash: string, payer: string, fee?: bigint): Promise<void> {
  const h = await horizonTx(t, hash);
  if (h.feeAccount !== payer) throw new Error(`${hash.slice(0, 12)}…: Horizon's fee account is ${h.feeAccount}, not ${payer}`);
  if (fee !== undefined && h.feeCharged !== fee) throw new Error(`${hash.slice(0, 12)}…: Horizon charged ${h.feeCharged}, the API says ${fee}`);
}

/** The logged transaction's row. */
export async function logged(t: E2E, hash: string): Promise<any> {
  const [row] = await t.db`select fee_payer, step_kind, section, max_fee, fee_charged, result, status from lite.tx_log where hash = ${hash}`;
  if (!row) throw new Error(`no tx_log row for ${hash}`);
  return row;
}

/** The test's account signed in and set up (Friendbot, USDC enabled): what the auth phase leaves, for a phase run alone. */
export async function setUp(t: E2E): Promise<void> {
  if (t.token) return;
  t.token = await signIn(t, t.user);
  const act = await t.api("POST", "/account/activate");
  if (act.planId) await t.runPlan(act);
}

export default async function auth(t: E2E): Promise<string> {
  const { API, api, db, user } = t;
  t.config = await api("GET", "/config");
  const address = user.publicKey();
  const sign = async () => {
    const ch = await api("POST", "/auth/challenge", { address });
    return { nonce: ch.nonce, signature: user.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message))).toString("base64") };
  };
  const verify = (body: unknown) => fetch(`${API}/v1/auth/verify`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  let invites: string;
  let last: { nonce: string; signature: string };
  if (t.config.inviteRequired === false) {
    // No invite on testnet: the first sign-in registers the address as a tester (still revocable).
    last = await sign();
    const v = await verify({ address, ...last });
    if (v.status !== 200) throw new Error(`a first sign-in without an invite: ${v.status} ${await v.text()}`);
    t.token = (await v.json()).token;
    const [tester] = await db`select invite_id, revoked_at from lite.testers where address = ${address}`;
    if (!tester || tester.invite_id !== null || tester.revoked_at !== null) throw new Error(`the tester wasn't registered: ${JSON.stringify(tester)}`);
    invites = "no invite needed, the tester registered";
  } else {
    // Invites required (mainnet, or LITE_INVITE_REQUIRED=1): refused without one.
    const refused = await verify({ address, ...(await sign()) });
    if (refused.status !== 403) throw new Error(`expected 403 without an invite, got ${refused.status}`);
    await refused.body?.cancel();
    const code = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
    await db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(code))}, 'e2e', 1)`;
    last = await sign();
    const v = await verify({ address, ...last, inviteCode: code });
    if (v.status !== 200) throw new Error(`sign-in with an invite: ${v.status} ${await v.text()}`);
    t.token = (await v.json()).token;
    invites = "an invite required, refused without one";
  }
  // A nonce can't be replayed.
  const replay = await verify({ address, ...last });
  if (replay.status !== 401) throw new Error(`expected 401 on replay, got ${replay.status}`);
  await replay.body?.cancel();

  // Setup: Friendbot, then USDC enabled at the user's cost.
  const act = await t.api("POST", "/account/activate");
  if (!act.planId) throw new Error(`expected a trust plan after Friendbot, got ${JSON.stringify(act).slice(0, 200)}`);
  const step = act.steps[0];
  const shape = [step.stepKind, step.feePayer, step.sponsorReason, step.reserveDelta, act.fees.sponsored, act.fees.newReserves, act.fees.userMax === step.maxFee];
  if (JSON.stringify(shape) !== JSON.stringify(["trust", "user", null, 1, false, 1, true])) throw new Error(`the trust step: ${JSON.stringify(shape)}`);
  const built = TransactionBuilder.fromXDR(step.xdr, t.config.passphrase) as Transaction;
  if (built.fee !== step.maxFee || built.source !== address || built.operations.length !== 1) throw new Error("the trust step's transaction isn't a plain changeTrust the user pays");
  const before = (await t.api("GET", "/account")).xlm;
  const [status] = await t.runPlan(act);
  const after = await t.api("GET", "/account");
  const fee = BigInt(status.feeCharged);
  if (status.feePayer !== "user") throw new Error(`the trust step was paid by ${status.feePayer}`);
  await expectFeePaidBy(t, status.hash, address, fee);
  const fell = BigInt(before.balance) - BigInt(after.xlm.balance);
  const spendableFell = BigInt(before.spendable) - BigInt(after.xlm.spendable);
  if (fell !== fee || spendableFell !== fee + BigInt(after.xlm.baseReserve)) {
    throw new Error(`XLM fell by ${fell} (spendable ${spendableFell}), expected the fee ${fee} (plus the reserve ${after.xlm.baseReserve})`);
  }
  const usdc = after.balances.find((b: any) => b.asset === "USDC");
  if (!after.exists || !usdc?.enabled) throw new Error("account not active with USDC");
  const row = await logged(t, status.hash);
  if (row.fee_payer !== "user" || row.step_kind !== "trust" || row.section !== "account" || String(row.fee_charged) !== String(fee)) {
    throw new Error(`the trust step's log row: ${JSON.stringify(row)}`);
  }
  return `signed in ${address.slice(0, 8)}… (${invites}); USDC enabled at the user's cost: fee ${fee} stroops + the ${Number(after.xlm.baseReserve) / 1e7} XLM reserve, Horizon fee account the user`;
}
