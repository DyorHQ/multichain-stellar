// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { redactor, scrubUrls } from "./redact.ts";

// Test values only: a made-up host and key.
const KEY = "fAkEaLcHeMyKeY-must-never-be-logged-0123";
const URL_ = `https://monad-mainnet.g.alchemy.test/v2/${KEY}`;
const leaks = (text: string) => text.includes(KEY) || text.includes("/v2/fAkE") || text.includes(URL_);

Deno.test("redactor: the keyed URL, whole or in parts, becomes its label wherever the runtime or a provider quotes it", () => {
  const redact = redactor([{ url: URL_, label: "alchemy" }]);
  const texts = [
    `TypeError: error sending request for url (${URL_}): client error (Connect): dns error`, // a failed fetch's cause
    `Invalid URL: '${URL_}'`,                                                                 // new URL() on a bad value
    `request to ${URL_}/ failed`,
    `POST monad-mainnet.g.alchemy.test/v2/${KEY} 401`,
    `path /v2/${KEY} refused`,
    `your key ${KEY} is invalid; see https://dashboard.alchemy.test/apps/abc123?key=${KEY}`,
    `{"error":"${URL_}"}`,
    `escaped ${encodeURIComponent(URL_)}`,
  ];
  for (const t of texts) {
    const out = redact(t);
    assert(!leaks(out), `${t} → ${out}`);
  }
  assertEquals(redact(`error sending request for url (${URL_})`), "error sending request for url (alchemy)");
  assertEquals(redact(`{"error":"${URL_}"}`), `{"error":"alchemy"}`);
  // Another URL keeps only its origin; text without a URL is unchanged.
  assertEquals(redact("see https://docs.example.com/reference/eth-getlogs?x=1 for limits"), "see https://docs.example.com/… for limits");
  assertEquals(redact("eth_getLogs is limited to a 1,000 range"), "eth_getLogs is limited to a 1,000 range");
  assertEquals(redact("rpc2: HTTP 429"), "rpc2: HTTP 429");
});

Deno.test("redactor: a key in the query, in user info, several endpoints, a value that is not a URL", () => {
  const q = "https://rpc.provider.test/monad?auth=Q-KEY-0123456789abcdef&chain=143";
  const u = "https://user:P4ssw0rd-0123456789@rpc.other.test/rpc";
  const raw = "http//broken value with K3Y-0123456789abcdef";
  const redact = redactor([{ url: q, label: "custom-1" }, { url: u, label: "custom-2" }, { url: raw, label: "alchemy" }]);
  for (const t of [`fetch ${q} failed`, "auth=Q-KEY-0123456789abcdef", "Q-KEY-0123456789abcdef", `GET ${u}`,
                   "P4ssw0rd-0123456789", "user:P4ssw0rd-0123456789@rpc.other.test", `bad ${raw}`]) {
    const out = redact(t);
    assert(!out.includes("Q-KEY") && !out.includes("P4ssw0rd") && !out.includes("K3Y"), `${t} → ${out}`);
  }
  assertEquals(redact(`fetch ${q} failed`), "fetch custom-1 failed");
});

Deno.test("scrubUrls: no keyed URL known, still no path or query of any URL", () => {
  assertEquals(scrubUrls(`error sending request for url (${URL_})`), "error sending request for url (https://monad-mainnet.g.alchemy.test/…)");
  assertEquals(scrubUrls("https://rpc2.monad.xyz answered 429"), "https://rpc2.monad.xyz answered 429");
});
