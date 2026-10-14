// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { bundledDefs, canonicalLines, defsDrift, defsFromState, filterFor, type ScanDef, subjectOf, walletWord } from "./scans.ts";

const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const W1 = "0x90f3e7c3b4e32494b06814fd2f4556671f5f4c47";
const W2 = "0x" + "ab".repeat(20);
const pad = (a: string) => "0x" + "0".repeat(24) + a.slice(2);
const stateRows = () => bundledDefs().map((d) => ({ ...d, defVersion: 1, covered: [], holes: [], holesCheckedAt: null, head: null }));

Deno.test("defsFromState: the five scans from history_state, validated", () => {
  const defs = defsFromState(stateRows());
  assertEquals(defs.map((d) => d.id), ["launchpad", "fee-sharing", "moments", "transfers-in", "transfers-out"]);
  assertEquals(defs.find((d) => d.id === "moments")!.addresses.length, 16);
  const bad: [string, (rows: Record<string, unknown>[]) => unknown][] = [
    ["missing scan", (r) => r.slice(1)],
    ["duplicate", (r) => [...r.slice(1), r[1]]],
    ["unknown id", (r) => { r[0].id = "other"; return r; }],
    ["wrong kind", (r) => { r[0].kind = "wallet"; return r; }],
    ["wallet topic 3", (r) => { r[0].walletTopic = 3; return r; }],
    ["negative floor", (r) => { r[0].floor = -1; return r; }],
    ["def version 0", (r) => { r[0].defVersion = 0; return r; }],
    ["upper-case address", (r) => { r[1].addresses = ["0x" + "AB".repeat(20)]; return r; }],
    ["no topic0", (r) => { r[0].topic0s = []; return r; }],
    ["short topic", (r) => { r[0].topic0s = ["0x1234"]; return r; }],
    ["address twice", (r) => { r[1].addresses = [W1, W1]; return r; }],
    ["not a list", () => ({})],
  ];
  for (const [what, mutate] of bad) assertThrows(() => defsFromState(mutate(stateRows())), Error, undefined, what);
});

Deno.test("defsDrift: an added address, a changed floor, a changed topic, a changed wallet topic", () => {
  const bundled = bundledDefs();
  assertEquals(defsDrift(defsFromState(stateRows()), bundled), []);
  const db = defsFromState(stateRows());
  db[1].addresses = [...db[1].addresses, W2].sort();
  db[2].floor += 1;
  db[0].topic0s = [...db[0].topic0s.slice(1), "0x" + "11".repeat(32)].sort();
  db[3].walletTopic = 1;
  assertEquals(defsDrift(db, bundled), ["launchpad", "fee-sharing", "moments", "transfers-in"]);
  // Order inside the lists does not matter.
  const shuffled = defsFromState(stateRows()).map((d) => ({ ...d, addresses: [...d.addresses].reverse(), topic0s: [...d.topic0s].reverse() }));
  assertEquals(defsDrift(shuffled, bundled), []);
});

Deno.test("canonicalLines: migration 32's verify format, ordered by id", () => {
  const lines = canonicalLines(bundledDefs());
  assertEquals(lines.map((l) => l.split("|")[0]), ["fee-sharing", "launchpad", "moments", "transfers-in", "transfers-out"]);
  assertEquals(lines[3], ["transfers-in", "wallet", "2", "0", "", TRANSFER_TOPIC].join("|"));
  const fee = lines[0].split("|");
  assertEquals(fee.slice(0, 4), ["fee-sharing", "global", "2", "103542521"]);
  assertEquals(fee[4].split(",").length, 5);
  assertEquals(fee[4].split(","), [...fee[4].split(",")].sort());
});

Deno.test("walletWord and subjectOf", () => {
  assertEquals(walletWord("0x" + "AB".repeat(20)), pad(W2));
  const def = { walletTopic: 2 as const };
  assertEquals(subjectOf(def, ["0x" + "1".repeat(64), pad(W2), pad(W1).toUpperCase().replace("0X", "0x")]), W1);
  assertEquals(subjectOf(def, ["0x" + "1".repeat(64), pad(W2)]), null); // no topic 2
  assertEquals(subjectOf(def, ["0x" + "1".repeat(64), pad(W2), "0xff" + "0".repeat(62)]), null); // not an address
  assertEquals(subjectOf({ walletTopic: 1 }, ["0x" + "1".repeat(64), pad(W2)]), W2);
});

Deno.test("filterFor: per scan", () => {
  const defs = Object.fromEntries(defsFromState(stateRows()).map((d) => [d.id, d])) as Record<string, ScanDef>;
  const lp = filterFor(defs["launchpad"], 100, 10_099, []);
  assertEquals(lp, { fromBlock: "0x64", toBlock: "0x2773", topics: [defs["launchpad"].topic0s] });
  const fee = filterFor(defs["fee-sharing"], 1, 2, []);
  assertEquals(fee.address, defs["fee-sharing"].addresses);
  assertEquals(fee.topics, [defs["fee-sharing"].topic0s]);
  const out = filterFor(defs["transfers-out"], 1, 2, [W1, W2]);
  assertEquals(out.topics, [defs["transfers-out"].topic0s, [pad(W1), pad(W2)]]);
  assert(!("address" in out));
  const into = filterFor(defs["transfers-in"], 1, 2, [W1]);
  assertEquals(into.topics, [defs["transfers-in"].topic0s, null, [pad(W1)]]);
});
