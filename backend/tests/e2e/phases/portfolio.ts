// portfolio: over a day: launch volume, spot trades and network fees (docs/DESIGN-stellar-parity.md §12.6). No checks
// yet.
import type { E2E } from "../lite_e2e.ts";

export default function portfolio(_t: E2E): Promise<string | null> {
  return Promise.resolve(null);
}
