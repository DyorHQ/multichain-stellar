// Read-only monitor for the live Moments deployment: every Moment's state, money and supply invariants, straight
// from Monad mainnet. No key, no transaction. Usage: node scripts/moments-status.mjs [rpcUrl]
import { createPublicClient, formatUnits, http } from "viem";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const RPC = process.argv[2] ?? "https://rpc.monad.xyz";
const dep = JSON.parse(readFileSync(`${root}/contracts/deployments/moments-143.json`, "utf8"));
const abi = (name) => JSON.parse(readFileSync(`${root}/contracts/out/${name}.sol/${name}.json`, "utf8")).abi;
const pub = createPublicClient({ transport: http(RPC) });
const factory = { address: dep.factory, abi: abi("MomentsFactory") };
const collect = { address: dep.collect, abi: abi("MomentCollect") };
const vesting = { address: dep.vesting, abi: abi("MomentVesting") };
const graduation = { address: dep.graduation, abi: abi("MomentGraduation") };
const locker = { address: dep.locker, abi: abi("MomentLocker") };
const hook = { address: dep.hook, abi: abi("MomentFeeHook") };
const buyback = { address: dep.buyback, abi: abi("MomentBuyback") };
const erc20 = [{ type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }, { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }];
const S = 100_000_000n * 10n ** 18n;
const usd = (x) => `$${formatUnits(x, 6)}`;
const coins = (x) => `${Number(formatUnits(x, 18)).toLocaleString("en-US", { maximumFractionDigits: 3 })}`;
const STATES = ["Collecting", "GraduationPending", "Graduated", "Expired"];

const [count, paused, policy, base, gov, pending] = await Promise.all([
  pub.readContract({ ...factory, functionName: "momentCount" }),
  pub.readContract({ ...factory, functionName: "publishingPaused" }),
  pub.readContract({ ...factory, functionName: "policy" }),
  pub.readContract({ ...factory, functionName: "externalBaseURI" }),
  pub.readContract({ ...factory, functionName: "governance" }),
  pub.readContract({ ...factory, functionName: "pendingPolicyAt" }),
]);
console.log(`factory ${dep.factory} · governance ${gov} · publishing ${paused ? "PAUSED" : "open"} · externalBaseURI ${base || "(unset)"}`);
console.log(`policy: threshold ${usd(policy[0])} · minPrice ${usd(policy[1])} · split ${policy[2]}/${policy[3]}/${policy[4]} bps · maxAlloc ${policy[5]} · expiryCreator ${policy[6]} · royalty ${policy[7]} bps · platform ${policy[8]} · treasury ${policy[9]}${pending ? ` · PENDING policy applicable at ${new Date(Number(pending) * 1000).toISOString()}` : ""}`);
console.log(`moments: ${count}`);
let collectOwed = 0n;
let hookOwed = 0n;
let carrySum = 0n;
let problems = 0;
for (let id = 1n; id <= count; id++) {
  const [m, l, ents, graduated] = await Promise.all([
    pub.readContract({ ...factory, functionName: "getMoment", args: [id] }),
    pub.readContract({ ...collect, functionName: "ledger", args: [id] }),
    pub.readContract({ ...vesting, functionName: "totalEntitlement", args: [id] }),
    pub.readContract({ ...graduation, functionName: "isGraduated", args: [id] }),
  ]);
  const alloc = (S * BigInt(m.creatorAllocBps)) / 10_000n;
  const supply = await pub.readContract({ address: m.coin, abi: erc20, functionName: "totalSupply" });
  collectOwed += l.reserve + l.creatorClaimable + l.platformClaimable + l.treasuryClaimable;
  let line = `#${id} ${STATES[l.state]} coin=${m.coin} price=${usd(m.price)} reserve=${usd(l.reserve)}/${usd(m.threshold)} gross=${usd(l.totalGross)} collects=${l.collects} ents=${coins(ents)} deadline=${new Date(Number(m.deadline) * 1000).toISOString().slice(0, 16)}`;
  if (graduated) {
    const [r, liq, cA, pA, bA, carry] = await Promise.all([
      pub.readContract({ ...graduation, functionName: "record", args: [id] }),
      pub.readContract({ ...locker, functionName: "liquidityOf", args: [id] }),
      pub.readContract({ ...hook, functionName: "creatorAccrued", args: [id] }),
      pub.readContract({ ...hook, functionName: "platformAccrued", args: [id] }),
      pub.readContract({ ...hook, functionName: "buybackAccrued", args: [id] }),
      pub.readContract({ ...buyback, functionName: "carry", args: [id] }),
    ]);
    hookOwed += cA + pA + bA;
    carrySum += carry;
    const minted = await pub.readContract({ ...vesting, functionName: "totalMinted", args: [id] });
    const identity = r.poolCoins + ents + alloc === S;
    const mintedOk = supply === r.poolCoins + minted && supply <= S;
    if (!identity || !mintedOk) problems++;
    line += ` | pool=${coins(r.poolCoins)} liq=${liq}${liq > r.liquidity ? ` (+${((Number(liq - r.liquidity) / Number(r.liquidity)) * 100).toFixed(3)}%)` : ""} fees c/p/b=${usd(cA)}/${usd(pA)}/${usd(bA)} carry=${usd(carry)} | identity ${identity ? "OK" : "BROKEN"} minted ${mintedOk ? "OK" : "BROKEN"}`;
  } else {
    if (supply !== 0n) problems++;
    line += ` | coin supply ${supply === 0n ? "0 OK" : "NONZERO BEFORE GRADUATION"}`;
    if (ents + alloc > S) problems++;
  }
  console.log(line);
}
const [collectBal, hookBal, buybackBal] = await Promise.all([
  pub.readContract({ address: dep.usdc, abi: erc20, functionName: "balanceOf", args: [dep.collect] }),
  pub.readContract({ address: dep.usdc, abi: erc20, functionName: "balanceOf", args: [dep.hook] }),
  pub.readContract({ address: dep.usdc, abi: erc20, functionName: "balanceOf", args: [dep.buyback] }),
]);
const solvent = collectBal === collectOwed && hookBal === hookOwed && buybackBal === carrySum;
if (!solvent) problems++;
console.log(`USDC solvency: collect ${usd(collectBal)} vs owed ${usd(collectOwed)} · hook ${usd(hookBal)} vs owed ${usd(hookOwed)} · buyback ${usd(buybackBal)} vs carry ${usd(carrySum)} → ${solvent ? "OK" : "MISMATCH"}`);
console.log(problems === 0 ? "ALL INVARIANTS OK" : `!! ${problems} PROBLEM(S) FOUND`);
process.exit(problems === 0 ? 0 : 2);
