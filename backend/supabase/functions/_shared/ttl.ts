// Rent upkeep (docs/DESIGN-stellar-parity.md §4.8b). Soroban archives any entry whose TTL runs out, and extending a
// contract instance doesn't extend its WASM. That cost is protocol upkeep, DyorHQ's: the keeper extends, from its own
// account, the app's contract instances (the launchpad, Moments, every live launch token and its pool), the WASMs they
// run, each quote's settings in the launchpad and Moments, and the launchpad's entries of every live launch and the
// Moments still collecting. A launch with no trade in `idleDays` and no holders is left to archive, which bounds what
// spam launches can cost. Each run checks the entries checked longest ago first, at most `perRun`, and extends those
// under the threshold while it has time.
import { Address, Keypair, Operation, rpc, SorobanDataBuilder, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { inclusionFee } from "./fees.ts";
import { TtlPolicy } from "./networks.ts";
import { keeper, keeperSend, prepare, rpcServer, sendSigned, waitForTx, withInclusionBid } from "./stellar.ts";

/** Ledgers in a day, at 5 s each. */
const DAY = 17_280;

export function instanceKey(contract: string): xdr.LedgerKey {
  return persistentKey(contract, xdr.ScVal.scvLedgerKeyContractInstance());
}

export function codeKey(hashHex: string): xdr.LedgerKey {
  return xdr.LedgerKey.contractCode(new xdr.LedgerKeyContractCode({ hash: Buffer.from(hashHex, "hex") as any }));
}

function persistentKey(contract: string, key: xdr.ScVal): xdr.LedgerKey {
  return xdr.LedgerKey.contractData(
    new xdr.LedgerKeyContractData({ contract: new Address(contract).toScAddress(), key, durability: xdr.ContractDataDurability.persistent() }),
  );
}

/** A `#[contracttype]` enum variant as a storage key: the variant's name, then its values. */
function variant(name: string, ...values: xdr.ScVal[]): xdr.ScVal {
  return xdr.ScVal.scvVec([xdr.ScVal.scvSymbol(name), ...values]);
}

/** The launchpad's persistent DataKey::Launch(token) and DataKey::Curve(token): a launch can't trade without them. */
export function launchKeys(launchpad: string, token: string): xdr.LedgerKey[] {
  const t = new Address(token).toScVal();
  return [persistentKey(launchpad, variant("Launch", t)), persistentKey(launchpad, variant("Curve", t))];
}

/** The Moments contract's persistent DataKey::Moment(id). */
export function momentKey(moments: string, id: number): xdr.LedgerKey {
  return persistentKey(moments, variant("Moment", xdr.ScVal.scvU32(id)));
}

/** A quote's settings, DataKey::Quote(quote), persistent in the launchpad (its economics, which every launch in it
 *  reads) and in Moments (its rule, which every Moment published in it reads). */
export function quoteKey(contract: string, quote: string): xdr.LedgerKey {
  return persistentKey(contract, variant("Quote", new Address(quote).toScVal()));
}

/** The launchpad's persistent DataKey::ProtocolFees(quote), which every trade in that quote adds to. */
export function protocolFeesKey(launchpad: string, quote: string): xdr.LedgerKey {
  return persistentKey(launchpad, variant("ProtocolFees", new Address(quote).toScVal()));
}

/** The assets launches and Moments are priced in (launchpad.ts, moments.ts). */
const QUOTES = ["XLM", "USDC"];

/** Code hashes of the given contracts' instances. */
export async function codeHashes(contracts: string[]): Promise<string[]> {
  const r = await rpcServer().getLedgerEntries(...contracts.map(instanceKey));
  return r.entries.map((e) => e.val.contractData().val().instance().executable().wasmHash().toString("hex"));
}

export interface TtlReport {
  checked: number;
  extended: number;
  fee: string;
  hashes: string[];
}

/** Extends every entry below `thresholdDays` to `extendToDays`, in batches: `contracts`' instances and WASMs and the
 *  WASMs in `extraCodeHashes`. For a deploy (deploy-contracts.ts), from the account it names. */
export async function keepAlive(contracts: string[], extraCodeHashes: string[] = [], thresholdDays = 10, extendToDays = 30, payer: Keypair = keeper()): Promise<TtlReport> {
  if (contracts.length === 0 && extraCodeHashes.length === 0) return { checked: 0, extended: 0, fee: "0", hashes: [] };
  const latest = (await rpcServer().getLatestLedger()).sequence;
  const hashes = new Set([...extraCodeHashes, ...(contracts.length ? await codeHashes(contracts) : [])]);
  const keys = [...contracts.map(instanceKey), ...[...hashes].map(codeKey)];
  const low: xdr.LedgerKey[] = [];
  for (let i = 0; i < keys.length; i += 50) {
    const batch = keys.slice(i, i + 50);
    const r = await rpcServer().getLedgerEntries(...batch);
    for (const e of r.entries) {
      if ((e.liveUntilLedgerSeq ?? 0) - latest < thresholdDays * DAY) low.push(e.key);
    }
  }
  let fee = 0n;
  const sent: string[] = [];
  for (let i = 0; i < low.length; i += 20) {
    const prepared = await prepare(await extendTx(payer.publicKey(), low.slice(i, i + 20), extendToDays));
    prepared.sign(payer);
    const hash = await sendSigned(prepared, "keeper");
    const s = await waitForTx(hash, 40_000);
    if (s.status === "SUCCESS") {
      fee += BigInt(prepared.fee);
      sent.push(hash);
    }
  }
  return { checked: keys.length, extended: low.length, fee: fee.toString(), hashes: sent };
}

/** An ExtendFootprintTTL of `keys` to `extendToDays` from `source`, before simulation. */
async function extendTx(source: string, keys: xdr.LedgerKey[], extendToDays: number) {
  const acct = await rpcServer().getAccount(source);
  return new TransactionBuilder(acct, { fee: "100", networkPassphrase: env.network.passphrase })
    .addOperation(Operation.extendFootprintTtl({ extendTo: extendToDays * DAY }))
    .setSorobanData(new SorobanDataBuilder().setReadOnly(keys).build())
    .setTimeout(120)
    .build();
}

// ------------------------------------------------------------------------------------------------ the keeper's rotation

/** An entry the keeper keeps alive, and what it is (for its log). */
export interface TtlEntry {
  key: xdr.LedgerKey;
  label: string;
}

/** Everything the keeper keeps alive now (§4.8b): the deployment's instances and WASMs; each quote's settings in the
 *  launchpad and Moments, and its protocol fees in the launchpad; each live launch's token instance, its pool's after
 *  graduation, and its Launch and Curve entries; each Moment still collecting. A launch is live with a trade in the
 *  last `idleDays`, or with holders (traders whose indexed trades leave them tokens). */
export async function upkeepEntries(policy: TtlPolicy = env.network.ttlPolicy): Promise<TtlEntry[]> {
  const { contracts: c, deployment: d } = env.network;
  const entries: TtlEntry[] = [];
  if (c.launchpad) entries.push({ key: instanceKey(c.launchpad), label: "instance launchpad" });
  if (c.moments) entries.push({ key: instanceKey(c.moments), label: "instance moments" });
  const code: [string | undefined, string][] = [[d?.launchpadWasmHash, "launchpad"], [d?.momentsWasmHash, "moments"], [d?.launchTokenWasmHash, "launch token"]];
  for (const [hash, name] of code) if (hash) entries.push({ key: codeKey(hash), label: `code ${name}` });
  // Only set_quote extends a quote's settings, and only a trade with a protocol fee its protocol fees: left alone,
  // they archive, and the next launch, publish or trade in that quote makes its user pay to restore them (§4.9).
  for (const q of env.network.assets.filter((a) => QUOTES.includes(a.id))) {
    if (c.launchpad) {
      entries.push({ key: quoteKey(c.launchpad, q.contract), label: `quote launchpad ${q.id}` });
      entries.push({ key: protocolFeesKey(c.launchpad, q.contract), label: `protocol fees ${q.id}` });
    }
    if (c.moments) entries.push({ key: quoteKey(c.moments, q.contract), label: `quote moments ${q.id}` });
  }
  const launches = await sql()`
    select l.token, l.pair from lite.launches l
     where greatest(l.created_at, (select max(t.ts) from lite.launch_trades t where t.token = l.token)) > now() - make_interval(days => ${policy.idleDays})
        or exists (select 1 from lite.launch_trades h where h.token = l.token group by h.trader
                    having sum(case when h.side = 'buy' then h.token_amount else -h.token_amount end) > 0)`;
  for (const l of launches) {
    const token = String(l.token);
    entries.push({ key: instanceKey(token), label: `instance ${token}` });
    if (c.launchpad) {
      const [launch, curve] = launchKeys(c.launchpad, token);
      entries.push({ key: launch, label: `launch ${token}` }, { key: curve, label: `curve ${token}` });
    }
    if (l.pair) entries.push({ key: instanceKey(String(l.pair)), label: `instance pool ${l.pair}` });
  }
  if (c.moments) {
    const moments = await sql()`select id from lite.moments where deadline > now() and (max_editions = 0 or minted < max_editions)`;
    for (const m of moments) entries.push({ key: momentKey(c.moments, Number(m.id)), label: `moment ${m.id}` });
  }
  return entries;
}

/** The entries one run checks: each once, those checked longest ago (or never) first, at most `perRun`. */
export function rotation<T extends { id: string }>(entries: T[], lastChecked: Map<string, number>, perRun: number): T[] {
  const seen = new Set<string>();
  const unique = entries.filter((e) => !seen.has(e.id) && seen.add(e.id));
  return unique
    .map((e, i) => ({ e, i, at: lastChecked.get(e.id) ?? -Infinity }))
    .sort((a, b) => a.at - b.at || a.i - b.i)
    .slice(0, perRun)
    .map((x) => x.e);
}

/** Whether an entry live until `liveUntil` needs extending at ledger `latest`. */
export function needsExtending(liveUntil: number, latest: number, policy: Pick<TtlPolicy, "thresholdDays">): boolean {
  return liveUntil - latest < policy.thresholdDays * DAY;
}

export interface UpkeepReport {
  /** Entries the keeper keeps alive. */
  entries: number;
  checked: number;
  /** Under the threshold. */
  low: number;
  extended: number;
  /** Not live: not on the ledger (not created yet) or archived (a user's restore brings it back). */
  missing: number;
  fee: string;
  hashes: string[];
}

/** Keys per extension: well inside a transaction's footprint limit. */
const EXTEND_BATCH = 25;

/** One run of the rotation: checks `entries` as rotation() orders them, extends the low ones by batch from the keeper's
 *  account, one transaction at a time, until `deadline` (ms since the epoch), and records each check in
 *  lite.ttl_checks. A low entry it had no time for keeps its old check time, so it comes first next run. */
export async function upkeep(entries: TtlEntry[], policy: TtlPolicy, deadline: number): Promise<UpkeepReport> {
  const all = entries.map((e) => ({ ...e, id: e.key.toXDR("base64") }));
  const ids = [...new Set(all.map((e) => e.id))];
  const rows = ids.length ? await sql()`select key, checked_at from lite.ttl_checks where key = any(${ids})` : [];
  const last = new Map(rows.map((r) => [String(r.key), new Date(r.checked_at as Date).getTime()]));
  const batch = rotation(all, last, policy.perRun);
  const report: UpkeepReport = { entries: ids.length, checked: batch.length, low: 0, extended: 0, missing: 0, fee: "0", hashes: [] };
  if (batch.length === 0) return report;

  // Each entry's TTL against the ledger RPC read it at.
  let latest = 0;
  const liveUntil = new Map<string, number>();
  const readAt = new Map<string, number>();
  for (let i = 0; i < batch.length; i += 200) {
    const r = await rpcServer().getLedgerEntries(...batch.slice(i, i + 200).map((e) => e.key));
    latest = Math.max(latest, r.latestLedger);
    for (const e of r.entries as rpc.Api.LedgerEntryResult[]) {
      liveUntil.set(e.key.toXDR("base64"), e.liveUntilLedgerSeq ?? 0);
      readAt.set(e.key.toXDR("base64"), r.latestLedger);
    }
  }
  // An entry past its TTL is archived, even while RPC still returns it: no extension reaches it, and one in a batch
  // would fail that batch's extension on every run.
  const live = (e: { id: string }) => liveUntil.has(e.id) && liveUntil.get(e.id)! >= readAt.get(e.id)!;
  const low = batch.filter((e) => live(e) && needsExtending(liveUntil.get(e.id)!, readAt.get(e.id)!, policy));
  report.low = low.length;
  report.missing = batch.filter((e) => !live(e)).length;

  const extended = new Set<string>();
  let fee = 0n;
  for (let i = 0; i < low.length && Date.now() < deadline; i += EXTEND_BATCH) {
    const part = low.slice(i, i + EXTEND_BATCH);
    try {
      const extend = await prepare(await extendTx(keeper().publicKey(), part.map((e) => e.key), policy.extendToDays));
      const prepared = withInclusionBid(extend, await inclusionFee("soroban"));
      const hash = await keeperSend("ttl", prepared, { entries: part.map((e) => e.label) });
      const s = await waitForTx(hash, Math.max(5_000, deadline - Date.now()));
      if (s.status !== "SUCCESS") break;
      for (const e of part) extended.add(e.id);
      fee += BigInt(s.feeCharged ?? prepared.fee);
      report.hashes.push(hash);
    } catch (err) {
      console.warn("ttl: extension failed", String((err as Error).message ?? err).slice(0, 200));
      break;
    }
  }
  report.extended = extended.size;
  report.fee = fee.toString();

  const lowIds = new Set(low.map((e) => e.id));
  const done = batch.filter((e) => !lowIds.has(e.id) || extended.has(e.id));
  if (done.length) {
    const until = done.map((e) => (extended.has(e.id) ? latest + policy.extendToDays * DAY : liveUntil.get(e.id) ?? null));
    await sql()`
      insert into lite.ttl_checks (key, label, live_until)
      select * from unnest(${done.map((e) => e.id)}::text[], ${done.map((e) => e.label)}::text[], ${until}::int[])
      on conflict (key) do update set label = excluded.label, live_until = excluded.live_until, checked_at = now()`;
  }
  // Entries the keeper no longer keeps alive (a dead launch, a closed Moment, another deployment) leave the rotation.
  await sql()`delete from lite.ttl_checks where not (key = any(${ids}))`;
  return report;
}
