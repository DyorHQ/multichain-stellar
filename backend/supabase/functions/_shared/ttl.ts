// Keeps Lite's contracts alive. Soroban archives any entry whose TTL runs out; extending a contract instance also
// means extending its WASM, which is large (≈30–50 KB) and costs real rent. That cost is the operator's, so contracts
// never extend their own instance in a user's call: this keeper does it from the sponsor account, only when an entry
// gets close to expiry. Launch-token instances (small) are kept alive the same way.
import { Address, Keypair, Operation, rpc, SorobanDataBuilder, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { env } from "./env.ts";
import { prepare, rpcServer, sendSigned, sponsor, waitForTx } from "./stellar.ts";

const DAY = 17_280;

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
  return xdr.LedgerKey.contractCode(new xdr.LedgerKeyContractCode({ hash: Buffer.from(hashHex, "hex") as any }));
}

/** Code hashes of the given contracts' instances. */
export async function codeHashes(contracts: string[]): Promise<string[]> {
  const r = await rpcServer().getLedgerEntries(...contracts.map(instanceKey));
  return r.entries.map((e) => e.val.contractData().val().instance().executable().wasmHash().toString("hex"));
}

export interface TtlReport {
  checked: number;
  extended: number;
  fee: string;
  hashes: string[];
}

/** Extends every entry below `thresholdDays` to `extendToDays`, in batches. */
export async function keepAlive(contracts: string[], extraCodeHashes: string[] = [], thresholdDays = 10, extendToDays = 30, payer: Keypair = sponsor()): Promise<TtlReport> {
  if (contracts.length === 0 && extraCodeHashes.length === 0) return { checked: 0, extended: 0, fee: "0", hashes: [] };
  const latest = (await rpcServer().getLatestLedger()).sequence;
  const hashes = new Set([...extraCodeHashes, ...(contracts.length ? await codeHashes(contracts) : [])]);
  const keys = [...contracts.map(instanceKey), ...[...hashes].map(codeKey)];
  const low: xdr.LedgerKey[] = [];
  for (let i = 0; i < keys.length; i += 50) {
    const batch = keys.slice(i, i + 50);
    const r = await rpcServer().getLedgerEntries(...batch);
    for (const e of r.entries) {
      if ((e.liveUntilLedgerSeq ?? 0) - latest < thresholdDays * DAY) low.push(e.key);
    }
  }
  let fee = 0n;
  const sent: string[] = [];
  for (let i = 0; i < low.length; i += 20) {
    const batch = low.slice(i, i + 20);
    const acct = await rpcServer().getAccount(payer.publicKey());
    const tx = new TransactionBuilder(acct, { fee: "100", networkPassphrase: env.network.passphrase })
      .addOperation(Operation.extendFootprintTtl({ extendTo: extendToDays * DAY }))
      .setSorobanData(new SorobanDataBuilder().setReadOnly(batch).build())
      .setTimeout(120)
      .build();
    const prepared = await prepare(tx);
    prepared.sign(payer);
    const hash = await sendSigned(prepared);
    const s = await waitForTx(hash, 40_000);
    if (s.status === "SUCCESS") {
      fee += BigInt(prepared.fee);
      sent.push(hash);
    }
  }
  return { checked: keys.length, extended: low.length, fee: fee.toString(), hashes: sent };
}

export { rpc };
