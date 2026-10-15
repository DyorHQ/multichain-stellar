// Network fees (public; docs/DESIGN-stellar-parity.md §6.3): GET /v1/fees, the base reserve, the inclusion bid and an
// estimate per step kind, from what each kind declared over the last 7 days.
import { feesView } from "../../_shared/fees.ts";
import { json, PUBLIC_CACHE, Router } from "../../_shared/http.ts";

export function register(router: Router): void {
  router.on("GET /v1/fees", async () => json(await feesView(), 200, PUBLIC_CACHE));
}
