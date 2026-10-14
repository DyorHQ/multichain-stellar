// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
import { assertEquals } from "jsr:@std/assert@1";
import { gateRefusal } from "./rate.ts";

const cors = { "Access-Control-Allow-Origin": "*" };

Deno.test("gateRefusal: proceeds only on {ok: true}", () => {
  assertEquals(gateRefusal({ ok: true }, false, cors), null);
});

Deno.test("gateRefusal: a refusal is a 429 with Retry-After and the limit that fired", async () => {
  const res = gateRefusal({ retryAfter: 12.2, limit: "network" }, false, cors)!;
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("Retry-After"), "13");
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(await res.json(), { error: "too many requests — try again later", retryAfter: 13, limit: "network" });
  const odd = gateRefusal({ retryAfter: 0, limit: "something" }, false, cors)!;
  assertEquals(await odd.json(), { error: "too many requests — try again later", retryAfter: 1 });
  const overall = gateRefusal({ retryAfter: 600, limit: "global" }, false, cors)!;
  assertEquals((await overall.json()).limit, "global");
});

Deno.test("gateRefusal: an RPC error or an unexpected answer fails closed as a retryable 503", async () => {
  for (const [data, failed] of [[null, true], [{ ok: true }, true], [null, false], ["ok", false], [{ ok: "yes" }, false], [{ retryAfter: "9" }, false]] as const) {
    const res = gateRefusal(data, failed, cors)!;
    assertEquals(res.status, 503, JSON.stringify(data));
    assertEquals((await res.json()).retryable, true);
  }
});
