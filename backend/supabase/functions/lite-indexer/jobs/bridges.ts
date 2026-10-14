// CCTP transfers: follows each burn's attestation and relays the Stellar mint.
import { advanceBridges } from "../../_shared/bridge.ts";

export function bridges(): Promise<number> {
  return advanceBridges();
}
