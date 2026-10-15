// Builds the owner's admin transactions as prepared, unsigned envelopes for `owner-v2.ts sign`
// (docs/DESIGN-stellar-contracts-v2.md §5.4, §9.2, §16, §17 step 6; CT-11). It never signs and never submits: each
// envelope is simulated read-only against testnet, with the signing role's account as its source, and written to a
// file. The role's account is read first: a multi-signer account where one signer meets the medium threshold alone is
// refused (require_auth on a G-account checks the medium threshold, B11a).
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/admin-v2.ts <command> [options] --out <file>
//
// The v1 cutover (only after the lead says the app serves v2; v1 keeps working until then, §17 steps 6–7):
//   cutover-v1 --out-dir <dir>   v1 launchpad set_launches_enabled(false) and v1 Moments set_policy(<platform_bps>,
//                                <royalty_bps>, false), with the values read from config() first; signed --as v1-admin.
// launchpad-v2 (ids from deployments/testnet-v2.json) and moments-v2: see USAGE. The v2 builders follow the spec's
// signatures with CT-05's names; CT-11 re-checks them against the merged contracts.
//
// ADMIN_FNS lists every call admin-v2.ts writes, with its signing roles, its argument encodings and the description
// derived from the decoded call. `owner-v2.ts sign` accepts exactly these calls and shows that description.
import { type Account, Address, BASE_FEE, Contract, nativeToScVal, scValToNative, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";
import { consoleIo, type Io, loadRolesFile, readIfExists, refuseRoleEnv, repoRoot, requireRoles, ROLES_FILE, secretsDir } from "./lib/owner-files.ts";
import {
  type Chain,
  ENVELOPE_FORMAT,
  type SigningRole,
  singleSignerMeetsMedium,
  testnetChain,
  type UnsignedEnvelope,
} from "./lib/preflight-v2.ts";
import { VENUE_KIND_VALUE } from "./lib/v2-constructors.ts";
import type { V2Roles } from "./lib/v2-profile.ts";

export const USAGE = `usage: admin-v2.ts <command> [options] --out <file> [--valid-for <seconds>]

v1 cutover (signed --as v1-admin; only once the lead says the app serves v2):
  cutover-v1 --out-dir <dir>

launchpad-v2:
  rescue --token C…                      allow-fallback --token C…                       (admin)
  takeover-propose --token C… --to G…    takeover-cancel --token C…                      (admin)
  takeover-execute --token C…                                                            (admin)
  treasury-propose --to G…               treasury-apply                                  (admin)
  treasury-cancel --as admin|guardian
  venue-propose --kind soroswap|aquarius --executor C… [--fee-fraction 10|30|100]        (admin)
  venue-apply --id n                     venue-enable --id n --enabled true|false        (admin)
  venue-cancel --id n --as admin|guardian
  quote --asset XLM|USDC|C… --phantom n --threshold n --enabled true|false --fallback n [--venues 0,1]   (admin)
  launches-enabled --enabled true|false                                                  (admin)
  guardian-transfer --to G…              guardian-renounce                               (guardian)
  guardian-accept --from G…              (the new guardian, signed --as guardian with its key)
  guardian-propose --to G…|none          guardian-apply      guardian-cancel             (admin)

moments-v2:
  policy-propose [--threshold n] [--min-price n] [--creator-bps n] [--platform-bps n] [--reserve-bps n]
                 [--max-alloc-bps n] [--expiry-creator-bps n] [--royalty-bps n] [--platform G…] [--treasury G…]
                 (governance; unset fields keep the current policy())
  policy-apply   (governance)            policy-cancel --as governance|guardian
  publishing-paused --paused true|false  (governance)
  guardian-paused --paused true|false    moments-guardian-transfer --to G…|none          (Moments guardian)

Amounts are in base units (7 decimals). Sign each envelope with: owner-v2.ts sign <file> --as <role>`;

export interface AdminCtx {
  io: Io;
  env: (name: string) => string | undefined;
  secretsDir: string;
  root: string;
  deploymentsDir: string;
  chain: Chain;
  now(): Date;
}

export function realCtx(): AdminCtx {
  const env = (n: string) => Deno.env.get(n);
  const root = repoRoot();
  return {
    io: consoleIo(),
    env,
    secretsDir: secretsDir(env),
    root,
    deploymentsDir: `${root}backend/supabase/functions/_shared/deployments`,
    chain: testnetChain({
      rpcUrl: env("STELLAR_RPC_URL")?.trim() || TESTNET.rpcUrl,
      horizonUrl: TESTNET.horizonUrl,
      friendbotUrl: TESTNET.friendbotUrl!,
    }),
    now: () => new Date(),
  };
}

// ------------------------------------------------------------------------------------------------ arguments

type Opts = Map<string, string>;

function parseOpts(args: string[]): { cmd: string; opts: Opts } {
  const [cmd, ...rest] = args;
  const opts: Opts = new Map();
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (!a.startsWith("--")) throw new Error(`unexpected ${a}\n${USAGE}`);
    const v = rest[i + 1];
    if (v === undefined || v.startsWith("--")) throw new Error(`${a} needs a value`);
    opts.set(a.slice(2), v);
    i++;
  }
  return { cmd: cmd ?? "", opts };
}

const sv = {
  addr: (a: string) => new Address(a).toScVal(),
  u32: (n: number) => nativeToScVal(n, { type: "u32" }),
  i128: (n: bigint) => nativeToScVal(n, { type: "i128" }),
  bool: (b: boolean) => xdr.ScVal.scvBool(b),
  str: (s: string) => nativeToScVal(s, { type: "string" }),
};

function need(o: Opts, k: string): string {
  const v = o.get(k);
  if (v === undefined) throw new Error(`--${k} is needed`);
  return v;
}

function account(o: Opts, k: string): string {
  const v = need(o, k);
  if (!/^G[A-Z2-7]{55}$/.test(v)) throw new Error(`--${k} must be a G-address`);
  return v;
}

function contractId(o: Opts, k: string): string {
  const v = need(o, k);
  if (!/^C[A-Z2-7]{55}$/.test(v)) throw new Error(`--${k} must be a contract id (C…)`);
  return v;
}

function bool(o: Opts, k: string): boolean {
  const v = need(o, k);
  if (v !== "true" && v !== "false") throw new Error(`--${k} is true or false`);
  return v === "true";
}

function u32(o: Opts, k: string, fallback?: number): number {
  const v = o.get(k);
  if (v === undefined) {
    if (fallback !== undefined) return fallback;
    throw new Error(`--${k} is needed`);
  }
  if (!/^\d{1,10}$/.test(v) || Number(v) > 0xffffffff) throw new Error(`--${k} must be a whole number`);
  return Number(v);
}

function amount(o: Opts, k: string, fallback?: bigint): bigint {
  const v = o.get(k);
  if (v === undefined) {
    if (fallback !== undefined) return fallback;
    throw new Error(`--${k} is needed`);
  }
  if (!/^\d{1,30}$/.test(v)) throw new Error(`--${k} must be a whole number of base units`);
  return BigInt(v);
}

// ------------------------------------------------------------------------------------------------ the calls admin-v2.ts writes

/** The contracts admin-v2.ts calls: the v1 launchpad and Moments (deployments/testnet.json) and launchpad-v2 and
 *  moments-v2 (testnet-v2.json's launchpadV2 and momentsV2). */
export type AdminTarget = "v1 launchpad" | "v1 Moments" | "launchpad-v2" | "moments-v2";

/** An argument as admin-v2.ts encodes it. `caller` is the transaction's source account as an Address argument. */
export type ArgKind =
  | "false"
  | "bool"
  | "u32"
  | "i128"
  | "contract"
  | "asset"
  | "account"
  | "account or none"
  | "caller"
  | "venue kind"
  | "venue params"
  | "venue ids"
  | "policy";

export type ArgValue = boolean | number | bigint | string | null | number[] | Record<string, unknown>;

export interface AdminFn {
  target: AdminTarget;
  fn: string;
  /** The roles that sign it; the transaction's source is that role's account. */
  roles: readonly SigningRole[];
  args: readonly ArgKind[];
  /** Names shown before arguments, where a bare value would be unclear. */
  names?: readonly (string | null)[];
  /** What the call does, from its decoded arguments and its source. */
  effect: (a: ArgValue[], source: string) => string;
}

/** The longest validity window admin-v2.ts writes (--valid-for), in seconds; `sign` refuses a longer one. */
export const MAX_VALID_FOR = 86_400;

const said = (s: string) => () => s;
const ADMIN = ["admin"] as const;
const GUARDIAN = ["guardian"] as const;
const GOVERNANCE = ["governance"] as const;
const LP = "launchpad-v2" as const;
const MO = "moments-v2" as const;

/** Every call admin-v2.ts writes. `owner-v2.ts sign` refuses anything else. */
export const ADMIN_FNS: readonly AdminFn[] = [
  // The v1 cutover (§17 step 6).
  { target: "v1 launchpad", fn: "set_launches_enabled", roles: ["v1-admin"], args: ["false"], effect: said("new launches stop; sells, claims and graduations go on") },
  {
    target: "v1 Moments",
    fn: "set_policy",
    roles: ["v1-admin"],
    args: ["u32", "u32", "false"],
    // The values as the envelope carries them; cutover-v1 copies them from config() when it builds the envelope, and
    // prints config()'s values beside them.
    effect: (a) => `publishing stops; platform_bps is set to ${a[0]} and royalty_bps to ${a[1]}`,
  },
  // launchpad-v2.
  { target: LP, fn: "rescue", roles: ADMIN, args: ["contract"], effect: said("the admin rescues the stuck launch (from stuck_since + 7 days)") },
  { target: LP, fn: "allow_fallback", roles: ADMIN, args: ["contract"], effect: said("the venue-locked launch may graduate through its fallback venue now") },
  {
    target: LP,
    fn: "propose_creator_fee_recipient",
    roles: ADMIN,
    args: ["contract", "account"],
    effect: said("the admin proposes a takeover of the launch's creator fees: anyone executes it inside its window; the recipient can veto it"),
  },
  { target: LP, fn: "cancel_recipient_change", roles: ADMIN, args: ["contract", "caller"], effect: said("the admin cancels the launch's pending takeover") },
  { target: LP, fn: "execute_recipient_change", roles: ADMIN, args: ["contract"], effect: said("executes the launch's pending takeover inside its window") },
  { target: LP, fn: "propose_treasury", roles: ADMIN, args: ["account"], effect: said("a new treasury, applied after the 48 h timelock") },
  { target: LP, fn: "apply_treasury", roles: ADMIN, args: [], effect: said("applies the pending treasury change") },
  { target: LP, fn: "cancel_treasury", roles: ["admin", "guardian"], args: ["caller"], effect: said("cancels the pending treasury change") },
  {
    target: LP,
    fn: "propose_venue",
    roles: ADMIN,
    args: ["venue kind", "contract", "venue params"],
    effect: said("a new venue with this executor, applied after the timelock; it starts disabled"),
  },
  { target: LP, fn: "apply_venue", roles: ADMIN, args: ["u32"], effect: said("applies the pending venue") },
  { target: LP, fn: "cancel_venue", roles: ["admin", "guardian"], args: ["caller", "u32"], effect: said("cancels the pending venue") },
  {
    target: LP,
    fn: "set_venue_enabled",
    roles: ADMIN,
    args: ["u32", "bool"],
    effect: (a) => (a[1] ? "future launches may graduate through the venue" : "future launches can't choose the venue; launches that chose it keep it"),
  },
  {
    target: LP,
    fn: "set_quote",
    roles: ADMIN,
    args: ["asset", "i128", "i128", "bool", "venue ids", "u32"],
    names: [null, "phantom", "threshold", "enabled", "venues", "fallback"],
    effect: said("the economics of future launches quoted in this asset"),
  },
  {
    target: LP,
    fn: "set_launches_enabled",
    roles: ADMIN,
    args: ["bool"],
    effect: (a) => (a[0] ? "new launches open" : "new launches stop; sells, claims and graduations go on"),
  },
  { target: LP, fn: "transfer_guardian", roles: GUARDIAN, args: ["account"], effect: said("the guardian hands its role over; the new key accepts with guardian-accept") },
  { target: LP, fn: "accept_guardian", roles: GUARDIAN, args: [], effect: (_a, source) => `${source}, the source, becomes the launchpad's guardian` },
  { target: LP, fn: "renounce_guardian", roles: GUARDIAN, args: [], effect: said("the launchpad has no guardian afterwards") },
  {
    target: LP,
    fn: "propose_guardian",
    roles: ADMIN,
    args: ["account or none"],
    effect: (a) => (a[0] === null ? "removes the guardian after the 48 h timelock" : "a new guardian, applied after the 48 h timelock"),
  },
  { target: LP, fn: "apply_guardian", roles: ADMIN, args: [], effect: said("applies the pending guardian change") },
  { target: LP, fn: "cancel_guardian", roles: ADMIN, args: [], effect: said("cancels the pending guardian change") },
  // moments-v2.
  { target: MO, fn: "propose_policy", roles: GOVERNANCE, args: ["policy"], effect: said("the whole new policy, applied after the timelock") },
  { target: MO, fn: "apply_policy", roles: GOVERNANCE, args: [], effect: said("applies the pending policy") },
  { target: MO, fn: "cancel_policy", roles: ["governance", "guardian"], args: ["caller"], effect: said("cancels the pending policy") },
  { target: MO, fn: "set_publishing_paused", roles: GOVERNANCE, args: ["bool"], effect: (a) => (a[0] ? "publishing pauses" : "publishing resumes") },
  { target: MO, fn: "set_guardian_paused", roles: GUARDIAN, args: ["bool"], effect: (a) => (a[0] ? "the guardian pauses publishing" : "the guardian's pause ends") },
  {
    target: MO,
    fn: "transfer_guardian",
    roles: GUARDIAN,
    args: ["account or none"],
    effect: (a) => (a[0] === null ? "Moments has no guardian afterwards" : "the Moments guardian role goes to this account"),
  },
];

export function adminFn(target: AdminTarget, fn: string): AdminFn | undefined {
  return ADMIN_FNS.find((f) => f.target === target && f.fn === fn);
}

/** What each encoding looks like, for a refusal. */
export const ARG_TEXT: Record<ArgKind, string> = {
  "false": "false",
  bool: "a bool",
  u32: "a u32",
  i128: "an i128",
  contract: "a contract address (C…)",
  asset: "a Stellar Asset Contract address (C…)",
  account: "an account address (G…)",
  "account or none": "an account address (G…) or none",
  caller: "the source account's address",
  "venue kind": "a venue kind: Soroswap (0) or Aquarius (1)",
  "venue params": "venue params {fee_fraction: u32}",
  "venue ids": "a list of venue ids (u32)",
  policy: "a moments-v2 Policy",
};

const VENUE_KINDS = ["Soroswap", "Aquarius"] as const;
const POLICY_FIELDS: [string, "amount" | "bps" | "account"][] = [
  ["threshold", "amount"],
  ["min_price", "amount"],
  ["creator_bps", "bps"],
  ["platform_bps", "bps"],
  ["reserve_bps", "bps"],
  ["max_creator_alloc_bps", "bps"],
  ["expiry_creator_bps", "bps"],
  ["royalty_bps", "bps"],
  ["platform", "account"],
  ["treasury", "account"],
];

function addressOf(v: xdr.ScVal): string | null {
  if (v.switch().name !== "scvAddress") return null;
  try {
    return Address.fromScVal(v).toString();
  } catch {
    return null;
  }
}

const isAccount = (a: string | null): a is string => a !== null && /^G[A-Z2-7]{55}$/.test(a);
const isContract = (a: string | null): a is string => a !== null && /^C[A-Z2-7]{55}$/.test(a);
const u32Of = (v: xdr.ScVal): number | undefined => (v.switch().name === "scvU32" ? v.u32() : undefined);

/** One argument decoded to the encoding admin-v2.ts writes, or undefined when it's anything else. */
function decodeArg(kind: ArgKind, v: xdr.ScVal, source: string): ArgValue | undefined {
  const t = v.switch().name;
  switch (kind) {
    case "false":
      return t === "scvBool" && v.b() === false ? false : undefined;
    case "bool":
      return t === "scvBool" ? v.b() : undefined;
    case "u32":
      return u32Of(v);
    case "i128":
      return t === "scvI128" ? (scValToNative(v) as bigint) : undefined;
    case "contract":
    case "asset": {
      const a = addressOf(v);
      return isContract(a) ? a : undefined;
    }
    case "account": {
      const a = addressOf(v);
      return isAccount(a) ? a : undefined;
    }
    case "account or none": {
      if (t === "scvVoid") return null;
      const a = addressOf(v);
      return isAccount(a) ? a : undefined;
    }
    case "caller":
      return addressOf(v) === source ? source : undefined;
    case "venue kind": {
      const n = u32Of(v);
      return n === 0 || n === 1 ? n : undefined;
    }
    case "venue params": {
      const m = t === "scvMap" ? v.map() ?? [] : null;
      if (!m || m.length !== 1 || m[0].key().switch().name !== "scvSymbol" || m[0].key().sym().toString() !== "fee_fraction") return undefined;
      const f = u32Of(m[0].val());
      return f === undefined ? undefined : { fee_fraction: f };
    }
    case "venue ids": {
      if (t !== "scvVec") return undefined;
      const ids = (v.vec() ?? []).map(u32Of);
      return ids.every((x) => x !== undefined) ? (ids as number[]) : undefined;
    }
    case "policy": {
      const m = t === "scvMap" ? v.map() ?? [] : null;
      if (!m || m.length !== POLICY_FIELDS.length) return undefined;
      const sorted = [...POLICY_FIELDS].sort((a, b) => (a[0] < b[0] ? -1 : 1));
      const out: Record<string, unknown> = {};
      for (let i = 0; i < sorted.length; i++) {
        const [name, kind] = sorted[i];
        const key = m[i].key();
        if (key.switch().name !== "scvSymbol" || key.sym().toString() !== name) return undefined;
        const val = m[i].val();
        const x = kind === "amount" ? decodeArg("i128", val, source) : kind === "bps" ? u32Of(val) : decodeArg("account", val, source);
        if (x === undefined) return undefined;
        out[name] = x;
      }
      return out;
    }
  }
}

/** The call's arguments decoded as admin-v2.ts encodes them; otherwise the first one that isn't, and what it should be. */
export function decodeAdminArgs(f: AdminFn, args: xdr.ScVal[], source: string): { values: ArgValue[] } | { bad: number; expected: string } {
  if (args.length !== f.args.length) return { bad: -1, expected: `${f.args.length} argument(s)` };
  const values: ArgValue[] = [];
  for (let i = 0; i < args.length; i++) {
    const x = decodeArg(f.args[i], args[i], source);
    if (x === undefined) return { bad: i, expected: ARG_TEXT[f.args[i]] };
    values.push(x);
  }
  return { values };
}

function argText(kind: ArgKind, v: ArgValue): string {
  switch (kind) {
    case "asset":
      return TESTNET.assets.find((a) => a.contract === v)?.id ?? String(v);
    case "account or none":
      return v === null ? "none" : String(v);
    case "venue kind":
      return VENUE_KINDS[v as number];
    case "venue params":
      return `fee_fraction ${(v as { fee_fraction: number }).fee_fraction}`;
    case "venue ids":
      return `[${(v as number[]).join(", ")}]`;
    case "policy": {
      const p = v as Record<string, unknown>;
      return `{${POLICY_FIELDS.map(([k]) => `${k} ${p[k]}`).join(", ")}}`;
    }
    default:
      return String(v);
  }
}

/** The description of a decoded call: `<target> <fn>(<arguments>): <what it does>`. admin-v2.ts writes it into the
 *  envelope file and `owner-v2.ts sign` derives it again from the transaction, so the two always agree. */
export function describeAdminCall(f: AdminFn, values: ArgValue[], source: string): string {
  const shown = values.map((v, i) => `${f.names?.[i] ? `${f.names[i]} ` : ""}${argText(f.args[i], v)}`);
  return `${f.target} ${f.fn}(${shown.join(", ")}): ${f.effect(values, source)}`;
}

// ------------------------------------------------------------------------------------------------ building

interface Call {
  target: AdminTarget;
  contract: string;
  fn: string;
  args: xdr.ScVal[];
  role: SigningRole;
  /** The source account: the role's address. */
  source: string;
  /** A line admin-v2.ts prints besides the description (what a proposal changes). */
  note?: string;
}

/** The description of a call admin-v2.ts is about to write: it must be one ADMIN_FNS lists, with its encodings. */
function describeOwn(call: Call): string {
  const f = adminFn(call.target, call.fn);
  if (!f || !f.roles.includes(call.role)) throw new Error(`internal: ${call.target} ${call.fn} --as ${call.role} isn't in ADMIN_FNS`);
  const d = decodeAdminArgs(f, call.args, call.source);
  if ("bad" in d) throw new Error(`internal: ${call.target} ${call.fn} argument ${d.bad + 1} isn't ${d.expected}`);
  return describeAdminCall(f, d.values, call.source);
}

async function readJson(path: string): Promise<any | null> {
  const t = await readIfExists(path);
  return t === null ? null : JSON.parse(t);
}

async function v2Ids(ctx: AdminCtx): Promise<{ launchpad: string; moments: string }> {
  const d = await readJson(`${ctx.deploymentsDir}/testnet-v2.json`);
  const launchpad = d?.contracts?.launchpadV2;
  const moments = d?.contracts?.momentsV2;
  if (!launchpad || !moments) throw new Error("no deployments/testnet-v2.json with launchpadV2 and momentsV2: deploy v2 first");
  return { launchpad, moments };
}

async function roles(ctx: AdminCtx): Promise<V2Roles> {
  refuseRoleEnv(ctx.env);
  const f = await loadRolesFile(ctx.secretsDir);
  if (!f) throw new Error(`no roles file at ${ctx.secretsDir}/${ROLES_FILE}`);
  return requireRoles(f);
}

/** Reads the source account and refuses one where a single signer meets the medium threshold of a multi-signer
 *  account (§16, B11a). */
export async function checkSigners(chain: Chain, source: string): Promise<void> {
  const a = await chain.account(source);
  if (!a) throw new Error(`the source account ${source} doesn't exist on testnet`);
  if (singleSignerMeetsMedium(a)) {
    const heaviest = Math.max(...a.signers.map((s) => s.weight));
    throw new Error(
      `refused: ${source} has ${a.signers.filter((s) => s.weight > 0).length} signers and one of them (weight ${heaviest}) meets the medium ` +
        `threshold ${a.thresholds.med} alone; raise the medium threshold so it needs more than one signer`,
    );
  }
}

/** Simulates the call (read-only) and writes the prepared, unsigned envelope. `source`, when given, is the account
 *  object of an envelope built just before for the same role: this one then takes the next sequence number. */
export async function writeEnvelope(ctx: AdminCtx, call: Call, out: string, validFor: number, source?: Account): Promise<UnsignedEnvelope> {
  const description = describeOwn(call);
  await checkSigners(ctx.chain, call.source);
  const account = source ?? await ctx.chain.sourceAccount(call.source);
  const tx = new TransactionBuilder(account, { fee: BASE_FEE, networkPassphrase: ctx.chain.passphrase })
    .addOperation(new Contract(call.contract).call(call.fn, ...call.args))
    .setTimeout(validFor)
    .build();
  const prepared = await ctx.chain.prepare(tx);
  if (prepared.signatures.length !== 0) throw new Error("internal: the prepared envelope carries a signature");
  // `sign` accepts the source account's authorization of the call itself and nothing more.
  for (const a of ((prepared.operations[0] as { auth?: xdr.SorobanAuthorizationEntry[] }).auth ?? [])) {
    if (a.credentials().switch().name !== "sorobanCredentialsSourceAccount" || a.rootInvocation().subInvocations().length !== 0) {
      throw new Error(`the simulation of ${call.fn} asks for more authorization than the source account's for the call itself; owner-v2.ts sign would refuse it, so nothing was written`);
    }
  }
  const envelope: UnsignedEnvelope = {
    format: ENVELOPE_FORMAT,
    networkPassphrase: ctx.chain.passphrase,
    role: call.role,
    source: call.source,
    contract: call.contract,
    function: call.fn,
    description,
    builtAt: ctx.now().toISOString(),
    xdr: prepared.toEnvelope().toXDR("base64"),
  };
  await Deno.writeTextFile(out, JSON.stringify(envelope, null, 2) + "\n");
  ctx.io.out(`wrote ${out}: ${description}`);
  if (call.note) ctx.io.out(`  ${call.note}`);
  ctx.io.out(`  source ${call.source} (${call.role}), sequence ${prepared.sequence}; valid for ${validFor} s; max fee ${prepared.fee} stroops`);
  ctx.io.out(`  check it, then sign it: owner-v2.ts sign ${out} --as ${call.role}`);
  return envelope;
}

// ------------------------------------------------------------------------------------------------ the v1 cutover

/** §17 step 6: both cutover envelopes, after reading the v1 contracts' config() (read-only). */
export async function cutoverV1(ctx: AdminCtx, outDir: string, validFor: number): Promise<UnsignedEnvelope[]> {
  const v1 = await readJson(`${ctx.deploymentsDir}/testnet.json`);
  if (!v1?.launchpad || !v1?.moments || !v1?.admin) throw new Error("deployments/testnet.json has no v1 launchpad, Moments or admin");
  const padCfg = scValToNative(await ctx.chain.view(v1.launchpad, "config", [])) as Record<string, unknown>;
  if (padCfg.admin !== v1.admin) throw new Error(`the v1 launchpad's admin is ${padCfg.admin}, not ${v1.admin} (deployments/testnet.json)`);
  const momCfg = scValToNative(await ctx.chain.view(v1.moments, "config", [])) as Record<string, unknown>;
  if (momCfg.admin !== v1.admin) throw new Error(`the v1 Moments admin is ${momCfg.admin}, not ${v1.admin} (deployments/testnet.json)`);
  const platform = Number(momCfg.platform_bps);
  const royalty = Number(momCfg.royalty_bps);
  if (!Number.isInteger(platform) || !Number.isInteger(royalty)) throw new Error("the v1 Moments config() has no platform_bps or royalty_bps");
  ctx.io.out(`v1 launchpad ${v1.launchpad}: launches_enabled is ${padCfg.launches_enabled}`);
  ctx.io.out(`v1 Moments ${v1.moments}: platform_bps ${platform}, royalty_bps ${royalty}, publishing_enabled ${momCfg.publishing_enabled}`);
  await Deno.mkdir(outDir, { recursive: true });
  const out: UnsignedEnvelope[] = [];
  // One account object for both: the second envelope takes the sequence number after the first.
  const admin = await ctx.chain.sourceAccount(v1.admin);
  out.push(await writeEnvelope(ctx, {
    target: "v1 launchpad",
    contract: v1.launchpad,
    fn: "set_launches_enabled",
    args: [sv.bool(false)],
    role: "v1-admin",
    source: v1.admin,
    note: "cutover 1 of 2",
  }, `${outDir}/1-v1-launchpad-set_launches_enabled.json`, validFor, admin));
  out.push(await writeEnvelope(ctx, {
    target: "v1 Moments",
    contract: v1.moments,
    fn: "set_policy",
    args: [sv.u32(platform), sv.u32(royalty), sv.bool(false)],
    role: "v1-admin",
    source: v1.admin,
    note: `cutover 2 of 2; config() says platform_bps ${platform} and royalty_bps ${royalty} today`,
  }, `${outDir}/2-v1-moments-set_policy.json`, validFor, admin));
  ctx.io.out("Sign both with --as v1-admin, 1 then 2 (the second takes the next sequence number), and only once the lead says the app serves v2.");
  return out;
}

// ------------------------------------------------------------------------------------------------ v2 commands

const POLICY_KEYS: [string, string, "amount" | "bps" | "account"][] = [
  ["threshold", "threshold", "amount"],
  ["min-price", "min_price", "amount"],
  ["creator-bps", "creator_bps", "bps"],
  ["platform-bps", "platform_bps", "bps"],
  ["reserve-bps", "reserve_bps", "bps"],
  ["max-alloc-bps", "max_creator_alloc_bps", "bps"],
  ["expiry-creator-bps", "expiry_creator_bps", "bps"],
  ["royalty-bps", "royalty_bps", "bps"],
  ["platform", "platform", "account"],
  ["treasury", "treasury", "account"],
];

/** §9.2's policy validation, adapted to 7 dp. */
export function policyErrors(p: Record<string, unknown>): string[] {
  const e: string[] = [];
  const T = BigInt(p.threshold as bigint);
  const bps = (k: string) => Number(p[k]);
  if (T < 10_000_000n || T > 10_000_000_000_000n) e.push("threshold must be 1 to 1,000,000 USDC");
  if (BigInt(p.min_price as bigint) < 100_000n) e.push("min_price must be at least 0.01 USDC");
  if (bps("reserve_bps") <= 0 || bps("creator_bps") + bps("platform_bps") + bps("reserve_bps") !== 10_000) e.push("creator + platform + reserve must be 10,000 with a reserve");
  else if (BigInt(p.min_price as bigint) > (T * 10_000n + BigInt(bps("reserve_bps")) - 1n) / BigInt(bps("reserve_bps"))) e.push("min_price is above ceil(threshold·10,000/reserve)");
  if (bps("max_creator_alloc_bps") > 1_000) e.push("max_creator_alloc_bps is at most 1,000");
  if (bps("expiry_creator_bps") > 10_000) e.push("expiry_creator_bps is at most 10,000");
  if (bps("royalty_bps") > 1_000) e.push("royalty_bps is at most 1,000");
  return e;
}

function policyScVal(p: Record<string, unknown>): xdr.ScVal {
  const entries: [string, xdr.ScVal][] = POLICY_KEYS.map(([, k, kind]) => [
    k,
    kind === "amount" ? sv.i128(BigInt(p[k] as bigint)) : kind === "bps" ? sv.u32(Number(p[k])) : sv.addr(String(p[k])),
  ]);
  entries.sort((a, b) => (a[0] < b[0] ? -1 : 1));
  return xdr.ScVal.scvMap(entries.map(([k, v]) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: v })));
}

async function v2Call(ctx: AdminCtx, cmd: string, o: Opts): Promise<Call> {
  const r = await roles(ctx);
  const ids = await v2Ids(ctx);
  const lp = (fn: string, args: xdr.ScVal[], role: SigningRole, source: string): Call => ({ target: LP, contract: ids.launchpad, fn, args, role, source });
  const mo = (fn: string, args: xdr.ScVal[], role: SigningRole, source: string, note?: string): Call => ({ target: MO, contract: ids.moments, fn, args, role, source, note });
  const asAdminOrGuardian = () => {
    const as = need(o, "as");
    if (as === "admin") return { role: "admin" as const, source: r.ADMIN_PUBLIC };
    if (as === "guardian") return { role: "guardian" as const, source: r.LAUNCHPAD_GUARDIAN_PUBLIC };
    throw new Error("--as is admin or guardian");
  };
  const optional = (v: string) => (v === "none" ? xdr.ScVal.scvVoid() : sv.addr(v));
  const target = (k: string) => {
    const v = need(o, k);
    if (v !== "none" && !/^G[A-Z2-7]{55}$/.test(v)) throw new Error(`--${k} must be a G-address or none`);
    return v;
  };
  switch (cmd) {
    case "rescue": {
      const t = contractId(o, "token");
      return lp("rescue", [sv.addr(t)], "admin", r.ADMIN_PUBLIC);
    }
    case "allow-fallback": {
      const t = contractId(o, "token");
      return lp("allow_fallback", [sv.addr(t)], "admin", r.ADMIN_PUBLIC);
    }
    case "takeover-propose": {
      const t = contractId(o, "token");
      const to = account(o, "to");
      return lp("propose_creator_fee_recipient", [sv.addr(t), sv.addr(to)], "admin", r.ADMIN_PUBLIC);
    }
    case "takeover-cancel": {
      const t = contractId(o, "token");
      return lp("cancel_recipient_change", [sv.addr(t), sv.addr(r.ADMIN_PUBLIC)], "admin", r.ADMIN_PUBLIC);
    }
    case "takeover-execute": {
      const t = contractId(o, "token");
      return lp("execute_recipient_change", [sv.addr(t)], "admin", r.ADMIN_PUBLIC);
    }
    case "treasury-propose": {
      const to = account(o, "to");
      return lp("propose_treasury", [sv.addr(to)], "admin", r.ADMIN_PUBLIC);
    }
    case "treasury-apply":
      return lp("apply_treasury", [], "admin", r.ADMIN_PUBLIC);
    case "treasury-cancel": {
      const a = asAdminOrGuardian();
      return lp("cancel_treasury", [sv.addr(a.source)], a.role, a.source);
    }
    case "venue-propose": {
      const kind = need(o, "kind");
      const executor = contractId(o, "executor");
      const kinds: Record<string, "Soroswap" | "Aquarius"> = { soroswap: "Soroswap", aquarius: "Aquarius" };
      if (!kinds[kind]) throw new Error("--kind is soroswap or aquarius");
      const fee = u32(o, "fee-fraction", kind === "aquarius" ? 30 : 0);
      if (kind === "aquarius" && ![10, 30, 100].includes(fee)) throw new Error("--fee-fraction is 10, 30 or 100 for Aquarius");
      if (kind !== "aquarius" && fee !== 0) throw new Error("--fee-fraction is for Aquarius only");
      const params = xdr.ScVal.scvMap([new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("fee_fraction"), val: sv.u32(fee) })]);
      return lp("propose_venue", [sv.u32(VENUE_KIND_VALUE[kinds[kind]]), sv.addr(executor), params], "admin", r.ADMIN_PUBLIC);
    }
    case "venue-apply": {
      const id = u32(o, "id");
      return lp("apply_venue", [sv.u32(id)], "admin", r.ADMIN_PUBLIC);
    }
    case "venue-cancel": {
      const id = u32(o, "id");
      const a = asAdminOrGuardian();
      return lp("cancel_venue", [sv.addr(a.source), sv.u32(id)], a.role, a.source);
    }
    case "venue-enable": {
      const id = u32(o, "id");
      const b = bool(o, "enabled");
      return lp("set_venue_enabled", [sv.u32(id), sv.bool(b)], "admin", r.ADMIN_PUBLIC);
    }
    case "quote": {
      const name = need(o, "asset");
      const asset = name === "XLM" || name === "USDC" ? TESTNET.assets.find((a) => a.id === name)!.contract : contractId(o, "asset");
      const phantom = amount(o, "phantom");
      const threshold = amount(o, "threshold");
      const enabled = bool(o, "enabled");
      const fallback = u32(o, "fallback");
      const venues = (o.get("venues") ?? "").split(",").filter((x) => x !== "").map((x) => {
        if (!/^\d{1,3}$/.test(x)) throw new Error("--venues is a comma-separated list of venue ids");
        return Number(x);
      });
      if (enabled && (phantom <= 0n || threshold <= 0n)) throw new Error("an enabled quote needs a phantom and a threshold above 0");
      return lp(
        "set_quote",
        [sv.addr(asset), sv.i128(phantom), sv.i128(threshold), sv.bool(enabled), xdr.ScVal.scvVec(venues.map(sv.u32)), sv.u32(fallback)],
        "admin",
        r.ADMIN_PUBLIC,
      );
    }
    case "launches-enabled": {
      const b = bool(o, "enabled");
      return lp("set_launches_enabled", [sv.bool(b)], "admin", r.ADMIN_PUBLIC);
    }
    case "guardian-transfer": {
      const to = account(o, "to");
      return lp("transfer_guardian", [sv.addr(to)], "guardian", r.LAUNCHPAD_GUARDIAN_PUBLIC);
    }
    case "guardian-accept": {
      const from = account(o, "from");
      return lp("accept_guardian", [], "guardian", from);
    }
    case "guardian-renounce":
      return lp("renounce_guardian", [], "guardian", r.LAUNCHPAD_GUARDIAN_PUBLIC);
    case "guardian-propose": {
      const to = target("to");
      return lp("propose_guardian", [optional(to)], "admin", r.ADMIN_PUBLIC);
    }
    case "guardian-apply":
      return lp("apply_guardian", [], "admin", r.ADMIN_PUBLIC);
    case "guardian-cancel":
      return lp("cancel_guardian", [], "admin", r.ADMIN_PUBLIC);
    case "policy-propose": {
      const current = scValToNative(await ctx.chain.view(ids.moments, "policy", [])) as Record<string, unknown>;
      const next: Record<string, unknown> = { ...current };
      for (const [flag, k, kind] of POLICY_KEYS) {
        if (!o.has(flag)) continue;
        next[k] = kind === "amount" ? amount(o, flag) : kind === "bps" ? u32(o, flag) : account(o, flag);
      }
      const errors = policyErrors(next);
      if (errors.length) throw new Error(`refused: the policy is invalid:\n  ${errors.join("\n  ")}`);
      const changed = POLICY_KEYS.filter(([, k]) => String(next[k]) !== String(current[k])).map(([, k]) => `${k} ${current[k]} → ${next[k]}`);
      if (!changed.length) throw new Error("nothing to propose: every field equals the current policy()");
      return mo("propose_policy", [policyScVal(next)], "governance", r.GOVERNANCE_PUBLIC, `changes: ${changed.join(", ")}`);
    }
    case "policy-apply":
      return mo("apply_policy", [], "governance", r.GOVERNANCE_PUBLIC);
    case "policy-cancel": {
      const as = need(o, "as");
      if (as !== "governance" && as !== "guardian") throw new Error("--as is governance or guardian");
      const source = as === "governance" ? r.GOVERNANCE_PUBLIC : r.MOMENTS_GUARDIAN_PUBLIC;
      return mo("cancel_policy", [sv.addr(source)], as, source);
    }
    case "publishing-paused": {
      const b = bool(o, "paused");
      return mo("set_publishing_paused", [sv.bool(b)], "governance", r.GOVERNANCE_PUBLIC);
    }
    case "guardian-paused": {
      const b = bool(o, "paused");
      return mo("set_guardian_paused", [sv.bool(b)], "guardian", r.MOMENTS_GUARDIAN_PUBLIC);
    }
    case "moments-guardian-transfer": {
      const to = target("to");
      return mo("transfer_guardian", [optional(to)], "guardian", r.MOMENTS_GUARDIAN_PUBLIC);
    }
  }
  throw new Error(`unknown command ${cmd}\n${USAGE}`);
}

// ------------------------------------------------------------------------------------------------ main

export async function main(args: string[], ctx: AdminCtx): Promise<number> {
  try {
    const net = ctx.env("LITE_NETWORK");
    if (net && net !== "testnet") throw new Error(`LITE_NETWORK is ${net}: admin-v2.ts builds testnet transactions only`);
    if (args.length === 0 || args[0] === "--help") {
      ctx.io.err(USAGE);
      return 2;
    }
    const { cmd, opts } = parseOpts(args);
    const validFor = opts.has("valid-for") ? u32(opts, "valid-for") : 1_800;
    if (validFor < 60 || validFor > MAX_VALID_FOR) throw new Error("--valid-for is 60 to 86,400 seconds");
    if (cmd === "cutover-v1") {
      await cutoverV1(ctx, need(opts, "out-dir"), validFor);
      return 0;
    }
    const out = need(opts, "out");
    opts.delete("out");
    opts.delete("valid-for");
    await writeEnvelope(ctx, await v2Call(ctx, cmd, opts), out, validFor);
    return 0;
  } catch (e) {
    ctx.io.err(`admin-v2: ${(e as Error).message}`);
    return 1;
  }
}

if (import.meta.main) Deno.exit(await main(Deno.args, realCtx()));
