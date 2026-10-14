// session: sessions without gating (docs/DESIGN-stellar-parity.md §5.9, §6.18, §12.6). A first sign-in needs an invite
// only where config.inviteRequired, and registers the tester otherwise; verify hands out a refresh token, stored only as
// its SHA-256; a refresh rotates it; presenting a spent one ends its family, successor included; sign-out ends a family
// and answers 204 for any token or body; a revoked tester's refresh gets 403. On a stack with short sessions
// (LITE_JWT_TTL_S, local-stack.sh --short-sessions), a request after the access token expired gets 401 and succeeds
// after one refresh. The viewer routes whose handlers already serve the public view answer it for ?address= with no
// token. The phase signs in throwaway accounts of its own, so it runs with or without the auth phase.
import { Keypair } from "@stellar/stellar-sdk";
import { hex, SEP53_PREFIX, sha256 } from "../../../supabase/functions/_shared/auth.ts";
import type { E2E } from "../lite_e2e.ts";

/** Waiting for an access token to expire is checked only when it lives at most this long. */
const SHORT_SESSION_S = 300;

interface Answer {
  status: number;
  body: any;
  cacheControl: string | null;
}

export default async function session(t: E2E): Promise<string> {
  const { API, db } = t;
  t.config ??= await t.api("GET", "/config");

  /** One request with this token, or none: the answer whatever its status. */
  async function call(method: string, path: string, body?: unknown, token?: string): Promise<Answer> {
    const res = await fetch(`${API}/v1${path}`, {
      method,
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null, cacheControl: res.headers.get("cache-control") };
  }

  function expect(a: Answer, status: number, code: string | null, what: string): void {
    if (a.status !== status || (code !== null && a.body?.error?.code !== code)) {
      throw new Error(`${what}: expected ${status}${code ? ` ${code}` : ""}, got ${a.status} ${JSON.stringify(a.body)}`);
    }
  }

  async function signIn(kp: Keypair, inviteCode?: string): Promise<Answer> {
    const ch = await t.api("POST", "/auth/challenge", { address: kp.publicKey() });
    const signature = kp.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message))).toString("base64");
    return await call("POST", "/auth/verify", { address: kp.publicKey(), nonce: ch.nonce, signature, ...(inviteCode ? { inviteCode } : {}) });
  }

  const refresh = (kp: Keypair, refreshToken: string) => call("POST", "/auth/refresh", { address: kp.publicKey(), refreshToken });
  const signout = (refreshToken: unknown) => call("POST", "/auth/signout", { refreshToken });
  // A session route that reads only the database.
  const history = (token: string) => call("GET", "/activity", undefined, token);

  // 1. A first sign-in: an invite only where the network asks for one.
  const kp = Keypair.random();
  const address = kp.publicKey();
  let first: Answer;
  let invites: string;
  if (t.config.inviteRequired === false) {
    first = await signIn(kp);
    expect(first, 200, null, "a first sign-in without an invite");
    const [tester] = await db`select invite_id, revoked_at from lite.testers where address = ${address}`;
    if (!tester || tester.invite_id !== null || tester.revoked_at !== null) throw new Error(`the tester wasn't registered: ${JSON.stringify(tester)}`);
    invites = "none needed, the tester registered";
  } else {
    expect(await signIn(kp), 403, "not_invited", "a first sign-in without an invite");
    const code = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
    await db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(code))}, 'e2e session', 1)`;
    first = await signIn(kp, code);
    expect(first, 200, null, "a first sign-in with an invite");
    invites = "required, and the first sign-in without one refused";
  }

  // 2. verify's answer: an access token whose expiresAt is its exp, and a refresh token stored only as its hash.
  const v = first.body;
  if (!/^lrt_[A-Za-z0-9_-]{43}$/.test(v.refreshToken ?? "")) throw new Error(`no refresh token: ${JSON.stringify(Object.keys(v))}`);
  const claims = JSON.parse(atob(v.token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  const lifetime = claims.exp - claims.iat;
  if (new Date(v.expiresAt).getTime() !== claims.exp * 1000) throw new Error("expiresAt isn't the access token's exp");
  const short = lifetime <= SHORT_SESSION_S;
  if (!short && lifetime !== 3600) throw new Error(`the access token lives ${lifetime} s, not an hour`);
  if (!(new Date(v.refreshExpiresAt).getTime() > new Date(v.expiresAt).getTime())) throw new Error("the refresh token ends before the access token");
  const stored = await db`select * from lite.auth_refresh where address = ${address}`;
  if (stored.length !== 1 || stored[0].token_hash !== hex(await sha256(v.refreshToken))) throw new Error("the refresh token isn't stored as its SHA-256");
  if (JSON.stringify(stored).includes(v.refreshToken.slice(4))) throw new Error("the refresh token itself reached the database");
  expect(await history(v.token), 200, null, "a session route with the new token");

  // 3. A refresh rotates the token within its family.
  const r1 = await refresh(kp, v.refreshToken);
  expect(r1, 200, null, "a refresh");
  if (r1.body.refreshToken === v.refreshToken) throw new Error("the refresh didn't rotate the refresh token");
  expect(await history(r1.body.token), 200, null, "a session route after the refresh");
  const chain = await db`select token_hash, family, used_at, replaced_by, id from lite.auth_refresh where address = ${address} order by created_at`;
  if (chain.length !== 2 || chain[0].family !== chain[1].family || !chain[0].used_at || chain[0].replaced_by !== chain[1].id) {
    throw new Error("the successor isn't recorded in the same family");
  }

  // 4. Presenting the spent token again ends the family: it is refused, and so is its successor.
  expect(await refresh(kp, v.refreshToken), 401, "refresh_reused", "the spent token again");
  expect(await refresh(kp, r1.body.refreshToken), 401, "refresh_invalid", "the successor of a reused token");

  // 5. Sign-out ends a family, and answers 204 for tokens it doesn't know.
  const s = (await signIn(kp)).body;
  const out = await signout(s.refreshToken);
  if (out.status !== 204 || out.body !== null) throw new Error(`sign-out: expected 204 and no body, got ${out.status}`);
  expect(await refresh(kp, s.refreshToken), 401, "refresh_invalid", "a refresh after sign-out");
  for (const unknown of [`lrt_${"A".repeat(43)}`, "not-a-token", undefined]) {
    const a = await signout(unknown);
    if (a.status !== 204) throw new Error(`sign-out of ${String(unknown)}: expected 204, got ${a.status}`);
  }
  // A body that isn't a JSON object reads as one with no fields.
  const nullBody = await call("POST", "/auth/signout", null);
  if (nullBody.status !== 204) throw new Error(`sign-out with a null body: expected 204, got ${nullBody.status}`);
  expect(await call("POST", "/auth/refresh", null), 400, "bad_address", "a refresh with a null body");

  // 6. Short sessions: once the access token has expired, a request is refused and succeeds after one refresh.
  let expiry = `access tokens live ${lifetime} s, so expiry isn't waited for (run the stack with short sessions)`;
  if (short) {
    const e = (await signIn(kp)).body;
    const wait = new Date(e.expiresAt).getTime() - Date.now() + 1_500;
    console.log(`    waiting ${Math.ceil(wait / 1000)} s for the access token to expire`);
    await new Promise((r) => setTimeout(r, Math.max(wait, 0)));
    expect(await history(e.token), 401, "unauthorized", "a session route with an expired token");
    expect(await call("GET", "/account", undefined, e.token), 401, "unauthorized", "a viewer route with an expired token");
    const renewed = await refresh(kp, e.refreshToken);
    expect(renewed, 200, null, "the refresh after expiry");
    expect(await history(renewed.body.token), 200, null, "the request again after one refresh");
    expiry = `after ${lifetime} s an access token gets 401, and one refresh renews it`;
  }

  // 7. Viewer routes: a token that is present but invalid gets 401, never the public view; without a token, the
  //    routes whose handlers serve the public view answer it for ?address=.
  expect(await call("GET", `/account?address=${address}`, undefined, "not-a-token"), 401, "unauthorized", "a viewer route with a bad token");
  const served: string[] = [];
  const waiting: string[] = [];
  const unwritten: string[] = [];
  const views = [`/account?address=${address}`, `/holdings?address=${address}`, `/earn/positions?address=${address}`, `/moments/owned?address=${address}`, `/launches?address=${address}`, `/moments?address=${address}`, `/assets?q=XLM&address=${address}`];
  for (const path of views) {
    const a = await call("GET", path);
    const route = path.split("?")[0];
    // 401: its handler still asks for a session; 404: not written yet (WP-10, WP-14, WP-15, WP-16 and WP-18 serve them).
    if (a.status === 401 || a.status === 404) {
      (a.status === 401 ? waiting : unwritten).push(route);
      continue;
    }
    if (a.status !== 200 || a.body?.view !== "public" || a.cacheControl !== "public, max-age=15") {
      throw new Error(`public view of ${route}: ${a.status} view ${a.body?.view} cache-control ${a.cacheControl}`);
    }
    served.push(route);
  }

  // 8. A tester turned off can't renew: 403, and the family is revoked.
  const last = (await signIn(kp)).body;
  await db`update lite.testers set revoked_at = now() where address = ${address}`;
  expect(await refresh(kp, last.refreshToken), 403, "access_revoked", "a revoked tester's refresh");
  const [family] = await db`
    select count(*)::int as live from lite.auth_refresh
     where family = (select family from lite.auth_refresh where token_hash = ${hex(await sha256(last.refreshToken))}) and revoked_at is null`;
  if (family.live !== 0) throw new Error(`${family.live} refresh tokens of the family still live after the tester was revoked`);

  return [
    `invites: ${invites}`,
    "refresh rotates, a reused token ends its family, sign-out ends one (204 for any token or body), a revoked tester gets 403",
    expiry,
    `public views: ${served.length ? served.join(", ") : "none served yet"}`,
    ...(waiting.length ? [`still asking for a session: ${waiting.join(", ")}`] : []),
    ...(unwritten.length ? [`not written yet: ${unwritten.join(", ")}`] : []),
  ].join("; ");
}
