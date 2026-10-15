// Moments and media (§6.9): the feed, a Moment's page and an account's editions (viewer routes: no session needed,
// §6.0), My Moments (session: DyorHQ's history), metadata, publish and collect plans and upload tickets (session), and
// the local stack's stand-in for Storage. The static paths (owned, mine) come before /v1/moments/:id, which would take
// them otherwise.
import { intArg, json, rateLimit, readJson, Router, stringArg } from "../../_shared/http.ts";
import { readLocal, receiveUpload } from "../../_shared/localmedia.ts";
import { signedUpload } from "../../_shared/media.ts";
import { buildMoment, feed, filterArg, mine, momentDetail, owned, writeMetadata } from "../../_shared/moments.ts";
import { accountViewer, user, viewer } from "./auth.ts";

/** A public view (no token) may be cached for 15 s (§6.0); the owner's view never is. */
const PUBLIC_VIEW = { "cache-control": "public, max-age=15" };

/** The JSON object a request carries; other JSON reads as an object with no fields, which the route's own checks
 *  refuse with 400. */
async function body(req: Request): Promise<Record<string, unknown>> {
  const b = await readJson<unknown>(req);
  return (b !== null && typeof b === "object" && !Array.isArray(b) ? b : {}) as Record<string, unknown>;
}

export function register(router: Router): void {
  router.on("GET /v1/moments", async ({ req, url }) => {
    const v = await viewer(req);
    const q = url.searchParams;
    const moments = await feed(filterArg(q.get("filter")), intArg(q.get("limit") ?? 50, "limit", 1, 100));
    return v.scope === "public" ? json({ moments, view: v.scope }, 200, PUBLIC_VIEW) : json({ moments, view: v.scope });
  });

  // The owner's editions with a token; without one, those of ?address= (400 address_required with neither).
  router.on("GET /v1/moments/owned", async ({ req }) => {
    const v = await accountViewer(req);
    const out = { editions: await owned(v.address), view: v.scope };
    return v.scope === "public" ? json(out, 200, PUBLIC_VIEW) : json(out);
  });

  // My Moments: published and collected, with totals.
  router.on("GET /v1/moments/mine", async ({ req }) => json(await mine(await user(req))));

  router.on("GET /v1/moments/:id", async ({ req, params }) => {
    const v = await viewer(req);
    const detail = await momentDetail(intArg(params.id, "id", 1, 2 ** 31), v);
    return v.scope === "public" ? json(detail, 200, PUBLIC_VIEW) : json(detail);
  });

  router.on("POST /v1/moments/metadata", async ({ req }) => {
    const u = await user(req);
    rateLimit(`metadata:${u}`, 10);
    return json(await writeMetadata(u, await body(req)));
  });

  router.on("POST /v1/moments/build", async ({ req }) => json(await buildMoment(await user(req), await body(req))));

  router.on("POST /v1/media/upload-url", async ({ req }) => {
    const u = await user(req);
    rateLimit(`upload:${u}`, 10);
    const b = await body(req);
    return json(await signedUpload(u, stringArg(b.contentType, "contentType", 40), Number(b.bytes)));
  });

  // Local stack only (testnet, LITE_LOCAL_STORAGE_DIR; 404 anywhere else): a signed upload, then the stored file.
  // Public, like the Storage bucket it stands in for; the upload's token is its own signature.
  router.on("PUT /v1/local-media/upload/:token", async ({ req, params }) => {
    await receiveUpload(params.token, req);
    return new Response(null, { status: 204 });
  });

  router.on("GET /v1/local-media/lite-media/*path", async ({ params }) => {
    const file = await readLocal(params.path);
    // Write-once: a path never changes.
    return new Response(file.bytes, { headers: { "content-type": file.contentType, "cache-control": "public, max-age=31536000, immutable" } });
  });
}
