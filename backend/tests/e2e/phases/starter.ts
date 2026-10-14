// starter: with --activation sponsored, the first USDC → XLM swap is sponsored once, the next user-paid, a third
// refused (docs/DESIGN-stellar-parity.md §12.6). No checks yet.
import type { E2E } from "../lite_e2e.ts";

export default function starter(_t: E2E): Promise<string | null> {
  return Promise.resolve(null);
}
