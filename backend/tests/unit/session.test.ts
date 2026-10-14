// Sessions without gating (docs/DESIGN-stellar-parity.md §5.9, §6.18; §12.5): verify hands out a refresh token that
// starts a family; a refresh spends it and hands out its successor; presenting a spent token revokes the family, its
// successor included; unknown, expired and revoked tokens get refresh_invalid; a revoked tester gets 403 and the family
// goes; sign-out revokes a family and answers 204 for any token; the access token lives an hour. Then the invite gate:
// none on testnet (a first sign-in registers the tester), required with LITE_INVITE_REQUIRED=1 as on mainnet, an invite
// that is given is still checked and used, and an existing tester's is ignored.
//
// The database is a stand-in that answers _shared/auth.ts's own statements from rows held here, as Postgres would
// (the statements themselves run on Postgres in backend/tests/sql/auth_refresh_test.sql and the e2e session phase).
import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, goOffline, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
for (const name of ["LITE_INVITE_REQUIRED", "LITE_JWT_TTL_S", "LITE_REFRESH_TTL_S"]) Deno.env.delete(name);
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const auth = await import("../../supabase/functions/_shared/auth.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

const DAY = 86_400_000;

interface RefreshRow {
  id: string;
  family: string;
  address: string;
  token_hash: string;
  created_at: Date;
  expires_at: Date;
  used_at: Date | null;
  revoked_at: Date | null;
  replaced_by: string | null;
}

interface Tester {
  address: string;
  invite_id: string | null;
  label: string | null;
  revoked_at: Date | null;
}

interface Invite {
  id: string;
  code_hash: string;
  label: string;
  max_uses: number;
  uses: number;
  expires_at: Date;
}

/** lite.auth_nonces, testers, invites and auth_refresh, answering the statements below. */
class Tables {
  nonces = new Map<string, { address: string; message: string; used: boolean }>();
  testers = new Map<string, Tester>();
  invites: Invite[] = [];
  refresh: RefreshRow[] = [];
  /** Every statement and every parameter the code sent. */
  queries: string[] = [];
  sent: unknown[] = [];

  constructor() {
    replaceSql(fakeSql((q, ps) => {
      this.queries.push(q);
      this.sent.push(...ps);
      return this.answer(q, ps);
    }));
  }

  private live = (r: RefreshRow, now: Date) => r.used_at === null && r.revoked_at === null && r.expires_at > now;

  private revokeFamily(family: string | undefined): void {
    for (const r of this.refresh) if (r.family === family && r.revoked_at === null) r.revoked_at = new Date();
  }

  private answer(q: string, ps: unknown[]): Row[] {
    const now = new Date();
    const p = ps as any[];
    switch (q) {
      case "insert into lite.auth_nonces (nonce, address, message, expires_at) values (?, ?, ?, ?)":
        this.nonces.set(p[0], { address: p[1], message: p[2], used: false });
        return [];
      case "update lite.auth_nonces set used_at = now() where nonce = ? and address = ? and used_at is null and expires_at > now() returning message": {
        const n = this.nonces.get(p[0]);
        if (!n || n.address !== p[1] || n.used) return [];
        n.used = true;
        return [{ message: n.message }];
      }
      case "select address, label, revoked_at from lite.testers where address = ?": {
        const t = this.testers.get(p[0]);
        return t ? [{ address: t.address, label: t.label, revoked_at: t.revoked_at }] : [];
      }
      case "select 1 from lite.testers where address = ? and revoked_at is null":
        return this.testers.get(p[0])?.revoked_at === null ? [{ "?column?": 1 }] : [];
      case "select label from lite.testers where address = ? and revoked_at is null": {
        const t = this.testers.get(p[0]);
        return t && t.revoked_at === null ? [{ label: t.label }] : [];
      }
      case "insert into lite.testers (address) values (?) on conflict (address) do nothing":
        if (!this.testers.has(p[0])) this.testers.set(p[0], { address: p[0], invite_id: null, label: null, revoked_at: null });
        return [];
      case "update lite.invites set uses = uses + 1 where code_hash = ? and uses < max_uses and expires_at > now() returning id, label": {
        const inv = this.invites.find((i) => i.code_hash === p[0] && i.uses < i.max_uses && i.expires_at > now);
        if (!inv) return [];
        inv.uses++;
        return [{ id: inv.id, label: inv.label }];
      }
      case "insert into lite.testers (address, invite_id, label) values (?, ?, ?)":
        this.testers.set(p[0], { address: p[0], invite_id: p[1], label: p[2], revoked_at: null });
        return [];
      case "select to_regclass(?) is not null as present":
        return [{ present: true }];
      case "insert into lite.auth_refresh (family, address, token_hash, expires_at) values (?, ?, ?, ?)":
      case "insert into lite.auth_refresh (family, address, token_hash, expires_at) values (?, ?, ?, ?) returning id": {
        if (this.refresh.some((r) => r.token_hash === p[2])) throw new Error("duplicate key value violates unique constraint");
        const row: RefreshRow = { id: crypto.randomUUID(), family: p[0], address: p[1], token_hash: p[2], created_at: now, expires_at: p[3], used_at: null, revoked_at: null, replaced_by: null };
        this.refresh.push(row);
        return q.endsWith("returning id") ? [{ id: row.id }] : [];
      }
      case "update lite.auth_refresh set used_at = now() where token_hash = ? and address = ? and used_at is null and revoked_at is null and expires_at > now() returning id, family": {
        const r = this.refresh.find((r) => r.token_hash === p[0] && r.address === p[1] && this.live(r, now));
        if (!r) return [];
        r.used_at = now;
        return [{ id: r.id, family: r.family }];
      }
      case "select family, used_at from lite.auth_refresh where token_hash = ? and address = ?":
        return this.refresh.filter((r) => r.token_hash === p[0] && r.address === p[1]).map((r) => ({ family: r.family, used_at: r.used_at }));
      case "update lite.auth_refresh set revoked_at = now() where family = ? and revoked_at is null":
        this.revokeFamily(p[0]);
        return [];
      case "update lite.auth_refresh set revoked_at = now() where family = (select family from lite.auth_refresh where token_hash = ?) and revoked_at is null":
        this.revokeFamily(this.refresh.find((r) => r.token_hash === p[0])?.family);
        return [];
      case "update lite.auth_refresh set replaced_by = ? where id = ?":
        for (const r of this.refresh) if (r.id === p[1]) r.replaced_by = p[0];
        return [];
      case "delete from lite.auth_refresh where id in (select id from lite.auth_refresh where expires_at < now() - interval '7 days' limit 500)": {
        const old = this.refresh.filter((r) => r.expires_at.getTime() < now.getTime() - 7 * DAY).slice(0, 500);
        this.refresh = this.refresh.filter((r) => !old.includes(r));
        return [];
      }
    }
    throw new Error(`unexpected query: ${q}`);
  }

  tester(address: string, label: string | null = "Internal QA"): void {
    this.testers.set(address, { address, invite_id: null, label, revoked_at: null });
  }
}

async function hashOf(token: string): Promise<string> {
  return auth.hex(await auth.sha256(token));
}

async function rowOf(db: Tables, token: string): Promise<RefreshRow> {
  const hash = await hashOf(token);
  const row = db.refresh.find((r) => r.token_hash === hash);
  assert(row, "no row for that token");
  return row;
}

async function signIn(kp: Keypair, inviteCode?: string) {
  const ch = await auth.createChallenge(kp.publicKey());
  const signature = kp.sign(Buffer.from(await auth.sha256(auth.SEP53_PREFIX + ch.message))).toString("base64");
  return await auth.verifyChallenge({ address: kp.publicKey(), nonce: ch.nonce, signature, inviteCode });
}

/** The ApiError `fn` throws: [status, code]. */
async function refusal(fn: () => Promise<unknown>): Promise<[number, string]> {
  const err = await assertRejects(fn, ApiError);
  return [err.status, err.code];
}

const lifetimeOf = (jwt: string) => {
  const claims = JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  return claims.exp - claims.iat;
};
const near = (at: Date | string, ms: number) => Math.abs(new Date(at).getTime() - (Date.now() + ms)) < 5_000;
const fixture = async (name: string) => JSON.parse(await Deno.readTextFile(new URL(`../fixtures/api/${name}.json`, import.meta.url)));

// ------------------------------------------------------------------------------------------------ refresh tokens

Deno.test("verify starts a family with one refresh token, stored as its hash; the access token lives an hour", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey());
  const v = await signIn(kp);
  assertEquals(lifetimeOf(v.token), 3600);
  assert(/^lrt_[A-Za-z0-9_-]{43}$/.test(v.refreshToken!));
  const row = await rowOf(db, v.refreshToken!);
  assertEquals([row.address, row.used_at, row.revoked_at, row.replaced_by], [kp.publicKey(), null, null, null]);
  assert(near(row.expires_at, 30 * DAY) && row.expires_at.toISOString() === v.refreshExpiresAt);
  assert(!db.sent.some((p) => typeof p === "string" && p.includes(v.refreshToken!.slice(4))), "the token reached the database");
});

Deno.test("refresh rotates: the token is spent, its successor joins the family, and both tokens are new", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey(), "Internal QA");
  const v = await signIn(kp);
  const r = await auth.refreshSession({ address: kp.publicKey(), refreshToken: v.refreshToken! });
  assertEquals(Object.keys(r), Object.keys(await fixture("auth-refresh")));
  assertEquals(r.tester, { address: kp.publicKey(), label: "Internal QA" });
  // The refresh token is new. The access token is a fresh one too, though within the same second its claims, and so
  // its bytes, equal the last one's.
  assert(r.refreshToken !== v.refreshToken);
  assert(new Date(r.expiresAt).getTime() >= new Date(v.expiresAt).getTime());
  assertEquals(lifetimeOf(r.token), 3600);
  assertEquals((await auth.verifyJwt(r.token)).sub, kp.publicKey());
  const spent = await rowOf(db, v.refreshToken!);
  const successor = await rowOf(db, r.refreshToken!);
  assert(spent.used_at !== null && spent.revoked_at === null);
  assertEquals([spent.replaced_by, successor.family, successor.used_at], [successor.id, spent.family, null]);
  // A sliding lifetime: 30 days from this refresh.
  assert(near(successor.expires_at, 30 * DAY) && successor.expires_at.toISOString() === r.refreshExpiresAt);
  // The successor refreshes in turn.
  const again = await auth.refreshSession({ address: kp.publicKey(), refreshToken: r.refreshToken! });
  assertEquals((await rowOf(db, again.refreshToken!)).family, spent.family);
});

Deno.test("a spent token presented again revokes its family: 401 refresh_reused, and its successor stops working", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey());
  const v = await signIn(kp);
  const other = await signIn(kp); // another device's family
  const r = await auth.refreshSession({ address: kp.publicKey(), refreshToken: v.refreshToken! });
  assertEquals(await refusal(() => auth.refreshSession({ address: kp.publicKey(), refreshToken: v.refreshToken! })), [401, "refresh_reused"]);
  const family = (await rowOf(db, v.refreshToken!)).family;
  assert(db.refresh.filter((x) => x.family === family).every((x) => x.revoked_at !== null), "the family is revoked");
  assertEquals(await refusal(() => auth.refreshSession({ address: kp.publicKey(), refreshToken: r.refreshToken! })), [401, "refresh_invalid"]);
  // The other family is untouched.
  assertEquals((await rowOf(db, other.refreshToken!)).revoked_at, null);
  await auth.refreshSession({ address: kp.publicKey(), refreshToken: other.refreshToken! });
});

Deno.test("unknown, malformed, expired, revoked and another address's tokens get refresh_invalid and revoke nothing", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  const someone = Keypair.random();
  db.tester(kp.publicKey());
  db.tester(someone.publicKey());
  const v = await signIn(kp);
  const refresh = (refreshToken: unknown, address = kp.publicKey()) => refusal(() => auth.refreshSession({ address, refreshToken: refreshToken as string }));
  for (const token of [`lrt_${"A".repeat(43)}`, "lrt_short", v.refreshToken!.slice(4), "", undefined, 42]) {
    assertEquals(await refresh(token), [401, "refresh_invalid"], String(token));
  }
  // Presented for another address: refused, and kp's token still works afterwards.
  assertEquals(await refresh(v.refreshToken!, someone.publicKey()), [401, "refresh_invalid"]);
  assertEquals((await rowOf(db, v.refreshToken!)).revoked_at, null);
  assertEquals(await refusal(() => auth.refreshSession({ address: "GNOPE", refreshToken: v.refreshToken! })), [400, "bad_address"]);
  // Expired.
  const e = await signIn(kp);
  (await rowOf(db, e.refreshToken!)).expires_at = new Date(Date.now() - 1_000);
  assertEquals(await refresh(e.refreshToken!), [401, "refresh_invalid"]);
  // Revoked by a sign-out.
  const s = await signIn(kp);
  await auth.revokeSession(s.refreshToken);
  assertEquals(await refresh(s.refreshToken!), [401, "refresh_invalid"]);
  // None of these revoked v's family.
  await auth.refreshSession({ address: kp.publicKey(), refreshToken: v.refreshToken! });
});

Deno.test("a tester turned off gets 403 access_revoked on refresh, and the family goes", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey());
  const v = await signIn(kp);
  db.testers.get(kp.publicKey())!.revoked_at = new Date();
  assertEquals(await refusal(() => auth.refreshSession({ address: kp.publicKey(), refreshToken: v.refreshToken! })), [403, "access_revoked"]);
  const family = (await rowOf(db, v.refreshToken!)).family;
  assert(db.refresh.filter((x) => x.family === family).every((x) => x.revoked_at !== null));
  assertEquals(db.refresh.length, 1, "no successor");
});

Deno.test("sign-out revokes the token's family and nothing else; any other token changes nothing", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey());
  const v = await signIn(kp);
  const r = await auth.refreshSession({ address: kp.publicKey(), refreshToken: v.refreshToken! });
  const other = await signIn(kp);
  // Signing out with the spent token ends the family all the same.
  await auth.revokeSession(v.refreshToken);
  assertEquals(await refusal(() => auth.refreshSession({ address: kp.publicKey(), refreshToken: r.refreshToken! })), [401, "refresh_invalid"]);
  const before = JSON.stringify(db.refresh);
  for (const token of [`lrt_${"B".repeat(43)}`, "nope", undefined, null, 7]) await auth.revokeSession(token);
  assertEquals(JSON.stringify(db.refresh), before);
  assertEquals((await rowOf(db, other.refreshToken!)).revoked_at, null);
});

Deno.test("a refresh deletes at most 500 tokens that expired more than a week ago", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey());
  const old = (i: number, days: number): RefreshRow => ({
    id: crypto.randomUUID(),
    family: crypto.randomUUID(),
    address: kp.publicKey(),
    token_hash: `${i}`.padStart(64, "0"),
    created_at: new Date(Date.now() - (days + 30) * DAY),
    expires_at: new Date(Date.now() - days * DAY),
    used_at: null,
    revoked_at: null,
    replaced_by: null,
  });
  db.refresh.push(...Array.from({ length: 502 }, (_, i) => old(i, 8)), old(999, 6));
  const v = await signIn(kp);
  await auth.refreshSession({ address: kp.publicKey(), refreshToken: v.refreshToken! });
  assertEquals(db.refresh.filter((r) => r.expires_at.getTime() < Date.now() - 7 * DAY).length, 2);
  assertEquals(db.refresh.length, 2 + 1 + 2);
});

// ------------------------------------------------------------------------------------------------ the invite gate

Deno.test("testnet: a first sign-in needs no invite and registers the tester, who can still be revoked", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  const v = await signIn(kp);
  assertEquals(v.tester, { address: kp.publicKey(), label: null });
  assertEquals(db.testers.get(kp.publicKey()), { address: kp.publicKey(), invite_id: null, label: null, revoked_at: null });
  assert(!db.queries.some((q) => q.includes("lite.invites")), "no invite was looked at");
  // Signed in like any tester: the session check passes, and a revocation still applies at once.
  const req = () => new Request("http://127.0.0.1/lite/v1/activity", { headers: { authorization: `Bearer ${v.token}` } });
  assertEquals(await auth.requireUser(req()), kp.publicKey());
  db.testers.get(kp.publicKey())!.revoked_at = new Date();
  assertEquals(await refusal(() => auth.requireUser(req())), [403, "access_revoked"]);
  assertEquals(await refusal(() => signIn(kp)), [403, "access_revoked"]);
});

Deno.test("testnet: an invite that is given is still checked, and used", async () => {
  const db = new Tables();
  db.invites.push({ id: crypto.randomUUID(), code_hash: await hashOf("DYOR-ABCDE-FGHJK"), label: "Jay", max_uses: 1, uses: 0, expires_at: new Date(Date.now() + DAY) });
  assertEquals(await refusal(() => signIn(Keypair.random(), "DYOR-WRONG-CODE0")), [403, "bad_invite"]);
  const kp = Keypair.random();
  const v = await signIn(kp, " dyor-abcde-fghjk ");
  assertEquals([v.tester.label, db.invites[0].uses, db.testers.get(kp.publicKey())?.invite_id], ["Jay", 1, db.invites[0].id]);
});

Deno.test("LITE_INVITE_REQUIRED=1, as on mainnet: a first sign-in without an invite is refused as before", async () => {
  Deno.env.set("LITE_INVITE_REQUIRED", "1");
  try {
    const db = new Tables();
    db.invites.push({ id: crypto.randomUUID(), code_hash: await hashOf("DYOR-ABCDE-FGHJK"), label: "Jay", max_uses: 1, uses: 0, expires_at: new Date(Date.now() + DAY) });
    const kp = Keypair.random();
    assertEquals(await refusal(() => signIn(kp)), [403, "not_invited"]);
    assertEquals(db.testers.size, 0);
    const v = await signIn(kp, "DYOR-ABCDE-FGHJK");
    assertEquals([v.tester.label, db.invites[0].uses], ["Jay", 1]);
    assert(v.refreshToken);
  } finally {
    Deno.env.delete("LITE_INVITE_REQUIRED");
  }
});

Deno.test("an existing tester's invite code is ignored, not used", async () => {
  for (const required of [undefined, "1"]) {
    if (required) Deno.env.set("LITE_INVITE_REQUIRED", required);
    try {
      const db = new Tables();
      const kp = Keypair.random();
      db.tester(kp.publicKey(), "Early tester");
      db.invites.push({ id: crypto.randomUUID(), code_hash: await hashOf("DYOR-ABCDE-FGHJK"), label: "Jay", max_uses: 1, uses: 0, expires_at: new Date(Date.now() + DAY) });
      const v = await signIn(kp, "DYOR-ABCDE-FGHJK");
      assertEquals([v.tester.label, db.invites[0].uses], ["Early tester", 0]);
      assert(!db.queries.some((q) => q.includes("lite.invites")), "the invite was looked at");
    } finally {
      Deno.env.delete("LITE_INVITE_REQUIRED");
    }
  }
});

// ------------------------------------------------------------------------------------------------ over HTTP

function post(path: string, body: unknown, ip = "192.0.2.10"): Promise<Response> {
  return handle(new Request(`http://127.0.0.1/functions/v1/lite/v1${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-forwarded-for": ip },
    body: typeof body === "string" ? body : JSON.stringify(body),
  }));
}

Deno.test("POST /v1/auth/refresh answers a sign-in's fields; a reused token gets the contract's error body", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey());
  const v = await signIn(kp);
  const ok = await post("/auth/refresh", { address: kp.publicKey(), refreshToken: v.refreshToken });
  assertEquals([ok.status, ok.headers.get("cache-control")], [200, "no-store"]);
  assertEquals(Object.keys(await ok.json()), Object.keys(await fixture("auth-refresh")));
  const reused = await post("/auth/refresh", { address: kp.publicKey(), refreshToken: v.refreshToken });
  assertEquals([reused.status, await reused.json()], [401, await fixture("error-refresh-reused")]);
  const invalid = await post("/auth/refresh", { address: kp.publicKey(), refreshToken: "nope" });
  assertEquals([invalid.status, (await invalid.json()).error.code], [401, "refresh_invalid"]);
});

Deno.test("POST /v1/auth/signout answers 204 with no body, for any token and any body", async () => {
  const db = new Tables();
  const kp = Keypair.random();
  db.tester(kp.publicKey());
  const v = await signIn(kp);
  for (const body of [{ refreshToken: v.refreshToken }, { refreshToken: `lrt_${"C".repeat(43)}` }, {}, "not json", ""]) {
    const res = await post("/auth/signout", body);
    assertEquals([res.status, await res.text()], [204, ""], JSON.stringify(body));
  }
  assert(db.refresh.every((r) => r.revoked_at !== null));
});

Deno.test("refresh is limited to 30 and sign-out to 20 a minute per IP", async () => {
  new Tables();
  for (const [path, limit] of [["/auth/refresh", 30], ["/auth/signout", 20]] as const) {
    const ip = `198.51.100.${limit}`;
    for (let i = 0; i < limit; i++) assert((await post(path, { refreshToken: "nope" }, ip)).status !== 429, `${path} ${i + 1}`);
    const over = await post(path, { refreshToken: "nope" }, ip);
    assertEquals([over.status, (await over.json()).error.code], [429, "rate_limited"], path);
  }
});
