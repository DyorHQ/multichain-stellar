// Plans and transactions: build a plan's next step, submit a signed step, follow a transaction (§6.8).
import { json, rateLimit, readJson, Router, stringArg } from "../../_shared/http.ts";
import { buildStep, submitStep, trackTx } from "../../_shared/plans.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("POST /v1/plans/:plan/steps/:step/build", async ({ req, params }) => json(await buildStep(await user(req), params.plan, params.step)));

  router.on("POST /v1/tx/submit", async ({ req }) => {
    const u = await user(req);
    rateLimit(`submit:${u}`, 20);
    const body = await readJson<{ planId: string; stepId: string; signedXdr: string }>(req);
    return json(await submitStep(u, stringArg(body.planId, "planId", 40), stringArg(body.stepId, "stepId", 8), stringArg(body.signedXdr, "signedXdr", 60_000)));
  });

  router.on("GET /v1/tx/:hash", async ({ req, params }) => json(await trackTx(await user(req), params.hash)));
}
