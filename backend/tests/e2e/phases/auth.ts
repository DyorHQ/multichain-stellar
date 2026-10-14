// auth: sign in with an invite (refused without one; a nonce can't be replayed), then activate the account.
import { hex, SEP53_PREFIX, sha256 } from "../../../supabase/functions/_shared/auth.ts";
import type { E2E } from "../lite_e2e.ts";

export default async function auth(t: E2E): Promise<string> {
  const { API, api, bal, db, ONE, runPlan, user } = t;
  t.config = await api("GET", "/config");
  const code = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
  await db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(code))}, 'e2e', 1)`;
  const ch = await api("POST", "/auth/challenge", { address: user.publicKey() });
  const sig = user.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message)));
  // Without the invite: refused.
  const refused = await fetch(`${API}/v1/auth/verify`, { method: "POST", body: JSON.stringify({ address: user.publicKey(), nonce: ch.nonce, signature: sig.toString("base64") }) });
  if (refused.status !== 403) throw new Error(`expected 403 without invite, got ${refused.status}`);
  const ch2 = await api("POST", "/auth/challenge", { address: user.publicKey() });
  const sig2 = user.sign(Buffer.from(await sha256(SEP53_PREFIX + ch2.message)));
  const v = await api("POST", "/auth/verify", { address: user.publicKey(), nonce: ch2.nonce, signature: sig2.toString("base64"), inviteCode: code });
  t.token = v.token;
  // Nonce replay is refused.
  const replay = await fetch(`${API}/v1/auth/verify`, { method: "POST", body: JSON.stringify({ address: user.publicKey(), nonce: ch2.nonce, signature: sig2.toString("base64") }) });
  if (replay.status !== 401) throw new Error(`expected 401 on replay, got ${replay.status}`);
  // Activate: Friendbot on testnet, then a sponsored USDC trustline.
  const act = await api("POST", "/account/activate");
  if (act.planId) await runPlan(act);
  const acct = await api("GET", "/account");
  const usdc = acct.balances.find((b: any) => b.asset === "USDC");
  if (!acct.exists || !usdc.enabled) throw new Error("account not active with USDC");
  return `signed in ${user.publicKey().slice(0, 8)}…, XLM ${bal(acct, "XLM") / ONE}, USDC enabled (reserve sponsored: ${acct.reserves.sponsoredByDyorHQ})`;
}
