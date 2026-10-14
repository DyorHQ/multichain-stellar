// Sessions (§6.18): sign-in (SEP-53 challenge, then an access JWT and a refresh token), renewal and sign-out; and the
// checks behind the routes that aren't public: user() for a session, viewer() for a read whose session is optional.
import { assertAccountId, createChallenge, refreshSession, requireUser, revokeSession, verifyChallenge } from "../../_shared/auth.ts";
import type { View } from "../../_shared/contract.ts";
import { bad, clientIp, json, rateLimit, readJson, Router } from "../../_shared/http.ts";

const sessions = new WeakMap<Request, Promise<string>>();

/** The signed-in tester's address, rate-limited per address. index.ts checks it before any session route runs, and
 *  before a viewer route that carries a token, so a handler's own call answers from that check instead of checking
 *  twice. */
export function user(req: Request): Promise<string> {
  let address = sessions.get(req);
  if (!address) {
    address = (async () => {
      const a = await requireUser(req);
      rateLimit(`u:${a}`, 120);
      return a;
    })();
    sessions.set(req, address);
  }
  return address;
}

/** Whether a request carries an Authorization header. One that does is checked as a session, whatever it holds: a
 *  token that is invalid or expired gets 401, never the public view, so the phone renews instead of getting less. */
export function hasToken(req: Request): boolean {
  return req.headers.has("authorization");
}

/** Whom a viewer route answers for (§6.0): with a token, its own account (`owner`); without one, the public view of
 *  the account ?address= names, or of none (`address` null). */
export interface Viewer {
  address: string | null;
  scope: View;
}

export async function viewer(req: Request): Promise<Viewer> {
  if (hasToken(req)) return { address: await user(req), scope: "owner" };
  const named = new URL(req.url).searchParams.get("address");
  return { address: named ? assertAccountId(named) : null, scope: "public" };
}

/** viewer() for a route about an account (account, holdings, earn/positions, moments/owned): 400 address_required
 *  with neither a token nor ?address=. */
export async function accountViewer(req: Request): Promise<Viewer & { address: string }> {
  const v = await viewer(req);
  if (v.address === null) throw bad("address_required", "Sign in, or name the account with ?address=G….");
  return { address: v.address, scope: v.scope };
}

/** The JSON object a request carries. Other JSON (null, an array, a string, a number) reads as an empty object, so its
 *  fields count as missing (400 or 401) instead of failing the request as 500. */
async function readBody<T>(req: Request): Promise<T> {
  const body = await readJson<unknown>(req);
  return (body !== null && typeof body === "object" && !Array.isArray(body) ? body : {}) as T;
}

export function register(router: Router): void {
  router.on("POST /v1/auth/challenge", async ({ req }) => {
    rateLimit(`ip:${clientIp(req)}`, 20);
    const body = await readBody<{ address: string }>(req);
    return json(await createChallenge(assertAccountId(body.address)));
  });

  router.on("POST /v1/auth/verify", async ({ req }) => {
    rateLimit(`ip:${clientIp(req)}`, 20);
    const body = await readBody<{ address: string; nonce: string; signature: string; inviteCode?: string }>(req);
    return json(await verifyChallenge(body));
  });

  router.on("POST /v1/auth/refresh", async ({ req }) => {
    rateLimit(`refresh:${clientIp(req)}`, 30);
    const body = await readBody<{ address: string; refreshToken: string }>(req);
    return json(await refreshSession(body));
  });

  // 204 whatever the body holds: the answer says nothing about which refresh tokens exist.
  router.on("POST /v1/auth/signout", async ({ req }) => {
    rateLimit(`signout:${clientIp(req)}`, 20);
    const body = await readBody<{ refreshToken?: unknown }>(req).catch(() => ({ refreshToken: undefined }));
    await revokeSession(body.refreshToken);
    return new Response(null, { status: 204 });
  });
}
