// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
// history-scans.json is the canonical definition of the wallet-history cache's scans (migration 32 seeds the same rows;
// HistoryScanParityTests checks the app's WalletHistoryScans against it). Here: its shape, that every topic is the
// keccak of its signature, the address and topic rules the SQL CHECKs and the indexer rely on, and that the generated
// module the Edge Function bundles is exactly the JSON.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { keccak256, toBytes } from "npm:viem@2";
import { generatedModule } from "./gen_history_scans.ts";
import { HISTORY_SCANS } from "./history_scans.ts";

const JSON_URL = new URL("./history-scans.json", import.meta.url);
const raw = await Deno.readTextFile(JSON_URL);
const spec = JSON.parse(raw);

Deno.test("history-scans.json: five scans, in the app's ids, global then wallet", () => {
  assertEquals(spec.version, 1);
  assertEquals(spec.scans.map((s: { id: string }) => s.id), ["launchpad", "fee-sharing", "moments", "transfers-in", "transfers-out"]);
  assertEquals(spec.scans.map((s: { kind: string }) => s.kind), ["global", "global", "global", "wallet", "wallet"]);
  assertEquals(spec.scans.map((s: { walletTopic: number }) => s.walletTopic), [1, 2, 2, 2, 1]);
  // The floors: LaunchpadAddresses.feeHistoryStart, the earliest Moments cohort's deployBlock, and genesis for the
  // wallet scans (the server reads them whole; the app's own floor is recorded in appFloor).
  assertEquals(spec.scans.map((s: { floor: number }) => s.floor), [103_542_521, 103_542_521, 105_347_754, 0, 0]);
  for (const s of spec.scans) {
    if (s.kind === "wallet") assertEquals(s.appFloor, "earliest(firstTransaction, appTransferWindow)", s.id);
    else assertEquals("appFloor" in s, false, s.id);
  }
});

Deno.test("history-scans.json: the app's 30-day transfer window, in blocks (BlockClock.blocks rounds up)", () => {
  const w = spec.appTransferWindow;
  assertEquals([w.days, w.secondsPerBlock], [30, 0.3023]);
  assertEquals(w.blocks, Math.ceil((w.days * 86_400) / w.secondsPerBlock));
  assertEquals(w.blocks, 8_574_264);
});

Deno.test("history-scans.json: every topic is keccak256 of its signature; no event twice in a scan", () => {
  for (const s of spec.scans) {
    assert(s.events.length >= 1 && s.events.length <= 8, s.id);
    for (const e of s.events) assertEquals(e.topic, keccak256(toBytes(e.signature)), `${s.id}: ${e.signature}`);
    assertEquals(new Set(s.events.map((e: { topic: string }) => e.topic)).size, s.events.length, s.id);
  }
});

Deno.test("history-scans.json: addresses lowercase, sorted, unique; only fee-sharing and moments filter by contract", () => {
  for (const s of spec.scans) {
    for (const a of s.addresses) assert(/^0x[0-9a-f]{40}$/.test(a), `${s.id}: ${a}`);
    assertEquals([...s.addresses].sort(), s.addresses, `${s.id}: sorted`);
    assertEquals(new Set(s.addresses).size, s.addresses.length, `${s.id}: unique`);
  }
  assertEquals(spec.scans.map((s: { addresses: string[] }) => s.addresses.length), [0, 5, 16, 0, 0]);
  for (const s of spec.scans) for (const e of s.events) assert(/^0x[0-9a-f]{64}$/.test(e.topic), e.topic);
});

Deno.test("history_scans.ts is generated from the JSON, unedited", async () => {
  assertEquals(JSON.parse(JSON.stringify(HISTORY_SCANS)), spec);
  const onDisk = await Deno.readTextFile(new URL("./history_scans.ts", import.meta.url));
  assertEquals(onDisk, generatedModule(raw), "run gen_history_scans.ts after changing history-scans.json");
});
