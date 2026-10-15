// The owner's deployment kit, end to end, with no network: owner-v2.ts (keys, trust, check, sign),
// deploy-contracts-v2.ts (dry run, deploy, re-run, testnet-qa) and admin-v2.ts (the v1 cutover, a v2 builder, the
// multisig check). Every network call goes to an in-memory ledger that applies the transactions the scripts build;
// every secret directory is a fresh temporary one holding keys made here. Each CLI path's output is checked for
// secrets: no seed this file generated, and nothing shaped like one. The last tests run the scripts as processes
// without network permission, for their real stdout and stderr.
import { assert, assertEquals, assertFalse, assertMatch, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import {
  Account,
  Address,
  Asset,
  hash,
  Keypair,
  Memo,
  nativeToScVal,
  Operation,
  scValToNative,
  SorobanDataBuilder,
  StrKey,
  type Transaction,
  TransactionBuilder,
  xdr,
} from "@stellar/stellar-sdk";
import { main as adminMain } from "./admin-v2.ts";
import { type DeployCtx, main as deployMain } from "./deploy-contracts-v2.ts";
import { main as ownerMain, type OwnerCtx } from "./owner-v2.ts";
import { contractIdFor } from "./lib/contract-ids.ts";
import { KEYS_FILE, QA_KEYS_FILE, recordingIo, ROLES_FILE } from "./lib/owner-files.ts";
import type { AccountInfo, Chain, TxOutcome } from "./lib/preflight-v2.ts";
import { sha256Hex } from "./lib/reviewed-hashes.ts";
import { constructors, RUNTIME_CONSTRUCTORS, WASMS, type WasmKey } from "./lib/v2-constructors.ts";
import { customSections, specEntries, wasmWithSections } from "./lib/wasm-spec.ts";

const repo = new URL("../../", import.meta.url).pathname;
const PASSPHRASE = "Test SDF Network ; September 2015";
const FIXTURES = JSON.parse(Deno.readTextFileSync(`${repo}contracts/testdata/fixtures.json`));
const AQ = FIXTURES.aquarius;
const V1 = JSON.parse(Deno.readTextFileSync(`${repo}backend/supabase/functions/_shared/deployments/testnet.json`));
const USDC_CLASSIC = "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5";
const USDC_SAC = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA";
const XLM_SAC = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC";
const XLM = 10_000_000n;
const SEED = /S[A-Z2-7]{55}/;
/** Testnet's minimum persistent TTL: what a new entry starts with (about 7 days). */
const MIN_TTL = 120_960;

/** The source account's auth entry for a call, its root invocation the call itself (what simulation returns). */
function sourceAuth(call: xdr.InvokeContractArgs, sub: xdr.SorobanAuthorizedInvocation[] = []): xdr.SorobanAuthorizationEntry {
  return new xdr.SorobanAuthorizationEntry({
    credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(),
    rootInvocation: new xdr.SorobanAuthorizedInvocation({
      function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(call),
      subInvocations: sub,
    }),
  });
}

// ------------------------------------------------------------------------------------------------ the in-memory ledger

/** Native values to ScVals the way the contracts return them (integers as i128 or u32, addresses, maps by key). */
function sv(v: unknown): xdr.ScVal {
  if (v === null || v === undefined) return xdr.ScVal.scvVoid();
  if (typeof v === "boolean") return xdr.ScVal.scvBool(v);
  if (typeof v === "bigint") return nativeToScVal(v, { type: "i128" });
  if (typeof v === "number") return nativeToScVal(v, { type: "u32" });
  if (typeof v === "string") return /^[GC][A-Z2-7]{55}$/.test(v) ? new Address(v).toScVal() : nativeToScVal(v, { type: "string" });
  if (v instanceof Uint8Array) return xdr.ScVal.scvBytes(Buffer.from(v));
  if (Array.isArray(v)) return xdr.ScVal.scvVec(v.map(sv));
  const o = v as Record<string, unknown>;
  return xdr.ScVal.scvMap(Object.keys(o).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: sv(o[k]) })));
}

type Fn = (args: unknown[], source: string | null) => unknown;
interface Contract {
  kind: string;
  wasm: string;
  storage?: { key: xdr.ScVal; val: xdr.ScVal }[];
  fns: Record<string, Fn>;
}

/** A small Stellar: accounts, uploaded code, contracts with just enough behaviour for the kit, and a log. */
class Ledger implements Chain {
  passphrase = PASSPHRASE;
  ledger = 5_200_000;
  accounts = new Map<string, AccountInfo>();
  codes = new Set<string>();
  contracts = new Map<string, Contract>();
  /** Contract balances held by contracts (AQUA at exec-aquarius), by asset → holder. */
  held = new Map<string, Map<string, bigint>>();
  wasmKinds = new Map<string, string>();
  log: string[] = [];
  pool = { xlm: 349_583_963_389n, aqua: 7_911_445_542_969n };
  failSwap = false;
  /** The router's views fail (an upgrade removed them, or its instance is archived). */
  routerDown = false;
  /** Live-until ledgers of contract instances (by id) and WASMs (by hash). New entries get testnet's minimum TTL. */
  ttl = new Map<string, number>();
  /** Called when the router quotes a swap (a test's hook into the AQUA depth check). */
  onEstimate: (() => void) | null = null;

  constructor() {
    this.addContract(AQ.router.contract_id, {
      kind: "router",
      wasm: AQ.router.wasm_hash,
      storage: [
        { key: xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("ConstantPoolHash")]), val: xdr.ScVal.scvBytes(Buffer.from(AQ.router.constant_pool_hash, "hex")) },
        { key: xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("TokenHash")]), val: xdr.ScVal.scvBytes(Buffer.from(AQ.router.token_hash, "hex")) },
      ],
      fns: {
        estimate_swap: (a) => this.quote(BigInt(a[4] as bigint)),
        swap: (a, source) => {
          const [user, , , , , amount, min] = a as [string, unknown, unknown, unknown, unknown, bigint, bigint];
          if (user !== source) throw new Error("swap: user isn't the source");
          if (this.failSwap) throw new Error("Error(Contract, #2006)");
          const out = this.quote(amount);
          if (out < min) throw new Error("Error(Contract, #2004)");
          this.accounts.get(user)!.xlm -= amount;
          this.trust(user, `${AQ.aqua.code}:${AQ.aqua.issuer}`).balance += out;
          return out;
        },
        get_standard_pool_payment_amount: () => 10_000_000n,
        get_init_pool_payment_token: () => AQ.aqua.sac,
      },
    });
    this.addSac(`${AQ.aqua.code}:${AQ.aqua.issuer}`, AQ.aqua.sac);
    this.addSac(USDC_CLASSIC, USDC_SAC);
    this.addSac("native", XLM_SAC);
  }

  quote(xlmIn: bigint): bigint {
    const inWithFee = xlmIn * 997n;
    return (inWithFee * this.pool.aqua) / (this.pool.xlm * 1000n + inWithFee);
  }

  trust(id: string, asset: string) {
    const t = this.accounts.get(id)?.trustlines.find((x) => x.asset === asset);
    if (!t) throw new Error(`${id} has no ${asset} trustline`);
    return t;
  }

  addContract(id: string, c: Contract) {
    this.contracts.set(id, c);
  }

  addSac(classic: string, id: string) {
    const bal = (who: string): bigint => {
      if (StrKey.isValidContract(who)) return this.held.get(id)?.get(who) ?? 0n;
      const a = this.accounts.get(who);
      if (!a) return 0n;
      return classic === "native" ? a.xlm : (a.trustlines.find((t) => t.asset === classic)?.balance ?? 0n);
    };
    const add = (who: string, amount: bigint) => {
      if (StrKey.isValidContract(who)) {
        const m = this.held.get(id) ?? new Map<string, bigint>();
        m.set(who, (m.get(who) ?? 0n) + amount);
        this.held.set(id, m);
      } else if (classic === "native") this.accounts.get(who)!.xlm += amount;
      else this.trust(who, classic).balance += amount;
    };
    this.addContract(id, {
      kind: "sac",
      wasm: "stellar-asset",
      fns: {
        balance: (a) => bal(a[0] as string),
        transfer: (a, source) => {
          const [from, to, amount] = a as [string, string, bigint];
          if (from !== source) throw new Error("transfer: from isn't the source");
          if (bal(from) < amount) throw new Error("Error(Contract, #10)");
          add(from, -amount);
          add(to, amount);
        },
      },
    });
  }

  fund(id: string, xlm: bigint) {
    this.accounts.set(id, { id, sequence: "100", xlm, trustlines: [], signers: [{ key: id, weight: 1 }], thresholds: { low: 0, med: 0, high: 0 } });
  }

  // -- Chain
  account(id: string) {
    const a = this.accounts.get(id);
    return Promise.resolve(a ? structuredClone(a) : null);
  }
  latestLedger() {
    return Promise.resolve(this.ledger);
  }
  contractWasmHash(id: string) {
    return Promise.resolve(this.contracts.get(id)?.wasm ?? null);
  }
  instanceStorage(id: string) {
    return Promise.resolve(this.contracts.get(id)?.storage ?? (this.contracts.has(id) ? [] : null));
  }
  codeExists(h: string) {
    return Promise.resolve(this.codes.has(h));
  }
  liveUntil(contracts: string[], hashes: string[]) {
    return Promise.resolve(new Map([...contracts, ...hashes].map((k) => [k, this.ttl.get(k) ?? null])));
  }
  /** What ttl.ts keepAlive does when every batch applies: 30 days from now. `skip` entries are left as they were. */
  extendTtl(contracts: string[], hashes: string[], skip: string[] = []) {
    for (const k of [...contracts, ...hashes]) if (!skip.includes(k)) this.ttl.set(k, this.ledger + 30 * 17_280);
  }
  view(id: string, fn: string, args: xdr.ScVal[]) {
    const kind = this.contracts.get(id)?.kind ?? id;
    this.log.push(`view ${kind}.${fn}`);
    if (kind === "router") {
      if (fn === "estimate_swap") this.onEstimate?.();
      if (this.routerDown) return Promise.reject(new Error(`${fn} failed in simulation: host error Storage/MissingValue`));
    }
    try {
      return Promise.resolve(sv(this.call(id, fn, args.map((x) => scValToNative(x)), null)));
    } catch (e) {
      return Promise.reject(e);
    }
  }
  friendbot(id: string) {
    this.log.push(`friendbot ${id}`);
    if (!this.accounts.has(id)) this.fund(id, 10_000n * XLM);
    return Promise.resolve();
  }
  sourceAccount(id: string) {
    const a = this.accounts.get(id);
    if (!a) return Promise.reject(new Error(`account ${id} not found`));
    return Promise.resolve(new Account(id, a.sequence));
  }
  /** As the RPC's simulation and assembleTransaction do: Soroban data, and for a contract call the source account's
   *  auth entry whose root invocation is the call itself. */
  prepare(tx: Transaction) {
    this.log.push("prepare");
    const data = new SorobanDataBuilder().setResourceFee(50_000).build();
    const b = TransactionBuilder.cloneFrom(tx, { fee: String(Number(tx.fee) + 50_000), sorobanData: data, networkPassphrase: PASSPHRASE });
    const op = tx.operations[0] as any;
    if (op.type === "invokeHostFunction" && (op.func as xdr.HostFunction).switch().name === "hostFunctionTypeInvokeContract") {
      const call = (op.func as xdr.HostFunction).invokeContract();
      b.clearOperations();
      b.addOperation(Operation.invokeHostFunction({ func: op.func, auth: [sourceAuth(call)] }));
    }
    return Promise.resolve(b.build());
  }
  submit(tx: Transaction): Promise<TxOutcome> {
    try {
      const signer = Keypair.fromPublicKey(tx.source);
      if (!tx.signatures.some((s) => signer.verify(tx.hash(), s.signature()))) throw new Error("txBadAuth");
      const a = this.accounts.get(tx.source)!;
      if (BigInt(tx.sequence) !== BigInt(a.sequence) + 1n) throw new Error("txBadSeq");
      const returnValue = this.apply(tx);
      a.sequence = tx.sequence;
      this.ledger += 1;
      return Promise.resolve({ hash: tx.hash().toString("hex"), ledger: this.ledger, feeCharged: 1_000n, returnValue });
    } catch (e) {
      return Promise.reject(new Error(`transaction failed: ${(e as Error).message}`));
    }
  }

  apply(tx: Transaction): xdr.ScVal | null {
    const op = tx.operations[0] as any;
    if (op.type === "changeTrust") {
      const asset = op.line as Asset;
      const name = `${asset.getCode()}:${asset.getIssuer()}`;
      const acct = this.accounts.get(tx.source)!;
      if (!acct.trustlines.some((t) => t.asset === name)) acct.trustlines.push({ asset: name, balance: 0n, authorized: true });
      this.log.push(`changeTrust ${asset.getCode()} by ${tx.source}`);
      return null;
    }
    const f = op.func as xdr.HostFunction;
    switch (f.switch().name) {
      case "hostFunctionTypeUploadContractWasm": {
        const h = Buffer.from(hash(Buffer.from(f.wasm()))).toString("hex");
        this.codes.add(h);
        this.ttl.set(h, this.ledger + MIN_TTL);
        this.log.push(`upload ${this.wasmKinds.get(h) ?? h}`);
        return xdr.ScVal.scvBytes(Buffer.from(h, "hex"));
      }
      case "hostFunctionTypeCreateContract": {
        const asset = Asset.fromOperation(f.createContract().contractIdPreimage().fromAsset());
        const id = asset.contractId(PASSPHRASE);
        if (!this.contracts.has(id)) this.addSac(`${asset.getCode()}:${asset.getIssuer()}`, id);
        this.ttl.set(id, this.ledger + MIN_TTL);
        this.log.push(`create SAC ${asset.getCode()}`);
        return new Address(id).toScVal();
      }
      case "hostFunctionTypeCreateContractV2": {
        const c = f.createContractV2();
        const from = c.contractIdPreimage().fromAddress();
        const deployer = Address.fromScAddress(from.address()).toString();
        if (deployer !== tx.source) throw new Error("the deployer must sign");
        const wasm = Buffer.from(c.executable().wasmHash()).toString("hex");
        if (!this.codes.has(wasm)) throw new Error("the WASM isn't uploaded");
        const id = contractIdFor(deployer, Uint8Array.from(from.salt()), PASSPHRASE);
        if (this.contracts.has(id)) throw new Error("the contract exists");
        const kind = this.wasmKinds.get(wasm)!;
        const args = c.constructorArgs().map((x) => scValToNative(x));
        // Like the v2 contracts, the instance keeps its constructor arguments in its storage.
        this.addContract(id, { ...this.instantiate(kind, wasm, id, args), storage: [{ key: xdr.ScVal.scvSymbol("Args"), val: sv(args) }] });
        this.ttl.set(id, this.ledger + MIN_TTL);
        this.log.push(`create ${kind}`);
        return new Address(id).toScVal();
      }
      case "hostFunctionTypeInvokeContract": {
        const ic = f.invokeContract();
        const id = Address.fromScAddress(ic.contractAddress()).toString();
        const fn = ic.functionName().toString();
        this.log.push(`invoke ${this.contracts.get(id)?.kind ?? id}.${fn}`);
        return sv(this.call(id, fn, ic.args().map((x) => scValToNative(x)), tx.source));
      }
    }
    throw new Error(`unsupported host function ${f.switch().name}`);
  }

  call(id: string, fn: string, args: unknown[], source: string | null): unknown {
    const c = this.contracts.get(id);
    if (!c) throw new Error(`no contract ${id}`);
    const f = c.fns[fn];
    if (!f) throw new Error(`${c.kind} has no ${fn}`);
    return f(args, source);
  }

  /** The v2 contracts, from their constructor arguments (the pinned signatures). */
  instantiate(kind: string, wasm: string, id: string, a: unknown[]): Contract {
    const admin = (who: string | null, want: unknown) => {
      if (who !== want) throw new Error("Error(Auth, InvalidAction)");
    };
    const locker = (lockerId: unknown) => Number(this.call(String(lockerId), "harvest_interval", [], null));
    switch (kind) {
      case "exec-soroswap":
        return { kind, wasm, fns: { factory: () => a[0], callers: () => a[1] } };
      case "exec-aquarius":
        return { kind, wasm, fns: { max_pool_payment: () => a[2], float: () => this.held.get(AQ.aqua.sac)?.get(id) ?? 0n, pool_payment: () => [AQ.aqua.sac, 10_000_000n] } };
      case "qa-exec-fail":
        return { kind, wasm, fns: { callers: () => a[0], qa_admin: () => a[1], mode: () => Number(a[2]) } };
      case "lp-locker":
        if ((a[0] as unknown[]).length === 0) throw new Error("the locker needs an owner");
        return { kind, wasm, fns: { owners: () => a[0], soroswap_factory: () => a[1], aquarius_router: () => a[2], harvest_interval: () => BigInt(a[3] as bigint) } };
      case "moments-graduator":
        return { kind, wasm, fns: {} };
      case "launchpad-v2": {
        const [adm, guardian, treasury, xlm, tokenHash, lockerId, factory, router, launchFee, venues, durations, ttl] = a as any[];
        if (locker(lockerId) !== Number(durations.harvest_interval)) throw new Error("Error(Contract, #10129)");
        const cfg: Record<string, unknown> = {
          admin: adm, guardian, treasury, xlm, token_wasm_hash: tokenHash, locker: lockerId, soroswap_factory: factory, aquarius_router: router,
          supply: 10_000_000_000_000_000n, fee_bps: 100, protocol_share_bps: 5000, max_creator_fee_bps: 1000, snipe_schedule: [9800, 2500, 300, 30],
          snipe_step_secs: 5, launch_fee: BigInt(launchFee), launches_enabled: true, whitelist_enabled: false, durations, ttl,
        };
        const table = (venues as any[]).map((v, i) => ({ id: i, kind: Number(v.kind), executor: v.executor, params: { fee_fraction: Number(v.params.fee_fraction) }, enabled: true }));
        const quotes = new Map<string, unknown>();
        return {
          kind,
          wasm,
          fns: {
            config: () => cfg,
            venues: () => table,
            treasury: () => cfg.treasury,
            quote_economics: (x) => quotes.get(x[0] as string) ?? null,
            set_quote: (x, s) => {
              admin(s, cfg.admin);
              quotes.set(x[0] as string, { phantom: x[1], threshold: x[2], enabled: x[3], venues_allowed: x[4], fallback_venue: x[5] });
            },
            set_launch_fee: (x, s) => {
              admin(s, cfg.admin);
              cfg.launch_fee = x[0];
            },
            set_fees: (x, s) => {
              admin(s, cfg.admin);
              [cfg.fee_bps, cfg.protocol_share_bps, cfg.max_creator_fee_bps, cfg.snipe_schedule, cfg.snipe_step_secs] = x;
            },
            set_venue_enabled: (x, s) => {
              admin(s, cfg.admin);
              table[Number(x[0])].enabled = Boolean(x[1]);
            },
            propose_treasury: (_x, s) => admin(s, cfg.admin),
          },
        };
      }
      case "moments-v2": {
        const [governance, guardian, usdc, nftHash, graduator, lockerId, executor, factory, base, policy, durations, ttl] = a as any[];
        if (locker(lockerId) !== Number(durations.harvest_interval)) throw new Error("Error(Contract, #10729)");
        const cfg = { governance, guardian, usdc, nft_wasm_hash: nftHash, graduator, locker: lockerId, executor, soroswap_factory: factory, external_base: base, publishing_paused: false, guardian_paused: false, durations, ttl };
        return { kind, wasm, fns: { config: () => cfg, policy: () => policy } };
      }
    }
    throw new Error(`unknown kind ${kind}`);
  }
}

// ------------------------------------------------------------------------------------------------ fixtures

/** A temporary repository root: synthesized dist WASMs (each declaring the constructor the builders expect), the
 *  reviewed list, fixtures.json and the economics files. */
async function fakeRepo(ledger: Ledger, opts: { reviewed?: boolean } = {}): Promise<string> {
  const root = await Deno.makeTempDir({ prefix: "ct11a-repo-" });
  for (const d of ["contracts/dist", "contracts/review", "contracts/testdata", "backend/scripts/economics", "deployments"]) await Deno.mkdir(`${root}/${d}`, { recursive: true });
  await Deno.copyFile(`${repo}contracts/testdata/fixtures.json`, `${root}/contracts/testdata/fixtures.json`);
  for (const f of ["testnet-v2.json", "testnet-qa-v2.json"]) await Deno.copyFile(`${repo}backend/scripts/economics/${f}`, `${root}/backend/scripts/economics/${f}`);
  const params = paramsByWasm();
  const lines: string[] = [];
  for (const k of Object.keys(WASMS) as WasmKey[]) {
    const spec = Buffer.concat(specEntries("__constructor", params.get(k)!).map((e) => e.toXDR()));
    const wasm = wasmWithSections([["contractspecv0", Uint8Array.from(spec)], ["dyorhq-test", new TextEncoder().encode(k)]]);
    await Deno.writeFile(`${root}/contracts/dist/${WASMS[k].file}`, wasm);
    const h = await sha256Hex(wasm);
    ledger.wasmKinds.set(h, k);
    lines.push(`${h}  dist/${WASMS[k].file}`);
  }
  if (opts.reviewed !== false) await Deno.writeTextFile(`${root}/contracts/review/reviewed-wasm.sha256`, `${lines.sort().join("\n")}\ncommit 9354d56\n`);
  return `${root}/`;
}

/** The constructor parameters the builders declare, for every v2 WASM. */
function paramsByWasm() {
  const fake = "GAFMNWY5ZNQZ5QHVQW6JJO2L6XFC7ZHGGAAKEPLUCGBV7EQZELCITYSJ";
  const id = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC";
  const ids = Object.fromEntries(["exec-soroswap", "exec-aquarius", "qa-exec-fail", "lp-locker", "moments-graduator", "launchpad-v2", "moments-v2", "moments-graduator-qa-fail", "moments-v2-qa-fail"].map((n) => [n, id]));
  const econ = JSON.parse(Deno.readTextFileSync(`${repo}backend/scripts/economics/testnet-qa-v2.json`));
  const roles = { ADMIN_PUBLIC: fake, GOVERNANCE_PUBLIC: fake, LAUNCHPAD_GUARDIAN_PUBLIC: fake, MOMENTS_GUARDIAN_PUBLIC: fake, TREASURY_PUBLIC: fake, PLATFORM_PUBLIC: fake };
  const ctors = constructors({
    profile: { ...{ name: "testnet-qa" }, qaExecFail: true, failingMomentsStack: true, launchDurations: {}, momentsDurations: {}, ttl: { threshold: 1, extend_to: 2 } } as never,
    roles,
    ids,
    wasmHashes: {},
    network: { xlmSac: id, usdcSac: id, soroswapFactory: id, aquariusRouter: id },
    economics: econ,
    aquarius: { enabled: true, paymentAsset: id },
    qaAdmin: fake,
  });
  const m = new Map<WasmKey, ReturnType<typeof constructors>[number]["params"]>();
  for (const c of ctors) if (!m.has(c.wasm)) m.set(c.wasm, c.params);
  for (const [k, v] of Object.entries(RUNTIME_CONSTRUCTORS)) m.set(k as WasmKey, v);
  return m;
}

interface Kit {
  ledger: Ledger;
  root: string;
  secrets: string;
  deployments: string;
  env: Record<string, string>;
  /** Everything the scripts wrote, unredacted and unescaped (recordingIo). */
  outputs: string[];
  /** Entries the TTL step leaves short (a batch that "succeeded" without applying). */
  ttlSkip: string[];
}

async function kit(opts: { reviewed?: boolean } = {}): Promise<Kit> {
  const ledger = new Ledger();
  const root = await fakeRepo(ledger, opts);
  const secrets = await Deno.makeTempDir({ prefix: "ct11a-secrets-" });
  return { ledger, root, secrets, deployments: `${root}deployments`, env: {}, outputs: [], ttlSkip: [] };
}

async function cleanup(k: Kit) {
  await Deno.remove(k.root, { recursive: true });
  await Deno.remove(k.secrets, { recursive: true });
}

function ownerCtx(k: Kit, tty: { terminal?: boolean; answer?: string } = {}): OwnerCtx & { io: ReturnType<typeof recordingIo> } {
  const io = recordingIo();
  return {
    io,
    env: (n) => k.env[n],
    secretsDir: k.secrets,
    root: k.root,
    deploymentsDir: k.deployments,
    chain: k.ledger,
    isTerminal: () => tty.terminal ?? false,
    ask: () => Promise.resolve(tty.answer ?? null),
  };
}

async function owner(k: Kit, args: string[], tty: { terminal?: boolean; answer?: string } = {}) {
  const ctx = ownerCtx(k, tty);
  const code = await ownerMain(args, ctx);
  const out = [...ctx.io.stdout, ...ctx.io.stderr].join("\n");
  k.outputs.push(out);
  return { code, out };
}

const keptAlive: { contracts: string[]; hashes: string[]; payer: string }[] = [];

async function deploy(k: Kit, args: string[]) {
  const io = recordingIo();
  const ctx: DeployCtx = {
    io,
    env: (n) => k.env[n],
    secretsDir: k.secrets,
    root: k.root,
    deploymentsDir: k.deployments,
    chain: k.ledger,
    keepAlive: (contracts, hashes, payer) => {
      keptAlive.push({ contracts, hashes, payer: payer.publicKey() });
      // Like ttl.ts keepAlive: it reports every entry as extended, whether or not each batch applied.
      k.ledger.ledger += 2;
      k.ledger.extendTtl(contracts, hashes, k.ttlSkip);
      return Promise.resolve({ extended: contracts.length + hashes.length, fee: "123456" });
    },
    now: () => new Date("2026-10-15T00:00:00Z"),
  };
  const code = await deployMain(args, ctx);
  const out = [...io.stdout, ...io.stderr].join("\n");
  k.outputs.push(out);
  return { code, out };
}

async function admin(k: Kit, args: string[]) {
  const io = recordingIo();
  const code = await adminMain(args, { io, env: (n) => k.env[n], secretsDir: k.secrets, root: k.root, deploymentsDir: k.deployments, chain: k.ledger, now: () => new Date("2026-10-15T00:00:00Z") });
  const out = [...io.stdout, ...io.stderr].join("\n");
  k.outputs.push(out);
  return { code, out };
}

/** Every secret this kit's files hold. */
async function secretsOf(k: Kit): Promise<string[]> {
  const out: string[] = [];
  for (const f of [KEYS_FILE, QA_KEYS_FILE, "testnet-functions.env", "testnet-deployer.env"]) {
    const t = await Deno.readTextFile(`${k.secrets}/${f}`).catch(() => "");
    for (const m of t.matchAll(/=(S[A-Z2-7]{55})/g)) out.push(m[1]);
  }
  return [...out, ...Object.values(k.env).filter((v) => SEED.test(v))];
}

/** No output of this kit carries a secret: none of its seeds, nothing shaped like one. The outputs are what the
 *  scripts wrote before the console's redaction (recordingIo), so a leak fails here even though the console would mask
 *  it. Nor does any output carry a control character other than a newline. */
async function assertNoSecrets(k: Kit) {
  const secrets = await secretsOf(k);
  assert(k.outputs.length > 0, "nothing was recorded");
  for (const out of k.outputs) assertClean(out, secrets);
}

function assertClean(out: string, secrets: string[]) {
  assertFalse(SEED.test(out), "an output holds something shaped like a secret seed");
  for (const s of secrets) assertFalse(out.includes(s), "an output holds a secret");
  assertFalse(/[\x00-\x09\x0b-\x1f\x7f-\x9f]/.test(out), "an output holds a control character");
}

const rolesOf = async (k: Kit): Promise<Record<string, string>> =>
  Object.fromEntries((await Deno.readTextFile(`${k.secrets}/${ROLES_FILE}`)).split("\n").filter((l) => /^[A-Z_]+=G/.test(l)).map((l) => l.split("=") as [string, string]));

// ------------------------------------------------------------------------------------------------ owner-v2 keys

Deno.test("keys: generates exactly the missing keys, funds new accounts, writes the keys file with mode 600, prints no seed", async () => {
  const k = await kit();
  try {
    const first = await owner(k, ["keys"]);
    assertEquals(first.code, 0, first.out);
    const roles = await rolesOf(k);
    assertEquals(Object.keys(roles).length, 6);
    assertEquals(roles.GOVERNANCE_PUBLIC, roles.ADMIN_PUBLIC);
    assertEquals(roles.MOMENTS_GUARDIAN_PUBLIC, roles.LAUNCHPAD_GUARDIAN_PUBLIC);
    assertEquals(roles.PLATFORM_PUBLIC, roles.TREASURY_PUBLIC);
    assertEquals(new Set(Object.values(roles)).size, 3);
    const keysPath = `${k.secrets}/${KEYS_FILE}`;
    assertEquals((await Deno.stat(keysPath)).mode! & 0o777, 0o600);
    const keysText = await Deno.readTextFile(keysPath);
    assertEquals([...keysText.matchAll(/^(\w+)=S/gm)].map((m) => m[1]), ["ADMIN_SECRET", "GUARDIAN_SECRET", "TREASURY_SECRET"]);
    assertEquals(k.ledger.log.filter((l) => l.startsWith("friendbot")).length, 3);
    for (const id of Object.values(roles)) assert(k.ledger.accounts.has(id));
    assertStringIncludes(first.out, "password manager");
    assertStringIncludes(first.out, keysPath);
    assertStringIncludes(first.out, `${k.secrets}/${ROLES_FILE}`);

    // A second run changes nothing, makes nothing and funds nothing.
    const before = [await Deno.readTextFile(`${k.secrets}/${ROLES_FILE}`), keysText];
    const again = await owner(k, ["keys"]);
    assertEquals(again.code, 0, again.out);
    assertEquals([await Deno.readTextFile(`${k.secrets}/${ROLES_FILE}`), await Deno.readTextFile(keysPath)], before);
    assertEquals(k.ledger.log.filter((l) => l.startsWith("friendbot")).length, 3);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("keys: keeps the roles the owner filled in, makes no key for them and never overwrites a secret", async () => {
  const k = await kit();
  try {
    const mine = Keypair.random();
    const platform = Keypair.random();
    await Deno.writeTextFile(`${k.secrets}/${ROLES_FILE}`, `# mine\nADMIN_PUBLIC=${mine.publicKey()}\nGOVERNANCE_PUBLIC=\nPLATFORM_PUBLIC=${platform.publicKey()}\n`);
    const r = await owner(k, ["keys"]);
    assertEquals(r.code, 0, r.out);
    const roles = await rolesOf(k);
    assertEquals([roles.ADMIN_PUBLIC, roles.GOVERNANCE_PUBLIC, roles.PLATFORM_PUBLIC], [mine.publicKey(), mine.publicKey(), platform.publicKey()]);
    const keys = await Deno.readTextFile(`${k.secrets}/${KEYS_FILE}`);
    assertEquals([...keys.matchAll(/^(\w+)=S/gm)].map((m) => m[1]), ["GUARDIAN_SECRET", "TREASURY_SECRET"]);
    assertStringIncludes(await Deno.readTextFile(`${k.secrets}/${ROLES_FILE}`), "# mine\n");
    assertStringIncludes(r.out, "(yours, kept)");
    // The owner's accounts that don't exist yet are funded too.
    assert(k.ledger.accounts.has(mine.publicKey()) && k.ledger.accounts.has(platform.publicKey()));

    // A keys file with a wider mode is refused, and nothing is written.
    await Deno.chmod(`${k.secrets}/${KEYS_FILE}`, 0o644);
    const wide = await owner(k, ["keys"]);
    assertEquals(wide.code, 1);
    assertStringIncludes(wide.out, "mode 644");
    assertEquals(await Deno.readTextFile(`${k.secrets}/${KEYS_FILE}`), keys);
    await Deno.chmod(`${k.secrets}/${KEYS_FILE}`, 0o600);

    // A role in the environment is refused before anything happens.
    k.env.ADMIN_PUBLIC = mine.publicKey();
    const env = await owner(k, ["keys"]);
    assertEquals(env.code, 1);
    assertStringIncludes(env.out, "ADMIN_PUBLIC is set in the environment");
    delete k.env.ADMIN_PUBLIC;
    // A seed in the roles file is refused by line number.
    await Deno.writeTextFile(`${k.secrets}/${ROLES_FILE}`, `ADMIN_PUBLIC=${mine.publicKey()}\nTREASURY_PUBLIC=${mine.secret()}\n`);
    const seeded = await owner(k, ["keys"]);
    assertEquals(seeded.code, 1);
    assertStringIncludes(seeded.out, "line 2: holds a secret seed");
    k.env.SPARE = mine.secret(); // so assertNoSecrets looks for it too
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

// ------------------------------------------------------------------------------------------------ owner-v2 trust and check

Deno.test("trust: the treasury and the platform trust USDC once, already-trusting accounts are skipped, hashes are printed", async () => {
  const k = await kit();
  try {
    const platform = Keypair.random();
    await Deno.writeTextFile(`${k.secrets}/${ROLES_FILE}`, `PLATFORM_PUBLIC=${platform.publicKey()}\n`);
    assertEquals((await owner(k, ["keys"])).code, 0);
    const roles = await rolesOf(k);
    // The platform is the owner's own account: its key comes from the environment.
    const missing = await owner(k, ["trust"]);
    assertEquals(missing.code, 1);
    assertStringIncludes(missing.out, "set PLATFORM_SECRET");
    k.env.PLATFORM_SECRET = platform.secret();
    const r = await owner(k, ["trust"]);
    assertEquals(r.code, 0, r.out);
    assertEquals(k.ledger.log.filter((l) => l.startsWith("changeTrust USDC")), [`changeTrust USDC by ${roles.TREASURY_PUBLIC}`, `changeTrust USDC by ${platform.publicKey()}`]);
    assertMatch(r.out, /now trusts USDC: transaction [0-9a-f]{64}/);
    const again = await owner(k, ["trust"]);
    assertEquals(again.code, 0);
    assertEquals((again.out.match(/already trusts USDC/g) ?? []).length, 2);
    assertEquals(k.ledger.log.filter((l) => l.startsWith("changeTrust")).length, 2);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("check: one line per check; exit 0 only when everything the deploy needs passes", async () => {
  const k = await kit({ reviewed: false });
  try {
    assertEquals((await owner(k, ["keys"])).code, 0);
    const before = await owner(k, ["check"]);
    assertEquals(before.code, 1, "the treasury doesn't trust USDC yet");
    assertStringIncludes(before.out, "✗ treasury trusts USDC");
    assertEquals((await owner(k, ["trust"])).code, 0);
    const keeper = Keypair.random();
    await Deno.writeTextFile(`${k.secrets}/testnet-functions.env`, `LITE_NETWORK=testnet\nSPONSOR_SECRET=${Keypair.random().secret()}\nKEEPER_SECRET=${keeper.secret()}\n`);
    k.ledger.fund(keeper.publicKey(), 250n * XLM);
    const ok = await owner(k, ["check"]);
    assertEquals(ok.code, 0, ok.out);
    for (
      const line of [
        "✓ roles file",
        "✓ keys file mode is 600",
        "✓ deploy key is ADMIN_PUBLIC's",
        "✓ treasury trusts USDC",
        "✓ deployer holds at least 1,000 XLM",
        "✓ Aquarius router WASM hash matches fixtures.json",
        "✓ Aquarius ConstantPoolHash matches fixtures.json",
        "✓ Aquarius TokenHash matches fixtures.json",
        `✓ keeper key: ${keeper.publicKey()}, 250 XLM`,
        "✗ reviewed WASMs",
        "(reported only)",
      ]
    ) assertStringIncludes(ok.out, line);
    // 2,500 XLM with --fund-aqua-float: still fine with Friendbot's 10,000.
    assertEquals((await owner(k, ["check", "--fund-aqua-float"])).code, 0);
    // A deploy key that isn't the admin's is a failure.
    k.env.DEPLOYER_SECRET = Keypair.random().secret();
    const wrong = await owner(k, ["check"]);
    assertEquals(wrong.code, 1);
    assertStringIncludes(wrong.out, "✗ deploy key is ADMIN_PUBLIC's");
    delete k.env.DEPLOYER_SECRET;
    // A changed Aquarius router stops the deploy unless --aquarius off.
    k.ledger.contracts.get(AQ.router.contract_id)!.storage![1].val = xdr.ScVal.scvBytes(Buffer.alloc(32));
    assertEquals((await owner(k, ["check"])).code, 1);
    assertEquals((await owner(k, ["check", "--aquarius", "off"])).code, 0);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

// ------------------------------------------------------------------------------------------------ deploy-contracts-v2

async function readyOwner(k: Kit) {
  assertEquals((await owner(k, ["keys"])).code, 0);
  assertEquals((await owner(k, ["trust"])).code, 0);
}

Deno.test("deploy --dry-run: the plan, read-only checks and nothing sent", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    const sent = k.ledger.log.length;
    const r = await deploy(k, ["--deployment", "testnet", "--dry-run"]);
    assertEquals(r.code, 0, r.out);
    for (
      const s of [
        "DRY RUN: nothing is sent",
        "launch fee            10 XLM (100,000,000 stroops)",
        "XLM quote             phantom 2,000 XLM → threshold 4,324.55532 XLM",
        "USDC quote            phantom 20 USDC → threshold 43.2455532 USDC",
        "Moments threshold     10 USDC",
        "salt sha256(\"dyorhq/v2/testnet/g1/launchpad-v2\")",
        "✓ every WASM matches the reviewed list",
        "✓ dyor_launchpad_v2.wasm: __constructor(admin: Address, guardian: Option<Address>",
        "to deploy  launchpad-v2",
        "✓ treasury trusts USDC",
        "A real deploy would go ahead.",
        "Dry run: nothing was sent and no file was written.",
      ]
    ) assertStringIncludes(r.out, s);
    assertEquals(k.ledger.log.slice(sent).filter((l) => !l.startsWith("view")), []);
    assertEquals([...Deno.readDirSync(k.deployments)].length, 0);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("deploy: the owner's testnet end to end, then an idempotent re-run, then a refused conflicting re-run", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    keptAlive.length = 0;
    const startLedger = k.ledger.ledger;
    const r = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(r.code, 0, r.out);
    const log = k.ledger.log.filter((l) => !l.startsWith("view") && l !== "prepare" && !l.startsWith("friendbot") && !l.startsWith("changeTrust"));
    assertEquals(log.filter((l) => l.startsWith("upload")).length, 9, "nine WASMs (no qa-exec-fail on testnet)");
    assertEquals(log.filter((l) => l.startsWith("create")), [
      "create exec-soroswap",
      "create exec-aquarius",
      "create lp-locker",
      "create moments-graduator",
      "create launchpad-v2",
      "create moments-v2",
    ]);
    // The constructor set the launch fee, the fees and the venues; the admin adds the two quotes.
    assertEquals(log.filter((l) => l.startsWith("invoke")), ["invoke launchpad-v2.set_quote", "invoke launchpad-v2.set_quote"]);
    assertEquals(keptAlive.length, 1);
    assertEquals([keptAlive[0].contracts.length, keptAlive[0].hashes.length], [6, 9]);
    const roles = await rolesOf(k);
    assertEquals(keptAlive[0].payer, roles.ADMIN_PUBLIC, "the deployer (the admin) pays the TTL");
    assertStringIncludes(r.out, "AQUA float 0 of a 50 target: fund exec-aquarius");
    assertStringIncludes(r.out, "Do NOT run the v1 cutover");
    assertStringIncludes(r.out, `Wrote ${k.deployments}/testnet-v2.json`);

    const file = JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-v2.json`));
    assertEquals(Object.keys(file.contracts).sort(), ["execAquarius", "execSoroswap", "launchpadV2", "lpLocker", "momentsGraduator", "momentsV2"]);
    assertEquals(file.venues.map((v: any) => [v.id, v.kind, v.enabled]), [[0, "Soroswap", true], [1, "Aquarius", true]]);
    assertEquals(file.venues[1].executor, file.contracts.execAquarius);
    assertEquals(file.aquarius, { enabled: true, reason: null, router: AQ.router.contract_id, target: "500000000" });
    assertEquals(file.roles.treasury, roles.TREASURY_PUBLIC);
    assertEquals(file.quotes.USDC.fallback_venue, 0);
    assertEquals([file.generation, file.deployLedger, file.durations.set], [1, startLedger, "production"]);
    assertEquals(Object.keys(file.wasmHashes).length, 9);
    assertFalse(SEED.test(JSON.stringify(file)), "the deployment file holds no key");

    // Run it again: everything is there and matches, so nothing is sent.
    const before = k.ledger.log.length;
    const again = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(again.code, 0, again.out);
    const sentAgain = k.ledger.log.slice(before).filter((l) => !l.startsWith("view"));
    assertEquals(sentAgain, []);
    assertEquals((again.out.match(/already deployed with the planned configuration, skipped/g) ?? []).length, 6);
    assertStringIncludes(again.out, "launchpad-v2 already has the planned fees, venues and quotes");
    assertEquals(JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-v2.json`)).deployLedger, startLedger, "a re-run keeps the first ledger");

    // A changed role is a conflict with what is deployed: refused, nothing sent.
    const rolesText = await Deno.readTextFile(`${k.secrets}/${ROLES_FILE}`);
    const otherTreasury = Keypair.random().publicKey();
    k.ledger.fund(otherTreasury, 10n * XLM);
    k.ledger.accounts.get(otherTreasury)!.trustlines.push({ asset: USDC_CLASSIC, balance: 0n, authorized: true });
    await Deno.writeTextFile(`${k.secrets}/${ROLES_FILE}`, rolesText.replace(`TREASURY_PUBLIC=${roles.TREASURY_PUBLIC}`, `TREASURY_PUBLIC=${otherTreasury}`));
    const mark = k.ledger.log.length;
    // With --fund-aqua-float too: the conflict is found before anything is sent, so no XLM is swapped either.
    const conflict = await deploy(k, ["--deployment", "testnet", "--fund-aqua-float"]);
    assertEquals(conflict.code, 1);
    assertStringIncludes(conflict.out, "launchpad-v2 config().treasury is");
    assertStringIncludes(conflict.out, "nothing was sent");
    assertEquals(k.ledger.log.slice(mark).filter((l) => !l.startsWith("view")), []);

    // A new generation is a fresh set of contracts.
    await Deno.writeTextFile(`${k.secrets}/${ROLES_FILE}`, rolesText);
    const g2 = await deploy(k, ["--deployment", "testnet", "--generation", "2", "--dry-run"]);
    assertStringIncludes(g2.out, "dyorhq/v2/testnet/g2/launchpad-v2");
    assertStringIncludes(g2.out, "to deploy  launchpad-v2");
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("deploy: refused before anything is sent without the reviewed list, with a drifted constructor or a wrong deploy key", async () => {
  const k = await kit({ reviewed: false });
  try {
    await readyOwner(k);
    const mark = k.ledger.log.length;
    const noList = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(noList.code, 1);
    assertStringIncludes(noList.out, "missing: a real deploy stops here");
    assertStringIncludes(noList.out, "reviewed-hash check failed; nothing was sent");
    // A launchpad WASM whose constructor lacks launch_fee: the guard refuses it.
    const params = paramsByWasm().get("launchpad-v2")!.filter((p) => p.name !== "launch_fee");
    const drifted = wasmWithSections([["contractspecv0", Uint8Array.from(Buffer.concat(specEntries("__constructor", params).map((e) => e.toXDR())))]]);
    await Deno.writeFile(`${k.root}contracts/dist/dyor_launchpad_v2.wasm`, drifted);
    const lines: string[] = [];
    for (const key of Object.keys(WASMS) as WasmKey[]) lines.push(`${await sha256Hex(await Deno.readFile(`${k.root}contracts/dist/${WASMS[key].file}`))}  dist/${WASMS[key].file}`);
    await Deno.writeTextFile(`${k.root}contracts/review/reviewed-wasm.sha256`, lines.join("\n") + "\n");
    const guard = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(guard.code, 1);
    assertStringIncludes(guard.out, "✗ dyor_launchpad_v2.wasm: differs from the builder");
    assertStringIncludes(guard.out, "parameter 9 is named venues in the WASM, launch_fee in the builder");
    k.env.DEPLOYER_SECRET = Keypair.random().secret();
    const key = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(key.code, 1);
    assertStringIncludes(key.out, "not ADMIN_PUBLIC");
    assertEquals(k.ledger.log.slice(mark).filter((l) => !l.startsWith("view")), []);
    for (const d of ["mainnet", "testnet-v2"]) assertEquals((await deploy(k, ["--deployment", d, "--dry-run"])).code, 1);
    k.env.SMOKE = "1";
    delete k.env.DEPLOYER_SECRET;
    assertStringIncludes((await deploy(k, ["--deployment", "testnet", "--dry-run"])).out, "SMOKE=1 is refused for testnet");
    delete k.env.SMOKE;
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("deploy: testnet-qa with a deep XLM–AQUA pool acquires and sends the float; a thin pool deploys without Aquarius", async () => {
  for (const deep of [true, false]) {
    const k = await kit();
    try {
      // Thin: 1 XLM buys about 6.6 AQUA, and the 11 AQUA testnet-qa needs (10 × the payment, plus 10%) would move the
      // price far more than 3%.
      if (!deep) k.ledger.pool = { xlm: 2n * XLM, aqua: 20n * XLM };
      const r = await deploy(k, ["--deployment", "testnet-qa"]);
      assertEquals(r.code, 0, r.out);
      assertEquals((await Deno.stat(`${k.secrets}/${QA_KEYS_FILE}`)).mode! & 0o777, 0o600);
      const file = JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-qa-v2.json`));
      assert(file.contracts.qaExecFail && file.contracts.momentsV2QaFail && file.contracts.momentsGraduatorQaFail);
      assertEquals(file.durations.set, "testnet-qa");
      assertEquals(file.qaAsset.code, "DYORQA");
      const qaQuote = file.quotes.QA;
      const qaVenue = file.venues.find((v: any) => v.kind === "QaFail");
      assertEquals(qaQuote.venues_allowed, [qaVenue.id], "venues_allowed is the qa-exec-fail id read back (F8)");
      assertEquals(qaQuote.fallback_venue, file.venues.find((v: any) => v.kind === "Soroswap").id);
      if (deep) {
        assertEquals(file.aquarius.enabled, true);
        assert(k.ledger.log.includes("invoke router.swap"));
        const float = k.ledger.held.get(AQ.aqua.sac)!.get(file.contracts.execAquarius)!;
        assert(float >= 10n * XLM, `float ${float}`);
        assertStringIncludes(r.out, "AQUA float");
        assertStringIncludes(r.out, "✓");
        assertEquals(qaVenue.id, 2);
      } else {
        assertEquals(file.aquarius.enabled, false);
        assertStringIncludes(file.aquarius.reason, "too thin");
        assertEquals(file.contracts.execAquarius, undefined);
        assertFalse(file.venues.some((v: any) => v.kind === "Aquarius"));
        assertFalse(k.ledger.log.includes("invoke router.swap"));
        assertEquals(qaVenue.id, 1, "without Aquarius the qa-exec-fail venue takes the next id");
        assertStringIncludes(r.out, "testnet-qa goes on without exec-aquarius and the Aquarius venue");
      }
      // The QA treasury trusts USDC and the QA asset (F9).
      const treasury = file.roles.treasury;
      assertEquals(k.ledger.accounts.get(treasury)!.trustlines.map((t) => t.asset.split(":")[0]).sort(), ["DYORQA", "USDC"]);
      await assertNoSecrets(k);
    } finally {
      await cleanup(k);
    }
  }
});

// ------------------------------------------------------------------------------------------------ admin-v2 and sign

function v1Contracts(l: Ledger, platformBps = 250, royaltyBps = 300) {
  const admin = (s: string | null) => {
    if (s !== V1.admin) throw new Error("Error(Auth, InvalidAction)");
  };
  const pad = { admin: V1.admin, treasury: V1.treasury, launches_enabled: true, fee_bps: 100 };
  const mom = { admin: V1.admin, treasury: V1.treasury, platform_bps: platformBps, royalty_bps: royaltyBps, publishing_enabled: true };
  l.addContract(V1.launchpad, { kind: "v1-launchpad", wasm: V1.launchpadWasmHash, fns: { config: () => pad, set_launches_enabled: (a, s) => (admin(s), pad.launches_enabled = Boolean(a[0])) } });
  l.addContract(V1.moments, {
    kind: "v1-moments",
    wasm: V1.momentsWasmHash,
    fns: {
      config: () => mom,
      set_policy: (a, s) => {
        admin(s);
        [mom.platform_bps, mom.royalty_bps, mom.publishing_enabled] = [Number(a[0]), Number(a[1]), Boolean(a[2])];
      },
    },
  });
  l.fund(V1.admin, 9_000n * XLM);
  return { pad, mom };
}

async function copyV1(k: Kit) {
  await Deno.copyFile(`${repo}backend/supabase/functions/_shared/deployments/testnet.json`, `${k.deployments}/testnet.json`);
}

Deno.test("admin-v2 cutover-v1: reads config() first, writes two prepared unsigned envelopes; sign --decode-only shows the calls", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    const out = `${k.root}cutover`;
    const r = await admin(k, ["cutover-v1", "--out-dir", out]);
    assertEquals(r.code, 0, r.out);
    // config() of both contracts was read before the first envelope was prepared.
    const log = k.ledger.log.filter((l) => l.startsWith("view") || l === "prepare");
    assertEquals(log.slice(0, 3), ["view v1-launchpad.config", "view v1-moments.config", "prepare"]);
    const files = [...Deno.readDirSync(out)].map((e) => e.name).sort();
    assertEquals(files, ["1-v1-launchpad-set_launches_enabled.json", "2-v1-moments-set_policy.json"]);
    const seqs: bigint[] = [];
    for (const f of files) {
      const env = JSON.parse(await Deno.readTextFile(`${out}/${f}`));
      const tx = TransactionBuilder.fromXDR(env.xdr, PASSPHRASE) as Transaction;
      assertEquals(tx.signatures.length, 0, "unsigned");
      assertEquals(tx.source, V1.admin);
      assert(tx.toEnvelope().v1().tx().ext().switch() === 1, "prepared: it carries Soroban data");
      seqs.push(BigInt(tx.sequence));
    }
    assertEquals(seqs[1], seqs[0] + 1n, "the second envelope takes the next sequence number");

    const pad = await owner(k, ["sign", `${out}/${files[0]}`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(pad.code, 0, pad.out);
    assertStringIncludes(pad.out, `contract ${V1.launchpad} (v1 launchpad)`);
    assertStringIncludes(pad.out, "call     set_launches_enabled(false)");
    const mom = await owner(k, ["sign", `${out}/${files[1]}`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(mom.code, 0, mom.out);
    assertStringIncludes(mom.out, `contract ${V1.moments} (v1 Moments)`);
    assertStringIncludes(mom.out, "call     set_policy(250, 300, false)", "the values come from config()");
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("admin-v2 refuses a 2-signer source account where one signer meets the medium threshold", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    const a = k.ledger.accounts.get(V1.admin)!;
    a.signers = [{ key: V1.admin, weight: 1 }, { key: Keypair.random().publicKey(), weight: 1 }];
    a.thresholds = { low: 1, med: 1, high: 2 };
    const r = await admin(k, ["cutover-v1", "--out-dir", `${k.root}cutover`]);
    assertEquals(r.code, 1);
    assertStringIncludes(r.out, "meets the medium threshold 1 alone");
    a.thresholds = { low: 1, med: 2, high: 2 };
    assertEquals((await admin(k, ["cutover-v1", "--out-dir", `${k.root}cutover`])).code, 0);
  } finally {
    await cleanup(k);
  }
});

Deno.test("sign: refuses another network, another source and a missing TTY; signs and submits after a yes", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    assertEquals((await deploy(k, ["--deployment", "testnet"])).code, 0);
    const roles = await rolesOf(k);
    const newTreasury = Keypair.random().publicKey();
    const file = `${k.root}treasury.json`;
    const built = await admin(k, ["treasury-propose", "--to", newTreasury, "--out", file]);
    assertEquals(built.code, 0, built.out);
    assertStringIncludes(built.out, `owner-v2.ts sign ${file} --as admin`);

    // Another network's envelope.
    const env = JSON.parse(await Deno.readTextFile(file));
    await Deno.writeTextFile(`${k.root}mainnet.json`, JSON.stringify({ ...env, networkPassphrase: "Public Global Stellar Network ; September 2015" }));
    const net = await owner(k, ["sign", `${k.root}mainnet.json`, "--as", "admin", "--decode-only"]);
    assertEquals(net.code, 1);
    assertStringIncludes(net.out, "not testnet");
    // The admin's envelope offered to the guardian's key.
    const src = await owner(k, ["sign", file, "--as", "guardian"]);
    assertEquals(src.code, 1);
    assertStringIncludes(src.out, `the envelope's source is ${roles.ADMIN_PUBLIC}, not the guardian key's address`);
    // No terminal: refused before any prompt.
    const notty = await owner(k, ["sign", file, "--as", "admin"]);
    assertEquals(notty.code, 1);
    assertStringIncludes(notty.out, "there is no TTY");
    assertStringIncludes(notty.out, "call     propose_treasury(" + newTreasury + ")");
    // A terminal and a no: nothing sent.
    const before = k.ledger.log.length;
    const no = await owner(k, ["sign", file, "--as", "admin"], { terminal: true, answer: "n" });
    assertEquals(no.code, 1);
    assertStringIncludes(no.out, "Not signed. Nothing was sent.");
    assertEquals(k.ledger.log.slice(before).filter((l) => l.startsWith("invoke")), []);
    // A yes: signed with the keys file's ADMIN_SECRET and submitted.
    const yes = await owner(k, ["sign", file, "--as", "admin"], { terminal: true, answer: "y" });
    assertEquals(yes.code, 0, yes.out);
    assertMatch(yes.out, /✓ submitted: transaction [0-9a-f]{64}/);
    assertEquals(k.ledger.log.filter((l) => l === "invoke launchpad-v2.propose_treasury").length, 1);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

// ------------------------------------------------------------------------------------------------ sign: only what admin-v2 writes

const ATTACKER = Keypair.fromRawEd25519Seed(Buffer.alloc(32, 7)).publicKey();

interface Craft {
  /** Operations instead of the one contract call. */
  ops?: xdr.Operation[];
  call?: { contract: string; fn: string; args: xdr.ScVal[] };
  /** Auth entries of the call; its own source-account entry by default. */
  auth?: xdr.SorobanAuthorizationEntry[];
  opSource?: string;
  memo?: Memo;
  /** null: no time bound at all (an envelope that never expires). */
  timebounds?: { minTime: number; maxTime: number } | null;
  ledgerbounds?: { minLedger: number; maxLedger: number };
  /** Soroban data (a prepared envelope); on by default for the contract call. */
  soroban?: boolean;
  fee?: string;
  signWith?: Keypair;
  feeBump?: boolean;
  source?: string;
  meta?: Record<string, string>;
}

const callArgs = (c: { contract: string; fn: string; args: xdr.ScVal[] }) =>
  new xdr.InvokeContractArgs({ contractAddress: new Address(c.contract).toScAddress(), functionName: c.fn, args: c.args });

/** An envelope file in admin-v2.ts's format around a transaction built offline to the test's recipe. */
function craft(c: Craft = {}): string {
  const source = c.source ?? V1.admin;
  const call = c.call ?? { contract: V1.launchpad, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] };
  const opts: Record<string, unknown> = { fee: c.fee ?? "100", networkPassphrase: PASSPHRASE };
  if (c.memo) opts.memo = c.memo;
  if (c.ledgerbounds) opts.ledgerbounds = c.ledgerbounds;
  if (c.timebounds !== null) opts.timebounds = c.timebounds ?? { minTime: 0, maxTime: Math.floor(Date.now() / 1000) + 1_800 };
  const b = new TransactionBuilder(new Account(source, "22204675977641999"), opts as never);
  if (c.timebounds === null) b.setTimeout(0);
  const ops = c.ops ?? [
    Operation.invokeHostFunction({
      func: xdr.HostFunction.hostFunctionTypeInvokeContract(callArgs(call)),
      auth: c.auth ?? [sourceAuth(callArgs(call))],
      ...(c.opSource ? { source: c.opSource } : {}),
    }),
  ];
  for (const o of ops) b.addOperation(o);
  if (c.soroban ?? !c.ops) b.setSorobanData(new SorobanDataBuilder().setResourceFee(50_000).build());
  const tx = b.build();
  if (c.signWith) tx.sign(c.signWith);
  const env = c.feeBump ? TransactionBuilder.buildFeeBumpTransaction(source, "1000", tx, PASSPHRASE) : tx;
  return JSON.stringify({
    format: "dyorhq-unsigned-envelope/1",
    networkPassphrase: PASSPHRASE,
    role: "v1-admin",
    source,
    contract: call.contract,
    function: call.fn,
    description: "v1 cutover 1 of 2: v1 launchpad set_launches_enabled(false)",
    builtAt: "2026-10-15T00:00:00.000Z",
    ...c.meta,
    xdr: env.toEnvelope().toXDR("base64"),
  });
}

const transferAll = (to: string) =>
  new xdr.SorobanAuthorizedInvocation({
    function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(
      callArgs({ contract: XLM_SAC, fn: "transfer", args: [new Address(V1.admin).toScVal(), new Address(to).toScVal(), nativeToScVal(90_000_000_000n, { type: "i128" })] }),
    ),
    subInvocations: [],
  });

Deno.test("sign refuses every envelope admin-v2.ts never writes, before any prompt (the review's crafted envelopes and each rule)", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    const launchpadCall = { contract: V1.launchpad, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] };
    const cases: [string, string, string][] = [
      // craft.ts 1: several classic operations, one adding a signer that takes the account over, one paying out.
      [
        "classic",
        craft({
          ops: [
            Operation.setOptions({ signer: { ed25519PublicKey: ATTACKER, weight: 255 }, masterWeight: 0 }),
            Operation.payment({ destination: ATTACKER, asset: Asset.native(), amount: "9000" }),
            Operation.manageData({ name: "x", value: "y" }),
          ],
        }),
        "refused: 3 operations; admin-v2.ts writes exactly one contract call",
      ],
      // craft.ts 3 without its text: one classic payment.
      ["payment", craft({ ops: [Operation.payment({ destination: ATTACKER, asset: Asset.native(), amount: "9000" })] }), "refused: the operation is payment, not a contract call"],
      // craft.ts 2: a call to a contract that isn't DyorHQ's, whose auth root is a 9,000 XLM transfer.
      [
        "unknown contract",
        craft({ call: { contract: AQ.router.contract_id, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] }, auth: [new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: transferAll(ATTACKER) })] }),
        `refused: the call goes to ${AQ.router.contract_id}, which is none of DyorHQ's contracts`,
      ],
      // The same auth root on the real v1 launchpad call: the label says set_launches_enabled, the signature pays out.
      [
        "auth root",
        craft({ auth: [new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: transferAll(ATTACKER) })] }),
        `refused: auth entry 1 authorizes ${XLM_SAC} (XLM SAC) transfer(${V1.admin}, ${ATTACKER}, 90000000000), not the call set_launches_enabled itself`,
      ],
      [
        "address credentials",
        craft({
          auth: [
            new xdr.SorobanAuthorizationEntry({
              credentials: xdr.SorobanCredentials.sorobanCredentialsAddress(
                new xdr.SorobanAddressCredentials({ address: new Address(ATTACKER).toScAddress(), nonce: xdr.Int64.fromString("1"), signatureExpirationLedger: 1, signature: xdr.ScVal.scvVoid() }),
              ),
              rootInvocation: new xdr.SorobanAuthorizedInvocation({
                function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(callArgs(launchpadCall)),
                subInvocations: [],
              }),
            }),
          ],
        }),
        "refused: auth entry 1 needs another account's signature",
      ],
      ["operation source", craft({ opSource: ATTACKER }), "refused: the operation has its own source account"],
      ["memo", craft({ memo: Memo.text("pay me") }), "refused: the transaction has a memo"],
      ["ledger bounds", craft({ ledgerbounds: { minLedger: 0, maxLedger: 9_999_999 } }), "refused: the transaction has preconditions beyond a time bound"],
      ["no expiry", craft({ timebounds: null }), "refused: the transaction never expires"],
      ["start time", craft({ timebounds: { minTime: 1_000, maxTime: Math.floor(Date.now() / 1000) + 600 } }), "refused: the transaction has a start time"],
      ["signed", craft({ signWith: Keypair.random() }), "refused: the envelope already carries 1 signature(s)"],
      [
        "metadata",
        craft({ call: { contract: V1.moments, fn: "set_policy", args: [nativeToScVal(0, { type: "u32" }), nativeToScVal(0, { type: "u32" }), xdr.ScVal.scvBool(true)] }, meta: { contract: V1.launchpad, function: "set_launches_enabled" } }),
        "refused: the file says set_launches_enabled on",
      ],
      ["not prepared", craft({ soroban: false }), "refused: the transaction isn't prepared (no Soroban data)"],
      ["fee", craft({ fee: "40000000" }), "refused: the max fee 4.005 XLM is above the 3 XLM cap"],
      // craft2.ts: a fee-bump.
      ["fee bump", craft({ feeBump: true }), "refused: a fee-bump envelope"],
      ["passphrase", JSON.stringify({ ...JSON.parse(craft()), networkPassphrase: "Public Global Stellar Network ; September 2015" }), "not testnet"],
      ["upload", craft({ ops: [Operation.uploadContractWasm({ wasm: Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]) })], soroban: true }), "refused: the operation is hostFunctionTypeUploadContractWasm, not a contract call"],
      [
        "create",
        craft({ ops: [Operation.createCustomContract({ address: new Address(V1.admin), wasmHash: Buffer.alloc(32, 1), salt: Buffer.alloc(32, 2), constructorArgs: [] })], soroban: true }),
        "refused: the operation is hostFunctionTypeCreateContractV2, not a contract call",
      ],
      ["not json", "AAAAAgAAAAA=", "not an envelope file written by admin-v2.ts"],
    ];
    for (const [name, text, reason] of cases) {
      const file = `${k.root}${name.replace(/ /g, "-")}.json`;
      await Deno.writeTextFile(file, text);
      const before = k.ledger.log.length;
      const decode = await owner(k, ["sign", file, "--as", "v1-admin", "--decode-only"]);
      assertEquals(decode.code, 1, `${name}: ${decode.out}`);
      assertStringIncludes(decode.out, reason, name);
      const signing = await owner(k, ["sign", file, "--as", "v1-admin"], { terminal: true, answer: "y" });
      assertEquals(signing.code, 1, name);
      assertStringIncludes(signing.out, reason, name);
      assertFalse(signing.out.includes("Sign and submit"), `${name}: no prompt`);
      assertEquals(k.ledger.log.slice(before).filter((l) => !l.startsWith("view")), [], `${name}: nothing sent`);
    }
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("sign: an expired envelope is shown and refused, with --decode-only too; a good one passes decode-only", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    // craft2.ts 5, prepared: expired in 2023.
    await Deno.writeTextFile(`${k.root}expired.json`, craft({ timebounds: { minTime: 0, maxTime: 1_700_000_000 } }));
    for (const args of [["--decode-only"], []]) {
      const r = await owner(k, ["sign", `${k.root}expired.json`, "--as", "v1-admin", ...args], { terminal: true, answer: "y" });
      assertEquals(r.code, 1);
      assertStringIncludes(r.out, "valid until  2023-11-14T22:13:20.000Z (expired: build it again)");
      assertStringIncludes(r.out, "refused: the envelope has expired");
    }
    await Deno.writeTextFile(`${k.root}good.json`, craft());
    const good = await owner(k, ["sign", `${k.root}good.json`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(good.code, 0, good.out);
    for (
      const s of [
        "  network      testnet ✓",
        `  source       ${V1.admin} (v1-admin) ✓`,
        "  memo         none; no signatures yet",
        "  operation    one contract call, no operation source",
        `      contract ${V1.launchpad} (v1 launchpad)`,
        "      call     set_launches_enabled(false)",
        "      auth 1   the source account authorizes:",
        `              ${V1.launchpad} (v1 launchpad) set_launches_enabled(false)`,
      ]
    ) assertStringIncludes(good.out, s);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("sign escapes every control character from the file and the chain: nothing can fake a line or hide the prompt", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    // craft.ts 3's text, on an otherwise valid envelope: fake lines, then ESC[8m to hide what follows.
    const fake = "v1 cutover 1 of 2\n  source ... (v1-admin) OK\n   1. contract " + V1.launchpad + " (v1 launchpad)\n      call     set_launches_enabled(false)\n\x1b[8m";
    const text = craft({
      call: { contract: V1.launchpad, fn: "set_label\x1b[2J", args: [nativeToScVal("https://x\x1b[8m‮evil", { type: "string" }), xdr.ScVal.scvSymbol("a\x07b")] },
      meta: { description: fake, builtAt: "\x1b]0;title\x07", role: "v1-admin\x1b[2J" },
    });
    await Deno.writeTextFile(`${k.root}escapes.json`, text);
    const r = await owner(k, ["sign", `${k.root}escapes.json`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(r.code, 0, r.out);
    // Shown as text, on the lines where they belong.
    assertStringIncludes(r.out, "  built        \\x1b]0;title\\x07: v1 cutover 1 of 2\\x0a  source ... (v1-admin) OK\\x0a");
    assertStringIncludes(r.out, "\\x1b[8m");
    assertStringIncludes(r.out, "  note: the envelope was built for --as v1-admin\\x1b[2J");
    assertStringIncludes(r.out, `      call     set_label\\x1b[2J("https://x\\x1b[8m\\u{202e}evil", a\\x07b)`);
    // The recorded output (before the console's own escaping) holds no control character at all.
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("sign prints the full invocation tree with decoded arguments", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    const call = { contract: V1.launchpad, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] };
    const create = new xdr.SorobanAuthorizedInvocation({
      function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeCreateContractV2HostFn(
        new xdr.CreateContractArgsV2({
          contractIdPreimage: xdr.ContractIdPreimage.contractIdPreimageFromAddress(
            new xdr.ContractIdPreimageFromAddress({ address: new Address(V1.admin).toScAddress(), salt: Buffer.alloc(32, 2) }),
          ),
          executable: xdr.ContractExecutable.contractExecutableWasm(Buffer.alloc(32, 1)),
          constructorArgs: [new Address(ATTACKER).toScVal(), nativeToScVal(7, { type: "u32" })],
        }),
      ),
      subInvocations: [],
    });
    const sub = new xdr.SorobanAuthorizedInvocation({ function: transferAll(V1.launchpad).function(), subInvocations: [create] });
    await Deno.writeTextFile(`${k.root}tree.json`, craft({ auth: [sourceAuth(callArgs(call), [sub])] }));
    const r = await owner(k, ["sign", `${k.root}tree.json`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(r.code, 0, r.out);
    assertStringIncludes(r.out, `              ${V1.launchpad} (v1 launchpad) set_launches_enabled(false)`);
    assertStringIncludes(r.out, `                ↳ ${XLM_SAC} (XLM SAC) transfer(${V1.admin}, ${V1.launchpad}, 90000000000)`);
    assertStringIncludes(
      r.out,
      `                  ↳ create a contract from WASM ${"01".repeat(32)} by ${V1.admin} with salt ${"02".repeat(32)}(${ATTACKER}, 7)`,
    );
  } finally {
    await cleanup(k);
  }
});

Deno.test("the secret and control-character checks can fail: the recorder sees what a script writes, unredacted", () => {
  const seed = Keypair.random().secret();
  const io = recordingIo();
  io.out(`leaked ${seed}`);
  assertEquals(io.stdout, [`leaked ${seed}`], "the recorder doesn't redact");
  assertThrows(() => assertClean(io.stdout.join("\n"), [seed]), Error, "secret seed");
  assertThrows(() => assertClean("ok\x1b[8m", []), Error, "control character");
  assertClean("line one\nline two ✓", []);
});

// ------------------------------------------------------------------------------------------------ deploy: the review's findings

Deno.test("--aquarius off never asks the router: a router that doesn't answer blocks neither the dry run nor the deploy", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    k.ledger.routerDown = true;
    const dry = await deploy(k, ["--deployment", "testnet", "--dry-run", "--aquarius", "off"]);
    assertEquals(dry.code, 0, dry.out);
    assertStringIncludes(dry.out, "Aquarius router: not asked (the venue is off: --aquarius off)");
    assertStringIncludes(dry.out, "A real deploy would go ahead.");
    const r = await deploy(k, ["--deployment", "testnet", "--aquarius", "off"]);
    assertEquals(r.code, 0, r.out);
    assertEquals(k.ledger.log.filter((l) => l.startsWith("view router.")), [], "the router was never asked");
    const file = JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-v2.json`));
    assertEquals(file.aquarius.enabled, false);
    assertEquals(file.contracts.execAquarius, undefined);
    // With Aquarius on, a router that doesn't answer stops the owner's deploy with a way out.
    const auto = await deploy(k, ["--deployment", "testnet", "--generation", "2"]);
    assertEquals(auto.code, 1);
    assertStringIncludes(auto.out, "the Aquarius router didn't answer");
    assertStringIncludes(auto.out, "--aquarius off");
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("testnet-qa: a router that doesn't answer means no Aquarius venue, and the deploy goes on", async () => {
  const k = await kit();
  try {
    k.ledger.routerDown = true;
    const r = await deploy(k, ["--deployment", "testnet-qa"]);
    assertEquals(r.code, 0, r.out);
    const file = JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-qa-v2.json`));
    assertEquals(file.aquarius.enabled, false);
    assertStringIncludes(file.aquarius.reason, "the Aquarius router didn't answer");
    assertEquals(file.contracts.execAquarius, undefined);
  } finally {
    await cleanup(k);
  }
});

Deno.test("the TTL step is checked: an entry left short fails the run loudly, before the deployment file; a re-run fixes it", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    // One WASM's batch "succeeds" without applying, as a pending or failed keepAlive batch would.
    const launchpadWasm = [...k.ledger.wasmKinds.entries()].find(([, kind]) => kind === "launchpad-v2")![0];
    k.ttlSkip = [launchpadWasm];
    const r = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(r.code, 1);
    assertStringIncludes(r.out, "the TTL step didn't reach 30 days");
    assertMatch(r.out, /dyor_launchpad_v2\.wasm code: live until \d+/);
    assertStringIncludes(r.out, "Run the same command again");
    assertFalse(await Deno.stat(`${k.deployments}/testnet-v2.json`).then(() => true, () => false), "no deployment file yet");
    k.ttlSkip = [];
    const again = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(again.code, 0, again.out);
    assertStringIncludes(again.out, "✓ every instance and WASM lives until ledger");
    assert(await Deno.stat(`${k.deployments}/testnet-v2.json`));
  } finally {
    await cleanup(k);
  }
});

Deno.test("testnet-qa: after a failed AQUA funding the rebuilt plan is checked again, so a dist that changed is refused", async () => {
  const k = await kit();
  try {
    k.ledger.pool = { xlm: 2n * XLM, aqua: 20n * XLM };
    // While the depth check runs, dist/dyor_launchpad_v2.wasm is replaced (its new hash even added to the reviewed list).
    k.ledger.onEstimate = () => {
      k.ledger.onEstimate = null;
      const path = `${k.root}contracts/dist/dyor_launchpad_v2.wasm`;
      const old = Deno.readFileSync(path);
      const swapped = wasmWithSections([["contractspecv0", customSections(old, "contractspecv0")[0]], ["dyorhq-test", new TextEncoder().encode("swapped")]]);
      Deno.writeFileSync(path, swapped);
      const h = Buffer.from(hash(Buffer.from(swapped))).toString("hex");
      const reviewed = `${k.root}contracts/review/reviewed-wasm.sha256`;
      Deno.writeTextFileSync(reviewed, Deno.readTextFileSync(reviewed).replace(/^[0-9a-f]{64}  dist\/dyor_launchpad_v2\.wasm$/m, `${h}  dist/dyor_launchpad_v2.wasm`));
    };
    const r = await deploy(k, ["--deployment", "testnet-qa"]);
    assertEquals(r.code, 1, r.out);
    assertStringIncludes(r.out, "testnet-qa goes on without exec-aquarius");
    // The swapped file passes the reviewed list and the guard on its own: only the comparison with what was checked
    // at the start of the run catches it.
    assertStringIncludes(r.out, "contracts/dist changed during this run (dyor_launchpad_v2.wasm); nothing more was sent");
    assertEquals(k.ledger.log.filter((l) => l.startsWith("upload") || l.startsWith("create ") && !l.startsWith("create SAC")), [], "nothing uploaded or deployed");
  } finally {
    await cleanup(k);
  }
});

Deno.test("re-runs compare the instance storage too: a contract with the planned WASM but another configuration is refused", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    assertEquals((await deploy(k, ["--deployment", "testnet"])).code, 0);
    const file = JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-v2.json`));
    // moments-graduator has no view: its storage is all there is. Give it another executor.
    const grad = k.ledger.contracts.get(file.contracts.momentsGraduator)!;
    const args = scValToNative(grad.storage![0].val) as unknown[];
    const other = [...args];
    other[2] = ATTACKER;
    grad.storage = [{ key: xdr.ScVal.scvSymbol("Args"), val: sv(other) }];
    const mark = k.ledger.log.length;
    const r = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(r.code, 1);
    assertStringIncludes(r.out, `moments-graduator's instance storage doesn't hold executor ${file.contracts.execSoroswap}`);
    assertStringIncludes(r.out, "use a new --generation");
    assertEquals(k.ledger.log.slice(mark).filter((l) => !l.startsWith("view")), [], "nothing sent");
    // exec-aquarius shows only max_pool_payment: its router comes from the storage.
    grad.storage = [{ key: xdr.ScVal.scvSymbol("Args"), val: sv(args) }];
    const exec = k.ledger.contracts.get(file.contracts.execAquarius)!;
    const execArgs = scValToNative(exec.storage![0].val) as unknown[];
    exec.storage = [{ key: xdr.ScVal.scvSymbol("Args"), val: sv([XLM_SAC, ...execArgs.slice(1)]) }];
    const r2 = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(r2.code, 1);
    assertStringIncludes(r2.out, `exec-aquarius's instance storage doesn't hold router ${AQ.router.contract_id}`);
    // And another WASM at the planned id is refused whatever its configuration.
    exec.storage = [{ key: xdr.ScVal.scvSymbol("Args"), val: sv(execArgs) }];
    grad.wasm = "ab".repeat(32);
    const r3 = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(r3.code, 1);
    assertStringIncludes(r3.out, `moments-graduator runs WASM ${"ab".repeat(32)}`);
  } finally {
    await cleanup(k);
  }
});

// ------------------------------------------------------------------------------------------------ as processes, without network

async function run(script: string, args: string[], env: Record<string, string>, write: string[]) {
  const cmd = new Deno.Command(Deno.execPath(), {
    args: ["run", "--allow-read", "--allow-env", `--allow-write=${write.join(",")}`, "--config", `${repo}backend/supabase/functions/deno.json`, `${repo}backend/scripts/${script}`, ...args],
    env: { ...env, NO_COLOR: "1" },
    clearEnv: true,
    stdout: "piped",
    stderr: "piped",
  });
  const r = await cmd.output();
  return { code: r.code, stdout: new TextDecoder().decode(r.stdout), stderr: new TextDecoder().decode(r.stderr) };
}

Deno.test("as processes without network permission: the offline dry run, decode-only and the refusals print no secret", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    await copyV1(k);
    v1Contracts(k.ledger);
    const out = `${k.root}cutover`;
    assertEquals((await admin(k, ["cutover-v1", "--out-dir", out])).code, 0);
    const env = { DYOR_SECRETS_DIR: k.secrets, PATH: Deno.env.get("PATH") ?? "", HOME: Deno.env.get("HOME") ?? "", DENO_DIR: Deno.env.get("DENO_DIR") ?? "" };
    if (!env.DENO_DIR) delete (env as Record<string, string>).DENO_DIR;
    const secrets = await secretsOf(k);
    const runs = [
      // The real repository: no contracts/dist and no reviewed list yet.
      await run("deploy-contracts-v2.ts", ["--deployment", "testnet", "--dry-run", "--offline"], env, [k.secrets]),
      await run("owner-v2.ts", ["sign", `${out}/2-v1-moments-set_policy.json`, "--as", "v1-admin", "--decode-only"], env, [k.secrets]),
      await run("owner-v2.ts", ["keys"], { ...env, ADMIN_PUBLIC: (await rolesOf(k)).ADMIN_PUBLIC }, [k.secrets]),
      await run("deploy-contracts-v2.ts", ["--deployment", "mainnet"], env, [k.secrets]),
      await run("owner-v2.ts", ["keys", "--deployment", "testnet-qa"], env, [k.secrets]),
      await run("admin-v2.ts", [], env, [k.secrets]),
    ];
    const [dry, decode, roleEnv, mainnet, qa, usage] = runs;
    assertEquals(dry.code, 0, dry.stderr);
    for (
      const s of [
        "launch fee            10 XLM (100,000,000 stroops)",
        "phantom 2,000 XLM",
        "phantom 20 USDC",
        "Moments threshold     10 USDC",
        "Planned contract ids",
        "salt sha256(\"dyorhq/v2/testnet/g1/",
        "__constructor(admin: Address",
        "missing: a real deploy stops here",
        "absent from contracts/dist: dyor_launchpad_v2.wasm",
        "Network checks: skipped (--offline)",
      ]
    ) assertStringIncludes(dry.stdout, s);
    assertEquals(decode.code, 0, decode.stderr);
    assertStringIncludes(decode.stdout, "call     set_policy(250, 300, false)");
    assertEquals(roleEnv.code, 1);
    assertStringIncludes(roleEnv.stderr, "ADMIN_PUBLIC is set in the environment");
    assertEquals(mainnet.code, 1);
    assertStringIncludes(mainnet.stderr, "mainnet is refused");
    assertEquals(qa.code, 1);
    assertStringIncludes(qa.stderr, "testnet-qa is refused");
    assertEquals(usage.code, 2);
    for (const r of runs) {
      for (const text of [r.stdout, r.stderr]) {
        assertClean(text, secrets);
        // The console redacts anything shaped like a seed as a last line of defence; it must never have had to.
        assertFalse(text.includes("[redacted]"), "a process tried to print something shaped like a seed");
      }
    }
  } finally {
    await cleanup(k);
  }
});
