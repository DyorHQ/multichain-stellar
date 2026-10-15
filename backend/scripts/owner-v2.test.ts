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
import { ADMIN_FNS, main as adminMain } from "./admin-v2.ts";
import { type DeployCtx, main as deployMain } from "./deploy-contracts-v2.ts";
import { main as ownerMain, type OwnerCtx } from "./owner-v2.ts";
import { contractIdFor, normalize } from "./lib/contract-ids.ts";
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
  if (v instanceof xdr.ScVal) return v;
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
  /** Every contract call a transaction made: the contract's kind, the function and the transaction's source. */
  calls: { kind: string; fn: string; source: string }[] = [];
  /** The ledger's close time (unix seconds): 5 s per transaction, and the smoke's waits. */
  time = 1_760_486_400;
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
      this.time += 5;
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
        this.calls.push({ kind: this.contracts.get(id)?.kind ?? id, fn, source: tx.source });
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
        // Its constructor arguments as views (§12), which moments-v2's constructor and the re-run check read.
        return { kind, wasm, fns: { moments: () => a[0], coin_wasm_hash: () => a[1], executor: () => a[2], locker: () => a[3], soroswap_factory: () => a[4] } };
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
        // Like moments-v2's constructor: the graduator must be wired to this contract and its peers.
        const g = (fn: string) => this.call(String(graduator), fn, [], null);
        if (g("moments") !== id || g("locker") !== lockerId || g("executor") !== executor || g("soroswap_factory") !== factory) throw new Error("Error(Contract, #10732)");
        const cfg = { governance, guardian, usdc, nft_wasm_hash: nftHash, coin_wasm_hash: g("coin_wasm_hash"), graduator, locker: lockerId, executor, soroswap_factory: factory, external_base: base, publishing_paused: false, guardian_paused: false, durations, ttl };
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

/** deploy-contracts-v2.ts with the Aquarius path on (--aquarius auto) unless a test chooses: these tests cover it too.
 *  `deployDefault` runs the script with exactly the arguments given (Aquarius off by default, O7). */
async function deploy(k: Kit, args: string[]) {
  return await deployDefault(k, args.includes("--aquarius") || args.includes("--smoke") ? args : [...args, "--aquarius", "auto"]);
}

async function deployDefault(k: Kit, args: string[]) {
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
    // The smoke's waits: ledgers close while it waits.
    sleep: (ms) => {
      k.ledger.time += Math.ceil(ms / 1000);
      k.ledger.ledger += Math.ceil(ms / 5000);
      return Promise.resolve();
    },
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
  // Outside text is escaped to printable ASCII; the scripts' own marks (✓ ✗ → …) are none of these.
  assertFalse(/[\p{Cf}\p{Zl}\p{Zp}\p{M}\p{Script=Cyrillic}\p{Script=Greek}\u3164]/u.test(out), "an output holds a format, separator, combining or look-alike character");
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
    // Aquarius is off by default (O7): the router isn't asked.
    const off = await owner(k, ["check"]);
    assertEquals(off.code, 0, off.out);
    assertStringIncludes(off.out, "✓ Aquarius: off (owner decision O7: Soroswap only), not checked");
    assertFalse(off.out.includes("dyor_exec_aquarius.wasm"), "exec-aquarius is not expected with Aquarius off");
    const ok = await owner(k, ["check", "--aquarius", "auto"]);
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
    assertEquals((await owner(k, ["check", "--aquarius", "auto"])).code, 1);
    assertEquals((await owner(k, ["check", "--aquarius", "off"])).code, 0);
    assertEquals((await owner(k, ["check"])).code, 0);
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
    assertStringIncludes((await deploy(k, ["--deployment", "testnet", "--dry-run"])).out, "the smoke run (--smoke, SMOKE=1) is refused for testnet");
    delete k.env.SMOKE;
    assertStringIncludes((await deploy(k, ["--deployment", "testnet", "--smoke"])).out, "the smoke run (--smoke, SMOKE=1) is refused for testnet");
    assertStringIncludes((await deploy(k, ["--deployment", "testnet", "--smoke", "--dry-run"])).out, "the smoke run (--smoke, SMOKE=1) is refused for testnet");
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
    assertStringIncludes(pad.out, `  description  ${V1_PAUSE}`);
    assertStringIncludes(r.out, "cutover 2 of 2; config() says platform_bps 250 and royalty_bps 300 today");
    const mom = await owner(k, ["sign", `${out}/${files[1]}`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(mom.code, 0, mom.out);
    assertStringIncludes(mom.out, `contract ${V1.moments} (v1 Moments)`);
    assertStringIncludes(mom.out, "call     set_policy(250, 300, false)", "the values come from config()");
    assertStringIncludes(mom.out, "  description  v1 Moments set_policy(250, 300, false): publishing stops; platform_bps is set to 250 and royalty_bps to 300");
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
    // The admin's call offered to the guardian's key: not a call the guardian signs.
    const notGuardians = await owner(k, ["sign", file, "--as", "guardian"]);
    assertEquals(notGuardians.code, 1);
    assertStringIncludes(notGuardians.out, "refused: admin-v2.ts writes launchpad-v2 propose_treasury for --as admin, not --as guardian");
    // cancel_treasury is the admin's or the guardian's: the admin's envelope offered to the guardian's key.
    const cancel = `${k.root}cancel.json`;
    assertEquals((await admin(k, ["treasury-cancel", "--as", "admin", "--out", cancel])).code, 0);
    const src = await owner(k, ["sign", cancel, "--as", "guardian"]);
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
/** The description admin-v2.ts writes for the first cutover envelope, and `sign` derives from its call. */
const V1_PAUSE = "v1 launchpad set_launches_enabled(false): new launches stop; sells, claims and graduations go on";

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
  /** The prepared resource fee, in stroops (50,000 by default); the builder adds it to `fee`. */
  resourceFee?: number;
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
  if (c.soroban ?? !c.ops) b.setSorobanData(new SorobanDataBuilder().setResourceFee(c.resourceFee ?? 50_000).build());
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
    description: V1_PAUSE,
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

const u32v = (n: number) => nativeToScVal(n, { type: "u32" });
const i128v = (n: bigint) => nativeToScVal(n, { type: "i128" });
const addr = (a: string) => new Address(a).toScVal();
const invocation = (contract: string, fn: string, args: xdr.ScVal[], subs: xdr.SorobanAuthorizedInvocation[] = []) =>
  new xdr.SorobanAuthorizedInvocation({
    function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(callArgs({ contract, fn, args })),
    subInvocations: subs,
  });
/** The review's look-alike text (craft3.ts n3): Cyrillic у, a right-to-left override, a pop-direction mark, the Hangul
 *  filler, a combining long stroke, and a line separator. */
const LOOKALIKE = "https://dуorhq.fun/m/‮gpj.evil‬ xㅤy̶z ";
const LOOKALIKE_SHOWN = "https://d\\u{443}orhq.fun/m/\\u{202e}gpj.evil\\u{202c} x\\u{3164}y\\u{336}z\\u{2028}";
/** v2 contracts for the table: testnet-v2.json lists them. */
const LP2 = StrKey.encodeContract(Buffer.alloc(32, 11));
const MO2 = StrKey.encodeContract(Buffer.alloc(32, 12));
const LOCK = StrKey.encodeContract(Buffer.alloc(32, 13));

/** craft4.ts n8: the cutover call in a v0 envelope (ENVELOPE_TYPE_TX_V0). */
function v0Envelope(): string {
  const v1tx = new TransactionBuilder(new Account(V1.admin, "1"), { fee: "100", networkPassphrase: PASSPHRASE, timebounds: { minTime: 0, maxTime: Math.floor(Date.now() / 1000) + 1_800 } })
    .addOperation(Operation.invokeContractFunction({ contract: V1.launchpad, function: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] }))
    .build();
  const b = v1tx.toEnvelope().v1().tx();
  const v0 = xdr.TransactionEnvelope.envelopeTypeTxV0(
    new xdr.TransactionV0Envelope({
      tx: new xdr.TransactionV0({
        sourceAccountEd25519: StrKey.decodeEd25519PublicKey(V1.admin),
        fee: b.fee(),
        seqNum: b.seqNum(),
        timeBounds: b.cond().timeBounds(),
        memo: b.memo(),
        operations: b.operations(),
        ext: new xdr.TransactionV0Ext(0),
      }),
      signatures: [],
    }),
  );
  return JSON.stringify({
    format: "dyorhq-unsigned-envelope/1",
    networkPassphrase: PASSPHRASE,
    role: "v1-admin",
    source: V1.admin,
    contract: V1.launchpad,
    function: "set_launches_enabled",
    description: V1_PAUSE,
    builtAt: "2026-10-15T00:00:00.000Z",
    xdr: v0.toXDR("base64"),
  });
}

/** Runs each case through sign, --decode-only and with a terminal and a yes: refused with its reason, no prompt,
 *  nothing sent. */
async function assertRefused(k: Kit, cases: [string, string, string][]) {
  for (const [name, text, reason] of cases) {
    const file = `${k.root}${name.replace(/[^A-Za-z0-9]+/g, "-")}.json`;
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
}

Deno.test("sign refuses every envelope admin-v2.ts never writes, before any prompt (the review's crafted envelopes and each rule)", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    await Deno.writeTextFile(`${k.deployments}/testnet-v2.json`, JSON.stringify({ contracts: { launchpadV2: LP2, momentsV2: MO2, lpLocker: LOCK } }));
    const launchpadCall = { contract: V1.launchpad, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] };
    const now = Math.floor(Date.now() / 1000);
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
        `refused: the call goes to ${AQ.router.contract_id} (Aquarius router), which admin-v2.ts never calls`,
      ],
      // A v2 contract testnet-v2.json lists, but admin-v2.ts never calls.
      ["v2 contract", craft({ call: { contract: LOCK, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] } }), `refused: the call goes to ${LOCK} (v2 lpLocker), which admin-v2.ts never calls`],
      // craft3.ts n7: the auth root elsewhere, on the real v1 launchpad call: the label says set_launches_enabled, the
      // signature pays out.
      [
        "craft3 n7 auth root elsewhere",
        craft({ auth: [new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: transferAll(ATTACKER) })], meta: { description: "d", builtAt: "x" } }),
        `refused: auth entry 1 authorizes ${XLM_SAC} (XLM SAC) transfer(${V1.admin}, ${ATTACKER}, 90000000000), not the call set_launches_enabled itself`,
      ],
      // craft3.ts n1: the call itself as the root, with a sub-invocation that pays the attacker.
      [
        "craft3 n1 sub-invocation",
        craft({ auth: [sourceAuth(callArgs(launchpadCall), [transferAll(ATTACKER)])] }),
        `refused: auth entry 1 also authorizes 1 sub-invocation(s), the first ${XLM_SAC} (XLM SAC) transfer(${V1.admin}, ${ATTACKER}, 90000000000); admin-v2.ts's calls authorize nothing beyond themselves`,
      ],
      // craft3.ts n2a: a function admin-v2.ts never builds, on a contract testnet.json names (a 100% protocol share).
      [
        "craft3 n2a set_fees",
        craft({ call: { contract: V1.launchpad, fn: "set_fees", args: [u32v(1000), u32v(10000), u32v(1000), xdr.ScVal.scvVec([])] } }),
        "refused: v1 launchpad set_fees is a call admin-v2.ts never writes; on the v1 launchpad it writes only set_launches_enabled",
      ],
      // craft3.ts n2b: v1 buy(admin, token, 9,000 XLM, 0), the transfer as the sub-invocation.
      [
        "craft3 n2b buy",
        (() => {
          const buy = { contract: V1.launchpad, fn: "buy", args: [addr(V1.admin), addr(StrKey.encodeContract(Buffer.alloc(32, 9))), i128v(90_000_000_000n), i128v(0n)] };
          return craft({ call: buy, auth: [sourceAuth(callArgs(buy), [invocation(XLM_SAC, "transfer", [addr(V1.admin), addr(V1.launchpad), i128v(90_000_000_000n)])])] });
        })(),
        "refused: v1 launchpad buy is a call admin-v2.ts never writes",
      ],
      // craft3.ts n3: v1 Moments publish with look-alike text.
      [
        "craft3 n3 publish",
        craft({
          call: {
            contract: V1.moments,
            fn: "publish",
            args: [addr(V1.admin), nativeToScVal(LOOKALIKE, { type: "string" }), i128v(1_000_000n), addr(XLM_SAC), u32v(1), nativeToScVal(3600n, { type: "u64" })],
          },
        }),
        "refused: v1 Moments publish is a call admin-v2.ts never writes; on the v1 Moments it writes only set_policy",
      ],
      // craft3.ts n5: a validity window to the year 2100; and one just over admin-v2.ts's 24 h.
      [
        "craft3 n5 far expiry",
        craft({ timebounds: { minTime: 0, maxTime: 4_102_444_800 } }),
        "refused: the transaction stays valid until 2100-01-01T00:00:00.000Z",
      ],
      ["a day and two minutes", craft({ timebounds: { minTime: 0, maxTime: now + 86_520 } }), "admin-v2.ts writes envelopes valid for at most 86,400 s (24 h)"],
      // craft3.ts n6: a valid call whose description draws a fake summary and hides the rest.
      [
        "craft3 n6 description",
        craft({ meta: { description: "ok\n   1. contract fake\n\x1b[8m‮" } }),
        `refused: the file describes the call as "ok\\x0a   1. contract fake\\x0a\\x1b[8m\\u{202e}", but its transaction is: ${V1_PAUSE}`,
      ],
      // The review's point: the cutover's description on another call.
      [
        "cutover description on set_policy",
        craft({ call: { contract: V1.moments, fn: "set_policy", args: [u32v(0), u32v(1000), xdr.ScVal.scvBool(false)] } }),
        "but its transaction is: v1 Moments set_policy(0, 1000, false): publishing stops; platform_bps is set to 0 and royalty_bps to 1000",
      ],
      // craft4.ts n8: a v0 envelope.
      ["craft4 n8 v0", v0Envelope(), "refused: a v0 transaction envelope (the format from before protocol 13); admin-v2.ts writes v1 envelopes only"],
      // An allowed call with an argument admin-v2.ts never writes.
      ["argument", craft({ call: { contract: V1.launchpad, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(true)] } }), "refused: argument 1 of set_launches_enabled is true; admin-v2.ts writes false"],
      ["argument count", craft({ call: { contract: V1.launchpad, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false), xdr.ScVal.scvBool(false)] } }), "refused: set_launches_enabled has 2 argument(s); admin-v2.ts writes 1 argument(s)"],
      // A look-alike function name: Cyrillic е.
      [
        "look-alike function",
        craft({ call: { contract: V1.launchpad, fn: "set_launches_enablеd", args: [xdr.ScVal.scvBool(false)] } }),
        "refused: v1 launchpad set_launches_enabl\\u{435}d is a call admin-v2.ts never writes",
      ],
      ["role", craft({ meta: { role: "admin" } }), "refused: the file says --as admin, but admin-v2.ts writes v1 launchpad set_launches_enabled for --as v1-admin"],
      [
        "build time",
        craft({ meta: { builtAt: "2026-10-15T00:00:00.000Z: approved by the lead " } }),
        `refused: the file's build time "2026-10-15T00:00:00.000Z: approved by the lead\\u{2028}" isn't a time admin-v2.ts writes`,
      ],
      // launchpad-v2 and moments-v2: only the admin, guardian and governance calls admin-v2.ts builds.
      [
        "v2 set_fees",
        craft({ call: { contract: LP2, fn: "set_fees", args: [u32v(1000), u32v(10000), u32v(1000), xdr.ScVal.scvVec([]), u32v(5)] } }),
        "refused: launchpad-v2 set_fees is a call admin-v2.ts never writes; on the launchpad-v2 it writes only rescue, allow_fallback",
      ],
      // launchpad-v2 admin powers admin-v2.ts has no builder for: the admin handover, the launch fee.
      ["v2 propose_admin", craft({ call: { contract: LP2, fn: "propose_admin", args: [addr(ATTACKER)] } }), "refused: launchpad-v2 propose_admin is a call admin-v2.ts never writes"],
      ["v2 set_launch_fee", craft({ call: { contract: LP2, fn: "set_launch_fee", args: [i128v(0n)] } }), "refused: launchpad-v2 set_launch_fee is a call admin-v2.ts never writes"],
      [
        "caller other than the source",
        craft({ call: { contract: LP2, fn: "cancel_treasury", args: [addr(ATTACKER)] }, meta: { role: "admin" } }),
        `refused: argument 1 of cancel_treasury is ${ATTACKER}; admin-v2.ts writes the source account's address`,
      ],
      ["v2 publish", craft({ call: { contract: MO2, fn: "publish", args: [addr(V1.admin)] } }), "refused: moments-v2 publish is a call admin-v2.ts never writes"],
      [
        "address credentials",
        craft({
          auth: [
            new xdr.SorobanAuthorizationEntry({
              credentials: xdr.SorobanCredentials.sorobanCredentialsAddress(
                new xdr.SorobanAddressCredentials({ address: new Address(ATTACKER).toScAddress(), nonce: xdr.Int64.fromString("1"), signatureExpirationLedger: 1, signature: xdr.ScVal.scvVoid() }),
              ),
              rootInvocation: invocation(V1.launchpad, "set_launches_enabled", [xdr.ScVal.scvBool(false)]),
            }),
          ],
        }),
        "refused: auth entry 1 needs another account's signature",
      ],
      ["operation source", craft({ opSource: ATTACKER }), "refused: the operation has its own source account"],
      ["memo", craft({ memo: Memo.text("pay me") }), "refused: the transaction has a memo"],
      ["ledger bounds", craft({ ledgerbounds: { minLedger: 0, maxLedger: 9_999_999 } }), "refused: the transaction has preconditions beyond a time bound"],
      ["no expiry", craft({ timebounds: null }), "refused: the transaction never expires"],
      ["start time", craft({ timebounds: { minTime: 1_000, maxTime: now + 600 } }), "refused: the transaction has a start time"],
      ["signed", craft({ signWith: Keypair.random() }), "refused: the envelope already carries 1 signature(s)"],
      [
        "metadata",
        craft({ call: { contract: V1.moments, fn: "set_policy", args: [u32v(0), u32v(0), xdr.ScVal.scvBool(true)] }, meta: { contract: V1.launchpad, function: "set_launches_enabled" } }),
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
    await assertRefused(k, cases);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("sign: an expired envelope is shown and refused, with --decode-only too; a good one passes decode-only with the derived description", async () => {
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
    // A good envelope, its file named with a Cyrillic о: the name is shown escaped.
    await Deno.writeTextFile(`${k.root}cutоver.json`, craft());
    const good = await owner(k, ["sign", `${k.root}cutоver.json`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(good.code, 0, good.out);
    for (
      const s of [
        `Envelope ${k.root}cut\\u{43e}ver.json`,
        "  network      testnet ✓",
        `  source       ${V1.admin} (v1-admin) ✓`,
        `  description  ${V1_PAUSE}`,
        "  built        2026-10-15T00:00:00.000Z",
        "  memo         none; no signatures yet",
        "  operation    one contract call, no operation source",
        `      contract ${V1.launchpad} (v1 launchpad)`,
        "      call     set_launches_enabled(false)",
        "      arg 1    Bool false",
        "      auth 1   the source account authorizes this call only, no sub-invocations",
      ]
    ) assertStringIncludes(good.out, s);
    // craft3.ts n4: fee and resources inflated up to the 3 XLM cap are shown, and accepted within it.
    await Deno.writeTextFile(`${k.root}inflated.json`, craft({ fee: "1000", resourceFee: 29_999_000 }));
    const inflated = await owner(k, ["sign", `${k.root}inflated.json`, "--as", "v1-admin", "--decode-only"]);
    assertEquals(inflated.code, 0, inflated.out);
    assertStringIncludes(inflated.out, "  max fee      3 XLM (30,000,000 stroops; resource fee 2.9999 XLM)");
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("sign shows outside text as printable ASCII only: look-alike letters, invisible, combining and control characters are escaped", async () => {
  const k = await kit();
  try {
    await copyV1(k);
    v1Contracts(k.ledger);
    const cases: [string, string, string][] = [
      // The look-alike text as a decoded string argument (craft3.ts n3's string on an allowed call).
      [
        "string argument",
        craft({ call: { contract: V1.launchpad, fn: "set_launches_enabled", args: [nativeToScVal(LOOKALIKE, { type: "string" })] } }),
        `refused: argument 1 of set_launches_enabled is "${LOOKALIKE_SHOWN}"; admin-v2.ts writes false`,
      ],
      // ...as a symbol in a sub-invocation, which is refused.
      [
        "symbol in a sub-invocation",
        craft({ auth: [sourceAuth(callArgs({ contract: V1.launchpad, fn: "set_launches_enabled", args: [xdr.ScVal.scvBool(false)] }), [invocation(XLM_SAC, "apprоve", [xdr.ScVal.scvSymbol("a‍b")])])] }),
        `the first ${XLM_SAC} (XLM SAC) appr\\u{43e}ve(a\\u{200d}b)`,
      ],
      // ...in the description, the file's role and its metadata.
      ["description", craft({ meta: { description: LOOKALIKE } }), `refused: the file describes the call as "${LOOKALIKE_SHOWN}"`],
      ["role", craft({ meta: { role: "v1-аdmin" } }), "refused: the file says --as v1-\\u{430}dmin"],
      ["metadata", craft({ meta: { function: "set_launches_enabled   ok" } }), "refused: the file says set_launches_enabled\\u{2028}  ok on"],
      ["passphrase", JSON.stringify({ ...JSON.parse(craft()), networkPassphrase: "Test SDF Network ; September 2015‮" }), 'refused: the envelope is for the network "Test SDF Network ; September 2015\\u{202e}", not testnet'],
      // A backslash can't pass for an escape: it's doubled.
      ["backslash", craft({ meta: { description: "v1 launchpad\\u{2028}" } }), 'refused: the file describes the call as "v1 launchpad\\\\u{2028}"'],
    ];
    await assertRefused(k, cases);
    // Nothing recorded (before the console's own escaping) holds a control, format, combining or look-alike character.
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("sign refuses sub-invocations anywhere in an auth tree", async () => {
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
          constructorArgs: [new Address(ATTACKER).toScVal(), u32v(7)],
        }),
      ),
      subInvocations: [],
    });
    await assertRefused(k, [
      // A creation directly under the call.
      [
        "creation",
        craft({ auth: [sourceAuth(callArgs(call), [create])] }),
        `refused: auth entry 1 also authorizes 1 sub-invocation(s), the first create a contract from WASM ${"01".repeat(32)} by ${V1.admin} with salt ${"02".repeat(32)}(${ATTACKER}, 7)`,
      ],
      // A transfer with a creation under it, beside a harmless-looking second call.
      [
        "deep tree",
        craft({ auth: [sourceAuth(callArgs(call), [new xdr.SorobanAuthorizedInvocation({ function: transferAll(V1.launchpad).function(), subInvocations: [create] }), invocation(V1.launchpad, "config", [])])] }),
        `refused: auth entry 1 also authorizes 2 sub-invocation(s), the first ${XLM_SAC} (XLM SAC) transfer(${V1.admin}, ${V1.launchpad}, 90000000000)`,
      ],
      // A second, clean entry doesn't hide a first one with a sub-invocation.
      [
        "second entry",
        craft({ auth: [sourceAuth(callArgs(call)), sourceAuth(callArgs(call), [transferAll(ATTACKER)])] }),
        "refused: auth entry 2 also authorizes 1 sub-invocation(s)",
      ],
    ]);
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("every call admin-v2.ts writes is one sign accepts, with the same derived description; the takeover calls use CT-05's names", async () => {
  const k = await kit();
  try {
    await readyOwner(k);
    assertEquals((await deploy(k, ["--deployment", "testnet"])).code, 0);
    const roles = await rolesOf(k);
    const v2 = JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-v2.json`)).contracts;
    const token = StrKey.encodeContract(Buffer.alloc(32, 21));
    const someone = Keypair.random().publicKey();
    const commands: string[][] = [
      ["rescue", "--token", token],
      ["allow-fallback", "--token", token],
      ["takeover-propose", "--token", token, "--to", someone],
      ["takeover-cancel", "--token", token],
      ["takeover-execute", "--token", token],
      ["treasury-propose", "--to", someone],
      ["treasury-apply"],
      ["treasury-cancel", "--as", "admin"],
      ["treasury-cancel", "--as", "guardian"],
      ["venue-propose", "--kind", "aquarius", "--executor", token],
      ["venue-apply", "--id", "2"],
      ["venue-cancel", "--id", "2", "--as", "guardian"],
      ["venue-enable", "--id", "1", "--enabled", "false"],
      ["quote", "--asset", "USDC", "--phantom", "200000000", "--threshold", "432455532", "--enabled", "true", "--fallback", "0", "--venues", "0,1"],
      ["launches-enabled", "--enabled", "false"],
      ["guardian-transfer", "--to", someone],
      ["guardian-accept", "--from", roles.LAUNCHPAD_GUARDIAN_PUBLIC],
      ["guardian-renounce"],
      ["guardian-propose", "--to", "none"],
      ["guardian-apply"],
      ["guardian-cancel"],
      ["policy-propose", "--royalty-bps", "400"],
      ["policy-apply"],
      ["policy-cancel", "--as", "governance"],
      ["policy-cancel", "--as", "guardian"],
      ["publishing-paused", "--paused", "true"],
      ["guardian-paused", "--paused", "true"],
      ["moments-guardian-transfer", "--to", "none"],
    ];
    const built = new Set<string>();
    const descriptions: string[] = [];
    for (const [i, cmd] of commands.entries()) {
      const file = `${k.root}${i}-${cmd[0]}.json`;
      const r = await admin(k, [...cmd, "--out", file]);
      assertEquals(r.code, 0, `${cmd.join(" ")}: ${r.out}`);
      const env = JSON.parse(await Deno.readTextFile(file));
      const target = env.contract === v2.launchpadV2 ? "launchpad-v2" : env.contract === v2.momentsV2 ? "moments-v2" : "?";
      built.add(`${target} ${env.function}`);
      const s = await owner(k, ["sign", file, "--as", env.role, "--decode-only"]);
      assertEquals(s.code, 0, `${cmd.join(" ")}: ${s.out}`);
      assertStringIncludes(s.out, `  description  ${env.description}`);
      descriptions.push(env.description);
      if (cmd[0] === "policy-propose") assertMatch(r.out, /changes: royalty_bps \d+ → 400/);
    }
    // Every v2 call ADMIN_FNS lists is one admin-v2.ts builds.
    assertEquals([...built].sort(), ADMIN_FNS.filter((f) => !f.target.startsWith("v1")).map((f) => `${f.target} ${f.fn}`).sort());
    for (
      const d of [
        `launchpad-v2 cancel_recipient_change(${token}, ${roles.ADMIN_PUBLIC}): the admin cancels the launch's pending takeover`,
        `launchpad-v2 execute_recipient_change(${token}): executes the launch's pending takeover inside its window`,
        "launchpad-v2 set_quote(USDC, phantom 200000000, threshold 432455532, enabled true, venues [0, 1], fallback 0): the economics of future launches quoted in this asset",
        `launchpad-v2 propose_venue(Aquarius, ${token}, fee_fraction 30): a new venue with this executor, applied after the timelock; it starts disabled`,
        `launchpad-v2 accept_guardian(): ${roles.LAUNCHPAD_GUARDIAN_PUBLIC}, the source, becomes the launchpad's guardian`,
        "launchpad-v2 propose_guardian(none): removes the guardian after the 48 h timelock",
        `moments-v2 cancel_policy(${roles.MOMENTS_GUARDIAN_PUBLIC}): cancels the pending policy`,
        "moments-v2 transfer_guardian(none): Moments has no guardian afterwards",
      ]
    ) assert(descriptions.includes(d), `missing: ${d}\n${descriptions.join("\n")}`);
    await assertNoSecrets(k);
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
  assertThrows(() => assertClean("d\u0443orhq", []), Error, "look-alike character");
  assertThrows(() => assertClean("a\u202eb", []), Error, "look-alike character");
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

Deno.test("O7: by default Aquarius is off: no exec-aquarius is uploaded, deployed or required in the reviewed list or dist", async () => {
  for (const deployment of ["testnet", "testnet-qa"]) {
    const k = await kit();
    try {
      if (deployment === "testnet") await readyOwner(k);
      // CT-19 reviews no exec-aquarius (O7) and dist may lack it: neither stops a Soroswap-only deploy.
      const reviewed = `${k.root}contracts/review/reviewed-wasm.sha256`;
      await Deno.writeTextFile(reviewed, (await Deno.readTextFile(reviewed)).split("\n").filter((l) => !l.includes("dyor_exec_aquarius.wasm")).join("\n"));
      await Deno.remove(`${k.root}contracts/dist/dyor_exec_aquarius.wasm`);
      const dry = await deployDefault(k, ["--deployment", deployment, "--dry-run"]);
      assertEquals(dry.code, 0, dry.out);
      assertStringIncludes(dry.out, "Aquarius: disabled (--aquarius off)");
      assertStringIncludes(dry.out, "✓ every WASM matches the reviewed list");
      assertStringIncludes(dry.out, "A real deploy would go ahead.");
      assertFalse(dry.out.includes("exec-aquarius"), "exec-aquarius is never planned");
      const r = await deployDefault(k, ["--deployment", deployment]);
      assertEquals(r.code, 0, r.out);
      assertFalse(k.ledger.log.some((l) => l.includes("exec-aquarius")), "no exec-aquarius upload or deploy");
      assertEquals(k.ledger.log.filter((l) => l.startsWith("view router.") || l.startsWith("invoke router.")), [], "the Aquarius router was never asked");
      const file = JSON.parse(await Deno.readTextFile(`${k.deployments}/${deployment}-v2.json`));
      assertEquals([file.aquarius.enabled, file.aquarius.reason], [false, "--aquarius off"]);
      assertEquals(file.contracts.execAquarius, undefined);
      assertEquals(file.wasmHashes.execAquarius, undefined);
      assertEquals(file.venues.map((v: any) => v.kind), deployment === "testnet" ? ["Soroswap"] : ["Soroswap", "QaFail"]);
      // The locker was built without the Aquarius router.
      assertEquals(k.ledger.contracts.get(file.contracts.lpLocker)!.fns.aquarius_router([], null), null);
      await assertNoSecrets(k);
    } finally {
      await cleanup(k);
    }
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
    // moments-graduator shows its constructor arguments as views (CT-08): give it another executor.
    const grad = k.ledger.contracts.get(file.contracts.momentsGraduator)!;
    const executor = grad.fns.executor;
    grad.fns.executor = () => ATTACKER;
    const mark = k.ledger.log.length;
    const r = await deploy(k, ["--deployment", "testnet"]);
    assertEquals(r.code, 1);
    assertStringIncludes(r.out, `moments-graduator executor() is "${ATTACKER}" on chain, the plan has "${file.contracts.execSoroswap}"`);
    assertStringIncludes(r.out, "use a new --generation");
    assertEquals(k.ledger.log.slice(mark).filter((l) => !l.startsWith("view")), [], "nothing sent");
    grad.fns.executor = executor;
    // exec-aquarius shows only max_pool_payment: its router comes from the storage.
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

// ------------------------------------------------------------------------------------------------ the testnet-qa smoke

const ROUTER = "CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD";
const LAUNCH_PARAMS = ["creator_fee_bps", "creator_fee_recipient", "holder_sharing", "initial_buy", "min_tokens_out", "name", "nonce", "quote", "snipe_exempt", "symbol", "uri", "venue"];
const PUBLISH_PARAMS = ["creator_alloc_bps", "date", "media_hash", "metadata_uri", "name", "nonce", "place", "price", "symbol", "window_secs"];
const SYMBOL_RULE = /^[A-Za-z0-9]{2,10}$/;
const cid = (label: string) => StrKey.encodeContract(hash(Buffer.from(label)));
const sameNative = (a: unknown, b: unknown) => JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
const outcome = (pool: string) => xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("Graduated"), new Address(pool).toScVal()]);
const failed = (origin: number, code: number) => xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("Failed"), sv({ code, origin })]);

/** What the smoke drives, on top of the deployed fakes: the curve, launch tokens, Soroswap's router and pairs, the
 *  locker's harvest and a Moment's life. Each call checks its caller's auth (the transaction's source), its argument
 *  names and the state it needs, as the contracts do; a contract error is thrown as the RPC reports one. */
function smokeWorld(l: Ledger, file: any, opts: { graduation?: "ok" | "failed"; usdc?: "deep" | "thin" } = {}) {
  const auth = (who: unknown, source: string | null) => {
    if (who !== source) throw new Error("Error(Auth, InvalidAction)");
  };
  const fail = (code: number): never => {
    throw new Error(`Error(Contract, #${code})`);
  };
  const balanceOf = (asset: string, who: string) => BigInt(l.call(asset, "balance", [who], null) as bigint);
  const move = (asset: string, from: string, to: string, amount: bigint) => void l.call(asset, "transfer", [from, to, amount], from);
  const credit = (asset: string, holder: string, amount: bigint) => {
    const m = l.held.get(asset) ?? new Map<string, bigint>();
    m.set(holder, (m.get(holder) ?? 0n) + amount);
    l.held.set(asset, m);
  };
  const lpId: string = file.contracts.launchpadV2;
  const lp = l.contracts.get(lpId)!;
  const cfg = lp.fns.config([], null) as Record<string, any>;
  const table = lp.fns.venues([], null) as any[];
  const growth = new Map<string, number>();

  // A token whose holder rewards are queued from the next ledger on (launch-token-v2), or a plain one (moment-coin).
  const token = (id: string, kind: string) => {
    const balances = new Map<string, bigint>();
    const rewards = new Map<string, { quote: bigint; token: bigint; from: number }>();
    const get = (w: string) => balances.get(w) ?? 0n;
    const send = (from: string, to: string, amount: bigint) => {
      if (get(from) < amount) fail(10);
      balances.set(from, get(from) - amount);
      balances.set(to, get(to) + amount);
    };
    const mint = (to: string, amount: bigint) => void balances.set(to, get(to) + amount);
    l.addContract(id, {
      kind,
      wasm: `${kind}-instance`,
      fns: {
        balance: (a) => get(a[0] as string),
        transfer: (a, s) => {
          auth(a[0], s);
          send(a[0] as string, a[1] as string, BigInt(a[2] as bigint));
        },
        pending_rewards: (a) => {
          const r = rewards.get(a[0] as string);
          return r && l.ledger >= r.from ? [r.quote, r.token] : [0n, 0n];
        },
        claim: (a, s) => {
          auth(a[0], s);
          const holder = a[0] as string;
          const r = rewards.get(holder);
          if (!r || l.ledger < r.from) return [0n, 0n];
          rewards.delete(holder);
          move(XLM_SAC, id, holder, r.quote);
          send(id, holder, r.token);
          return [r.quote, r.token];
        },
      },
    });
    /** Queues `quote` and `tok` for the holders outside `excluded`, pro rata. */
    const notify = (quote: bigint, tok: bigint, excluded: string[]) => {
      const holders = [...balances.entries()].filter(([w, b]) => b > 0n && w !== id && !excluded.includes(w));
      const total = holders.reduce((s, [, b]) => s + b, 0n);
      for (const [w, b] of holders) {
        const r = rewards.get(w) ?? { quote: 0n, token: 0n, from: 0 };
        rewards.set(w, { quote: r.quote + (quote * b) / total, token: r.token + (tok * b) / total, from: l.ledger + 1 });
      }
    };
    return { send, mint, notify, balances };
  };

  // ---- launchpad-v2: the curve.
  const launches = new Map<string, any>();
  const tokenAddress = (creator: string, nonce: bigint) => cid(`launch/${lpId}/${creator}/${nonce}`);
  const preview = (quote: string, venue: number) => {
    const q = lp.fns.quote_economics([quote], null) as any;
    if (!q?.enabled) fail(10103);
    const v = table.find((x) => x.id === venue && x.enabled) ?? fail(10109);
    return {
      supply: cfg.supply,
      fee_bps: cfg.fee_bps,
      launch_fee: cfg.launch_fee,
      fee_asset: cfg.xlm,
      quote,
      phantom: q.phantom,
      threshold: q.threshold,
      venue: v,
      fallback: table[q.fallback_venue],
      venue_locked: false,
      locker: cfg.locker,
      token_wasm_hash: cfg.token_wasm_hash,
      durations: cfg.durations,
    };
  };
  const quoteBuy = (tok: string, quoteIn: bigint) => {
    const L = launches.get(tok) ?? fail(10111);
    if (L.phase !== 0) fail(10112);
    const snipe = l.time - L.created < 20 ? 2_500n : 0n;
    const total = 100n + BigInt(L.creatorFeeBps) + snipe;
    const remaining = BigInt(L.threshold) - BigInt(L.real);
    let used = quoteIn;
    let net = used - (used * total) / 10_000n;
    if (net > remaining) {
      used = (remaining * 10_000n + 10_000n - total - 1n) / (10_000n - total);
      net = remaining;
    }
    const base_fee = used / 100n;
    const creator_fee = (used * BigInt(L.creatorFeeBps)) / 10_000n;
    return { used, net, base_fee, creator_fee, snipe_fee: snipe ? used - net - base_fee - creator_fee : 0n, tokens_out: net * 200n };
  };
  Object.assign(lp.fns, {
    preview_launch_terms: (a: unknown[]) => preview(a[0] as string, Number(a[1])),
    token_address: (a: unknown[]) => tokenAddress(a[0] as string, BigInt(a[1] as bigint)),
    launch: (a: unknown[], s: string | null) => {
      const [creator, p, expected] = a as [string, Record<string, any>, unknown];
      auth(creator, s);
      assertEquals(Object.keys(p).sort(), LAUNCH_PARAMS);
      if (!SYMBOL_RULE.test(p.symbol)) fail(10105);
      if (!sameNative(expected, preview(p.quote, Number(p.venue)))) fail(10108);
      const id = tokenAddress(creator, BigInt(p.nonce));
      if (launches.has(id)) fail(10133);
      move(XLM_SAC, creator, lpId, BigInt(cfg.launch_fee));
      const t = token(id, "launch-token-v2");
      t.mint(lpId, BigInt(cfg.supply));
      const q = lp.fns.quote_economics([p.quote], null) as any;
      launches.set(id, { creator, quote: p.quote, creatorFeeBps: Number(p.creator_fee_bps), created: l.time, threshold: BigInt(q.threshold), real: 0n, protocol: 0n, launchFee: BigInt(cfg.launch_fee), phase: 0, t });
      return id;
    },
    quote_buy: (a: unknown[]) => quoteBuy(a[0] as string, BigInt(a[2] as bigint)),
    buy: (a: unknown[], s: string | null) => {
      const [buyer, tok, quoteIn, minOut] = a as [string, string, bigint, bigint];
      auth(buyer, s);
      const q = quoteBuy(tok, BigInt(quoteIn));
      if (q.tokens_out < BigInt(minOut)) fail(10114);
      const L = launches.get(tok);
      move(L.quote, buyer, lpId, q.used);
      L.real += q.net;
      L.protocol += (q.base_fee + q.snipe_fee) / 2n;
      if (L.real === L.threshold) L.phase = 1;
      L.t.send(lpId, buyer, q.tokens_out);
      return q.tokens_out;
    },
    status: (a: unknown[]) => ({ phase: (launches.get(a[0] as string) ?? fail(10111)).phase }),
    graduate: (a: unknown[]) => {
      const tok = a[0] as string;
      const L = launches.get(tok) ?? fail(10111);
      if (L.phase === 0) fail(10116);
      if (L.phase === 2) fail(10117);
      if (opts.graduation === "failed") return failed(3, 10_302);
      L.phase = 2;
      const pool = cid(`pair/${tok}`);
      pairs.set(`${tok}|${L.quote}`, pool);
      pairs.set(`${L.quote}|${tok}`, pool);
      move(L.quote, lpId, pool, L.real);
      L.t.send(lpId, pool, 200_000_000n * XLM);
      positions.set(pool, { tok, last: l.time });
      return outcome(pool);
    },
    claim_protocol_fees: (a: unknown[]) => {
      let total = 0n;
      for (const tok of a[0] as string[]) {
        const L = launches.get(tok) ?? fail(10111);
        total += L.protocol + L.launchFee;
        [L.protocol, L.launchFee] = [0n, 0n];
      }
      if (total === 0n) fail(10123);
      move(XLM_SAC, lpId, cfg.treasury, total);
      return [[XLM_SAC, total]];
    },
  });

  // ---- Soroswap: the router and its pairs (XLM–USDC already there, a launch's pair from its graduation).
  const pairs = new Map<string, string>();
  const usdcPair = cid("pair/XLM/USDC");
  const [rx, ru] = opts.usdc === "thin" ? [1_000n * XLM, 20n * XLM] : [1_000_000n * XLM, 106_000n * XLM];
  credit(XLM_SAC, usdcPair, rx);
  credit(USDC_SAC, usdcPair, ru);
  pairs.set(`${XLM_SAC}|${USDC_SAC}`, usdcPair);
  pairs.set(`${USDC_SAC}|${XLM_SAC}`, usdcPair);
  const pairOf = (path: string[]) => {
    if (path.length !== 2) throw new Error("Error(Contract, #LibraryInvalidPath)");
    return pairs.get(`${path[0]}|${path[1]}`) ?? (() => {
      throw new Error("SoroswapRouter: pair does not exist");
    })();
  };
  const out = (amountIn: bigint, rIn: bigint, rOut: bigint) => (amountIn * 997n * rOut) / (rIn * 1000n + amountIn * 997n);
  const inFor = (amountOut: bigint, rIn: bigint, rOut: bigint) => {
    if (amountOut >= rOut) throw new Error("SoroswapLibrary: insufficient liquidity");
    return (rIn * amountOut * 1000n) / ((rOut - amountOut) * 997n) + 1n;
  };
  const swap = (path: string[], to: string, amountIn: bigint, amountOut: bigint, deadline: bigint) => {
    if (deadline < BigInt(l.time)) throw new Error("SoroswapRouter: deadline expired");
    const pair = pairOf(path);
    move(path[0], to, pair, amountIn);
    move(path[1], pair, to, amountOut);
    growth.set(pair, (growth.get(pair) ?? 0) + 1);
    return [amountIn, amountOut];
  };
  l.addContract(ROUTER, {
    kind: "soroswap-router",
    wasm: "router",
    fns: {
      router_get_amounts_out: (a) => {
        const [amount, path] = a as [bigint, string[]];
        const pair = pairOf(path);
        return [BigInt(amount), out(BigInt(amount), balanceOf(path[0], pair), balanceOf(path[1], pair))];
      },
      router_get_amounts_in: (a) => {
        const [amount, path] = a as [bigint, string[]];
        const pair = pairOf(path);
        return [inFor(BigInt(amount), balanceOf(path[0], pair), balanceOf(path[1], pair)), BigInt(amount)];
      },
      swap_exact_tokens_for_tokens: (a, s) => {
        const [amount, min, path, to, deadline] = a as [bigint, bigint, string[], string, bigint];
        auth(to, s);
        const pair = pairOf(path);
        const o = out(BigInt(amount), balanceOf(path[0], pair), balanceOf(path[1], pair));
        if (o < BigInt(min)) throw new Error("SoroswapRouter: insufficient output amount");
        return swap(path, to, BigInt(amount), o, BigInt(deadline));
      },
      swap_tokens_for_exact_tokens: (a, s) => {
        const [amount, max, path, to, deadline] = a as [bigint, bigint, string[], string, bigint];
        auth(to, s);
        const pair = pairOf(path);
        const i = inFor(BigInt(amount), balanceOf(path[0], pair), balanceOf(path[1], pair));
        if (i > BigInt(max)) throw new Error("SoroswapRouter: excessive input amount");
        return swap(path, to, i, BigInt(amount), BigInt(deadline));
      },
    },
  });

  // ---- lp-locker: one harvest per interval, half to the treasury, half to the holders (sharing on).
  const lockerId: string = file.contracts.lpLocker;
  const locker = l.contracts.get(lockerId)!;
  const interval = Number(locker.fns.harvest_interval([], null));
  const positions = new Map<string, { tok: string; last: number }>();
  Object.assign(locker.fns, {
    harvestable: (a: unknown[]) => {
      const p = positions.get(a[0] as string) ?? fail(10601);
      const g = BigInt(growth.get(a[0] as string) ?? 0);
      return [g, g * 1_000n, g * 1_000n * XLM, g * XLM, BigInt(p.last + interval)];
    },
    harvest: (a: unknown[], s: string | null) => {
      const pool = a[0] as string;
      const p = positions.get(pool) ?? fail(10601);
      if (l.time < p.last + interval) fail(10603);
      const g = BigInt(growth.get(pool) ?? 0);
      if (g === 0n) fail(10604);
      // A simulation (a view has no source) commits nothing.
      if (s === null) return [g * 1_000n * XLM, g * XLM];
      growth.set(pool, 0);
      p.last = l.time;
      const [base, quote] = [g * 1_000n * XLM, g * XLM];
      const t = launches.get(p.tok).t;
      t.send(pool, cfg.treasury, base / 2n);
      move(XLM_SAC, pool, cfg.treasury, quote / 2n);
      t.send(pool, p.tok, base / 2n);
      move(XLM_SAC, pool, p.tok, quote / 2n);
      t.notify(quote / 2n, base / 2n, [pool, lpId, lockerId, cfg.treasury]);
      return [base, quote];
    },
  });

  // ---- moments-v2: publish, collect, graduate, vest.
  const moId: string = file.contracts.momentsV2;
  const mo = l.contracts.get(moId)!;
  const policy = mo.fns.policy([], null) as Record<string, any>;
  const terms = () => ({ policy, durations: (mo.fns.config([], null) as any).durations, usdc: USDC_SAC });
  const nftAddress = (creator: string, nonce: bigint) => cid(`nft/${moId}/${creator}/${nonce}`);
  const moments = new Map<string, any>();
  const quoteCollect = (nft: string, qty: number) => {
    const M = moments.get(nft) ?? fail(10708);
    if (M.state !== 0) fail(10709);
    const r = BigInt(policy.reserve_bps);
    const requested = M.price * BigInt(qty);
    const remaining = BigInt(policy.threshold) - M.reserve;
    let [gross, reserve_in, editions] = [requested, (requested * r) / 10_000n, qty];
    const terminal = reserve_in >= remaining;
    if (terminal) {
      gross = (remaining * 10_000n + r - 1n) / r;
      reserve_in = (gross * r) / 10_000n;
      editions = Number((gross + M.price - 1n) / M.price);
    }
    return { gross, editions, entitlement: gross * 50_000n, reserve_in, creator_in: 0n, platform_in: 0n, excess: requested - gross, terminal };
  };
  const due = (M: any, account: string): [bigint, bigint] => [
    ((M.entitlements.get(account) ?? 0n) * 6_000n) / 10_000n - (M.claimed.get(account) ?? 0n),
    account === M.creator ? (1_000_000_000_000_000n * BigInt(M.alloc) / 10_000n) * 2_000n / 10_000n - M.creatorClaimed : 0n,
  ];
  Object.assign(mo.fns, {
    terms: () => terms(),
    nft_address: (a: unknown[]) => nftAddress(a[0] as string, BigInt(a[1] as bigint)),
    publish: (a: unknown[], s: string | null) => {
      const [creator, p, expected] = a as [string, Record<string, any>, unknown];
      auth(creator, s);
      assertEquals(Object.keys(p).sort(), PUBLISH_PARAMS);
      if (!SYMBOL_RULE.test(p.symbol) || (p.media_hash as Uint8Array).length !== 32) fail(10707);
      if (!sameNative(expected, terms())) fail(10702);
      if (BigInt(p.price) < BigInt(policy.min_price)) fail(10703);
      if (Number(p.creator_alloc_bps) > Number(policy.max_creator_alloc_bps)) fail(10705);
      const nft = nftAddress(creator, BigInt(p.nonce));
      if (moments.has(nft)) fail(10730);
      moments.set(nft, { creator, price: BigInt(p.price), alloc: Number(p.creator_alloc_bps), state: 0, reserve: 0n, entitlements: new Map(), claimed: new Map(), creatorClaimed: 0n });
      l.addContract(nft, { kind: "moment-nft", wasm: "moment-nft-instance", fns: {} });
      return nft;
    },
    quote: (a: unknown[]) => quoteCollect(a[0] as string, Number(a[1])),
    collect: (a: unknown[], s: string | null) => {
      const [collector, nft, qty, max] = a as [string, string, number, bigint];
      auth(collector, s);
      const q = quoteCollect(nft, Number(qty));
      if (q.gross > BigInt(max)) fail(10712);
      move(USDC_SAC, collector, moId, q.gross);
      const M = moments.get(nft);
      M.reserve += q.reserve_in;
      M.entitlements.set(collector, (M.entitlements.get(collector) ?? 0n) + q.entitlement);
      if (q.terminal) M.state = 1;
      return { first_rank: 1, editions: q.editions, gross: q.gross, entitlement: q.entitlement };
    },
    ledger: (a: unknown[]) => ({ state: (moments.get(a[0] as string) ?? fail(10708)).state }),
    get_moment: (a: unknown[]) => ({ coin: cid(`coin/${a[0]}`), creator: (moments.get(a[0] as string) ?? fail(10708)).creator }),
    graduate: (a: unknown[]) => {
      const nft = a[0] as string;
      const M = moments.get(nft) ?? fail(10708);
      if (M.state !== 1) fail(10714);
      if (opts.graduation === "failed") return failed(10, 11_003);
      M.state = 2;
      M.coin = token(cid(`coin/${nft}`), "moment-coin");
      return outcome(cid(`pair/coin/${nft}`));
    },
    claimable: (a: unknown[]) => {
      const M = moments.get(a[0] as string) ?? fail(10708);
      return M.state === 2 ? due(M, a[1] as string) : [0n, 0n];
    },
    claim: (a: unknown[], s: string | null) => {
      const [account, nft] = a as [string, string];
      auth(account, s);
      const M = moments.get(nft) ?? fail(10708);
      if (M.state !== 2) fail(10714);
      const [c, cr] = due(M, account);
      if (c === 0n && cr === 0n) fail(10715);
      M.claimed.set(account, (M.claimed.get(account) ?? 0n) + c);
      M.creatorClaimed += cr;
      M.coin.mint(account, c + cr);
      return [c, cr];
    },
  });
  return { launches, moments, growth };
}

/** A testnet-qa deployment on the in-memory ledger (Aquarius off), with the smoke's world on top. */
async function qaDeployed(opts: Parameters<typeof smokeWorld>[2] = {}) {
  const k = await kit();
  const r = await deploy(k, ["--deployment", "testnet-qa", "--aquarius", "off"]);
  assertEquals(r.code, 0, r.out);
  const file = JSON.parse(await Deno.readTextFile(`${k.deployments}/testnet-qa-v2.json`));
  const world = smokeWorld(k.ledger, file, opts);
  return { k, file, world };
}

const TX_LINE = /^ {2}(.+): ([0-9a-f]{64}) \(fee 0\.0001 XLM\)$/;

Deno.test("--smoke on testnet-qa: a launch through graduation, a harvest and both claims, a Moment through its first vest claims; each hash and fee printed", async () => {
  const { k, file } = await qaDeployed();
  try {
    const deployer = file.deployer;
    const treasury = file.roles.treasury;
    const treasuryBefore = k.ledger.accounts.get(treasury)!.xlm;
    // The dry run checks the deployment and the USDC route and sends nothing.
    const mark = k.ledger.log.length;
    const dry = await deployDefault(k, ["--deployment", "testnet-qa", "--smoke", "--dry-run"]);
    assertEquals(dry.code, 0, dry.out);
    for (const s of ["DRY RUN: nothing is sent", "✓ the deployment file is testnet-qa's", "✓ XLM → USDC depth check", "Dry run: nothing was sent."]) assertStringIncludes(dry.out, s);
    assertEquals(k.ledger.log.slice(mark).filter((l) => !l.startsWith("view")), [], "a dry run sends nothing");

    const calls = k.ledger.calls.length;
    const r = await deployDefault(k, ["--deployment", "testnet-qa", "--smoke"]);
    assertEquals(r.code, 0, r.out);
    // Every transaction: its label, hash and fee.
    const txs = r.out.split("\n").filter((l) => TX_LINE.test(l)).map((l) => l.match(TX_LINE)![1]);
    const expected = [
      /^launch SMK\d{5}$/,
      /^buy \(completes the curve\)$/,
      /^keeper graduate \(Soroswap\)$/,
      /^swap: sell 5% of the tokens on the pool$/,
      /^swap: buy with 100 XLM on the pool$/,
      /^keeper harvest$/,
      /^holder claim \(quote and token rewards\)$/,
      /^claim_protocol_fees \(to the treasury\)$/,
      /^collector trusts USDC$/,
      /^swap: 14\.3333334 USDC for at most [\d,.]+ XLM$/,
      /^publish SMM\d{5}$/,
      /^collect 14 \(terminal\)$/,
      /^keeper graduate \(Moment\)$/,
      /^collector's first vest claim$/,
      /^creator's first vest claim$/,
    ];
    assertEquals(txs.length, expected.length, txs.join("\n"));
    txs.forEach((t, i) => assertMatch(t, expected[i]));
    assertStringIncludes(r.out, `Smoke passed: 15 transactions, 0.0015 XLM in fees.`);
    // Who signed what: the creator launches and publishes, the buyer buys, swaps and claims, the QA deployer keeps.
    const by = k.ledger.calls.slice(calls).map((c) => `${c.kind}.${c.fn} ${c.source === deployer ? "keeper" : c.source}`);
    const [creator, buyer, collector] = ["creator", "buyer", "collector"].map((n) => r.out.match(new RegExp(`  ${n} +(G[A-Z2-7]{55})`))![1]);
    const who = (s: string) => s.replace(creator, "creator").replace(buyer, "buyer").replace(collector, "collector");
    assertEquals(by.map(who), [
      "launchpad-v2.launch creator",
      "launchpad-v2.buy buyer",
      "launchpad-v2.graduate keeper",
      "soroswap-router.swap_exact_tokens_for_tokens buyer",
      "soroswap-router.swap_exact_tokens_for_tokens buyer",
      "lp-locker.harvest keeper",
      "launch-token-v2.claim buyer",
      "launchpad-v2.claim_protocol_fees keeper",
      "soroswap-router.swap_tokens_for_exact_tokens collector",
      "moments-v2.publish creator",
      "moments-v2.collect collector",
      "moments-v2.graduate keeper",
      "moments-v2.claim collector",
      "moments-v2.claim creator",
    ]);
    for (const s of ["✓ completed", "✓ graduated: pool", "✓ harvested", "✓ the holder claimed", "✓ collected 14 editions for 13.3333334 USDC", "✓ the collector claimed"]) assertStringIncludes(r.out, s);
    // The treasury got the launch fee and the protocol fees, and half of the harvest's XLM.
    assert(k.ledger.accounts.get(treasury)!.xlm - treasuryBefore > 10n * XLM);
    // The throwaway accounts were funded by Friendbot; their keys were never printed.
    for (const a of [creator, buyer, collector]) assert(k.ledger.log.includes(`friendbot ${a}`));
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

Deno.test("--smoke stops at the step that fails, naming it: a recorded graduation failure; a thin USDC route stops it before the Moment", async () => {
  {
    const { k } = await qaDeployed({ graduation: "failed" });
    try {
      const r = await deployDefault(k, ["--deployment", "testnet-qa", "--smoke"]);
      assertEquals(r.code, 1);
      assertStringIncludes(r.out, "the smoke stopped: the launch's graduation recorded a failure: origin 3, code 10302");
      assertStringIncludes(r.out, "keeper graduate (Soroswap): ");
      assertFalse(r.out.includes("keeper harvest"));
      await assertNoSecrets(k);
    } finally {
      await cleanup(k);
    }
  }
  {
    // F10: the launch part runs; the Moment part stops before the collector's trustline or any USDC swap.
    const { k } = await qaDeployed({ usdc: "thin" });
    try {
      const dry = await deployDefault(k, ["--deployment", "testnet-qa", "--smoke", "--dry-run"]);
      assertEquals(dry.code, 0);
      assertStringIncludes(dry.out, "✗ XLM → USDC depth check");
      const r = await deployDefault(k, ["--deployment", "testnet-qa", "--smoke"]);
      assertEquals(r.code, 1);
      assertStringIncludes(r.out, "✗ XLM → USDC depth check");
      assertStringIncludes(r.out, "✓ the treasury");
      assertStringIncludes(r.out, "the smoke stopped: testnet XLM→USDC liquidity too thin");
      assertFalse(r.out.includes("collector trusts USDC"));
      assertFalse(k.ledger.calls.some((c) => c.kind === "moments-v2"));
    } finally {
      await cleanup(k);
    }
  }
});

Deno.test("--smoke is testnet-qa's only, and only against its own deployment and keys", async () => {
  const { k, file } = await qaDeployed();
  try {
    for (const d of ["testnet", "mainnet"]) assertEquals((await deployDefault(k, ["--deployment", d, "--smoke"])).code, 1);
    assertStringIncludes((await deployDefault(k, ["--deployment", "testnet", "--smoke"])).out, "the smoke run (--smoke, SMOKE=1) is refused for testnet");
    assertStringIncludes((await deployDefault(k, ["--deployment", "testnet-qa", "--smoke", "--generation", "2"])).out, "--smoke runs against the deployment file");
    // SMOKE=1 alone doesn't turn a deploy into a smoke.
    k.env.SMOKE = "1";
    assertStringIncludes((await deployDefault(k, ["--deployment", "testnet-qa", "--dry-run"])).out, "SMOKE=1 is set: run the smoke with --smoke");
    delete k.env.SMOKE;
    // A deployment file whose deployer isn't the QA keys' is refused before anything is sent.
    const path = `${k.deployments}/testnet-qa-v2.json`;
    await Deno.writeTextFile(path, JSON.stringify({ ...file, deployer: Keypair.random().publicKey() }));
    const mark = k.ledger.log.length;
    const other = await deployDefault(k, ["--deployment", "testnet-qa", "--smoke"]);
    assertEquals(other.code, 1);
    assertStringIncludes(other.out, "isn't the QA keys' deployer");
    assertEquals(k.ledger.log.slice(mark).filter((l) => !l.startsWith("view")), []);
    // A contract that runs another WASM than the file records is refused too.
    await Deno.writeTextFile(path, JSON.stringify({ ...file, wasmHashes: { ...file.wasmHashes, lpLocker: "ab".repeat(32) } }));
    assertStringIncludes((await deployDefault(k, ["--deployment", "testnet-qa", "--smoke", "--dry-run"])).out, `lpLocker ${file.contracts.lpLocker} runs WASM`);
    await Deno.remove(path);
    assertStringIncludes((await deployDefault(k, ["--deployment", "testnet-qa", "--smoke", "--dry-run"])).out, "run deploy-contracts-v2.ts --deployment testnet-qa first");
    await assertNoSecrets(k);
  } finally {
    await cleanup(k);
  }
});

// ------------------------------------------------------------------------------------------------ as processes, without network

/** A temporary repository holding only what the scripts read: backend/scripts, the functions' _shared modules and
 *  contracts/testdata/fixtures.json. It has no contracts/dist and no reviewed list, whatever the real checkout has
 *  (build.sh writes a git-ignored dist into it), so what the processes print doesn't depend on the checkout. */
async function scriptsRepo(): Promise<string> {
  const root = await Deno.makeTempDir({ prefix: "ct11-scripts-" });
  const copy = async (from: string, to: string) => {
    for await (const e of Deno.readDir(from)) {
      if (e.isDirectory) {
        await Deno.mkdir(`${to}/${e.name}`, { recursive: true });
        await copy(`${from}/${e.name}`, `${to}/${e.name}`);
      } else if (e.isFile) await Deno.copyFile(`${from}/${e.name}`, `${to}/${e.name}`);
    }
  };
  for (const d of ["backend/scripts", "backend/supabase/functions/_shared", "contracts/testdata"]) {
    await Deno.mkdir(`${root}/${d}`, { recursive: true });
    if (d === "contracts/testdata") await Deno.copyFile(`${repo}${d}/fixtures.json`, `${root}/${d}/fixtures.json`);
    else await copy(`${repo}${d}`, `${root}/${d}`);
  }
  return `${root}/`;
}

async function run(script: string, args: string[], env: Record<string, string>, write: string[], root = repo) {
  const cmd = new Deno.Command(Deno.execPath(), {
    args: ["run", "--allow-read", "--allow-env", `--allow-write=${write.join(",")}`, "--config", `${repo}backend/supabase/functions/deno.json`, `${root}backend/scripts/${script}`, ...args],
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
  const scripts = await scriptsRepo();
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
      // A copy of the scripts without contracts/dist and without the reviewed list: the state before a build.
      await run("deploy-contracts-v2.ts", ["--deployment", "testnet", "--dry-run", "--offline"], env, [k.secrets], scripts),
      await run("owner-v2.ts", ["sign", `${out}/2-v1-moments-set_policy.json`, "--as", "v1-admin", "--decode-only"], env, [k.secrets], scripts),
      await run("owner-v2.ts", ["keys"], { ...env, ADMIN_PUBLIC: (await rolesOf(k)).ADMIN_PUBLIC }, [k.secrets], scripts),
      await run("deploy-contracts-v2.ts", ["--deployment", "mainnet"], env, [k.secrets], scripts),
      await run("owner-v2.ts", ["keys", "--deployment", "testnet-qa"], env, [k.secrets], scripts),
      await run("admin-v2.ts", [], env, [k.secrets], scripts),
      await run("deploy-contracts-v2.ts", ["--deployment", "testnet", "--smoke", "--dry-run", "--offline"], env, [k.secrets], scripts),
    ];
    const [dry, decode, roleEnv, mainnet, qa, usage, smoke] = runs;
    assertEquals(smoke.code, 1);
    assertStringIncludes(smoke.stderr, "the smoke run (--smoke, SMOKE=1) is refused for testnet");
    assertStringIncludes(dry.stdout, "Aquarius: disabled (--aquarius off)");
    assertFalse(dry.stdout.includes("exec-aquarius"), "with Aquarius off by default, exec-aquarius is never planned");
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
    await Deno.remove(scripts, { recursive: true });
  }
});
