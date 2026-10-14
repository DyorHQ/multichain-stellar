// Seeds a LOCAL anvil fork (anvil --fork-url https://rpc.monad.xyz) with launches so the UI can be exercised.
// Usage: node scripts/dev/seed-fork.mjs <record.json> [port]   (after deploying to the fork, e.g. the v2 launchpad's
//   contracts/deployments/pending-143.json; the RPC is always 127.0.0.1, on `port`, default 8545)
//
//        node scripts/dev/seed-fork.mjs --text [port]
//   seeds the SHIPPED v2 launchpad (LaunchpadAddresses.monadMainnet, forked, nothing deployed) with the launches
//   DyorKit's ChainTextForkTests reads: one whose every text field isn't UTF-8, and one whose description is as long as
//   a 30M-gas transaction stores. The launcher's key is derived at run time from a public label and funded with
//   anvil_setBalance: fork only.
import { concat, createPublicClient, createWalletClient, encodeAbiParameters, http, keccak256, parseAbi, parseAbiParameters, parseEther, parseEventLogs, formatEther, toFunctionSelector, toHex, zeroAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";

if (process.argv[2] === "--text") {
  await seedText(process.argv[3] ?? "8545");
  process.exit(0);
}

/** The --text fixture (see the usage above). `bytes` has `string`'s ABI layout, so text that isn't UTF-8 is sent as bytes
 *  under the real `launchToken` signature. */
async function seedText(port) {
  if (!/^[0-9]{2,5}$/.test(port)) throw new Error("the port must be a number");
  const RPC = `http://127.0.0.1:${port}`; // the local fork only, never a public RPC
  const chain = { id: 143, name: "Monad fork", nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
  const pub = createPublicClient({ chain, transport: http(RPC) });
  if (await pub.getChainId() !== 143) throw new Error("not a Monad (143) fork");
  const FACTORY = "0x3B1f5f562f5F61B980aBfDDbebD6cdF9a73b0b5b"; // LaunchpadAddresses.monadMainnet.factory
  const factoryAbi = parseAbi(["function launchFee() view returns (uint256)", "function launchCount() view returns (uint256)",
    "function previewLaunchEconomics(uint256 configId, address pairToken) view returns (bytes32)"]);
  const account = privateKeyToAccount(keccak256(toHex("dyorhq-chain-text-fork-launcher")));
  const wallet = createWalletClient({ account, chain, transport: http(RPC) });
  await pub.request({ method: "anvil_setBalance", params: [account.address, toHex(parseEther("100000"))] });
  const fee = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "launchFee" });
  const economics = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "previewLaunchEconomics", args: [0n, zeroAddress] });
  const selector = toFunctionSelector("launchToken((string,string,string,string,(string,string,string,string,string),address,uint16,bool,uint8,bytes32,bytes32),uint256,address,address[])");
  const layout = parseAbiParameters("(bytes,bytes,bytes,bytes,(bytes,bytes,bytes,bytes,bytes),address,uint16,bool,uint8,bytes32,bytes32),uint256,address,address[]");
  const MAX_GAS = 29_900_000n; // Monad's per-transaction limit is 30M
  const data = (t) => concat([selector, encodeAbiParameters(layout, [[t.name, t.symbol, t.logo, t.description, t.links, account.address, 0, false, 0, economics,
    toHex(crypto.getRandomValues(new Uint8Array(32)))], 0n, zeroAddress, []])]);
  async function launch(label, t) {
    const call = { account, to: FACTORY, data: data(t), value: fee };
    const gas = await pub.estimateGas(call);
    if (gas > MAX_GAS) throw new Error(`${label}: ${gas} gas is over the limit`);
    const receipt = await pub.waitForTransactionReceipt({ hash: await wallet.sendTransaction({ ...call, gas: MAX_GAS }) });
    if (receipt.status !== "success") throw new Error(`${label} reverted ${receipt.transactionHash}`);
    console.log(`launched ${label} (${receipt.gasUsed} gas)`);
  }
  const text = (s) => toHex(s);
  // 1. Every text field ill-formed UTF-8, each a different way: overlong, truncated, a surrogate, past U+10FFFF, bytes
  //    that never occur in UTF-8, a lone continuation byte.
  await launch("text that isn't UTF-8", {
    name: "0x426164c0af21", symbol: "0xfffe", logo: "0x4180" + "5a", description: "0x41eda080" + "5a",
    links: ["0x41f4908080" + "5a", "0x41e282" + "5a", "0x41c3" + "5a", "0x41f09f98" + "5a", "0x41bf80bf" + "5a"],
  });
  // 2. The longest description a transaction under the limit stores (about 40 KB on the fork's gas prices).
  for (let length = 44_000; ; length -= 2_000) {
    if (length < 20_000) throw new Error("no description of 20 KB or more fits under the gas limit");
    const t = { name: text("Long Story"), symbol: text("LONG"), logo: text(""), description: text("d".repeat(length)), links: ["", "", "", "", ""].map(text) };
    try {
      await launch(`a ${length}-byte description`, t);
      break;
    } catch (error) {
      if (!/over the limit|gas|exceeds/i.test(String(error?.message ?? error))) throw error;
    }
  }
  console.log(`launchCount ${await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "launchCount" })}`);
}

const port = process.argv[3] ?? "8545";
if (!/^[0-9]{2,5}$/.test(port)) throw new Error("the port must be a number");
const RPC = `http://127.0.0.1:${port}`; // the local fork only, never a public RPC
if (!process.argv[2]) throw new Error("usage: node scripts/dev/seed-fork.mjs <record.json> [port]");
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const abi = (name) => JSON.parse(readFileSync(`${root}/contracts/out/${name}.sol/${name}.json`, "utf8")).abi;
const dep = JSON.parse(readFileSync(process.argv[2], "utf8"));
const chain = { id: 143, name: "Monad fork", nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const keys = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // anvil #0 (owner)
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // anvil #1
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // anvil #2
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // anvil #3
];
const wallets = keys.map((k) => createWalletClient({ account: privateKeyToAccount(k), chain, transport: http(RPC) }));
const factory = { address: dep.factory, abi: abi("LaunchpadFactory") };
const router = { address: dep.launchAndBuyRouter, abi: abi("LaunchAndBuyRouter") };
const curveAbi = abi("BondingCurve");
const fee = await pub.readContract({ ...factory, functionName: "launchFee" });
const economics = await pub.readContract({ ...factory, functionName: "previewLaunchEconomics", args: [0n, "0x0000000000000000000000000000000000000000"] });
const rnd = () => toHex(crypto.getRandomValues(new Uint8Array(32)));
const params = (o) => ({ name: o.name, symbol: o.symbol, logo: o.logo ?? "", description: o.description ?? "", socials: { twitter: o.twitter ?? "", telegram: "", discord: "", website: "", farcaster: "" }, creatorFeeRecipient: o.creator, creatorTaxBps: o.tax ?? 0, holderFeeSharing: o.sharing ?? true, expectedEconomics: economics, salt: rnd() });
async function send(wallet, req) {
  const { request } = await pub.simulateContract({ ...req, account: wallet.account });
  const hash = await wallet.writeContract(request);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("reverted " + hash);
  return receipt;
}
async function launch(wallet, o, devBuy = 0n) {
  const receipt = devBuy > 0n
    ? await send(wallet, { ...router, functionName: "launchAndBuy", args: [params(o), 0n, "0x0000000000000000000000000000000000000000", devBuy, 0n, wallet.account.address, []], value: fee + devBuy })
    : await send(wallet, { ...factory, functionName: "launchToken", args: [params(o), 0n, "0x0000000000000000000000000000000000000000", []], value: fee });
  const [ev] = parseEventLogs({ abi: factory.abi, eventName: "TokenLaunched", logs: receipt.logs });
  console.log(`launched ${o.symbol} token=${ev.args.token} curve=${ev.args.curve}`);
  return ev.args;
}
const buy = (wallet, curve, amount) => send(wallet, { address: curve, abi: curveAbi, functionName: "buy", args: [amount, 0n, wallet.account.address], value: amount });

// 1. A launch with a developer buy and holder fee sharing.
const a = await launch(wallets[1], { name: "Jensen's Jacket", symbol: "JENSEN", description: "Blackwell demand keeps surprising. A meme for everyone betting on the AI supercycle.", logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/2/21/Nvidia_logo.svg/512px-Nvidia_logo.svg.png", twitter: "https://x.com/nvidia", creator: wallets[1].account.address }, parseEther("25"));
await pub.request({ method: "evm_increaseTime", params: [10] }); await pub.request({ method: "evm_mine", params: [] });
await buy(wallets[2], a.curve, parseEther("1500"));
await buy(wallets[3], a.curve, parseEther("2200"));
// 2. A creator-tax launch without sharing and without a dev buy.
const b = await launch(wallets[2], { name: "Purple Lambo", symbol: "PURPLE", description: "The fastest chain deserves the fastest car. Fair launch, no team allocation.", creator: wallets[2].account.address, tax: 200, sharing: false });
await pub.request({ method: "evm_increaseTime", params: [10] }); await pub.request({ method: "evm_mine", params: [] });
await buy(wallets[3], b.curve, parseEther("400"));
// 3. A launch that graduates into the real (forked) Uniswap v4 PoolManager.
const c = await launch(wallets[3], { name: "Monad Maxi", symbol: "MAXI", description: "Graduated on day one. Liquidity locked in Uniswap v4 forever.", creator: wallets[3].account.address });
await pub.request({ method: "evm_increaseTime", params: [10] }); await pub.request({ method: "evm_mine", params: [] });
await pub.request({ method: "anvil_setBalance", params: [wallets[1].account.address, toHex(parseEther("50000"))] });
await buy(wallets[1], c.curve, parseEther("9000"));
await buy(wallets[2], c.curve, parseEther("8000"));
const rec = await pub.readContract({ ...factory, functionName: "getLaunchedToken", args: [c.token] });
console.log(`MAXI phase=${rec.phase} poolId=${rec.poolId} sweptQuote=${formatEther(rec.sweptQuote)} MON`);
console.log(JSON.stringify({ JENSEN: a.token, PURPLE: b.token, MAXI: c.token }));
