// The scans the indexer reads. Every filter is built from the DEFINITIONS IN THE DATABASE (history_state's `scans`, each
// with its def_version, which every commit carries): the bundled copy of history-scans.json is only compared with them
// and reported as `defsDrift` (a deploy-order fault), so neither deploy order nor a redefinition can store logs read
// under one definition as coverage of another (migration 32, history_redefine_scan / PT412).
import { HISTORY_SCANS } from "../_shared/history_scans.ts";

export type ScanId = "launchpad" | "fee-sharing" | "moments" | "transfers-in" | "transfers-out";
export const SCAN_IDS: readonly ScanId[] = ["launchpad", "fee-sharing", "moments", "transfers-in", "transfers-out"];
export const GLOBAL_SCANS: readonly ScanId[] = ["launchpad", "fee-sharing", "moments"];
export const WALLET_SCANS: readonly ScanId[] = ["transfers-in", "transfers-out"];

export type ScanDef = {
  id: ScanId;
  kind: "global" | "wallet";
  walletTopic: 1 | 2;
  floor: number;
  defVersion: number;
  addresses: string[];
  topic0s: string[];
};
export type BundledDef = Omit<ScanDef, "defVersion">;

const ADDRESS = /^0x[0-9a-f]{40}$/;
const WORD = /^0x[0-9a-f]{64}$/;
const isScanId = (v: unknown): v is ScanId => typeof v === "string" && (SCAN_IDS as readonly string[]).includes(v);
const kindOf = (id: ScanId) => (GLOBAL_SCANS.includes(id) ? "global" : "wallet");

function sortedUnique(list: unknown, shape: RegExp, what: string, max: number): string[] {
  if (!Array.isArray(list) || list.length > max) throw new Error(`${what} must be a list of at most ${max}`);
  for (const x of list) if (typeof x !== "string" || !shape.test(x)) throw new Error(`${what}: a malformed entry`);
  const out = [...new Set(list as string[])].sort();
  if (out.length !== list.length) throw new Error(`${what}: an entry listed twice`);
  return out;
}

// history_state's `scans`, validated: exactly the five scans, each well-formed. Throws on anything else (the run then
// stops before reading anything).
export function defsFromState(rows: unknown): ScanDef[] {
  if (!Array.isArray(rows)) throw new Error("scans: not a list");
  const out: ScanDef[] = [];
  for (const row of rows) {
    if (!row || typeof row !== "object") throw new Error("scans: not an object");
    const r = row as Record<string, unknown>;
    if (!isScanId(r.id)) throw new Error("scans: unknown id");
    if (r.kind !== kindOf(r.id)) throw new Error(`${r.id}: wrong kind`);
    if (r.walletTopic !== 1 && r.walletTopic !== 2) throw new Error(`${r.id}: walletTopic must be 1 or 2`);
    if (!Number.isSafeInteger(r.floor) || (r.floor as number) < 0) throw new Error(`${r.id}: bad floor`);
    if (!Number.isSafeInteger(r.defVersion) || (r.defVersion as number) < 1) throw new Error(`${r.id}: bad defVersion`);
    const addresses = sortedUnique(r.addresses, ADDRESS, `${r.id} addresses`, 1000);
    const topic0s = sortedUnique(r.topic0s, WORD, `${r.id} topic0s`, 8);
    if (topic0s.length === 0) throw new Error(`${r.id}: no topic0`);
    out.push({ id: r.id, kind: r.kind as "global" | "wallet", walletTopic: r.walletTopic, floor: r.floor as number,
               defVersion: r.defVersion as number, addresses, topic0s });
  }
  if (out.length !== SCAN_IDS.length || new Set(out.map((d) => d.id)).size !== SCAN_IDS.length) {
    throw new Error("scans: expected each of the five scans once");
  }
  return SCAN_IDS.map((id) => out.find((d) => d.id === id)!);
}

// The definitions this function was built with (history-scans.json, through the generated module).
export function bundledDefs(): BundledDef[] {
  return HISTORY_SCANS.scans.map((s) => ({
    id: s.id as ScanId,
    kind: s.kind as "global" | "wallet",
    walletTopic: s.walletTopic as 1 | 2,
    floor: s.floor,
    addresses: [...s.addresses].sort(),
    topic0s: s.events.map((e) => e.topic as string).sort(),
  }));
}

const sameSet = (a: readonly string[], b: readonly string[]) => a.length === b.length && [...a].sort().every((x, i) => x === [...b].sort()[i]);

// The scans whose kind, wallet topic, floor, address set or topic0 set differ between the database and the bundle.
export function defsDrift(db: readonly BundledDef[], bundled: readonly BundledDef[]): ScanId[] {
  return SCAN_IDS.filter((id) => {
    const a = db.find((d) => d.id === id), b = bundled.find((d) => d.id === id);
    if (!a || !b) return true;
    return a.kind !== b.kind || a.walletTopic !== b.walletTopic || a.floor !== b.floor ||
      !sameSet(a.addresses, b.addresses) || !sameSet(a.topic0s, b.topic0s);
  });
}

// One line per scan, `id|kind|walletTopic|floor|addresses|topic0s` (sorted, comma-joined), ordered by id: the format of
// migration 32's "Verify after apply" query, so the deployed rows can be diffed against print_scans.ts.
export function canonicalLines(defs: readonly BundledDef[]): string[] {
  return [...defs].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
    .map((d) => [d.id, d.kind, d.walletTopic, d.floor, [...d.addresses].sort().join(","), [...d.topic0s].sort().join(",")].join("|"));
}

// The 32-byte topic word of an address: 12 zero bytes, then the address.
export function walletWord(wallet: string): string {
  return "0x" + "0".repeat(24) + wallet.slice(2).toLowerCase();
}

// The wallet a log names at the scan's wallet topic, or null when that topic is missing or not address-shaped.
export function subjectOf(def: Pick<ScanDef, "walletTopic">, topics: readonly string[]): string | null {
  const word = topics[def.walletTopic];
  if (typeof word !== "string" || !/^0x0{24}[0-9a-fA-F]{40}$/.test(word)) return null;
  return "0x" + word.slice(26).toLowerCase();
}

const hex = (n: number) => "0x" + n.toString(16);

// The eth_getLogs filter for one piece: a global scan reads every wallet (topic0s only, plus its contracts when it has
// any); a wallet scan carries the wallets' words at its wallet topic (transfers-out [topic0s, words], transfers-in
// [topic0s, null, words]).
export function filterFor(def: Pick<ScanDef, "kind" | "walletTopic" | "addresses" | "topic0s">, from: number, to: number,
                          wallets: readonly string[]): Record<string, unknown> {
  const topics: (string[] | null)[] = [[...def.topic0s]];
  if (def.kind === "wallet") {
    while (topics.length < def.walletTopic) topics.push(null);
    topics.push(wallets.map(walletWord));
  }
  const filter: Record<string, unknown> = { fromBlock: hex(from), toBlock: hex(to), topics };
  if (def.addresses.length > 0) filter.address = [...def.addresses];
  return filter;
}
