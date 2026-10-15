// CCTP transfers: follows each burn's attestation; the keeper relays the Stellar mint (§4.7, §6.10).
import { advanceBridges } from "../../_shared/bridge.ts";

export function bridges(): Promise<number> {
  return advanceBridges();
}
