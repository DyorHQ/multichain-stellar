// markets: XLM and USDC priced, or null and stale when the provider is unreachable, never a constant (docs/DESIGN-
// stellar-parity.md §12.6). No checks yet.
import type { E2E } from "../lite_e2e.ts";

export default function markets(_t: E2E): Promise<string | null> {
  return Promise.resolve(null);
}
