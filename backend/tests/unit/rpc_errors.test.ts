// RPC failures as clients see them: an RPC client's own error text (which can carry the RPC's URL, a keyed provider's
// included) is logged with its URLs stripped and never answered; a refused simulation keeps its contract error.
import { Account, Contract, Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
// A malformed keyed URL: the RPC client's error then quotes it (a closed port would say only "fetch failed").
Deno.env.set("STELLAR_RPC_URL", "http://user:FAKEKEY0123456789@[zz/v2");
const { prepare, newTx } = await import("../../supabase/functions/_shared/stellar.ts");
const { ApiError, errorResponse, redactUrls } = await import("../../supabase/functions/_shared/http.ts");

/** Runs `fn` with console.warn captured. */
async function warnings(fn: () => Promise<void>): Promise<string[]> {
  const warn = console.warn;
  const seen: string[] = [];
  console.warn = (...args: unknown[]) => void seen.push(args.join(" "));
  try {
    await fn();
  } finally {
    console.warn = warn;
  }
  return seen;
}

Deno.test("rpc_unavailable: the client never sees the RPC client's text; the log has it with the URL stripped", async () => {
  const source = new Account(Keypair.random().publicKey(), "0");
  const tx = newTx(source, 30).addOperation(new Contract("CA3D5KRYM6CB7OWQ6TWYRR3Z4T7GNZLKERYNZGGA5SOAOPIFY6YQGAXE").call("x")).build();
  let caught: unknown;
  try {
    await prepare(tx);
  } catch (err) {
    caught = err;
  }
  assert(caught instanceof ApiError, `expected ApiError, got ${caught}`);
  let text = "";
  const logged = await warnings(async () => {
    text = await errorResponse(caught).text();
  });
  const body = JSON.parse(text);
  assertEquals([body.error.code, body.error.detail], ["rpc_unavailable", null]);
  assert(!text.includes("FAKEKEY"), "the RPC URL never reaches the client");
  assertEquals(logged.length, 1);
  assert(logged[0].startsWith("rpc_unavailable:") && !logged[0].includes("FAKEKEY"), logged[0]);
});

Deno.test("an unconfirmed send keeps its hash for the client, never the RPC client's text", async () => {
  const err = new ApiError(502, "rpc_unavailable", "Stellar RPC didn't confirm it received this transaction.", { hash: "ab".repeat(32), raw: "connect to https://key@rpc.example/v1 failed" });
  let body: any;
  await warnings(async () => {
    body = await errorResponse(err).json();
  });
  assertEquals(body.error.detail, { hash: "ab".repeat(32) });
});

Deno.test("simulation_failed keeps its raw contract error, which the phone reads", async () => {
  const err = new ApiError(422, "simulation_failed", "The contract refused this (code 8).", { raw: "HostError: Error(Contract, #8)" });
  const body = await errorResponse(err).json();
  assertEquals(body.error.detail, { raw: "HostError: Error(Contract, #8)" });
});

Deno.test("redactUrls strips every URL, credentials and all", () => {
  assertEquals(redactUrls("Invalid URL: 'http://user:KEY@[zz/v2' and https://rpc.example/abc?key=1 end"), "Invalid URL: '<url>' and <url> end");
});
