// Read-only inventory of spot pools on Monad mainnet for the core pairs (Uniswap v3/v4 and Monday Trade).
// Usage: node scripts/dev/pool-inventory.mjs
import { createPublicClient, http, parseAbi, keccak256, encodeAbiParameters, formatUnits } from "viem";
import { monad } from "viem/chains";
const pc = createPublicClient({ chain: monad, transport: http("https://rpc.monad.xyz", { batch: true }), batch: { multicall: true } });
const factoryAbi = parseAbi(["function getPool(address,address,uint24) view returns (address)"]);
const poolAbi = parseAbi(["function liquidity() view returns (uint128)"]);
const quoterAbi = parseAbi(["function quoteExactInputSingle((address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96) params) view returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)"]);
const stateViewAbi = parseAbi(["function getLiquidity(bytes32) view returns (uint128)"]);
const v4QuoterAbi = parseAbi(["struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }", "struct QuoteExactSingleParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }", "function quoteExactInputSingle(QuoteExactSingleParams params) view returns (uint256 amountOut, uint256 gasEstimate)"]);
const T = { WMON: "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A", USDC: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", USDT0: "0xe7cd86e13AC4309349F30B3435a9d337750fC82D", WETH: "0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242", WBTC: "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c", gMON: "0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081" };
const Z = "0x0000000000000000000000000000000000000000";
const venues = { uniswap: { factory: "0x204faca1764b154221e35c0d20abb3c525710498", tiers: [100, 500, 3000, 10000] }, monday: { factory: "0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21", tiers: [100, 300, 500, 3000, 10000] } };
const pairs = [["WMON", "USDC"], ["WMON", "USDT0"], ["WMON", "WETH"], ["WMON", "WBTC"], ["WETH", "USDC"], ["WBTC", "USDC"], ["USDT0", "USDC"], ["WMON", "gMON"]];
for (const [vname, v] of Object.entries(venues)) {
  const calls = pairs.flatMap(([a, b]) => v.tiers.map((fee) => ({ address: v.factory, abi: factoryAbi, functionName: "getPool", args: [T[a], T[b], fee] })));
  const pools = await pc.multicall({ contracts: calls, allowFailure: false });
  const liqCalls = pools.map((p) => ({ address: p, abi: poolAbi, functionName: "liquidity" }));
  const liqs = await pc.multicall({ contracts: liqCalls, allowFailure: true });
  let i = 0;
  for (const [a, b] of pairs) { const parts = []; for (const fee of v.tiers) { const p = pools[i]; const l = liqs[i]; i++; if (p !== Z) parts.push(`${fee}${l.status === "success" && l.result > 0n ? "*" : ""}`); } console.log(`${vname.padEnd(8)} ${(a + "/" + b).padEnd(11)} tiers: ${parts.join(" ") || "-"}   (* = has liquidity)`); }
}
console.log("--- v4 hookless pools with native MON ---");
const v4Tiers = [[100, 1], [500, 10], [3000, 60], [10000, 200]];
for (const q of ["USDC", "USDT0", "WETH", "WBTC", "gMON"]) {
  const ids = v4Tiers.map(([fee, ts]) => keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }], [Z, T[q], fee, ts, Z])));
  const liq = await pc.multicall({ contracts: ids.map((id) => ({ address: "0x77395f3b2e73ae90843717371294fa97cc419d64", abi: stateViewAbi, functionName: "getLiquidity", args: [id] })), allowFailure: false });
  console.log(`MON/${q}`.padEnd(11), v4Tiers.map(([fee], k) => `${fee}${liq[k] > 0n ? "*" : ""}`).join(" "));
}
console.log("--- sample quotes for 100 MON -> USDC ---");
const amt = 100n * 10n ** 18n;
const [u] = await pc.multicall({ contracts: [{ address: "0x661e93cca42afacb172121ef892830ca3b70f08d", abi: quoterAbi, functionName: "quoteExactInputSingle", args: [{ tokenIn: T.WMON, tokenOut: T.USDC, amountIn: amt, fee: 500, sqrtPriceLimitX96: 0n }] }], allowFailure: false });
const [m] = await pc.multicall({ contracts: [{ address: "0xB97eCD41Aef0F842E773C8F9905919cDE49880C9", abi: quoterAbi, functionName: "quoteExactInputSingle", args: [{ tokenIn: T.WMON, tokenOut: T.USDC, amountIn: amt, fee: 500, sqrtPriceLimitX96: 0n }] }], allowFailure: false });
const [v4] = await pc.multicall({ contracts: [{ address: "0xa222dd357a9076d1091ed6aa2e16c9742dd26891", abi: v4QuoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey: { currency0: Z, currency1: T.USDC, fee: 500, tickSpacing: 10, hooks: Z }, zeroForOne: true, exactAmount: amt, hookData: "0x" }] }], allowFailure: false });
console.log("uniswap v3 (500):", formatUnits(u[0], 6), "USDC  gas", u[3].toString());
console.log("monday    (500):", formatUnits(m[0], 6), "USDC  gas", m[3].toString());
console.log("uniswap v4 (500):", formatUnits(v4[0], 6), "USDC  gas", v4[1].toString());
