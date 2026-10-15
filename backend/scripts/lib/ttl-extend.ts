// The deploy's TTL step (CT-11a L-g; docs/DESIGN-stellar-contracts-v2.md §13): extends contract instances and WASMs
// to a number of days with ExtendFootprintTTL (permissionless), paid by the deployer, through the kit's Chain.
//
// Why not _shared/ttl.ts keepAlive, which the functions' keeper uses: it extends up to 20 entries in one transaction,
// and a transaction's fee is a uint32, at most 429.4967295 XLM. Testnet's rent on 2026-10-15 is about 0.08 XLM per KB
// of WASM a day (launchpad-v2's 90 KB: about 7.4 XLM a day), so v2's WASMs together (about 24 XLM a day) can't gain
// even 30 days in one transaction, and launchpad-v2 alone can't gain 179 days (about 1,270 XLM). So here instances go
// together (a few hundred bytes each) and each WASM goes alone, CODE_STEP_DAYS more per transaction until it has the
// days asked for. Each step pays only the rent of the days it adds.
import { Buffer } from "node:buffer";
import { Address, BASE_FEE, type Keypair, Operation, SorobanDataBuilder, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import type { Chain } from "./preflight-v2.ts";

export const LEDGERS_PER_DAY = 17_280;
/** Days one transaction adds to one WASM. At testnet's 2026-10-15 rent a 128 KB WASM (the largest the network takes)
 *  costs about 10.4 XLM a day: 25 days is about 260 XLM, 340 XLM with prepare's 1.3× headroom, under the 429 XLM a
 *  transaction's fee can be. */
export const CODE_STEP_DAYS = 25;
/** Instances per transaction (each a few hundred bytes: well under a XLM a day together). */
const INSTANCES_PER_TX = 20;

export function instanceKey(contract: string): xdr.LedgerKey {
  return xdr.LedgerKey.contractData(
    new xdr.LedgerKeyContractData({
      contract: new Address(contract).toScAddress(),
      key: xdr.ScVal.scvLedgerKeyContractInstance(),
      durability: xdr.ContractDataDurability.persistent(),
    }),
  );
}

export function codeKey(hashHex: string): xdr.LedgerKey {
  return xdr.LedgerKey.contractCode(new xdr.LedgerKeyContractCode({ hash: Buffer.from(hashHex, "hex") }));
}

/** The relative TTLs (ledgers) a WASM with `left` ledgers to live is extended to, one transaction each: CODE_STEP_DAYS
 *  more each time, the last one exactly `full`. */
export function codeSteps(left: number, full: number, stepDays = CODE_STEP_DAYS): number[] {
  const step = stepDays * LEDGERS_PER_DAY;
  const out: number[] = [];
  for (let s = Math.max(0, left) + step; s < full; s += step) out.push(s);
  out.push(full);
  return out;
}

export interface ExtendResult {
  /** Entries that had less than the threshold left and were extended. */
  extended: number;
  /** Stroops charged. */
  fee: bigint;
  transactions: number;
}

/** Extends every instance and WASM given that has less than `thresholdDays` left to `extendToDays` from now, paid by
 *  `payer`; entries not on chain (or archived) are left out, as keepAlive does. Throws on the first transaction that
 *  fails: what was extended stays extended, and running it again goes on from there. */
export async function extendTtl(
  chain: Chain,
  payer: Keypair,
  contracts: string[],
  codeHashes: string[],
  extendToDays: number,
  thresholdDays: number,
  log: (line: string) => void = () => {},
  label: (key: string) => string = (k) => k,
): Promise<ExtendResult> {
  const full = extendToDays * LEDGERS_PER_DAY;
  // The RPC refuses a request that names an entry twice.
  const [allInstances, allCodes] = [[...new Set(contracts)], [...new Set(codeHashes)]];
  const latest = await chain.latestLedger();
  const live = await chain.liveUntil(allInstances, allCodes);
  const low = (k: string) => {
    const l = live.get(k);
    return l !== null && l !== undefined && l - latest < thresholdDays * LEDGERS_PER_DAY;
  };
  const instances = allInstances.filter(low);
  const codes = allCodes.filter(low);
  const result: ExtendResult = { extended: instances.length + codes.length, fee: 0n, transactions: 0 };
  const extend = async (keys: xdr.LedgerKey[], extendTo: number, what: string) => {
    const account = await chain.sourceAccount(payer.publicKey());
    const tx = new TransactionBuilder(account, { fee: BASE_FEE, networkPassphrase: chain.passphrase })
      .addOperation(Operation.extendFootprintTtl({ extendTo }))
      .setSorobanData(new SorobanDataBuilder().setReadOnly(keys).build())
      .setTimeout(300)
      .build();
    const prepared = await chain.prepare(tx);
    prepared.sign(payer);
    const out = await chain.submit(prepared);
    result.fee += out.feeCharged;
    result.transactions += 1;
    log(`${what} to ${(extendTo / LEDGERS_PER_DAY).toFixed(1)} days: ${out.hash} (fee ${(Number(out.feeCharged) / 1e7).toFixed(4)} XLM)`);
  };
  for (let i = 0; i < instances.length; i += INSTANCES_PER_TX) {
    const batch = instances.slice(i, i + INSTANCES_PER_TX);
    await extend(batch.map(instanceKey), full, `extended ${batch.length} instance${batch.length === 1 ? "" : "s"}`);
  }
  for (const h of codes) {
    for (const s of codeSteps(live.get(h)! - latest, full)) await extend([codeKey(h)], s, `extended ${label(h)}`);
  }
  return result;
}
