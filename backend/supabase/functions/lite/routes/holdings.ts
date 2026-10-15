// Holdings: GET /v1/holdings, everything the account holds, valued, for Home and Portfolio (§6.5). A viewer route: the
// owner's view with a token; without one, the public view of ?address= (400 address_required with neither).
import { holdings, publicHoldings } from "../../_shared/holdings.ts";
import { json, PUBLIC_VIEW_CACHE, Router } from "../../_shared/http.ts";
import { accountViewer } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/holdings", async ({ req }) => {
    const v = await accountViewer(req);
    if (v.scope === "owner") return json(await holdings(v.address, "owner"));
    return json(await publicHoldings(v.address), 200, PUBLIC_VIEW_CACHE);
  });
}
