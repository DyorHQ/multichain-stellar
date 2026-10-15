// The network side of the v2 deploy kit and the preflight shared by `owner-v2.ts check` and deploy-contracts-v2.ts
// (CT-11a lead decision L-e; docs/DESIGN-stellar-contracts-v2.md §16, §17, finding F9).
//
// - `Chain`: what the kit reads from and sends to Stellar testnet (RPC for contracts and transactions, Horizon for
//   accounts and trustlines, Friendbot). `testnetChain()` is the real one; tests pass an in-memory one, so no test
//   touches the network. `readOnlyChain()` wraps a chain for dry runs and `check`: anything that would send throws.
// - Transaction helpers: build, simulate (`prepare`), sign and submit one operation at a time.
// - `preflight`: every role account exists; the treasury trusts every enabled classic quote asset (claim_protocol_fees
//   is all-or-nothing per call, F9); the Moments platform trusts USDC (withdraw_platform pays USDC); the deployer
//   holds at least MIN_DEPLOYER_XLM (3,000 XLM; 4,500 with --fund-aqua-float): the uploads and the TTL step's 75 days
//   of rent cost about 1,800 XLM at testnet's 2026-10-15 rates.
import { Buffer } from "node:buffer";
import {
  Account,
  Address,
  BASE_FEE,
  Contract,
  Horizon,
  Keypair,
  Operation,
  rpc,
  Transaction,
  TransactionBuilder,
  xdr,
} from "@stellar/stellar-sdk";
import type { ContractReader } from "./contract-ids.ts";
import type { V2Roles } from "./v2-profile.ts";

export const STROOPS_PER_XLM = 10_000_000n;

export interface Trustline {
  /** CODE:ISSUER */
  asset: string;
  balance: bigint;
  authorized: boolean;
}

export interface AccountInfo {
  id: string;
  sequence: string;
  /** Native balance in stroops. */
  xlm: bigint;
  trustlines: Trustline[];
  signers: { key: string; weight: number }[];
  thresholds: { low: number; med: number; high: number };
}

export interface TxOutcome {
  hash: string;
  ledger: number;
  /** Stroops actually charged. */
  feeCharged: bigint;
  returnValue: xdr.ScVal | null;
}

/** Read-only access to testnet. */
export interface ChainReader extends ContractReader {
  readonly passphrase: string;
  /** Null when the account doesn't exist. */
  account(id: string): Promise<AccountInfo | null>;
  latestLedger(): Promise<number>;
  /** The contract instance's storage entries; null when there is no such contract. */
  instanceStorage(id: string): Promise<{ key: xdr.ScVal; val: xdr.ScVal }[] | null>;
  /** True when the WASM with this hash (hex) is uploaded. */
  codeExists(hashHex: string): Promise<boolean>;
  /** The live-until ledger of each contract instance and each WASM (by id or hash); null when the entry is missing. */
  liveUntil(contracts: string[], codeHashes: string[]): Promise<Map<string, number | null>>;
}

/** Everything that sends. */
export interface Chain extends ChainReader {
  friendbot(id: string): Promise<void>;
  /** The account as a transaction source (its current sequence). */
  sourceAccount(id: string): Promise<Account>;
  /** Simulates a Soroban transaction and assembles footprint, resources and auth (unsigned). */
  prepare(tx: Transaction): Promise<Transaction>;
  /** Sends a signed transaction and waits for it. Throws unless it succeeded. */
  submit(tx: Transaction): Promise<TxOutcome>;
}

export const TESTNET_PASSPHRASE = "Test SDF Network ; September 2015";

// ------------------------------------------------------------------------------------------------ the real chain

function instanceKey(contract: string): xdr.LedgerKey {
  return xdr.LedgerKey.contractData(
    new xdr.LedgerKeyContractData({
      contract: new Address(contract).toScAddress(),
      key: xdr.ScVal.scvLedgerKeyContractInstance(),
      durability: xdr.ContractDataDurability.persistent(),
    }),
  );
}

function codeKey(hashHex: string): xdr.LedgerKey {
  return xdr.LedgerKey.contractCode(new xdr.LedgerKeyContractCode({ hash: Buffer.from(hashHex, "hex") }));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------------------------------------ resource limits

/** The network's per-transaction resource limits, read live from its config settings. */
export interface TxLimits {
  instructions: number;
  diskReadBytes: number;
  writeBytes: number;
}

const configKey = (id: xdr.ConfigSettingId) => xdr.LedgerKey.configSetting(new xdr.LedgerKeyConfigSetting({ configSettingId: id }));

/** Reads txMaxInstructions (CONTRACT_COMPUTE_V0) and txMaxDiskReadBytes and txMaxWriteBytes (CONTRACT_LEDGER_COST_V0)
 *  from the network's config settings. Throws when they can't be read. */
export async function readTxLimits(server: Pick<rpc.Server, "getLedgerEntries">): Promise<TxLimits> {
  const r = await server.getLedgerEntries(
    configKey(xdr.ConfigSettingId.configSettingContractComputeV0()),
    configKey(xdr.ConfigSettingId.configSettingContractLedgerCostV0()),
  );
  let instructions: number | null = null;
  let diskReadBytes: number | null = null;
  let writeBytes: number | null = null;
  for (const e of r.entries) {
    const cs = e.val.configSetting();
    if (cs.switch().name === "configSettingContractComputeV0") instructions = Number(cs.contractCompute().txMaxInstructions().toString());
    if (cs.switch().name === "configSettingContractLedgerCostV0") {
      const c = cs.contractLedgerCost();
      diskReadBytes = Number(c.txMaxDiskReadBytes());
      writeBytes = Number(c.txMaxWriteBytes());
    }
  }
  if (!instructions || !diskReadBytes || !writeBytes) throw new Error("the network's config settings didn't include the per-transaction limits");
  return { instructions, diskReadBytes, writeBytes };
}

/** The resources to declare: the simulation's with headroom (state can move between the simulation and the ledger that
 *  applies it), never above the network's per-transaction limits. A simulation that already exceeds a limit can't be
 *  sent at all, so it is refused. */
export function fitResources(
  simulated: { instructions: number; diskReadBytes: number; writeBytes: number },
  limits: TxLimits,
): { instructions: number; diskReadBytes: number; writeBytes: number } {
  const over = (["instructions", "diskReadBytes", "writeBytes"] as const).filter((k) => simulated[k] > limits[k]);
  if (over.length) {
    throw new Error(
      `this transaction needs more than the network allows per transaction (${over.map((k) => `${k} ${simulated[k]} > ${limits[k]}`).join(", ")}); nothing was sent`,
    );
  }
  return {
    instructions: Math.min(limits.instructions, Math.ceil(simulated.instructions * 1.25) + 100_000),
    diskReadBytes: Math.min(limits.diskReadBytes, Math.ceil(simulated.diskReadBytes * 1.2) + 1_000),
    writeBytes: Math.min(limits.writeBytes, Math.ceil(simulated.writeBytes * 1.2) + 1_000),
  };
}

export interface TestnetUrls {
  rpcUrl: string;
  horizonUrl: string;
  friendbotUrl: string;
}

/** The RPC calls the chain makes (rpc.Server's), so tests can stand in for the network. */
export type RpcLike = Pick<
  rpc.Server,
  "getLedgerEntries" | "getLatestLedger" | "simulateTransaction" | "getAccount" | "sendTransaction" | "getTransaction"
>;

/** Stellar testnet through its public endpoints (or STELLAR_RPC_URL for RPC, as the functions use it). `deps` replaces
 *  the RPC and Horizon clients (tests). */
export function testnetChain(urls: TestnetUrls, deps: { server?: RpcLike; horizon?: Pick<Horizon.Server, "loadAccount"> } = {}): Chain {
  const server: RpcLike = deps.server ?? new rpc.Server(urls.rpcUrl, { allowHttp: urls.rpcUrl.startsWith("http://") });
  const horizon = deps.horizon ?? new Horizon.Server(urls.horizonUrl);
  const instance = async (id: string) => {
    const r = await server.getLedgerEntries(instanceKey(id));
    return r.entries.length ? r.entries[0].val.contractData().val().instance() : null;
  };
  let limits: Promise<TxLimits> | null = null;
  const txLimits = () => {
    limits ??= readTxLimits(server).catch((e) => {
      limits = null;
      throw new Error(`can't read the network's per-transaction limits (${(e as Error).message}); nothing was sent`);
    });
    return limits;
  };
  return {
    passphrase: TESTNET_PASSPHRASE,
    async account(id) {
      try {
        const a: any = await horizon.loadAccount(id);
        const trustlines: Trustline[] = [];
        let native = 0n;
        for (const b of a.balances) {
          if (b.asset_type === "native") native = toStroops(b.balance);
          else if (b.asset_code && b.asset_issuer) {
            trustlines.push({ asset: `${b.asset_code}:${b.asset_issuer}`, balance: toStroops(b.balance), authorized: b.is_authorized !== false });
          }
        }
        return {
          id,
          sequence: String(a.sequence),
          xlm: native,
          trustlines,
          signers: (a.signers ?? []).map((s: any) => ({ key: s.key, weight: Number(s.weight) })),
          thresholds: {
            low: Number(a.thresholds?.low_threshold ?? 0),
            med: Number(a.thresholds?.med_threshold ?? 0),
            high: Number(a.thresholds?.high_threshold ?? 0),
          },
        };
      } catch (e: any) {
        if (e?.response?.status === 404 || e?.name === "NotFoundError") return null;
        throw new Error(`Horizon didn't answer for ${id}: ${e?.message ?? e}`);
      }
    },
    async latestLedger() {
      return (await server.getLatestLedger()).sequence;
    },
    async contractWasmHash(id) {
      const inst = await instance(id);
      if (!inst) return null;
      const exec = inst.executable();
      return exec.switch().name === "contractExecutableWasm" ? Buffer.from(exec.wasmHash()).toString("hex") : "stellar-asset";
    },
    async instanceStorage(id) {
      const inst = await instance(id);
      if (!inst) return null;
      return (inst.storage() ?? []).map((e) => ({ key: e.key(), val: e.val() }));
    },
    async codeExists(hashHex) {
      return (await server.getLedgerEntries(codeKey(hashHex))).entries.length > 0;
    },
    async liveUntil(contracts, codeHashes) {
      const wanted = [...contracts.map((id) => ({ name: id, key: instanceKey(id) })), ...codeHashes.map((h) => ({ name: h, key: codeKey(h) }))];
      const out = new Map<string, number | null>(wanted.map((w) => [w.name, null]));
      for (let i = 0; i < wanted.length; i += 50) {
        const batch = wanted.slice(i, i + 50);
        const r = await server.getLedgerEntries(...batch.map((b) => b.key));
        for (const e of r.entries) {
          const found = batch.find((b) => b.key.toXDR("base64") === e.key.toXDR("base64"));
          if (found) out.set(found.name, e.liveUntilLedgerSeq ?? null);
        }
      }
      return out;
    },
    async view(id, fn, args) {
      const source = new Account(Keypair.random().publicKey(), "0");
      const tx = new TransactionBuilder(source, { fee: BASE_FEE, networkPassphrase: TESTNET_PASSPHRASE })
        .addOperation(new Contract(id).call(fn, ...args)).setTimeout(60).build();
      const sim = await server.simulateTransaction(tx);
      if (rpc.Api.isSimulationError(sim)) throw new Error(`${fn} failed in simulation: ${simulationError(sim.error)}`);
      const ok = sim as rpc.Api.SimulateTransactionSuccessResponse;
      return ok.result?.retval ?? xdr.ScVal.scvVoid();
    },
    async friendbot(id) {
      const r = await fetch(`${urls.friendbotUrl}?addr=${encodeURIComponent(id)}`);
      const body = await r.text();
      if (!r.ok && !/already funded|createAccountAlreadyExist|op_already_exists/i.test(body)) {
        throw new Error(`Friendbot didn't fund ${id} (HTTP ${r.status})`);
      }
    },
    async sourceAccount(id) {
      return await server.getAccount(id);
    },
    async prepare(tx) {
      const lim = await txLimits();
      const sim = await server.simulateTransaction(tx);
      if (rpc.Api.isSimulationError(sim)) throw new Error(`simulation failed: ${simulationError(sim.error)}`);
      if (rpc.Api.isSimulationRestore(sim)) throw new Error("part of this contract's state is archived; restore it first");
      const ok = sim as rpc.Api.SimulateTransactionSuccessResponse;
      // Headroom within the network's limits (fitResources). The resource fee lives in the Soroban data
      // (assembleTransaction adds it to the fee), so it is raised with the resources.
      const data = ok.transactionData;
      const r = data.build().resources();
      const fit = fitResources({ instructions: r.instructions(), diskReadBytes: r.diskReadBytes(), writeBytes: r.writeBytes() }, lim);
      data.setResources(fit.instructions, fit.diskReadBytes, fit.writeBytes);
      data.setResourceFee(BigInt(Math.ceil(Number(ok.minResourceFee) * 1.3) + 100_000));
      ok.transactionData = data;
      return rpc.assembleTransaction(tx, ok).build();
    },
    async submit(tx) {
      let sent = await server.sendTransaction(tx);
      for (let i = 0; i < 5 && sent.status === "TRY_AGAIN_LATER"; i++) {
        await sleep(2_000);
        sent = await server.sendTransaction(tx);
      }
      if (sent.status === "ERROR") {
        throw new Error(`the network refused transaction ${sent.hash} (${sent.errorResult?.result().switch().name ?? "error"})`);
      }
      if (sent.status === "TRY_AGAIN_LATER") throw new Error(`the network is busy; transaction ${sent.hash} was not sent`);
      const until = Date.now() + 120_000;
      while (Date.now() < until) {
        const r = await server.getTransaction(sent.hash);
        if (r.status === rpc.Api.GetTransactionStatus.SUCCESS) {
          const s = r as rpc.Api.GetSuccessfulTransactionResponse;
          return {
            hash: sent.hash,
            ledger: s.ledger,
            feeCharged: BigInt((s as any).resultXdr?.feeCharged?.()?.toString() ?? "0"),
            returnValue: s.returnValue ?? null,
          };
        }
        if (r.status === rpc.Api.GetTransactionStatus.FAILED) {
          const code = (r as any).resultXdr?.result?.()?.switch?.()?.name ?? "failed";
          throw new Error(`transaction ${sent.hash} failed (${code})`);
        }
        await sleep(1_500);
      }
      throw new Error(`transaction ${sent.hash} was sent but not seen within 2 minutes; check it before running again`);
    },
  };
}

/** The useful part of a simulation error: the contract error code or the host error, not the whole event dump. */
export function simulationError(raw: string): string {
  const contract = raw.match(/Error\(Contract, #(\d+)\)/);
  if (contract) return `contract error #${contract[1]}`;
  const host = raw.match(/Error\((\w+), (\w+)\)/);
  if (host) return `host error ${host[1]}/${host[2]}`;
  return raw.split("\n")[0].slice(0, 200);
}

/** For dry runs and `check`: every sending method throws. */
export function readOnlyChain(chain: ChainReader): Chain {
  const refuse = (what: string) => () => Promise.reject(new Error(`${what} refused: this run is read-only`));
  return {
    passphrase: chain.passphrase,
    account: (id) => chain.account(id),
    latestLedger: () => chain.latestLedger(),
    contractWasmHash: (id) => chain.contractWasmHash(id),
    instanceStorage: (id) => chain.instanceStorage(id),
    codeExists: (h) => chain.codeExists(h),
    liveUntil: (contracts, hashes) => chain.liveUntil(contracts, hashes),
    view: (id, fn, args) => chain.view(id, fn, args),
    friendbot: refuse("Friendbot"),
    sourceAccount: refuse("building a transaction"),
    prepare: refuse("preparing a transaction"),
    submit: refuse("submitting a transaction"),
  };
}

// ------------------------------------------------------------------------------------------------ transactions

/** A transaction with one operation from `source`, valid for `timeoutSec`. */
export async function buildTx(chain: Chain, source: string, op: xdr.Operation, timeoutSec = 300): Promise<Transaction> {
  const account = await chain.sourceAccount(source);
  return new TransactionBuilder(account, { fee: BASE_FEE, networkPassphrase: chain.passphrase })
    .addOperation(op)
    .setTimeout(timeoutSec)
    .build();
}

const isSoroban = (tx: Transaction) =>
  tx.operations.some((o) => o.type === "invokeHostFunction" || o.type === "extendFootprintTtl" || o.type === "restoreFootprint");

/** Builds, prepares (Soroban only), signs with `signer` and submits one operation. */
export async function send(chain: Chain, signer: Keypair, op: xdr.Operation): Promise<TxOutcome> {
  const built = await buildTx(chain, signer.publicKey(), op);
  const tx = isSoroban(built) ? await chain.prepare(built) : built;
  tx.sign(signer);
  return await chain.submit(tx);
}

/** A contract call signed by `signer`, which is the source (its auth is the source account's). */
export async function invoke(chain: Chain, signer: Keypair, contract: string, fn: string, args: xdr.ScVal[]): Promise<TxOutcome> {
  return await send(chain, signer, new Contract(contract).call(fn, ...args));
}

/** Uploads a WASM unless it is already there. Returns its hash and the outcome (null when skipped). */
export async function uploadWasm(chain: Chain, signer: Keypair, wasm: Uint8Array, hashHex: string): Promise<TxOutcome | null> {
  if (await chain.codeExists(hashHex)) return null;
  const out = await send(chain, signer, Operation.uploadContractWasm({ wasm: Buffer.from(wasm) }));
  const got = out.returnValue ? Buffer.from(out.returnValue.bytes()).toString("hex") : null;
  if (got !== null && got !== hashHex) throw new Error(`the network stored the WASM as ${got}, expected ${hashHex}`);
  return out;
}

/** Creates a contract from an uploaded WASM with the deployer's salt and constructor arguments; checks the id. */
export async function createContract(
  chain: Chain,
  deployer: Keypair,
  wasmHashHex: string,
  salt: Uint8Array,
  args: xdr.ScVal[],
  expectedId: string,
): Promise<TxOutcome> {
  const op = Operation.createCustomContract({
    address: new Address(deployer.publicKey()),
    wasmHash: Buffer.from(wasmHashHex, "hex"),
    salt: Buffer.from(salt),
    constructorArgs: args,
  });
  const out = await send(chain, deployer, op);
  const id = out.returnValue ? Address.fromScVal(out.returnValue).toString() : null;
  if (id !== expectedId) throw new Error(`the contract was created at ${id}, not at the planned ${expectedId}`);
  return out;
}

// ------------------------------------------------------------------------------------------------ unsigned envelopes

/** The file admin-v2.ts writes and `owner-v2.ts sign` reads: a prepared, unsigned transaction and what it is for.
 *  The passphrase travels with it because the XDR alone doesn't say which network it is for. */
export interface UnsignedEnvelope {
  format: typeof ENVELOPE_FORMAT;
  networkPassphrase: string;
  /** The role whose key signs it: admin, governance, guardian, treasury or v1-admin. */
  role: string;
  /** The source account, which is the role's address. */
  source: string;
  contract: string;
  function: string;
  /** One line for the owner. */
  description: string;
  builtAt: string;
  /** Base64 TransactionEnvelope, unsigned. */
  xdr: string;
}

export const ENVELOPE_FORMAT = "dyorhq-unsigned-envelope/1";
export const SIGNING_ROLES = ["admin", "governance", "guardian", "treasury", "v1-admin"] as const;
export type SigningRole = typeof SIGNING_ROLES[number];

/** Parses an envelope file; throws on anything else. */
export function parseEnvelope(text: string): UnsignedEnvelope {
  let raw: any;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new Error("not an envelope file written by admin-v2.ts (not JSON)");
  }
  if (raw?.format !== ENVELOPE_FORMAT) throw new Error(`not an envelope file written by admin-v2.ts (its format isn't ${ENVELOPE_FORMAT})`);
  for (const k of ["networkPassphrase", "role", "source", "xdr"]) {
    if (typeof raw[k] !== "string" || raw[k] === "") throw new Error(`the envelope file has no ${k}`);
  }
  return raw as UnsignedEnvelope;
}

// ------------------------------------------------------------------------------------------------ numbers

export function toStroops(decimal: string): bigint {
  const neg = decimal.startsWith("-");
  const [i, f = ""] = decimal.replace(/^-/, "").split(".");
  const v = BigInt(i || "0") * STROOPS_PER_XLM + BigInt((f + "0000000").slice(0, 7));
  return neg ? -v : v;
}

/** 12_345_678_900n → "1,234.56789". */
export function fmtUnits(stroops: bigint, decimals = 7): string {
  const neg = stroops < 0n;
  const abs = neg ? -stroops : stroops;
  const base = 10n ** BigInt(decimals);
  const whole = (abs / base).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = (abs % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return `${neg ? "-" : ""}${whole}${frac ? "." + frac : ""}`;
}

export const fmtXlm = (stroops: bigint) => `${fmtUnits(stroops)} XLM`;

// ------------------------------------------------------------------------------------------------ preflight

export interface CheckLine {
  ok: boolean;
  label: string;
  /** Addresses and amounts only. */
  detail: string;
  /** False for lines that are reported but never stop a deploy. */
  needed: boolean;
}

export const line = (ok: boolean, label: string, detail = "", needed = true): CheckLine => ({ ok, label, detail, needed });

export function renderCheck(l: CheckLine): string {
  return `${l.ok ? "✓" : "✗"} ${l.label}${l.detail ? `: ${l.detail}` : ""}${!l.ok && !l.needed ? " (reported only)" : ""}`;
}

export const allNeededPass = (lines: CheckLine[]) => lines.every((l) => l.ok || !l.needed);

export interface PreflightInput {
  chain: ChainReader;
  roles: V2Roles;
  /** The account that pays for the deploy. */
  deployer: string;
  /** Classic assets (CODE:ISSUER) the treasury must trust: every enabled classic quote asset (F9). */
  treasuryAssets: string[];
  /** Classic assets the Moments platform must trust: USDC. */
  platformAssets: string[];
  /** Stroops: MIN_DEPLOYER_XLM, or MIN_DEPLOYER_XLM_FLOAT with --fund-aqua-float. */
  minDeployerXlm: bigint;
  /** Names for asset strings in messages ("USDC"). */
  assetNames?: Map<string, string>;
}

/** XLM the deployer must hold before a deploy: the uploads (about 170 XLM) and the TTL step's 75 days of rent for every
 *  v2 WASM and instance (at most about 1,630 XLM; the Soroswap entries have more than 75 days and are skipped),
 *  simulated on testnet on 2026-10-15: about 1,800 XLM, with a 50% margin 2,700, rounded up to a whole 500. Friendbot
 *  funds a new account with 10,000. */
export const MIN_DEPLOYER_XLM = 3_000n;
/** With --fund-aqua-float: up to 1,500 XLM more for the XLM → AQUA swap. */
export const MIN_DEPLOYER_XLM_FLOAT = 4_500n;

const ROLE_LABELS: [keyof V2Roles, string][] = [
  ["ADMIN_PUBLIC", "admin"],
  ["GOVERNANCE_PUBLIC", "Moments governance"],
  ["LAUNCHPAD_GUARDIAN_PUBLIC", "launchpad guardian"],
  ["MOMENTS_GUARDIAN_PUBLIC", "Moments guardian"],
  ["TREASURY_PUBLIC", "treasury"],
  ["PLATFORM_PUBLIC", "Moments platform"],
];

/** L-e: one line per check, read-only. */
export async function preflight(p: PreflightInput): Promise<CheckLine[]> {
  const out: CheckLine[] = [];
  const accounts = new Map<string, AccountInfo | null>();
  const get = async (id: string) => {
    if (!accounts.has(id)) accounts.set(id, await p.chain.account(id));
    return accounts.get(id)!;
  };
  // Each distinct role account once, with every role it holds.
  const byAddress = new Map<string, string[]>();
  for (const [k, label] of ROLE_LABELS) byAddress.set(p.roles[k], [...(byAddress.get(p.roles[k]) ?? []), label]);
  for (const [id, labels] of byAddress) {
    const a = await get(id);
    out.push(line(a !== null, `${labels.join(" + ")} account exists`, a ? `${id}, ${fmtXlm(a.xlm)}` : `${id} not found on testnet`));
  }
  const name = (asset: string) => p.assetNames?.get(asset) ?? asset.split(":")[0];
  const trusts = async (who: string, id: string, assets: string[]) => {
    const a = await get(id);
    for (const asset of assets) {
      const t = a?.trustlines.find((x) => x.asset === asset);
      const ok = !!t && t.authorized;
      out.push(line(ok, `${who} trusts ${name(asset)}`, ok ? id : `${id} has no ${t && !t.authorized ? "authorized " : ""}${name(asset)} trustline`));
    }
  };
  await trusts("treasury", p.roles.TREASURY_PUBLIC, p.treasuryAssets);
  if (p.roles.PLATFORM_PUBLIC !== p.roles.TREASURY_PUBLIC) await trusts("Moments platform", p.roles.PLATFORM_PUBLIC, p.platformAssets);
  else {
    const missing = p.platformAssets.filter((a) => !p.treasuryAssets.includes(a));
    if (missing.length) await trusts("Moments platform", p.roles.PLATFORM_PUBLIC, missing);
  }
  const d = await get(p.deployer);
  const enough = !!d && d.xlm >= p.minDeployerXlm;
  out.push(line(enough, `deployer holds at least ${fmtXlm(p.minDeployerXlm)}`, d ? `${p.deployer}, ${fmtXlm(d.xlm)}` : `${p.deployer} not found`));
  return out;
}

/** True when one signer can meet the account's medium threshold alone on a multi-signer account (B11a, §16):
 *  `require_auth` on a G-account checks the medium threshold. A single-signer account is not "multi-signer". */
export function singleSignerMeetsMedium(a: AccountInfo): boolean {
  const signers = a.signers.filter((s) => s.weight > 0);
  if (signers.length < 2) return false;
  return signers.some((s) => s.weight >= a.thresholds.med);
}
