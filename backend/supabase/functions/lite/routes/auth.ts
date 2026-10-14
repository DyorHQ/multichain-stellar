// Sign-in (SEP-53 challenge, then a Lite JWT), and user(): the session check behind every route that isn't public.
import { assertAccountId, createChallenge, requireUser, verifyChallenge } from "../../_shared/auth.ts";
import { clientIp, json, rateLimit, readJson, Router } from "../../_shared/http.ts";

const sessions = new WeakMap<Request, Promise<string>>();

/** The signed-in tester's address, rate-limited per address. index.ts checks it before any route that isn't public
 *  runs, so a handler's own call answers from that check instead of checking twice. */
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

export function register(router: Router): void {
  router.on("POST /v1/auth/challenge", async ({ req }) => {
    rateLimit(`ip:${clientIp(req)}`, 20);
    const body = await readJson<{ address: string }>(req);
    return json(await createChallenge(assertAccountId(body.address)));
  });

  router.on("POST /v1/auth/verify", async ({ req }) => {
    rateLimit(`ip:${clientIp(req)}`, 20);
    const body = await readJson<{ address: string; nonce: string; signature: string; inviteCode?: string }>(req);
    return json(await verifyChallenge(body));
  });
}
