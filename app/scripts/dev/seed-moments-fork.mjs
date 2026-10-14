// Seeds a LOCAL anvil fork of Monad mainnet (anvil --fork-url https://rpc3.monad.xyz --chain-id 143) with Moments so
// the UI can be exercised, on a v2 Moments deployment made on that fork (script/deploy-v2.sh FORK=1 writes its record to
// contracts/deployments/pending-moments-143.json). Anvil throwaway keys only; the RPC is always 127.0.0.1.
// Usage: node scripts/dev/seed-moments-fork.mjs [record.json] [port]
//   record: the v2 Moments deployment record (default contracts/deployments/pending-moments-143.json)
//   port:   the fork's local port (default 8545)
// v2 `publish(params, expectedTermsHash)` carries the factory's current `termsHash()`, read right before each publish.
//
//        node scripts/dev/seed-moments-fork.mjs --text [port]
//   publishes on the SHIPPED cohort 4 (MomentsAddresses.monadMainnet, forked, nothing deployed) the Moments DyorKit's
//   ChainTextForkTests reads: one whose name, symbol and provenance text aren't UTF-8, and one whose name is as long as a
//   30M-gas transaction stores. The creator's key is derived at run time from a public label: fork only.
import { concat, createPublicClient, createWalletClient, encodeAbiParameters, http, keccak256, parseAbi, parseAbiParameters, parseEventLogs, toFunctionSelector, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (process.argv[2] === "--text") {
  await seedText(process.argv[3] ?? "8545");
  process.exit(0);
}

/** The --text fixture (see the usage above). `bytes` has `string`'s ABI layout, so text that isn't UTF-8 is sent as bytes
 *  under the real `publish` signature. */
async function seedText(port) {
  if (!/^[0-9]{2,5}$/.test(port)) throw new Error("the port must be a number");
  const RPC = `http://127.0.0.1:${port}`; // the local fork only, never a public RPC
  const chain = { id: 143, name: "Monad fork", nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
  const pub = createPublicClient({ chain, transport: http(RPC) });
  if (await pub.getChainId() !== 143) throw new Error("not a Monad (143) fork");
  const FACTORY = "0x95eb7F5A88B10D9dF32aC54F48C767927fa80840"; // MomentsAddresses.monadMainnet.factory (cohort 4)
  const factoryAbi = parseAbi(["function termsHash() view returns (bytes32)", "function momentCount() view returns (uint256)"]);
  const account = privateKeyToAccount(keccak256(toHex("dyorhq-chain-text-fork-creator")));
  const wallet = createWalletClient({ account, chain, transport: http(RPC) });
  await pub.request({ method: "anvil_setBalance", params: [account.address, toHex(10n ** 22n)] });
  const selector = toFunctionSelector("publish((string,string,(string,bytes32,string,uint64,string),uint256,uint16,uint32,bytes32),bytes32)");
  const layout = parseAbiParameters("(bytes,bytes,(bytes,bytes32,bytes,uint64,bytes),uint256,uint16,uint32,bytes32),bytes32");
  const MAX_GAS = 29_900_000n; // Monad's per-transaction limit is 30M
  async function publish(label, t) {
    const terms = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "termsHash" });
    const data = concat([selector, encodeAbiParameters(layout, [[t.name, t.symbol, [t.media, keccak256(t.media), t.place, 1_790_000_000n, t.animation], 100_000n, 0, 86_400,
      toHex(crypto.getRandomValues(new Uint8Array(32)))], terms])]);
    const call = { account, to: FACTORY, data };
    const gas = await pub.estimateGas(call);
    if (gas > MAX_GAS) throw new Error(`${label}: ${gas} gas is over the limit`);
    const receipt = await pub.waitForTransactionReceipt({ hash: await wallet.sendTransaction({ ...call, gas: MAX_GAS }) });
    if (receipt.status !== "success") throw new Error(`${label} reverted ${receipt.transactionHash}`);
    console.log(`published ${label} (${receipt.gasUsed} gas)`);
  }
  // 1. The coin's name and symbol and every provenance text ill-formed UTF-8, each a different way.
  await publish("text that isn't UTF-8", { name: "0x41fffefdfc5a", symbol: "0x41805a", media: "0x697066733a2f2f41c0af5a", place: "0x41e2825a", animation: "0x41eda0805a" });
  // 2. The longest name a transaction under the limit stores (about 20 KB).
  for (let length = 24_000; ; length -= 1_000) {
    if (length < 8_000) throw new Error("no name of 8 KB or more fits under the gas limit");
    try {
      await publish(`a ${length}-byte name`, { name: toHex("Long " + "n".repeat(length - 5)), symbol: toHex("LONG"), media: toHex("ipfs://" + "m".repeat(1_000)), place: toHex("Accra"), animation: toHex("") });
      break;
    } catch (error) {
      if (!/over the limit|gas|exceeds/i.test(String(error?.message ?? error))) throw error;
    }
  }
  console.log(`momentCount ${await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "momentCount" })}`);
}

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const port = process.argv[3] ?? "8545";
if (!/^[0-9]{2,5}$/.test(port)) throw new Error("the port must be a number");
const RPC = `http://127.0.0.1:${port}`; // the local fork only, never a public RPC
const abi = (name) => JSON.parse(readFileSync(`${root}/contracts/out/${name}.sol/${name}.json`, "utf8")).abi;
const dep = JSON.parse(readFileSync(process.argv[2] ?? `${root}/contracts/deployments/pending-moments-143.json`, "utf8"));
if (await createPublicClient({ transport: http(RPC) }).getChainId() !== 143) throw new Error("not a Monad (143) fork");
const chain = { id: 143, name: "Monad fork", nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
// Anvil's default accounts carry EIP-7702 delegation code on Monad mainnet (their keys are public), which makes
// ERC-721 safeMint revert for them on a fork. These are fresh throwaway keys: keccak256("dyorhq-moments-fork-wallet-N").
const keys = [
  "0x57bcbb515c0a9835560414863de2a2903e4f195eb93fa071b8d0557608ee952a", // wallet 1 (dev wallet in the preview) 0x1C4d85cF39eD9343F1cdc34ea890394Aa63D7Bd8
  "0x3470e801c46dde26c5827e7caa3e523b54f026eec2b2d0bbbae6ad2e98179270", // wallet 2 0x5829268041d941e4E5594590B8133AC0319773A5
  "0x130eadc747f9b9e2c55ec6772c90b96a89e3b2890fa0f66ebd35aba462e32dd5", // wallet 3 0x70d54A7e83E6f09312e4cc2eAc87440A109dc082
];
const wallets = keys.map((k) => createWalletClient({ account: privateKeyToAccount(k), chain, transport: http(RPC) }));
const factory = { address: dep.factory, abi: abi("MomentsFactory") };
const collect = { address: dep.collect, abi: abi("MomentCollect") };
const erc20 = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
];
const usdc = { address: dep.usdc, abi: erc20 };

async function send(wallet, req) {
  const { request } = await pub.simulateContract({ ...req, account: wallet.account });
  const hash = await wallet.writeContract(request);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("reverted " + hash);
  return receipt;
}

/** Gives `who` USDC on the fork by finding the balances mapping slot (Circle's FiatToken keeps it at slot 9) and writing it. */
async function dealUsdc(who, amount) {
  for (let slot = 0n; slot < 40n; slot++) {
    const key = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [who, slot]));
    const before = await pub.getStorageAt({ address: dep.usdc, slot: key });
    await pub.request({ method: "anvil_setStorageAt", params: [dep.usdc, key, toHex(amount, { size: 32 })] });
    const bal = await pub.readContract({ ...usdc, functionName: "balanceOf", args: [who] });
    if (bal === amount) return slot;
    await pub.request({ method: "anvil_setStorageAt", params: [dep.usdc, key, before ?? toHex(0n, { size: 32 })] });
  }
  throw new Error("USDC balance slot not found");
}

const rnd = () => toHex(crypto.getRandomValues(new Uint8Array(32)));
async function publish(wallet, o) {
  const params = {
    name: o.name,
    symbol: o.symbol,
    provenance: { mediaURI: o.media, mediaHash: keccak256(toHex(o.media)), place: o.place, date: BigInt(o.date), animationURI: o.animation ?? "" },
    price: o.price,
    creatorAllocBps: o.alloc ?? 1000,
    collectWindow: o.window ?? 30 * 86400,
    salt: rnd(),
  };
  // The terms the publish is bound to: read now, as the app reads them with the policy it shows.
  const terms = await pub.readContract({ ...factory, functionName: "termsHash" });
  const receipt = await send(wallet, { ...factory, functionName: "publish", args: [params, terms] });
  const [ev] = parseEventLogs({ abi: factory.abi, eventName: "Published", logs: receipt.logs });
  console.log(`published #${ev.args.momentId} ${o.symbol} coin=${ev.args.coin} nft=${ev.args.nft}`);
  return ev.args;
}
async function collectN(wallet, id, n, price) {
  await send(wallet, { ...usdc, functionName: "approve", args: [dep.collect, price * BigInt(n) * 2n] });
  for (let i = 0; i < n; i++) {
    const state = await pub.readContract({ ...collect, functionName: "state", args: [id] });
    if (state !== 0) break;
    await send(wallet, { ...collect, functionName: "collect", args: [id, 1n] });
  }
}

for (const w of wallets) {
  await pub.request({ method: "anvil_setBalance", params: [w.account.address, toHex(10n ** 21n)] });
  const slot = await dealUsdc(w.account.address, 1_000_000_000n); // $1,000
  console.log(`${w.account.address} funded (USDC slot ${slot})`);
}

// 1. 14 x $1 across two collectors (under a $10-threshold policy the 14th is the clamped terminal collect and it graduates).
const a = await publish(wallets[0], { name: "Sunrise over Labadi", symbol: "LABADI", place: "Labadi Beach, Accra", date: 1_779_900_000, media: "https://picsum.photos/seed/labadi/960/720", price: 1_000_000n });
await collectN(wallets[1], a.momentId, 7, 1_000_000n);
await collectN(wallets[2], a.momentId, 7, 1_000_000n);
console.log(`#${a.momentId} state=${await pub.readContract({ ...collect, functionName: "state", args: [a.momentId] })} (2 = graduated)`);
// 2. A Moment still collecting at $0.50 with a 4% creator allocation.
const b = await publish(wallets[1], { name: "Osu night market", symbol: "OSU", place: "Oxford Street, Osu", date: 1_780_100_000, media: "https://picsum.photos/seed/osu/960/720", price: 500_000n, alloc: 400 });
await collectN(wallets[2], b.momentId, 3, 500_000n);
await collectN(wallets[0], b.momentId, 2, 500_000n);
// 3. A $10 Moment: one collect is 75% of the way; a single holder can graduate it (the containment case).
const c = await publish(wallets[2], { name: "Kakum canopy walk", symbol: "KAKUM", place: "Kakum National Park", date: 1_780_200_000, media: "https://picsum.photos/seed/kakum/960/720", price: 10_000_000n, alloc: 0, window: 7 * 86400 });
await collectN(wallets[0], c.momentId, 1, 10_000_000n);
console.log(JSON.stringify({ LABADI: a.momentId.toString(), OSU: b.momentId.toString(), KAKUM: c.momentId.toString(), devWallet: wallets[0].account.address }));
