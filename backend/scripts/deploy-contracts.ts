// Deploys the v1 Lite contracts (the launchpad, Moments and the launch-token code the launchpad deploys) as one named
// deployment, configures them from economics.<name>.json and writes deployments/<name>.json, which the API, the
// indexer and gen-pinned.ts read (docs/DESIGN-stellar-parity.md §6.16). The live testnet's contracts stay as they are
// (owner decision O5): this is tooling for local stacks and QA (the maintainers' runbook).
//
//   (cd contracts && ./build.sh)
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/deploy-contracts.ts \
//     --deployment <testnet|testnet-qa|mainnet> [--dry-run] [--replace]
//
// Both files live in backend/supabase/functions/_shared/deployments/. economics.<name>.json maps the network's asset
// ids (networks.ts) to each contract's set_quote arguments, in base units as strings (deployments/index.ts's
// parseEconomics checks it):
//   {"launchpad": {"XLM": {"phantom": "…", "threshold": "…", "enabled": true}, …},
//    "moments": {"XLM": {"minPrice": "…", "enabled": true}, …}}
//
// Keys. testnet-qa has throwaway keys of its own in .secrets/testnet-qa-deployer.env (git-ignored, mode 600): made on
// its first run, funded by Friendbot, the QA treasury's trustlines added. Every other deployment generates nothing: it
// needs DEPLOYER_SECRET (the admin's S…, which becomes the contracts' admin and pays) and TREASURY_PUBLIC in the
// environment, set without echo (`read -rs DEPLOYER_SECRET && export DEPLOYER_SECRET`). No secret is ever printed.
//
// The preflight runs before anything is uploaded: the WASMs are built, the admin and the treasury exist, and the
// treasury trusts every enabled classic quote (USDC), since Moments pays its platform share and the launchpad its
// protocol fees in the quote asset. --dry-run runs only the preflight and reports what it found. A real run replaces
// an existing deployments/<name>.json only with --replace.
//
// SMOKE=1 also launches "Deploy Check" (CHECK), publishes a Moment and collects one edition, and records both as the
// deployment's smoke items, which the indexer never lists, each as soon as it exists. It is refused on mainnet.
// indexFromLedger is the first ledger after the configuration and any smoke test.
import {
  Address,
  Asset,
  BASE_FEE,
  Contract,
  Keypair,
  nativeToScVal,
  Operation,
  rpc,
  scValToNative,
  SorobanDataBuilder,
  StrKey,
  Transaction,
  TransactionBuilder,
  xdr,
} from "@stellar/stellar-sdk";
import { DEPLOYMENT_NETWORKS, Economics, parseEconomics } from "../supabase/functions/_shared/deployments/index.ts";
import { AssetInfo, NetworkConfig, networkByName } from "../supabase/functions/_shared/networks.ts";

const root = new URL("../../", import.meta.url).pathname;
const dist = `${root}contracts/dist`;
const folder = `${root}backend/supabase/functions/_shared/deployments`;
const QA = "testnet-qa";
const QA_KEYS = `${root}.secrets/testnet-qa-deployer.env`;
const WASM = { token: "dyor_launch_token.wasm", launchpad: "dyor_launchpad.wasm", moments: "dyor_moments.wasm" };
const ONE = 10_000_000n;
const DAY = 17_280; // ledgers
const USAGE = "usage: deploy-contracts.ts --deployment <testnet|testnet-qa|mainnet> [--dry-run] [--replace]";

function refuse(message: string, status = 1): never {
  console.error(`deploy-contracts: ${message}`);
  Deno.exit(status);
}

// ------------------------------------------------------------------------------------------------ inputs (offline)

let name = "";
let dryRun = false;
let replace = false;
for (let i = 0; i < Deno.args.length; i++) {
  const arg = Deno.args[i];
  if (arg === "--deployment" && i + 1 < Deno.args.length) name = Deno.args[++i];
  else if (arg === "--dry-run") dryRun = true;
  else if (arg === "--replace") replace = true;
  else refuse(USAGE, 2);
}
if (!name) refuse(USAGE, 2);
if (!Object.hasOwn(DEPLOYMENT_NETWORKS, name)) refuse(`unknown deployment "${name}". ${USAGE}`, 2);

const base = networkByName(DEPLOYMENT_NETWORKS[name]);
const smokeSetting = Deno.env.get("SMOKE") ?? "0";
if (smokeSetting !== "0" && smokeSetting !== "1") refuse("SMOKE is 1 (run the smoke test) or 0");
const smoke = smokeSetting === "1";
if (smoke && base.name === "mainnet") refuse("SMOKE=1 is refused on mainnet: smoke items never go on a live network");
const rpcUrl = Deno.env.get("STELLAR_RPC_URL")?.trim() || base.rpcUrl;
if (!rpcUrl) refuse(`${base.name} has no keyless RPC here: set STELLAR_RPC_URL`);
const net: NetworkConfig = { ...base, rpcUrl };

/** economics.<name>.json, checked against the network's asset registry. Anything unexpected refuses the deploy. */
async function readEconomics(): Promise<Economics & { file: string }> {
  const file = `economics.${name}.json`;
  let raw: unknown;
  try {
    raw = JSON.parse(await Deno.readTextFile(`${folder}/${file}`));
  } catch (e) {
    refuse(e instanceof Deno.errors.NotFound ? `no deployments/${file}: write ${name}'s economics first` : `${file}: ${(e as Error).message}`);
  }
  try {
    return { file, ...parseEconomics(file, raw, net) };
  } catch (e) {
    refuse((e as Error).message);
  }
}

interface Keys {
  deployer: Keypair;
  treasury: string;
  /** testnet-qa only: the QA treasury's key, which adds its trustlines. */
  treasurySigner: Keypair | null;
}

/** DEPLOYER_SECRET and TREASURY_PUBLIC from the environment: every deployment but testnet-qa. */
function keysFromEnv(): Keys {
  const secret = Deno.env.get("DEPLOYER_SECRET")?.trim() ?? "";
  const treasury = Deno.env.get("TREASURY_PUBLIC")?.trim() ?? "";
  const missing = [
    !secret && ["DEPLOYER_SECRET", "`read -rs DEPLOYER_SECRET && export DEPLOYER_SECRET`"],
    !treasury && ["TREASURY_PUBLIC", "`export TREASURY_PUBLIC=G…`"],
  ].filter((m): m is string[] => Boolean(m));
  if (missing.length) {
    refuse(`${name} generates no keys (only ${QA} does): set ${missing.map((m) => m[0]).join(" and ")} first (${missing.map((m) => m[1]).join(", ")})`);
  }
  if (!StrKey.isValidEd25519SecretSeed(secret)) refuse("DEPLOYER_SECRET isn't a Stellar secret key (S…)");
  if (!StrKey.isValidEd25519PublicKey(treasury)) refuse("TREASURY_PUBLIC isn't a Stellar account (G…)");
  return { deployer: Keypair.fromSecret(secret), treasury, treasurySigner: null };
}

/** testnet-qa's own keys, made on its first real run. Null: there are none yet (a dry run makes none). */
async function qaKeys(make: boolean): Promise<Keys | null> {
  let text: string;
  try {
    text = await Deno.readTextFile(QA_KEYS);
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
    if (!make) return null;
    const d = Keypair.random();
    const t = Keypair.random();
    await Deno.mkdir(`${root}.secrets`, { recursive: true });
    text = [
      `# Throwaway keys of the ${QA} deployment (backend/scripts/deploy-contracts.ts). Never used for anything else.`,
      `DEPLOYER_SECRET=${d.secret()}`,
      `TREASURY_PUBLIC=${t.publicKey()}`,
      `TREASURY_SECRET=${t.secret()}`,
      "",
    ].join("\n");
    await Deno.writeTextFile(QA_KEYS, text, { mode: 0o600, createNew: true });
    console.log(`new ${QA} keys: admin ${d.publicKey()}, treasury ${t.publicKey()} (secrets in .secrets/, git-ignored)`);
  }
  const value = (k: string) => text.match(new RegExp(`^${k}=(\\S+)$`, "m"))?.[1] ?? "";
  const deployer = value("DEPLOYER_SECRET");
  const treasury = value("TREASURY_SECRET");
  if (!StrKey.isValidEd25519SecretSeed(deployer) || !StrKey.isValidEd25519SecretSeed(treasury)) {
    refuse(`${QA_KEYS} lacks DEPLOYER_SECRET or TREASURY_SECRET; move it aside to make new QA keys`);
  }
  const signer = Keypair.fromSecret(treasury);
  return { deployer: Keypair.fromSecret(deployer), treasury: signer.publicKey(), treasurySigner: signer };
}

const economics = await readEconomics();
const xlmCurve = economics.launchpad.find((q) => q.asset.id === "XLM");
const xlmMoments = economics.moments.find((q) => q.asset.id === "XLM");
if (smoke && !(xlmCurve?.enabled && xlmMoments?.enabled)) refuse(`SMOKE=1 trades in XLM: enable XLM in both sections of ${economics.file}`);
const outFile = `${folder}/${name}.json`;
const recorded = await Deno.stat(outFile).then(() => true, () => false);
// The environment's keys first; testnet-qa makes its own only once nothing else refuses the run.
const envKeys = name === QA ? null : keysFromEnv();
if (recorded && !dryRun && !replace) {
  refuse(`deployments/${name}.json records a deployment already: pass --replace to deploy a new one in its place`);
}
const keys = envKeys ?? (await qaKeys(!dryRun)) ??
  refuse(`no ${QA} keys yet (.secrets/testnet-qa-deployer.env): a run without --dry-run makes them`);

const wasms = new Map<string, Uint8Array>();
for (const file of Object.values(WASM)) {
  try {
    wasms.set(file, await Deno.readFile(`${dist}/${file}`));
  } catch {
    // reported by the preflight
  }
}

// ------------------------------------------------------------------------------------------------ chain

const server = new rpc.Server(net.rpcUrl, { allowHttp: net.rpcUrl.startsWith("http://") });
const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const units = (n: bigint) => (Number(n) / Number(ONE)).toLocaleString("en-US", { maximumFractionDigits: 7 });
/** The latest ledger any of this run's transactions landed in. */
let lastLedger = 0;

/** A Horizon account, or null when it doesn't exist. */
async function account(id: string): Promise<any | null> {
  const r = await fetch(`${net.horizonUrl}/accounts/${id}`);
  if (r.status === 404) {
    await r.body?.cancel();
    return null;
  }
  if (!r.ok) refuse(`Horizon answered ${r.status} for ${id}`);
  return await r.json();
}

function trustline(acct: any, classic: string): "trusted" | "unauthorized" | "missing" {
  const [code, issuer] = classic.split(":");
  const line = (acct?.balances ?? []).find((b: any) => b.asset_code === code && b.asset_issuer === issuer);
  if (!line) return "missing";
  return line.is_authorized === false ? "unauthorized" : "trusted";
}

/** Every enabled quote asset that is a classic credit asset: the treasury needs a trustline for each. */
function classicQuotes(): AssetInfo[] {
  const enabled = [...economics.launchpad, ...economics.moments].filter((q) => q.enabled).map((q) => q.asset);
  return [...new Map(enabled.filter((a) => a.classic && a.classic !== "native").map((a) => [a.id, a])).values()];
}

async function sha256(bytes: Uint8Array): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource)));
}

/** Everything a deploy needs, checked before anything is uploaded. Reports every finding; true when all pass. */
async function preflight(): Promise<boolean> {
  let ok = true;
  const report = (passed: boolean, text: string) => {
    ok &&= passed;
    console.log(`  ${passed ? "ok  " : "FAIL"}  ${text}`);
  };
  console.log(`preflight: ${name} on ${net.name}, ${economics.file}`);
  for (const file of Object.values(WASM)) {
    const bytes = wasms.get(file);
    report(Boolean(bytes), bytes ? `${file}: ${bytes.length} B, sha256 ${await sha256(bytes)}` : `contracts/dist/${file} is missing: run (cd contracts && ./build.sh)`);
  }
  const fund = (id: string) => (net.friendbotUrl ? `: fund it first (${net.friendbotUrl}?addr=${id})` : ": fund it first");
  const admin = keys.deployer.publicKey();
  const adminAccount = await account(admin);
  const xlm = adminAccount?.balances?.find((b: any) => b.asset_type === "native")?.balance;
  report(Boolean(adminAccount), adminAccount ? `admin ${admin} exists, ${Number(xlm).toLocaleString("en-US")} XLM` : `admin ${admin} doesn't exist on ${net.name}${fund(admin)}`);
  const treasuryAccount = await account(keys.treasury);
  report(Boolean(treasuryAccount), treasuryAccount ? `treasury ${keys.treasury} exists` : `treasury ${keys.treasury} doesn't exist on ${net.name}${fund(keys.treasury)}`);
  for (const asset of classicQuotes()) {
    const state = trustline(treasuryAccount, asset.classic!);
    report(
      state === "trusted",
      state === "trusted"
        ? `the treasury trusts ${asset.id} (${asset.classic})`
        : state === "unauthorized"
        ? `the treasury's ${asset.id} trustline isn't authorized by its issuer (${asset.classic})`
        : `the treasury has no ${asset.id} trustline (${asset.classic}): add it before deploying, or ${asset.id} fees can't be paid out`,
    );
  }
  return ok;
}

async function send(tx: Transaction): Promise<rpc.Api.GetSuccessfulTransactionResponse> {
  const sent = await server.sendTransaction(tx);
  if (sent.status === "ERROR") refuse(`send failed: ${sent.errorResult?.result().switch().name}`);
  for (let i = 0; i < 40; i++) {
    const r = await server.getTransaction(sent.hash);
    if (r.status === rpc.Api.GetTransactionStatus.SUCCESS) {
      lastLedger = Math.max(lastLedger, r.ledger);
      return r as rpc.Api.GetSuccessfulTransactionResponse;
    }
    if (r.status === rpc.Api.GetTransactionStatus.FAILED) refuse(`transaction ${sent.hash} failed`);
    await new Promise((resolve) => setTimeout(resolve, 1_500));
  }
  refuse(`transaction ${sent.hash} wasn't seen in a minute`);
}

/** A Soroban transaction: simulated for its footprint and resource fee, signed, sent. */
async function submit(tx: Transaction, kp: Keypair): Promise<rpc.Api.GetSuccessfulTransactionResponse> {
  const prepared = await server.prepareTransaction(tx);
  prepared.sign(kp);
  return await send(prepared);
}

async function build(kp: Keypair, op: xdr.Operation, data?: xdr.SorobanTransactionData) {
  const builder = new TransactionBuilder(await server.getAccount(kp.publicKey()), { fee: BASE_FEE, networkPassphrase: net.passphrase });
  if (data) builder.setSorobanData(data);
  return builder.addOperation(op).setTimeout(120).build();
}

async function friendbot(id: string) {
  const r = await fetch(`${net.friendbotUrl}?addr=${id}`);
  if (!r.ok && !/already funded|createAccountAlreadyExist/.test(await r.text())) refuse(`Friendbot didn't fund ${id}`);
}

/** testnet-qa: funds the QA admin and treasury where they don't exist, and adds the treasury's missing trustlines. */
async function readyQa() {
  for (const id of [keys.deployer.publicKey(), keys.treasury]) {
    if (!(await account(id))) {
      await friendbot(id);
      console.log(`funded ${id} with Friendbot`);
    }
  }
  const treasury = await account(keys.treasury);
  const missing = classicQuotes().filter((a) => trustline(treasury, a.classic!) === "missing");
  if (!missing.length) return;
  const signer = keys.treasurySigner!;
  const builder = new TransactionBuilder(await server.getAccount(signer.publicKey()), { fee: BASE_FEE, networkPassphrase: net.passphrase });
  for (const a of missing) {
    const [code, issuer] = a.classic!.split(":");
    builder.addOperation(Operation.changeTrust({ asset: new Asset(code, issuer) }));
  }
  const tx = builder.setTimeout(120).build();
  tx.sign(signer);
  await send(tx);
  console.log(`the ${QA} treasury trusts ${missing.map((a) => a.id).join(", ")} now`);
}

async function upload(file: string): Promise<Uint8Array> {
  const wasm = wasms.get(file)!;
  const r = await submit(await build(keys.deployer, Operation.uploadContractWasm({ wasm })), keys.deployer);
  const hash = scValToNative(r.returnValue!) as Uint8Array;
  console.log(`uploaded ${file} (${wasm.length} B), hash ${hex(hash)}`);
  return hash;
}

/** Creates a contract from uploaded code: its id and the ledger it was created in. */
async function create(wasmHash: Uint8Array, args: xdr.ScVal[]): Promise<{ id: string; ledger: number }> {
  const op = Operation.createCustomContract({
    address: new Address(keys.deployer.publicKey()),
    wasmHash: wasmHash as any,
    salt: crypto.getRandomValues(new Uint8Array(32)) as any,
    constructorArgs: args,
  });
  const r = await submit(await build(keys.deployer, op), keys.deployer);
  return { id: Address.fromScVal(r.returnValue!).toString(), ledger: r.ledger };
}

async function call(contract: string, fn: string, args: xdr.ScVal[]) {
  const r = await submit(await build(keys.deployer, new Contract(contract).call(fn, ...args)), keys.deployer);
  return r.returnValue ? scValToNative(r.returnValue) : undefined;
}

/** New entries start at the network's minimum TTL (7 days on testnet). The instances and the three codes are
 *  extended now, paid by the admin; the keeper takes over from here and never charges a user for it. */
async function extendTtl(contracts: string[], codes: Uint8Array[], days: number) {
  const keysToExtend = [
    ...contracts.map((c) =>
      xdr.LedgerKey.contractData(
        new xdr.LedgerKeyContractData({
          contract: new Address(c).toScAddress(),
          key: xdr.ScVal.scvLedgerKeyContractInstance(),
          durability: xdr.ContractDataDurability.persistent(),
        }),
      )
    ),
    ...codes.map((hash) => xdr.LedgerKey.contractCode(new xdr.LedgerKeyContractCode({ hash: hash as any }))),
  ];
  const op = Operation.extendFootprintTtl({ extendTo: days * DAY });
  const r = await submit(await build(keys.deployer, op, new SorobanDataBuilder().setReadOnly(keysToExtend).build()), keys.deployer);
  const fee = BigInt(r.resultXdr.feeCharged().toString());
  console.log(`extended ${keysToExtend.length} entries to ${days} days, fee ${units(fee)} XLM`);
}

const a = (s: string) => new Address(s).toScVal();
const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const text = (s: string) => nativeToScVal(s, { type: "string" });

if (name === QA && !dryRun) await readyQa();
const passed = await preflight();
if (dryRun) {
  if (name === QA) console.log(`a real run first funds the ${QA} accounts that don't exist and adds the treasury's trustlines`);
  if (recorded) console.log(`a real run replaces deployments/${name}.json, and needs --replace for it`);
  console.log(`dry run: the preflight ${passed ? "passed" : "failed"}; nothing was deployed`);
  Deno.exit(passed ? 0 : 1);
}
if (!passed) refuse("the preflight failed; nothing was uploaded");

// ------------------------------------------------------------------------------------------------ deploy

const admin = keys.deployer.publicKey();
const tokenHash = await upload(WASM.token);
const padHash = await upload(WASM.launchpad);
const momHash = await upload(WASM.moments);

const pad = await create(padHash, [a(admin), a(keys.treasury), xdr.ScVal.scvBytes(tokenHash as any), a(net.contracts.soroswapFactory)]);
console.log("launchpad", pad.id);
for (const q of economics.launchpad) {
  await call(pad.id, "set_quote", [a(q.asset.contract), i128(q.phantom), i128(q.threshold), xdr.ScVal.scvBool(q.enabled)]);
  console.log(`  ${q.asset.id}: phantom ${units(q.phantom)}, threshold ${units(q.threshold)}${q.enabled ? "" : " (disabled)"}`);
}
const moments = await create(momHash, [a(admin), a(keys.treasury)]);
console.log("moments", moments.id);
for (const q of economics.moments) {
  await call(moments.id, "set_quote", [a(q.asset.contract), i128(q.minPrice), xdr.ScVal.scvBool(q.enabled)]);
  console.log(`  ${q.asset.id}: minimum price ${units(q.minPrice)}${q.enabled ? "" : " (disabled)"}`);
}
await extendTtl([pad.id, moments.id], [tokenHash, padHash, momHash], 30);

const deployment = {
  network: net.name,
  launchpad: pad.id,
  moments: moments.id,
  launchTokenWasmHash: hex(tokenHash),
  launchpadWasmHash: hex(padHash),
  momentsWasmHash: hex(momHash),
  admin,
  treasury: keys.treasury,
  deployLedger: pad.ledger,
  deployedAt: new Date().toISOString(),
  indexFromLedger: lastLedger + 1,
  smoke: { launches: [] as string[], moments: [] as number[] },
};
const save = async (what: string) => {
  await Deno.writeTextFile(outFile, JSON.stringify(deployment, null, 2) + "\n");
  console.log(`wrote deployments/${name}.json: ${what}`);
};
await save(`index from ledger ${deployment.indexFromLedger}`);

// ------------------------------------------------------------------------------------------------ smoke test

// Each smoke item is recorded as soon as it exists: a smoke test that stops half-way, after its launch or its publish,
// still leaves nothing in the deployment that the indexer would list.
if (smoke) {
  const xlm = net.assets.find((x) => x.id === "XLM")!.contract;
  const token = String(await call(pad.id, "launch", [a(admin), a(xlm), text("Deploy Check"), text("CHECK"), text(""), u32(0), i128(10n * ONE), i128(0n)]));
  deployment.smoke.launches.push(token);
  await save(`smoke launch ${token}`);
  const curve = await call(pad.id, "get_curve", [a(token)]);
  console.log("smoke: launched", token, "real_quote", String(curve.real_quote));
  const price = xlmMoments!.minPrice > ONE ? xlmMoments!.minPrice : ONE;
  // Not a URL: the indexer reads metadata only from DyorHQ's storage, and a smoke Moment has none.
  const id = Number(await call(moments.id, "publish", [a(admin), text("urn:dyorhq:deploy-check"), i128(price), a(xlm), u32(0), nativeToScVal(3_600n, { type: "u64" })]));
  deployment.smoke.moments.push(id);
  await save(`smoke Moment ${id}`);
  const first = await call(moments.id, "collect", [a(admin), u32(id), u32(1), i128(price)]);
  console.log("smoke: Moment", id, "collected edition", first, "owner", await call(moments.id, "owner_of", [u32(Number(first))]));
  deployment.indexFromLedger = lastLedger + 1;
  await save(`index from ledger ${deployment.indexFromLedger}, after the smoke test`);
}

const pin = ({ testnet: "Testnet", [QA]: "TestnetQA" } as Record<string, string>)[name];
console.log(
  pin
    ? `next: SPONSOR_PUBLIC=G… deno run -A --config backend/supabase/functions/deno.json backend/scripts/gen-pinned.ts --deployment ${name}, ` +
      `then commit deployments/${name}.json and PinnedContracts+${pin}.swift`
    : `next: deployments/index.ts and gen-pinned.ts take deployments/${name}.json once the ${name} program wires it in`,
);
