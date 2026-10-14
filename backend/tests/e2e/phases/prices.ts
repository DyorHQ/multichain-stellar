// prices: the XLM reference price.
import type { E2E } from "../lite_e2e.ts";

export default async function prices({ api }: E2E): Promise<string> {
  const p = await api("GET", "/prices");
  return `XLM $${p.usd.XLM.toFixed(4)} (${p.reference})`;
}
