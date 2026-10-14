// Contract ids of the v2 singletons (docs/DESIGN-stellar-contracts-v2.md §3.4; CT-11a lead decision L-c).
//
// Each singleton's id is derived, before anything is deployed, from the deployer's address and a fixed salt:
//   salt = sha256("dyorhq/v2/<deployment>/g<generation>/<contract name>")
//   id   = sha256(xdr(HashIdPreimage::ContractId { networkId: sha256(passphrase),
//                                                  preimage: FromAddress { address: deployer, salt } }))
// which is how the network (and soroban-sdk's `deployer().with_address(..).deployed_address()`) derives it. So peers
// are constructor arguments and nothing needs an init function, and `--generation n` gives a fresh set of ids.
//
// A re-run of the same generation is idempotent: `reconcile` sorts each planned contract into "absent" (deploy it),
// "deployed" (its WASM and its config views match the plan: skip it) or "conflict" (refuse the run).
import { Buffer } from "node:buffer";
import { Address, Asset, hash, scValToNative, StrKey, xdr } from "@stellar/stellar-sdk";

/** The salt's text: "dyorhq/v2/<deployment>/g<generation>/<name>". */
export function saltLabel(deployment: string, generation: number, name: string): string {
  if (!/^[a-z][a-z0-9-]*$/.test(deployment)) throw new Error(`bad deployment name ${deployment}`);
  if (!Number.isSafeInteger(generation) || generation < 1) throw new Error(`the generation is a whole number from 1`);
  if (!/^[a-z][a-z0-9-]*$/.test(name)) throw new Error(`bad contract name ${name}`);
  return `dyorhq/v2/${deployment}/g${generation}/${name}`;
}

export function saltFor(deployment: string, generation: number, name: string): Uint8Array {
  return Uint8Array.from(hash(Buffer.from(saltLabel(deployment, generation, name), "utf8")));
}

/** The id of the contract `deployer` creates with `salt` on the network with this passphrase. */
export function contractIdFor(deployer: string, salt: Uint8Array, passphrase: string): string {
  if (salt.length !== 32) throw new Error("a salt is 32 bytes");
  const preimage = xdr.HashIdPreimage.envelopeTypeContractId(
    new xdr.HashIdPreimageContractId({
      networkId: hash(Buffer.from(passphrase, "utf8")),
      contractIdPreimage: xdr.ContractIdPreimage.contractIdPreimageFromAddress(
        new xdr.ContractIdPreimageFromAddress({ address: new Address(deployer).toScAddress(), salt: Buffer.from(salt) }),
      ),
    }),
  );
  return StrKey.encodeContract(hash(preimage.toXDR()));
}

/** The Stellar Asset Contract of a classic asset ("native" or CODE:ISSUER). */
export function sacIdFor(classic: string, passphrase: string): string {
  if (classic === "native") return Asset.native().contractId(passphrase);
  const [code, issuer] = classic.split(":");
  return new Asset(code, issuer).contractId(passphrase);
}

export interface PlannedId {
  name: string;
  salt: string;
  id: string;
}

/** The planned ids of `names` for one deployment and generation. */
export function planIds(
  deployment: string,
  generation: number,
  deployer: string,
  passphrase: string,
  names: string[],
): Map<string, PlannedId> {
  const out = new Map<string, PlannedId>();
  for (const name of names) {
    out.set(name, { name, salt: saltLabel(deployment, generation, name), id: contractIdFor(deployer, saltFor(deployment, generation, name), passphrase) });
  }
  return out;
}

// ------------------------------------------------------------------------------------------------ re-runs

/** A config view of a deployed contract and the value the plan expects from it. */
export interface ViewCheck {
  /** Shown in a refusal: "launchpad-v2 config().treasury". */
  label: string;
  fn: string;
  args: xdr.ScVal[];
  /** Picks the compared part out of the view's native value (a struct field, say); the whole value by default. */
  pick?: (native: unknown) => unknown;
  expected: unknown;
}

export interface PlannedContract {
  name: string;
  id: string;
  /** The WASM it must run (hex). */
  wasmHash: string;
  views: ViewCheck[];
}

/** What reconcile needs from the network: read-only. */
export interface ContractReader {
  /** The WASM hash (hex) behind a contract id; null when no contract is there. */
  contractWasmHash(id: string): Promise<string | null>;
  /** A read-only call (simulation). */
  view(id: string, fn: string, args: xdr.ScVal[]): Promise<xdr.ScVal>;
}

export type Reconciled =
  | { name: string; id: string; state: "absent" }
  | { name: string; id: string; state: "deployed" }
  | { name: string; id: string; state: "conflict"; differences: string[] };

/** Sorts each planned contract: absent (deploy), deployed with the planned WASM and config (skip), or a conflict
 *  (refuse): a contract at the planned id whose WASM or views differ from the plan. */
export async function reconcile(planned: PlannedContract[], chain: ContractReader): Promise<Reconciled[]> {
  const out: Reconciled[] = [];
  for (const p of planned) {
    const onChain = await chain.contractWasmHash(p.id);
    if (onChain === null) {
      out.push({ name: p.name, id: p.id, state: "absent" });
      continue;
    }
    const differences: string[] = [];
    if (onChain !== p.wasmHash) differences.push(`${p.name} runs WASM ${onChain}, the plan uploads ${p.wasmHash}`);
    else {
      for (const v of p.views) {
        let got: unknown;
        try {
          const native = scValToNative(await chain.view(p.id, v.fn, v.args));
          got = v.pick ? v.pick(native) : native;
        } catch (e) {
          differences.push(`${v.label}: can't read it (${(e as Error).message})`);
          continue;
        }
        if (!sameValue(got, v.expected)) {
          differences.push(`${v.label} is ${show(got)} on chain, the plan has ${show(v.expected)}`);
        }
      }
    }
    out.push(differences.length ? { name: p.name, id: p.id, state: "conflict", differences } : { name: p.name, id: p.id, state: "deployed" });
  }
  return out;
}

/** Native values in one comparable form: integers as decimal strings, bytes as hex, objects with sorted keys. */
export function normalize(v: unknown): unknown {
  if (v === undefined || v === null) return null;
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "number") return Number.isInteger(v) ? String(v) : v;
  if (v instanceof Uint8Array) return Buffer.from(v).toString("hex");
  if (Array.isArray(v)) return v.map(normalize);
  if (typeof v === "object") {
    const o = v as Record<string, unknown>;
    return Object.fromEntries(Object.keys(o).sort().map((k) => [k, normalize(o[k])]));
  }
  return v;
}

export function sameValue(a: unknown, b: unknown): boolean {
  return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
}

function show(v: unknown): string {
  const s = JSON.stringify(normalize(v));
  return s.length > 160 ? `${s.slice(0, 157)}…` : s;
}
