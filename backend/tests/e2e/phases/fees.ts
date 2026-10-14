// fees: Max sends XLM down to the minimum balance; a swap is then refused before signing for its fee; the faucet
// restores (docs/DESIGN-stellar-parity.md §12.6). No checks yet.
import type { E2E } from "../lite_e2e.ts";

export default function fees(_t: E2E): Promise<string | null> {
  return Promise.resolve(null);
}
