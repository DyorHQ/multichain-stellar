// Deploys the Lite contracts to Stellar testnet, configures them, smoke-tests them and writes
// backend/supabase/functions/_shared/deployments/testnet.json (the API and the app read contract ids from it).
//
//   cd contracts && ./build.sh
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/deploy-contracts.ts
//
// Keys: DEPLOYER_SECRET (becomes admin) and TREASURY_PUBLIC from the environment, or, on testnet only, fresh ones
// funded by Friendbot and saved to .secrets/testnet-deployer.env (git-ignored). Run again after every testnet reset.
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
  Transaction,
  TransactionBuilder,
  xdr,
} from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";
import { keepAlive } from "../supabase/functions/_shared/ttl.ts";

const net = TESTNET;
const server = new rpc.Server(net.rpcUrl);
const root = new URL("../../", import.meta.url).pathname;
const dist = `${root}contracts/dist`;
const outFile = `${root}backend/supabase/functions/_shared/deployments/testnet.json`;
const ONE = 10_000_000n;

async function friendbot(pub: string) {
  const r = await fetch(`${net.friendbotUrl}?addr=${pub}`);
  if (!r.ok && !/already funded|createAccountAlreadyExist/.test(await r.text())) throw new Error(`friendbot failed for ${pub}`);
}

async function keys(): Promise<{ deployer: Keypair; treasury: string }> {
  const secretFile = `${root}.secrets/testnet-deployer.env`;
  let deployerSecret = Deno.env.get("DEPLOYER_SECRET");
  let treasury = Deno.env.get("TREASURY_PUBLIC");
  if (!deployerSecret) {
    try {
      const text = await Deno.readTextFile(secretFile);
      deployerSecret = text.match(/DEPLOYER_SECRET=(\S+)/)?.[1];
      treasury = treasury ?? text.match(/TREASURY_PUBLIC=(\S+)/)?.[1];
    } catch { /* first run */ }
  }
  if (!deployerSecret) {
    const d = Keypair.random();
    const t = Keypair.random();
    await Deno.mkdir(`${root}.secrets`, { recursive: true });
    await Deno.writeTextFile(secretFile, `DEPLOYER_SECRET=${d.secret()}\nTREASURY_PUBLIC=${t.publicKey()}\nTREASURY_SECRET=${t.secret()}\n`, { mode: 0o600 });
    deployerSecret = d.secret();
    treasury = t.publicKey();
    console.log("new testnet deployer", d.publicKey(), "treasury", treasury, "(secrets in .secrets/, git-ignored)");
  }
  const deployer = Keypair.fromSecret(deployerSecret);
  await friendbot(deployer.publicKey());
  await friendbot(treasury!);
  // Treasury needs USDC trust to receive USDC fees (testnet convenience; mainnet treasury is a managed account).
  return { deployer, treasury: treasury! };
}

async function submit(tx: Transaction, kp: Keypair): Promise<rpc.Api.GetSuccessfulTransactionResponse> {
  const prepared = await server.prepareTransaction(tx);
  prepared.sign(kp);
  const sent = await server.sendTransaction(prepared);
  if (sent.status === "ERROR") throw new Error(`send failed: ${sent.errorResult?.result().switch().name}`);
  for (let i = 0; i < 40; i++) {
    const r = await server.getTransaction(sent.hash);
    if (r.status === rpc.Api.GetTransactionStatus.SUCCESS) return r as rpc.Api.GetSuccessfulTransactionResponse;
    if (r.status === rpc.Api.GetTransactionStatus.FAILED) throw new Error(`tx failed ${sent.hash}`);
    await new Promise((r) => setTimeout(r, 1_500));
  }
  throw new Error(`tx not seen ${sent.hash}`);
}

async function build(kp: Keypair, op: xdr.Operation) {
  const acct = await server.getAccount(kp.publicKey());
  return new TransactionBuilder(acct, { fee: BASE_FEE, networkPassphrase: net.passphrase }).addOperation(op).setTimeout(120).build();
}

async function upload(kp: Keypair, file: string): Promise<Uint8Array> {
  const wasm = await Deno.readFile(`${dist}/${file}`);
  const r = await submit(await build(kp, Operation.uploadContractWasm({ wasm })), kp);
  const hash = scValToNative(r.returnValue!) as Uint8Array;
  console.log(`uploaded ${file} (${wasm.length} B) hash ${Array.from(hash, (b) => b.toString(16).padStart(2, "0")).join("")}`);
  return hash;
}

async function deploy(kp: Keypair, wasmHash: Uint8Array, args: xdr.ScVal[]): Promise<string> {
  const op = Operation.createCustomContract({
    address: new Address(kp.publicKey()),
    wasmHash: wasmHash as any,
    salt: crypto.getRandomValues(new Uint8Array(32)) as any,
    constructorArgs: args,
  });
  const r = await submit(await build(kp, op), kp);
  return Address.fromScVal(r.returnValue!).toString();
}

async function call(kp: Keypair, contract: string, fn: string, args: xdr.ScVal[]) {
  const r = await submit(await build(kp, new Contract(contract).call(fn, ...args)), kp);
  return r.returnValue ? scValToNative(r.returnValue) : undefined;
}

const a = (s: string) => new Address(s).toScVal();
const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });

const { deployer, treasury } = await keys();
const admin = deployer.publicKey();
const xlm = net.assets.find((x) => x.id === "XLM")!.contract;
const usdc = net.assets.find((x) => x.id === "USDC")!.contract;

const tokenHash = await upload(deployer, "dyor_launch_token.wasm");
const padHash = await upload(deployer, "dyor_launchpad.wasm");
const momHash = await upload(deployer, "dyor_moments.wasm");

const launchpad = await deploy(deployer, padHash, [a(admin), a(treasury), xdr.ScVal.scvBytes(tokenHash as any), a(net.contracts.soroswapFactory)]);
console.log("launchpad", launchpad);
// Testnet economics: launch FDV ≈ 2,000 XLM or 200 USDC of phantom liquidity, graduation at phantom · (√10 − 1),
// so one tester's Friendbot XLM can take a launch all the way to Soroswap.
const mulSqrt10 = (p: bigint) => (p * 216_227_766n) / 100_000_000n;
await call(deployer, launchpad, "set_quote", [a(xlm), i128(2_000n * ONE), i128(mulSqrt10(2_000n * ONE)), xdr.ScVal.scvBool(true)]);
await call(deployer, launchpad, "set_quote", [a(usdc), i128(200n * ONE), i128(mulSqrt10(200n * ONE)), xdr.ScVal.scvBool(true)]);

const moments = await deploy(deployer, momHash, [a(admin), a(treasury)]);
console.log("moments", moments);
await call(deployer, moments, "set_quote", [a(xlm), i128(ONE / 10n), xdr.ScVal.scvBool(true)]);
await call(deployer, moments, "set_quote", [a(usdc), i128(ONE / 10n), xdr.ScVal.scvBool(true)]);

// New entries start at the network minimum TTL (7 days on testnet). Extend the instances and WASM now, paid by the
// deployer; the indexer's keeper takes over from here (and never charges a user for it).
const ttl = await keepAlive([launchpad, moments], [Array.from(tokenHash, (b) => b.toString(16).padStart(2, "0")).join("")], 31, 30, deployer);
console.log(`extended ${ttl.extended} entries to 30 days, fee ${Number(ttl.fee) / 1e7} XLM`);

const latest = await server.getLatestLedger();
const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const deployment = {
  network: "testnet",
  launchpad,
  moments,
  launchTokenWasmHash: hex(tokenHash),
  launchpadWasmHash: hex(padHash),
  momentsWasmHash: hex(momHash),
  admin,
  treasury,
  deployLedger: latest.sequence - 50,
  deployedAt: new Date().toISOString(),
};
await Deno.writeTextFile(outFile, JSON.stringify(deployment, null, 2) + "\n");
console.log("wrote", outFile);

// ------------------------------------------------------------------------------------------------ smoke test
if (Deno.env.get("SKIP_SMOKE") !== "1") {
  const token = await call(deployer, launchpad, "launch", [
    a(admin), a(xlm), nativeToScVal("Deploy Check", { type: "string" }), nativeToScVal("CHECK", { type: "string" }),
    nativeToScVal("", { type: "string" }), nativeToScVal(0, { type: "u32" }), i128(10n * ONE), i128(0n),
  ]);
  const curve = await call(deployer, launchpad, "get_curve", [a(String(token))]);
  console.log("smoke: launched", token, "real_quote", String(curve.real_quote));
  const id = await call(deployer, moments, "publish", [
    a(admin), nativeToScVal("https://example.invalid/deploy-check.json", { type: "string" }), i128(ONE), a(xlm),
    nativeToScVal(0, { type: "u32" }), nativeToScVal(3_600n, { type: "u64" }),
  ]);
  const first = await call(deployer, moments, "collect", [a(admin), nativeToScVal(Number(id), { type: "u32" }), nativeToScVal(1, { type: "u32" }), i128(ONE)]);
  console.log("smoke: moment", id, "collected token", first, "owner", await call(deployer, moments, "owner_of", [nativeToScVal(Number(first), { type: "u32" })]));
}
void Asset;
