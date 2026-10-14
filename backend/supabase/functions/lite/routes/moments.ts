// Moments and media: the feed, Moment pages, editions owned, My Moments, metadata, publish and collect, uploads, and
// the local stack's stand-in for Storage (§6.9). The static paths (owned, mine) come before /v1/moments/:id, which
// would take them otherwise.
import { intArg, json, notImplemented, rateLimit, readJson, Router, stringArg } from "../../_shared/http.ts";
import { signedUpload } from "../../_shared/media.ts";
import { buildMoment, feed, momentDetail, owned, writeMetadata } from "../../_shared/moments.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/moments", async ({ req, url }) => {
    await user(req);
    return json({ moments: await feed(intArg(url.searchParams.get("limit") ?? 50, "limit", 1, 100)) });
  });

  router.on("GET /v1/moments/owned", async ({ req }) => json({ editions: await owned(await user(req)) }));

  // My Moments: published and collected, with totals.
  router.on("GET /v1/moments/mine", async ({ req }) => {
    await user(req);
    throw notImplemented();
  });

  router.on("GET /v1/moments/:id", async ({ req, params }) => {
    await user(req);
    return json(await momentDetail(intArg(params.id, "id", 1, 2 ** 31)));
  });

  router.on("POST /v1/moments/metadata", async ({ req }) => {
    const u = await user(req);
    return json({ uri: await writeMetadata(u, await readJson(req)) });
  });

  router.on("POST /v1/moments/build", async ({ req }) => json(await buildMoment(await user(req), await readJson(req))));

  router.on("POST /v1/media/upload-url", async ({ req }) => {
    const u = await user(req);
    rateLimit(`upload:${u}`, 10);
    const body = await readJson<{ contentType: string; bytes: number }>(req);
    return json(await signedUpload(u, stringArg(body.contentType, "contentType", 40), Number(body.bytes)));
  });

  // Local stack only (testnet, LITE_LOCAL_STORAGE_DIR): a signed upload, then the stored file. Public, like the
  // Storage bucket it stands in for; the upload's token is its own signature.
  router.on("PUT /v1/local-media/upload/:token", () => Promise.reject(notImplemented()));
  router.on("GET /v1/local-media/lite-media/*path", () => Promise.reject(notImplemented()));
}
