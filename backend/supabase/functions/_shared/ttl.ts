// Rent upkeep (docs/DESIGN-stellar-parity.md §4.8b). Soroban archives any entry whose TTL runs out, and extending a
// contract instance doesn't extend its WASM. That cost is protocol upkeep, DyorHQ's: the keeper extends, from its own
// account, the app's contract instances (the launchpad, Moments, every live launch token and its pool), the WASMs they
// run, each quote's settings in the launchpad and Moments, and the launchpad's entries of every live launch and the
// Moments still collecting. A launch with no trade in `idleDays` and no holders is left to archive, which bounds what
// spam launches can cost. Each run checks the entries checked longest ago first, at most `perRun`, and extends those
// under the threshold while it has time.
//
// Contracts v2 (docs/DESIGN-stellar-contracts-v2.md §13) adds its singletons, every WASM its deployment uploaded, the
// quotes' settings, and per launch, Moment, locked position, unvested collector and owed balance the entries their
// calls read, up to 12 months after their last activity (v2UpkeepEntries). The graduation and harvest paths come
// first (v2PathEntries): the v2 singletons and code, and the Soroswap factory and pair code that DyorHQ doesn't own but
// every graduation runs. A graduation fits the per-transaction memory limit only while all of that code is live: an
// archived WASM misses the module cache and compiles inside the call, which goes over the limit, and that abort can't
// be recorded or retried. So the path is checked every run, not in its turn, and an archived entry of it is restored
// in a transaction of its own (lite-indexer/v2_keeper.ts also does it before it graduates or harvests anything).
import { Address, Keypair, Operation, rpc, SorobanDataBuilder, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { sql, tableExists } from "./db.ts";
import { env } from "./env.ts";
import { inclusionFee } from "./fees.ts";
import { NetworkConfig, TtlPolicy } from "./networks.ts";
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
  /** On the graduation or harvest path (v2PathEntries): checked every run, and restored when archived. */
  critical?: boolean;
}

/** Everything the keeper keeps alive now (§4.8b): the deployment's instances and WASMs; each quote's settings in the
 *  launchpad and Moments, and its protocol fees in the launchpad; each live launch's token instance, its pool's after
 *  graduation, and its Launch and Curve entries; each Moment still collecting. A launch is live with a trade in the
 *  last `idleDays`, or with holders (traders whose indexed trades leave them tokens). Then contracts v2's
 *  (v2UpkeepEntries). v1's rows are those with a launch index or a Moment number: v2's have neither. */
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
     where l.launch_index is not null
       and (greatest(l.created_at, (select max(t.ts) from lite.launch_trades t where t.token = l.token)) > now() - make_interval(days => ${policy.idleDays})
        or exists (select 1 from lite.launch_trades h where h.token = l.token group by h.trader
                    having sum(case when h.side = 'buy' then h.token_amount else -h.token_amount end) > 0))`;
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
    const moments = await sql()`select id from lite.moments where deadline > now() and (max_editions = 0 or minted < max_editions) and id is not null`;
    for (const m of moments) entries.push({ key: momentKey(c.moments, Number(m.id)), label: `moment ${m.id}` });
  }
  entries.push(...await v2UpkeepEntries(env.network));
  return entries;
}

// ------------------------------------------------------------------------------------------------ contracts v2

const addr = (a: string) => new Address(a).toScVal();

/** A `#[contracttype]` DataKey of `contract` in persistent storage: Launch(token), Position(nft, account), Sharing, … */
export function v2DataKey(contract: string, name: string, ...values: xdr.ScVal[]): xdr.LedgerKey {
  return persistentKey(contract, variant(name, ...values));
}

/** Soroswap's code that every graduation runs and DyorHQ doesn't own: the factory's, and the pair code its create_pair
 *  deploys, which the factory keeps in its persistent PairWasmHash entry. */
export interface SoroswapCode {
  factory: string;
  pair: string;
}

/** The Soroswap factory's persistent DataKey::PairWasmHash, which create_pair reads. */
export function pairWasmHashKey(factory: string): xdr.LedgerKey {
  return v2DataKey(factory, "PairWasmHash");
}

/** Soroswap's code is read again after an hour: an upgraded factory or a new pair code shows up within it. */
const SOROSWAP_CODE_MS = 3_600_000;
let soroswapRead: { factory: string; at: number; code: SoroswapCode } | null = null;

/** The Soroswap factory's code and the pair code it deploys, from its instance and its PairWasmHash entry. Null when
 *  RPC doesn't have both and they were never read. */
export async function soroswapCode(factory: string, now = Date.now()): Promise<SoroswapCode | null> {
  if (soroswapRead?.factory === factory && now - soroswapRead.at < SOROSWAP_CODE_MS) return soroswapRead.code;
  const r = await rpcServer().getLedgerEntries(instanceKey(factory), pairWasmHashKey(factory));
  let factoryCode: string | null = null;
  let pairCode: string | null = null;
  for (const e of r.entries) {
    const data = e.val.contractData();
    if (data.key().switch().name === "scvLedgerKeyContractInstance") factoryCode = data.val().instance().executable().wasmHash().toString("hex");
    else pairCode = Buffer.from(data.val().bytes()).toString("hex");
  }
  if (!factoryCode || !pairCode) return soroswapRead?.factory === factory ? soroswapRead.code : null;
  soroswapRead = { factory, at: now, code: { factory: factoryCode, pair: pairCode } };
  return soroswapRead.code;
}

/** v2's singletons: the deployment file's role and the contract's name. */
const V2_SINGLETONS = [
  ["launchpadV2", "launchpad-v2"],
  ["momentsV2", "moments-v2"],
  ["lpLocker", "lp-locker"],
  ["execSoroswap", "exec-soroswap"],
  ["execAquarius", "exec-aquarius"],
  ["momentsGraduator", "moments-graduator"],
] as const;

/** The graduation and harvest paths (lead note on CT-15): the instance of every v2 singleton (testnet-qa's failing
 *  venue and Moments stack too), every WASM the deployment uploaded (the launch tokens', Moment NFTs' and coins' that
 *  the singletons deploy among them), and Soroswap's factory: its instance, its PairWasmHash, its code and the pair
 *  code, where `soroswap` could be read. Every entry is critical. */
export function v2PathEntries(net: Pick<NetworkConfig, "deploymentV2" | "contracts">, soroswap: SoroswapCode | null): TtlEntry[] {
  const d = net.deploymentV2;
  if (!d) return [];
  const entries: TtlEntry[] = [];
  const push = (key: xdr.LedgerKey, label: string) => entries.push({ key, label, critical: true });
  for (const [role, name] of V2_SINGLETONS) {
    const contract = d.contracts[role];
    if (contract) push(instanceKey(contract), `instance ${name}`);
  }
  if (d.qa) {
    push(instanceKey(d.qa.qaExecFail), "instance qa-exec-fail");
    push(instanceKey(d.qa.momentsV2QaFail), "instance moments-v2 (failing stack)");
    push(instanceKey(d.qa.momentsGraduatorQaFail), "instance moments-graduator (failing stack)");
  }
  for (const [name, hash] of Object.entries(d.wasmHashes)) push(codeKey(hash), `code ${name}`);
  const factory = net.contracts.soroswapFactory;
  push(instanceKey(factory), "instance soroswap factory");
  push(pairWasmHashKey(factory), "soroswap PairWasmHash");
  if (soroswap) {
    push(codeKey(soroswap.factory), "code soroswap factory");
    push(codeKey(soroswap.pair), "code soroswap pair");
  }
  return entries;
}

/** The asset contract of each quote the v2 deployment has ("XLM", "USDC", testnet-qa's "QA"), by id. */
function v2Quotes(net: Pick<NetworkConfig, "deploymentV2" | "assets">): [string, string][] {
  const d = net.deploymentV2!;
  return Object.keys(d.quotes).flatMap((id): [string, string][] => {
    const contract = id === "QA" ? d.qaAsset?.sac : net.assets.find((a) => a.id === id)?.contract;
    return contract ? [[id, contract]] : [];
  });
}

/** How long after its last activity a v2 launch's, Moment's or position's entries are kept alive (§13). */
const ACTIVE_DAYS = 365;

/** What contracts v2 adds to the rotation (§13): the paths (v2PathEntries, `soroswap` read when not given); each quote's
 *  settings in launchpad-v2 and its asset contract; per launch its token instance, Launch, Curve and Recipient (a
 *  graduated launch's Curve is read by every harvest and never written again, CT-05 N2), its token's Sharing state, and
 *  after graduation its pool's instance and the locker's Position and Tracked entries; per Moment (both stacks on
 *  testnet-qa) its NFT instance, Moment and Ledger, and after graduation its coin's and pool's instances and the
 *  locker's entries; each collector's Position while unvested coins remain; and every owed balance, CreatorOwed in
 *  launchpad-v2 and Owed in the locker. A launch or a Moment counts while it waits for graduation, while a rescued
 *  launch still has refunds, with holders before graduation, and up to 12 months after its last activity: the last
 *  event the indexer recorded for it, or its position's last harvest. */
export async function v2UpkeepEntries(net: NetworkConfig = env.network, soroswap?: SoroswapCode | null): Promise<TtlEntry[]> {
  const d = net.deploymentV2;
  if (!d) return [];
  let code = soroswap ?? null;
  if (soroswap === undefined) {
    code = await soroswapCode(net.contracts.soroswapFactory).catch((err) => {
      console.warn("ttl: the Soroswap factory's code wasn't read", String((err as Error).message ?? err).slice(0, 160));
      return null;
    });
  }
  const entries = v2PathEntries(net, code);
  const { launchpadV2: pad, lpLocker: locker } = d.contracts;
  const stacks = [d.contracts.momentsV2, ...(d.qa ? [d.qa.momentsV2QaFail] : [])];
  for (const [id, contract] of v2Quotes(net)) {
    entries.push({ key: v2DataKey(pad, "Quote", addr(contract)), label: `quote launchpad-v2 ${id}` });
    entries.push({ key: instanceKey(contract), label: `instance asset ${id}` });
  }
  // Hosted applies migrations by hand: the rows below come with 20261015000012.
  if (!(await tableExists("lite.locker_positions"))) return entries;

  const position = (pool: string, lpToken: unknown) => {
    entries.push({ key: instanceKey(pool), label: `instance pool ${pool}` });
    if (lpToken) {
      entries.push({ key: v2DataKey(locker, "Position", addr(pool)), label: `locker position ${pool}` });
      entries.push({ key: v2DataKey(locker, "Tracked", addr(String(lpToken))), label: `locker tracked ${lpToken}` });
    }
  };
  const launches = await sql()`
    select l.token, l.holder_sharing, l.pair, p.lp_token from lite.launches l left join lite.locker_positions p on p.pool = l.pair
     where l.generation = 2 and l.contract = ${pad}
       and (l.phase = 'completed'
         or (l.phase = 'rescued' and l.refunded < l.refund_quote)
         or greatest(l.updated_at, p.last_harvest_at) > now() - make_interval(days => ${ACTIVE_DAYS})
         or (l.phase = 'curve' and exists (select 1 from lite.launch_trades h where h.token = l.token group by h.trader
                                            having sum(case when h.side = 'buy' then h.token_amount else -h.token_amount end) > 0)))`;
  for (const l of launches) {
    const token = String(l.token);
    entries.push({ key: instanceKey(token), label: `instance ${token}` });
    for (const name of ["Launch", "Curve", "Recipient"]) entries.push({ key: v2DataKey(pad, name, addr(token)), label: `${name.toLowerCase()} ${token}` });
    if (l.holder_sharing) entries.push({ key: v2DataKey(token, "Sharing"), label: `sharing ${token}` });
    if (l.pair) position(String(l.pair), l.lp_token);
  }
  const moments = await sql()`
    select m.nft, m.contract, m.coin, m.pool, m.state, p.lp_token from lite.moments m left join lite.locker_positions p on p.pool = m.pool
     where m.generation = 2 and m.contract = any(${stacks}::text[])
       and (m.state in ('collecting', 'graduation_pending')
         or greatest(m.updated_at, p.last_harvest_at) > now() - make_interval(days => ${ACTIVE_DAYS}))`;
  for (const m of moments) {
    const [nft, contract] = [String(m.nft), String(m.contract)];
    entries.push({ key: instanceKey(nft), label: `instance ${nft}` });
    entries.push({ key: v2DataKey(contract, "Moment", addr(nft)), label: `moment ${nft}` });
    entries.push({ key: v2DataKey(contract, "Ledger", addr(nft)), label: `ledger ${nft}` });
    if (m.state === "graduated" && m.coin) entries.push({ key: instanceKey(String(m.coin)), label: `instance coin ${m.coin}` });
    if (m.pool) position(String(m.pool), m.lp_token);
  }
  // A collector's coins vest over two periods after graduation; each claim extends its Position, but one that isn't
  // claimed would archive before the rest vests.
  const vesting = await sql()`
    select p.nft, p.account, m.contract from lite.moment_positions p join lite.moments m on m.nft = p.nft
     where m.generation = 2 and m.contract = any(${stacks}::text[]) and m.state <> 'expired' and p.entitlement > p.collector_claimed`;
  for (const p of vesting) {
    entries.push({ key: v2DataKey(String(p.contract), "Position", addr(String(p.nft)), addr(String(p.account))), label: `vesting ${p.nft} ${p.account}` });
  }
  const owed = await sql()`select contract, account, asset from lite.creator_owed where owed > 0 and contract = any(${[pad, locker]}::text[])`;
  for (const o of owed) {
    const name = o.contract === pad ? "CreatorOwed" : "Owed";
    entries.push({ key: v2DataKey(String(o.contract), name, addr(String(o.account)), addr(String(o.asset))), label: `${name} ${o.account} ${o.asset}` });
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
  /** Not live: not on the ledger (not created yet) or archived (a user's restore brings it back). A critical entry
   *  found archived is restored instead, and counts here only when its restore didn't apply. */
  missing: number;
  /** Critical entries found archived and restored this run. */
  restored: number;
  fee: string;
  hashes: string[];
}

/** Keys per extension: well inside a transaction's footprint limit. */
const EXTEND_BATCH = 25;

/** Each entry's TTL against the ledger RPC read it at: `live` says whether an entry is live. An entry past its TTL is
 *  archived, even while RPC still returns it: no extension reaches it, and one in a batch would fail that batch's
 *  extension on every run. */
async function readTtl(entries: { key: xdr.LedgerKey; id: string }[]) {
  let latest = 0;
  const liveUntil = new Map<string, number>();
  const readAt = new Map<string, number>();
  for (let i = 0; i < entries.length; i += 200) {
    const r = await rpcServer().getLedgerEntries(...entries.slice(i, i + 200).map((e) => e.key));
    latest = Math.max(latest, r.latestLedger);
    for (const e of r.entries as rpc.Api.LedgerEntryResult[]) {
      liveUntil.set(e.key.toXDR("base64"), e.liveUntilLedgerSeq ?? 0);
      readAt.set(e.key.toXDR("base64"), r.latestLedger);
    }
  }
  const live = (e: { id: string }) => liveUntil.has(e.id) && liveUntil.get(e.id)! >= readAt.get(e.id)!;
  return { latest, liveUntil, readAt, live };
}

/** Sends `tx`, prepared from the keeper's account, with the inclusion bid of the moment, logs it as the ttl job's and
 *  waits for it until `deadline`: its hash and fee when it applied, null when it didn't. */
async function sendUpkeep(tx: Transaction, detail: Record<string, unknown>, deadline: number): Promise<{ hash: string; fee: bigint } | null> {
  const prepared = withInclusionBid(tx, await inclusionFee("soroban"));
  const hash = await keeperSend("ttl", prepared, detail);
  const s = await waitForTx(hash, Math.max(5_000, deadline - Date.now()));
  if (s.status !== "SUCCESS") return null;
  return { hash, fee: BigInt(s.feeCharged ?? prepared.fee) };
}

/** Extends `entries` to `extendToDays` from the keeper's account, in one transaction. */
async function extendEntries(entries: TtlEntry[], extendToDays: number, deadline: number) {
  const extend = await prepare(await extendTx(keeper().publicKey(), entries.map((e) => e.key), extendToDays));
  return await sendUpkeep(extend, { entries: entries.map((e) => e.label) }, deadline);
}

/** Restores archived `entries` from the keeper's account, in a transaction of their own: whatever needs them runs in a
 *  later one. A restored entry lives only the network's minimum TTL, so it is extended next. */
export async function restoreEntries(entries: TtlEntry[], deadline: number) {
  const acct = await rpcServer().getAccount(keeper().publicKey());
  const tx = new TransactionBuilder(acct, { fee: "100", networkPassphrase: env.network.passphrase })
    .addOperation(Operation.restoreFootprint({}))
    .setSorobanData(new SorobanDataBuilder().setReadWrite(entries.map((e) => e.key)).build())
    .setTimeout(120)
    .build();
  return await sendUpkeep(await prepare(tx), { restored: entries.map((e) => e.label) }, deadline);
}

/** One run of the rotation: checks the critical entries (the graduation and harvest paths) every run and the others as
 *  rotation() orders them, within `perRun`; restores the critical ones found archived, in a transaction of their own;
 *  extends the low ones (and those restored) by batch from the keeper's account, one transaction at a time, until
 *  `deadline` (ms since the epoch); and records each check in lite.ttl_checks. A low entry it had no time for keeps its
 *  old check time, so it comes first next run. */
export async function upkeep(entries: TtlEntry[], policy: TtlPolicy, deadline: number): Promise<UpkeepReport> {
  const all = entries.map((e) => ({ ...e, id: e.key.toXDR("base64") }));
  const ids = [...new Set(all.map((e) => e.id))];
  const rows = ids.length ? await sql()`select key, checked_at from lite.ttl_checks where key = any(${ids})` : [];
  const last = new Map(rows.map((r) => [String(r.key), new Date(r.checked_at as Date).getTime()]));
  const critical = rotation(all.filter((e) => e.critical), new Map(), Infinity);
  const criticalIds = new Set(critical.map((e) => e.id));
  const batch = [...critical, ...rotation(all.filter((e) => !criticalIds.has(e.id)), last, Math.max(0, policy.perRun - critical.length))];
  const report: UpkeepReport = { entries: ids.length, checked: batch.length, low: 0, extended: 0, missing: 0, restored: 0, fee: "0", hashes: [] };
  if (batch.length === 0) return report;

  const { latest, liveUntil, readAt, live } = await readTtl(batch);
  let fee = 0n;
  const archived = critical.filter((e) => !live(e));
  const restored = new Set<string>();
  if (archived.length && Date.now() < deadline) {
    try {
      const sent = await restoreEntries(archived, deadline);
      if (sent) {
        for (const e of archived) restored.add(e.id);
        fee += sent.fee;
        report.hashes.push(sent.hash);
      }
    } catch (err) {
      console.warn("ttl: restore failed", archived.map((e) => e.label).join(", "), String((err as Error).message ?? err).slice(0, 200));
    }
  }
  const lowLive = batch.filter((e) => live(e) && needsExtending(liveUntil.get(e.id)!, readAt.get(e.id)!, policy));
  const low = [...archived.filter((e) => restored.has(e.id)), ...lowLive];
  report.restored = restored.size;
  report.low = lowLive.length;
  report.missing = batch.filter((e) => !live(e) && !restored.has(e.id)).length;

  const extended = new Set<string>();
  for (let i = 0; i < low.length && Date.now() < deadline; i += EXTEND_BATCH) {
    const part = low.slice(i, i + EXTEND_BATCH);
    try {
      const sent = await extendEntries(part, policy.extendToDays, deadline);
      if (!sent) break;
      for (const e of part) extended.add(e.id);
      fee += sent.fee;
      report.hashes.push(sent.hash);
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

/** What the keeper found on the graduation and harvest paths before it graduated or harvested anything. */
export interface PathReport {
  entries: number;
  /** Archived when read. While any was, nothing graduates or harvests in this run, restored or not: a restored WASM
   *  is in the module cache from a later ledger. */
  archived: string[];
  restored: boolean;
  /** Under the threshold (or just restored), extended now rather than in their turn. */
  extended: string[];
}

/** Checks the paths' `entries` (v2PathEntries) now: restores the archived ones in a transaction of their own, then
 *  extends those under `policy`'s threshold, the restored ones included, until `deadline`. */
export async function upkeepPath(entries: TtlEntry[], policy: TtlPolicy, deadline: number): Promise<PathReport> {
  const all = rotation(entries.map((e) => ({ ...e, id: e.key.toXDR("base64") })), new Map(), Infinity);
  const report: PathReport = { entries: all.length, archived: [], restored: false, extended: [] };
  if (all.length === 0) return report;
  const { liveUntil, readAt, live } = await readTtl(all);
  const archived = all.filter((e) => !live(e));
  report.archived = archived.map((e) => e.label);
  if (archived.length) {
    try {
      report.restored = (await restoreEntries(archived, deadline)) !== null;
    } catch (err) {
      console.warn("keeper: the graduation path's restore failed", report.archived.join(", "), String((err as Error).message ?? err).slice(0, 200));
    }
  }
  const low = [...(report.restored ? archived : []), ...all.filter((e) => live(e) && needsExtending(liveUntil.get(e.id)!, readAt.get(e.id)!, policy))];
  for (let i = 0; i < low.length && Date.now() < deadline; i += EXTEND_BATCH) {
    const part = low.slice(i, i + EXTEND_BATCH);
    try {
      if (!(await extendEntries(part, policy.extendToDays, deadline))) break;
      report.extended.push(...part.map((e) => e.label));
    } catch (err) {
      console.warn("keeper: the graduation path's extension failed", String((err as Error).message ?? err).slice(0, 200));
      break;
    }
  }
  return report;
}
