// The owner's tools for the v2 testnet deployment (docs/DESIGN-stellar-contracts-v2.md §16, §17; decision O5; CT-11a
// lead decisions L-a, L-e). Testnet only: mainnet and testnet-qa are refused.
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/owner-v2.ts <command>
//
//   keys    Creates or completes the roles file and the keys file in the secrets directory ($DYOR_SECRETS_DIR, else
//           .secrets/): for each empty role it makes at most three keys (admin, guardian, treasury), keeps every role
//           you filled in, never overwrites a role or a secret, and funds role accounts that don't exist yet through
//           Friendbot. It prints addresses and file paths only.
//   trust   Adds the Circle testnet USDC trustline to TREASURY_PUBLIC and PLATFORM_PUBLIC (once when they are one
//           account). Signs with TREASURY_SECRET from the keys file, or for an account you brought yourself with
//           TREASURY_SECRET / PLATFORM_SECRET from the environment (type it with `read -rs NAME && export NAME`).
//   check   [--fund-aqua-float] [--aquarius off]: the read-only preflight, one ✓ or ✗ line each. Exit 0 only when
//           everything the deploy needs passes.
//   sign    <file> --as admin|governance|guardian|treasury|v1-admin [--decode-only]: shows an envelope written by
//           admin-v2.ts, then asks "Sign and submit? [y/N]" in a terminal, signs, submits and waits. It accepts only
//           the calls admin-v2.ts writes (its ADMIN_FNS), shows the description it derives from the decoded call, and
//           escapes every character from the file or the chain that isn't printable ASCII.
//
// No secret is ever printed: keys are read by the script and only addresses are shown.
import { Buffer } from "node:buffer";
import { Address, Asset, FeeBumpTransaction, type Keypair, Operation, scValToNative, type Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";
import { ADMIN_FNS, type AdminFn, adminFn, type AdminTarget, type ArgValue, decodeAdminArgs, describeAdminCall, MAX_VALID_FOR } from "./admin-v2.ts";
import { aquariusLiveCheck, loadAquariusFixtures } from "./lib/aqua-float.ts";
import {
  completeRoles,
  consoleIo,
  FUNCTIONS_FILE,
  type Io,
  type KeyName,
  KEYS_FILE,
  loadKeysFile,
  loadRolesFile,
  modeProblem,
  parseRolesFile,
  readIfExists,
  refuseRoleEnv,
  repoRoot,
  requireRoles,
  ROLES_FILE,
  rolesErrors,
  safe,
  secretFromEnv,
  secretFromEnvFile,
  secretsDir,
  V1_DEPLOYER_FILE,
  writeSecretFile,
} from "./lib/owner-files.ts";
import {
  allNeededPass,
  type Chain,
  type CheckLine,
  fmtUnits,
  fmtXlm,
  line,
  parseEnvelope,
  preflight,
  readOnlyChain,
  renderCheck,
  send,
  SIGNING_ROLES,
  type SigningRole,
  STROOPS_PER_XLM,
  testnetChain,
  type UnsignedEnvelope,
} from "./lib/preflight-v2.ts";
import { checkReviewed, REVIEWED_FILE, sha256Hex } from "./lib/reviewed-hashes.ts";
import { WASMS, type WasmKey } from "./lib/v2-constructors.ts";
import { roleRuleErrors, ROLE_NAMES, type V2Roles } from "./lib/v2-profile.ts";

export const USAGE = [
  "usage: owner-v2.ts keys",
  "       owner-v2.ts trust",
  "       owner-v2.ts check [--fund-aqua-float] [--aquarius off]",
  "       owner-v2.ts sign <file> --as admin|governance|guardian|treasury|v1-admin [--decode-only]",
  "Testnet only. The secrets directory is $DYOR_SECRETS_DIR, else .secrets/ in the repository.",
].join("\n");

export interface OwnerCtx {
  io: Io;
  env: (name: string) => string | undefined;
  secretsDir: string;
  /** The repository root, with a trailing slash. */
  root: string;
  /** Where the deployment files are read (deployments/testnet.json, testnet-v2.json). */
  deploymentsDir: string;
  chain: Chain;
  isTerminal(): boolean;
  /** Asks a question in the terminal; null when there is no answer. */
  ask(question: string): Promise<string | null>;
  /** Key generation (tests replace it to know the keys they look for in the output). */
  generate?: () => Keypair;
}

export function realCtx(): OwnerCtx {
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
    isTerminal: () => Deno.stdin.isTerminal(),
    ask: (q) => Promise.resolve(prompt(q)),
  };
}

export async function main(args: string[], ctx: OwnerCtx): Promise<number> {
  try {
    const net = ctx.env("LITE_NETWORK");
    if (net && net !== "testnet") throw new Error(`LITE_NETWORK is ${net}: these tools are for testnet only`);
    const liteDeployment = ctx.env("LITE_DEPLOYMENT");
    if (liteDeployment && liteDeployment !== "testnet") throw new Error(`LITE_DEPLOYMENT is ${liteDeployment}: unset it (these tools are for the owner's testnet)`);
    const dep = args.indexOf("--deployment");
    if (dep >= 0 && args[dep + 1] !== "testnet") {
      throw new Error(`${args[dep + 1] ?? "that deployment"} is refused: owner-v2.ts is for the owner's testnet only (mainnet waits, testnet-qa keys belong to deploy-contracts-v2.ts)`);
    }
    const rest = dep >= 0 ? [...args.slice(0, dep), ...args.slice(dep + 2)] : args;
    switch (rest[0]) {
      case "keys":
        return await keys(ctx, rest.slice(1));
      case "trust":
        return await trust(ctx, rest.slice(1));
      case "check":
        return await check(ctx, rest.slice(1));
      case "sign":
        return await sign(ctx, rest.slice(1));
      default:
        ctx.io.err(USAGE);
        return 2;
    }
  } catch (e) {
    ctx.io.err(`owner-v2: ${(e as Error).message}`);
    return 1;
  }
}

function noArgs(cmd: string, args: string[]) {
  if (args.length) throw new Error(`${cmd} takes no arguments (${args[0]})\n${USAGE}`);
}

// ------------------------------------------------------------------------------------------------ keys

async function keys(ctx: OwnerCtx, args: string[]): Promise<number> {
  noArgs("keys", args);
  refuseRoleEnv(ctx.env);
  const say = (l = "") => ctx.io.out(l);
  await Deno.mkdir(ctx.secretsDir, { recursive: true });
  const rolesPath = `${ctx.secretsDir}/${ROLES_FILE}`;
  const keysPath = `${ctx.secretsDir}/${KEYS_FILE}`;
  const roles = (await loadRolesFile(ctx.secretsDir)) ?? parseRolesFile("");
  const keysFile = await loadKeysFile(ctx.secretsDir);
  const done = completeRoles(roles, keysFile, ctx.generate);
  const rules = roleRuleErrors(done.roles);
  if (rules.length) throw new Error(`the roles break a rule; nothing was written:\n  ${rules.join("\n  ")}\nEdit ${rolesPath}.`);

  // The keys first: a run stopped between the two writes leaves secrets whose roles are still empty, and the next run
  // fills those roles from the saved secrets. The other order could leave an address whose secret was never saved.
  if (done.generated.length) await writeSecretFile(keysPath, done.keysText);
  const rolesExisted = (await readIfExists(rolesPath)) !== null;
  if (done.filled.length || !rolesExisted) await writeSecretFile(rolesPath, done.rolesText);

  // Fund every role account that doesn't exist yet.
  const byAddress = new Map<string, string[]>();
  for (const n of ROLE_NAMES) byAddress.set(done.roles[n], [...(byAddress.get(done.roles[n]) ?? []), n.replace(/_PUBLIC$/, "")]);
  const funded: string[] = [];
  for (const [address, names] of byAddress) {
    if (await ctx.chain.account(address)) continue;
    await ctx.chain.friendbot(address);
    funded.push(`${address} (${names.join(", ").toLowerCase()})`);
  }

  say(`Roles (${rolesPath}):`);
  for (const n of ROLE_NAMES) {
    let how = "yours, kept";
    if (done.filled.includes(n)) {
      if (!isPrimary(n)) how = `same as ${primaryOf(n)}`;
      else how = done.generated.includes(keyFor(n)) ? `new key, ${keyFor(n)}` : `${keyFor(n)} from the keys file`;
    }
    say(`  ${n.padEnd(26)} ${done.roles[n]}  (${how})`);
  }
  say();
  if (done.generated.length) say(`Generated ${done.generated.join(", ")} into ${keysPath} (mode 600).`);
  else if (keysFile) say(`No new keys. Keys file: ${keysPath}`);
  else say("No keys generated: every role is yours.");
  for (const n of done.notes) say(`Note: ${n}.`);
  say(funded.length ? `Funded through Friendbot: ${funded.join("; ")}.` : "Every role account already exists on testnet.");
  say();
  if (done.generated.length || keysFile) {
    say(`Now copy the contents of ${keysPath} into your password manager (open the file in an editor; don't print it in a terminal or paste it into a chat).`);
    say("Keep the file until the deploy is done: deploy-contracts-v2.ts and owner-v2.ts read the keys from it.");
  }
  say("Next: owner-v2.ts trust, then owner-v2.ts check.");
  return 0;
}

const isPrimary = (n: keyof V2Roles) => ["ADMIN_PUBLIC", "LAUNCHPAD_GUARDIAN_PUBLIC", "TREASURY_PUBLIC"].includes(n);
const primaryOf = (n: keyof V2Roles): keyof V2Roles =>
  n === "GOVERNANCE_PUBLIC" ? "ADMIN_PUBLIC" : n === "MOMENTS_GUARDIAN_PUBLIC" ? "LAUNCHPAD_GUARDIAN_PUBLIC" : n === "PLATFORM_PUBLIC" ? "TREASURY_PUBLIC" : n;
const keyFor = (n: keyof V2Roles): KeyName => {
  const p = primaryOf(n);
  return p === "ADMIN_PUBLIC" ? "ADMIN_SECRET" : p === "LAUNCHPAD_GUARDIAN_PUBLIC" ? "GUARDIAN_SECRET" : "TREASURY_SECRET";
};

// ------------------------------------------------------------------------------------------------ trust

function usdc() {
  const a = TESTNET.assets.find((x) => x.id === "USDC")!;
  const [code, issuer] = a.classic!.split(":");
  return { classic: a.classic!, code, issuer };
}

async function trust(ctx: OwnerCtx, args: string[]): Promise<number> {
  noArgs("trust", args);
  refuseRoleEnv(ctx.env);
  const say = (l = "") => ctx.io.out(l);
  const rolesFile = await loadRolesFile(ctx.secretsDir);
  if (!rolesFile) throw new Error(`no roles file at ${ctx.secretsDir}/${ROLES_FILE}: run owner-v2.ts keys first`);
  const roles = requireRoles(rolesFile);
  const keysFile = await loadKeysFile(ctx.secretsDir);
  const u = usdc();
  const targets: { who: string; address: string; envName: string }[] = [{ who: "treasury", address: roles.TREASURY_PUBLIC, envName: "TREASURY_SECRET" }];
  if (roles.PLATFORM_PUBLIC !== roles.TREASURY_PUBLIC) targets.push({ who: "Moments platform", address: roles.PLATFORM_PUBLIC, envName: "PLATFORM_SECRET" });
  for (const t of targets) {
    const account = await ctx.chain.account(t.address);
    if (!account) throw new Error(`the ${t.who} account ${t.address} doesn't exist on testnet: run owner-v2.ts keys (it funds role accounts)`);
    if (account.trustlines.some((x) => x.asset === u.classic)) {
      say(`✓ ${t.who} ${t.address} already trusts USDC`);
      continue;
    }
    const candidates = [keysFile?.keys.TREASURY_SECRET ?? null, secretFromEnv(ctx.env, t.envName)];
    const key = candidates.find((k) => k && k.publicKey() === t.address) ?? null;
    if (!key) {
      throw new Error(`no key for the ${t.who} ${t.address}: it isn't the keys file's TREASURY_SECRET, so set ${t.envName} (read -rs ${t.envName} && export ${t.envName}) and run trust again`);
    }
    const out = await send(ctx.chain, key, Operation.changeTrust({ asset: new Asset(u.code, u.issuer) }));
    say(`✓ ${t.who} ${t.address} now trusts USDC: transaction ${out.hash} (fee ${fmtXlm(out.feeCharged)})`);
  }
  say("Next: owner-v2.ts check.");
  return 0;
}

// ------------------------------------------------------------------------------------------------ check

async function check(ctx: OwnerCtx, args: string[]): Promise<number> {
  let fundAquaFloat = false;
  let aquarius: "auto" | "off" = "auto";
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--fund-aqua-float") fundAquaFloat = true;
    else if (args[i] === "--aquarius" && (args[i + 1] === "off" || args[i + 1] === "auto")) aquarius = args[++i] as "auto" | "off";
    else throw new Error(`unknown argument ${args[i]}\n${USAGE}`);
  }
  const chain = readOnlyChain(ctx.chain);
  const lines: CheckLine[] = [];
  const add = (l: CheckLine) => lines.push(l);

  // The roles file (L-a).
  const roleEnv = ROLE_NAMES.filter((n) => (ctx.env(n) ?? "") !== "");
  add(line(roleEnv.length === 0, "no role is set in the environment", roleEnv.length ? `unset ${roleEnv.join(", ")}: roles come only from ${ROLES_FILE}` : ""));
  const rolesFile = await loadRolesFile(ctx.secretsDir);
  let roles: V2Roles | null = null;
  if (!rolesFile) add(line(false, "roles file", `${ctx.secretsDir}/${ROLES_FILE} is missing: run owner-v2.ts keys`));
  else {
    const errors = rolesErrors(rolesFile);
    if (errors.length) for (const e of errors) add(line(false, "roles file", e));
    else {
      roles = rolesFile.roles as V2Roles;
      add(line(true, "roles file", `${ctx.secretsDir}/${ROLES_FILE}: six roles, the rules hold`));
    }
  }

  // The keys file's mode, and the deploy key (addresses only, L-b).
  const keysPath = `${ctx.secretsDir}/${KEYS_FILE}`;
  let keysFile = null;
  if ((await readIfExists(keysPath)) === null) add(line(true, "keys file", "none (you bring the keys yourself)"));
  else {
    const mode = await modeProblem(keysPath);
    if (mode) add(line(false, "keys file mode is 600", mode));
    else {
      try {
        keysFile = await loadKeysFile(ctx.secretsDir);
        add(line(true, "keys file mode is 600", keysPath));
      } catch (e) {
        add(line(false, "keys file", (e as Error).message));
      }
    }
  }
  let deployKey: Keypair | null = null;
  let from = "";
  try {
    const env = secretFromEnv(ctx.env, "DEPLOYER_SECRET");
    deployKey = env ?? keysFile?.keys.ADMIN_SECRET ?? null;
    from = env ? "DEPLOYER_SECRET (environment)" : `ADMIN_SECRET (${KEYS_FILE})`;
  } catch (e) {
    add(line(false, "deploy key", (e as Error).message));
  }
  if (!deployKey) add(line(false, "deploy key", "none: set DEPLOYER_SECRET (read -rs) or keep ADMIN_SECRET in the keys file"));
  else if (roles) {
    const ok = deployKey.publicKey() === roles.ADMIN_PUBLIC;
    add(line(ok, "deploy key is ADMIN_PUBLIC's", `${from} → ${deployKey.publicKey()}${ok ? "" : `, but ADMIN_PUBLIC is ${roles.ADMIN_PUBLIC}`}`));
  }

  // Accounts, trustlines and the deployer's XLM (L-e).
  if (roles) {
    const u = usdc();
    for (
      const l of await preflight({
        chain,
        roles,
        deployer: roles.ADMIN_PUBLIC,
        treasuryAssets: [u.classic],
        platformAssets: [u.classic],
        minDeployerXlm: (fundAquaFloat ? 2_500n : 1_000n) * STROOPS_PER_XLM,
        assetNames: new Map([[u.classic, "USDC"]]),
      })
    ) add(l);
  }

  // The reviewed WASMs: reported, not fatal before CT-19 writes the file.
  const keysOf: WasmKey[] = (Object.keys(WASMS) as WasmKey[]).filter((k) => k !== "qa-exec-fail" && (aquarius === "auto" || k !== "exec-aquarius"));
  const wasms = [];
  for (const k of keysOf) {
    const bytes = await Deno.readFile(`${ctx.root}contracts/dist/${WASMS[k].file}`).catch(() => null);
    wasms.push({ file: WASMS[k].file, sha256: bytes ? await sha256Hex(bytes) : null });
  }
  const reviewedText = await readIfExists(`${ctx.root}${REVIEWED_FILE}`);
  const rev = checkReviewed("testnet", reviewedText, wasms);
  add(line(rev.ok, "reviewed WASMs", rev.ok ? `contracts/dist matches ${REVIEWED_FILE}` : rev.problems.slice(0, 3).join("; ") + (rev.problems.length > 3 ? `; and ${rev.problems.length - 3} more` : ""), false));

  // The live Aquarius router against CT-03's fixtures (ruling a).
  if (aquarius === "off") add(line(true, "Aquarius", "--aquarius off: not checked", false));
  else {
    try {
      const live = await aquariusLiveCheck(chain, await loadAquariusFixtures(ctx.root));
      for (const l of live.lines) add(line(l.ok, `Aquarius ${l.label} matches fixtures.json`, l.ok ? l.fixture : `live ${l.live ?? "unreadable"}, fixture ${l.fixture}: CT-03's gate must be re-run, or deploy with --aquarius off`));
    } catch (e) {
      add(line(false, "Aquarius router", `it didn't answer (${(e as Error).message}): try again, or deploy with --aquarius off`));
    }
  }

  // The keeper (reported only): it graduates, harvests and keeps v2 alive.
  try {
    const functionsPath = `${ctx.secretsDir}/${FUNCTIONS_FILE}`;
    const keeper = await secretFromEnvFile(functionsPath, "KEEPER_SECRET");
    const exists = await Deno.stat(functionsPath).then(() => true, () => false);
    if (!keeper) {
      add(line(false, "keeper key", `${exists ? `${FUNCTIONS_FILE} defines no KEEPER_SECRET` : `no ${FUNCTIONS_FILE} here`}: on testnet the sponsor pays protocol upkeep`, false));
    } else {
      const a = await chain.account(keeper.publicKey());
      add(line(!!a, "keeper key", a ? `${keeper.publicKey()}, ${fmtXlm(a.xlm)}` : `${keeper.publicKey()} not found on testnet`, false));
    }
  } catch (e) {
    add(line(false, "keeper key", (e as Error).message, false));
  }

  for (const l of lines) ctx.io.out(renderCheck(l));
  const ok = allNeededPass(lines);
  ctx.io.out(ok ? "Everything the deploy needs passes." : "✗ Fix the lines above before the deploy.");
  return ok ? 0 : 1;
}

// ------------------------------------------------------------------------------------------------ sign

interface V1Deployment {
  launchpad: string;
  moments: string;
  admin: string;
}

async function readJson(path: string): Promise<any | null> {
  const t = await readIfExists(path);
  return t === null ? null : JSON.parse(t);
}

/** What `sign` knows: the contracts admin-v2.ts calls, by id with their target, and a label for every address a
 *  summary may show (DyorHQ's contracts, the network's assets and routers). */
export interface Known {
  targets: Map<string, AdminTarget>;
  labels: Map<string, string>;
}

const isContractId = (v: unknown): v is string => typeof v === "string" && /^C[A-Z2-7]{55}$/.test(v);

/** The v1 launchpad and Moments from deployments/testnet.json; launchpad-v2 and moments-v2 from testnet-v2.json
 *  (its other contracts are labelled, and never signable: admin-v2.ts doesn't call them). */
export async function knownContracts(deploymentsDir: string): Promise<Known> {
  const targets = new Map<string, AdminTarget>();
  const labels = new Map<string, string>();
  for (const a of TESTNET.assets) labels.set(a.contract, `${a.id} SAC`);
  labels.set(TESTNET.contracts.soroswapFactory, "Soroswap factory");
  labels.set(TESTNET.contracts.soroswapRouter, "Soroswap router");
  if (TESTNET.contracts.aquariusRouter) labels.set(TESTNET.contracts.aquariusRouter, "Aquarius router");
  const v1 = (await readJson(`${deploymentsDir}/testnet.json`)) as V1Deployment | null;
  if (typeof v1?.admin === "string") labels.set(v1.admin, "v1 admin");
  const v2 = await readJson(`${deploymentsDir}/testnet-v2.json`);
  for (const [k, v] of Object.entries((v2?.contracts ?? {}) as Record<string, unknown>)) if (isContractId(v)) labels.set(v, `v2 ${k}`);
  const target = (id: unknown, t: AdminTarget) => {
    if (!isContractId(id)) return;
    targets.set(id, t);
    labels.set(id, t);
  };
  target(v1?.launchpad, "v1 launchpad");
  target(v1?.moments, "v1 Moments");
  target(v2?.contracts?.launchpadV2, "launchpad-v2");
  target(v2?.contracts?.momentsV2, "moments-v2");
  return { targets, labels };
}

const ROLE_LABELS: Record<string, string> = {
  ADMIN_PUBLIC: "admin",
  GOVERNANCE_PUBLIC: "governance",
  LAUNCHPAD_GUARDIAN_PUBLIC: "launchpad guardian",
  MOMENTS_GUARDIAN_PUBLIC: "Moments guardian",
  TREASURY_PUBLIC: "treasury",
  PLATFORM_PUBLIC: "platform",
};

/** Adds the roles file's accounts to the labels ("admin", "governance, admin" when one account holds both). */
function labelRoles(labels: Map<string, string>, roles: Record<string, string | undefined>) {
  const byAddress = new Map<string, string[]>();
  for (const [k, name] of Object.entries(ROLE_LABELS)) {
    const a = roles[k];
    if (a && /^G[A-Z2-7]{55}$/.test(a)) byAddress.set(a, [...(byAddress.get(a) ?? []), name]);
  }
  for (const [a, names] of byAddress) if (!labels.has(a)) labels.set(a, names.join(", "));
}

export interface Inspected {
  tx: Transaction;
  /** The call, as ADMIN_FNS lists it. */
  fn: AdminFn;
  /** The description derived from the decoded call (the file's must be the same). */
  description: string;
  /** The summary, every outside value escaped. */
  lines: string[];
  expired: boolean;
}

const ISO_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

/** A Unix time in seconds as an ISO date, or as a number past the last date JavaScript can show. */
function isoTime(seconds: number): string {
  return seconds * 1000 <= 8.64e15 ? new Date(seconds * 1000).toISOString() : `${seconds} (past any date)`;
}

/** Checks an envelope file against exactly what admin-v2.ts writes, and returns the transaction and its summary.
 *  Refused (throws): another network; XDR that doesn't parse; a fee-bump or a v0 envelope; signatures already on it;
 *  a memo; any precondition but a time bound from 0 to an expiry at most MAX_VALID_FOR (24 h) away; anything but ONE
 *  invokeContract operation without an operation source; a call to a contract admin-v2.ts doesn't call; metadata that
 *  doesn't match the transaction; a (contract, function) pair ADMIN_FNS doesn't list, or arguments it doesn't encode
 *  that way; an auth entry that isn't the source account's, whose root invocation isn't the call itself, or that has
 *  sub-invocations; no Soroban data; a fee above the network's cap; a role the call isn't signed by; a build time or a
 *  description other than admin-v2.ts writes (the description is derived from the decoded call). `now` is in
 *  milliseconds. */
export function inspectEnvelope(env: UnsignedEnvelope, known: Known, now: number): Inspected {
  const refuse = (why: string): never => {
    throw new Error(`refused: ${why}`);
  };
  const labels = known.labels;
  if (env.networkPassphrase !== TESTNET.passphrase) refuse(`the envelope is for the network "${safe(env.networkPassphrase)}", not testnet`);
  let parsed: Transaction | FeeBumpTransaction;
  try {
    parsed = TransactionBuilder.fromXDR(env.xdr, TESTNET.passphrase);
  } catch {
    return refuse("the envelope's XDR can't be read");
  }
  if (parsed instanceof FeeBumpTransaction) refuse("a fee-bump envelope; admin-v2.ts writes plain transactions");
  const tx = parsed as Transaction;
  const kind = tx.toEnvelope().switch().name;
  if (kind !== "envelopeTypeTx") {
    refuse(
      kind === "envelopeTypeTxV0"
        ? "a v0 transaction envelope (the format from before protocol 13); admin-v2.ts writes v1 envelopes only: build it again with admin-v2.ts"
        : `a ${safe(kind)} envelope; admin-v2.ts writes v1 transaction envelopes only`,
    );
  }
  const body = tx.toEnvelope().v1().tx();
  if (tx.signatures.length) refuse(`the envelope already carries ${tx.signatures.length} signature(s); admin-v2.ts writes unsigned ones`);
  if (tx.memo.type !== "none") refuse("the transaction has a memo; admin-v2.ts never sets one");
  const cond = body.cond();
  if (cond.switch().name !== "precondTime") {
    refuse(cond.switch().name === "precondNone" ? "the transaction never expires; admin-v2.ts always sets an expiry" : "the transaction has preconditions beyond a time bound (ledger bounds, sequence rules or extra signers)");
  }
  const minTime = Number(cond.timeBounds().minTime().toString());
  const maxTime = Number(cond.timeBounds().maxTime().toString());
  if (minTime !== 0) refuse("the transaction has a start time; admin-v2.ts sets none");
  if (maxTime === 0) refuse("the transaction never expires; admin-v2.ts always sets an expiry");
  const left = maxTime - Math.floor(now / 1000);
  if (left > MAX_VALID_FOR) {
    refuse(
      `the transaction stays valid until ${isoTime(maxTime)}, ${left.toLocaleString("en-US")} s from now; admin-v2.ts writes envelopes valid for ` +
        `at most ${MAX_VALID_FOR.toLocaleString("en-US")} s (24 h)`,
    );
  }
  if (tx.operations.length !== 1) refuse(`${tx.operations.length} operations; admin-v2.ts writes exactly one contract call`);
  const op = tx.operations[0] as any;
  if (op.type !== "invokeHostFunction") refuse(`the operation is ${safe(String(op.type))}, not a contract call`);
  if (op.source) refuse("the operation has its own source account; admin-v2.ts never sets one");
  const f = op.func as xdr.HostFunction;
  if (f.switch().name !== "hostFunctionTypeInvokeContract") refuse(`the operation is ${safe(f.switch().name)}, not a contract call`);
  const call = f.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const fnName = call.functionName().toString();
  const args = call.args();
  const target = known.targets.get(contract);
  if (!target) {
    refuse(
      labels.has(contract)
        ? `the call goes to ${label(contract, labels)}, which admin-v2.ts never calls`
        : `the call goes to ${contract}, which is none of DyorHQ's contracts (deployments/testnet.json, testnet-v2.json)`,
    );
  }
  if (env.contract !== contract || env.function !== fnName || env.source !== tx.source) {
    refuse(
      `the file says ${safe(String(env.function))} on ${safe(String(env.contract))} from ${safe(String(env.source))}, but its transaction calls ` +
        `${safe(fnName)} on ${contract} from ${tx.source}`,
    );
  }
  const fn = adminFn(target!, fnName);
  if (!fn) {
    const writes = ADMIN_FNS.filter((x) => x.target === target).map((x) => x.fn);
    refuse(`${target} ${safe(fnName)} is a call admin-v2.ts never writes; on the ${target} it writes only ${writes.join(", ")}`);
  }
  const decoded = decodeAdminArgs(fn!, args, tx.source);
  if ("bad" in decoded) {
    refuse(
      decoded.bad < 0
        ? `${fnName} has ${args.length} argument(s); admin-v2.ts writes ${decoded.expected}`
        : `argument ${decoded.bad + 1} of ${fnName} is ${renderScVal(args[decoded.bad])}; admin-v2.ts writes ${decoded.expected}`,
    );
  }
  const auth = (op.auth ?? []) as xdr.SorobanAuthorizationEntry[];
  const sameCall = (inv: xdr.SorobanAuthorizedInvocation) => {
    const g = inv.function();
    if (g.switch().name !== "sorobanAuthorizedFunctionTypeContractFn") return false;
    const c = g.contractFn();
    return c.contractAddress().toXDR("base64") === call.contractAddress().toXDR("base64") &&
      c.functionName().toString() === fnName &&
      c.args().length === args.length &&
      c.args().every((a, i) => a.toXDR("base64") === args[i].toXDR("base64"));
  };
  auth.forEach((a, i) => {
    if (a.credentials().switch().name !== "sorobanCredentialsSourceAccount") {
      refuse(`auth entry ${i + 1} needs another account's signature; admin-v2.ts uses the source account's only`);
    }
    if (!sameCall(a.rootInvocation())) {
      refuse(`auth entry ${i + 1} authorizes ${invocationText(a.rootInvocation(), labels)}, not the call ${fnName} itself`);
    }
    const subs = a.rootInvocation().subInvocations();
    if (subs.length) {
      refuse(
        `auth entry ${i + 1} also authorizes ${subs.length} sub-invocation(s), the first ${invocationText(subs[0], labels)}; ` +
          `admin-v2.ts's calls authorize nothing beyond themselves`,
      );
    }
  });
  let soroban: xdr.SorobanTransactionData | null = null;
  try {
    soroban = body.ext().sorobanData();
  } catch {
    soroban = null;
  }
  if (!soroban) refuse("the transaction isn't prepared (no Soroban data); build it with admin-v2.ts");
  const fee = BigInt(tx.fee);
  if (fee > TESTNET.feePolicy.maxFee) refuse(`the max fee ${fmtXlm(fee)} is above the ${fmtXlm(TESTNET.feePolicy.maxFee)} cap`);
  if (!fn!.roles.includes(env.role as SigningRole)) {
    refuse(`the file says --as ${safe(String(env.role))}, but admin-v2.ts writes ${target} ${fnName} for --as ${fn!.roles.join(" or ")}`);
  }
  if (typeof env.builtAt !== "string" || !ISO_TIME.test(env.builtAt)) refuse(`the file's build time "${safe(String(env.builtAt))}" isn't a time admin-v2.ts writes`);
  const description = describeAdminCall(fn!, (decoded as { values: ArgValue[] }).values, tx.source);
  if (env.description !== description) refuse(`the file describes the call as "${safe(String(env.description))}", but its transaction is: ${safe(description)}`);

  const expired = left < 0;
  const argLabel = (a: xdr.ScVal) => {
    const shown = renderScVal(a);
    return a.switch().name === "scvAddress" && labels.has(shown) ? `${shown} (${safe(labels.get(shown)!)})` : shown;
  };
  const lines = [
    `  network      testnet ✓`,
    `  description  ${safe(description)}`,
    `  built        ${env.builtAt}`,
    `  max fee      ${fmtUnits(fee)} XLM (${fee.toLocaleString("en-US")} stroops; resource fee ${fmtUnits(BigInt(soroban!.resourceFee().toString()))} XLM)`,
    `  sequence     ${tx.sequence}`,
    `  valid until  ${isoTime(maxTime)}${expired ? " (expired: build it again)" : ""}`,
    `  memo         none; no signatures yet`,
    `  operation    one contract call, no operation source`,
    `      contract ${label(contract, labels)}`,
    `      call     ${fnName}(${args.map(renderScVal).join(", ")})`,
    ...args.map((a, i) => `      arg ${i + 1}    ${a.switch().name.replace(/^scv/, "")} ${argLabel(a)}`),
    ...(auth.length === 0
      ? ["      auth     none: the call needs no signature but the transaction's"]
      : auth.map((_a, i) => `      auth ${i + 1}   the source account authorizes this call only, no sub-invocations`)),
  ];
  return { tx, fn: fn!, description, lines, expired };
}

const label = (a: string, labels: Map<string, string>) => (labels.has(a) ? `${a} (${safe(labels.get(a)!)})` : a);

/** One invocation as text, for a refusal: `<contract> <fn>(<args>)`, or a contract creation with its arguments. */
function invocationText(inv: xdr.SorobanAuthorizedInvocation, labels: Map<string, string>): string {
  const g = inv.function();
  switch (g.switch().name) {
    case "sorobanAuthorizedFunctionTypeContractFn": {
      const c = g.contractFn();
      return `${label(Address.fromScAddress(c.contractAddress()).toString(), labels)} ${safe(c.functionName().toString())}(${c.args().map(renderScVal).join(", ")})`;
    }
    case "sorobanAuthorizedFunctionTypeCreateContractHostFn":
    case "sorobanAuthorizedFunctionTypeCreateContractV2HostFn": {
      const v2 = g.switch().name === "sorobanAuthorizedFunctionTypeCreateContractV2HostFn";
      const c: any = v2 ? g.createContractV2HostFn() : g.createContractHostFn();
      const exec = c.executable();
      const what = exec.switch().name === "contractExecutableWasm" ? `WASM ${Buffer.from(exec.wasmHash()).toString("hex")}` : "a Stellar Asset Contract";
      const pre = c.contractIdPreimage();
      const from = pre.switch().name === "contractIdPreimageFromAddress"
        ? ` by ${Address.fromScAddress(pre.fromAddress().address()).toString()} with salt ${Buffer.from(pre.fromAddress().salt()).toString("hex")}`
        : " for a classic asset";
      const ctorArgs = v2 ? (c.constructorArgs() as xdr.ScVal[]).map(renderScVal).join(", ") : "";
      return `create a contract from ${what}${from}(${ctorArgs})`;
    }
  }
  return safe(g.switch().name);
}

async function sign(ctx: OwnerCtx, args: string[]): Promise<number> {
  const say = (l = "") => ctx.io.out(l);
  let file = "";
  let role = "";
  let decodeOnly = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--as") role = args[++i] ?? "";
    else if (args[i] === "--decode-only") decodeOnly = true;
    else if (!args[i].startsWith("--") && !file) file = args[i];
    else throw new Error(`unknown argument ${safe(args[i])}\n${USAGE}`);
  }
  if (!file || !(SIGNING_ROLES as readonly string[]).includes(role)) throw new Error(USAGE);
  refuseRoleEnv(ctx.env);

  const env = parseEnvelope(await Deno.readTextFile(file));
  const known = await knownContracts(ctx.deploymentsDir);
  labelRoles(known.labels, (await loadRolesFile(ctx.secretsDir).catch(() => null))?.roles ?? {});
  const { tx, fn, lines, expired } = inspectEnvelope(env, known, Date.now());
  if (!fn.roles.includes(role as SigningRole)) {
    throw new Error(`refused: admin-v2.ts writes ${fn.target} ${fn.fn} for --as ${fn.roles.join(" or ")}, not --as ${role}`);
  }

  const { key, addresses, from } = await roleKey(ctx, role as SigningRole);
  if (!addresses.includes(tx.source)) {
    throw new Error(
      `refused: the envelope's source is ${tx.source}, not the ${role} key's address (${addresses.join(" or ")}). ` +
        `If ${tx.source} is your own ${role} key: ${from}`,
    );
  }
  say(`Envelope ${safe(file)}`);
  if (env.role !== role) say(`  note: the envelope was built for --as ${safe(String(env.role))}`);
  say(`  source       ${tx.source} (${role}) ✓`);
  for (const l of lines) say(l);
  if (expired) throw new Error("refused: the envelope has expired; build it again with admin-v2.ts");
  if (decodeOnly) return 0;

  if (!key) throw new Error(`no key for ${role}: ${from}`);
  if (!ctx.isTerminal()) throw new Error("refused: signing asks for a yes in a terminal, and this isn't one (there is no TTY)");
  const answer = (await ctx.ask("Sign and submit? [y/N] "))?.trim().toLowerCase();
  if (answer !== "y" && answer !== "yes") {
    say("Not signed. Nothing was sent.");
    return 1;
  }
  tx.sign(key);
  const out = await ctx.chain.submit(tx);
  say(`✓ submitted: transaction ${out.hash}, ledger ${out.ledger}, fee ${fmtXlm(out.feeCharged)}`);
  say(`  result: ${out.returnValue ? renderScVal(out.returnValue) : "()"}`);
  return 0;
}

/** The key for a role (never printed) and the addresses its envelopes may come from. */
async function roleKey(ctx: OwnerCtx, role: SigningRole): Promise<{ key: Keypair | null; addresses: string[]; from: string }> {
  if (role === "v1-admin") {
    const v1 = (await readJson(`${ctx.deploymentsDir}/testnet.json`)) as V1Deployment | null;
    if (!v1) throw new Error("no deployments/testnet.json: the v1 admin is unknown");
    const path = `${ctx.secretsDir}/${V1_DEPLOYER_FILE}`;
    const key = (await secretFromEnvFile(path, "DEPLOYER_SECRET")) ?? secretFromEnv(ctx.env, "DEPLOYER_SECRET");
    return {
      key,
      addresses: key ? [key.publicKey()] : [v1.admin],
      from: `DEPLOYER_SECRET from ${path} (the live v1 admin ${v1.admin}); if you moved that file to your password manager, set DEPLOYER_SECRET with read -rs`,
    };
  }
  const rolesFile = await loadRolesFile(ctx.secretsDir);
  const roles = rolesFile ? rolesFile.roles : {};
  const keysFile = await loadKeysFile(ctx.secretsDir);
  const pick = (envName: string, fileKey: Keypair | undefined, roleAddresses: (string | undefined)[]) => {
    const k = secretFromEnv(ctx.env, envName) ?? fileKey ?? null;
    const addresses = k ? [k.publicKey()] : roleAddresses.filter((x): x is string => !!x);
    return { key: k, addresses, from: `set ${envName} (read -rs ${envName} && export ${envName}), or keep it in ${KEYS_FILE}` };
  };
  switch (role) {
    case "admin":
      return pick("ADMIN_SECRET", keysFile?.keys.ADMIN_SECRET, [roles.ADMIN_PUBLIC]);
    case "governance":
      return pick("GOVERNANCE_SECRET", keysFile?.keys.ADMIN_SECRET, [roles.GOVERNANCE_PUBLIC]);
    case "guardian":
      return pick("GUARDIAN_SECRET", keysFile?.keys.GUARDIAN_SECRET, [roles.LAUNCHPAD_GUARDIAN_PUBLIC, roles.MOMENTS_GUARDIAN_PUBLIC]);
    case "treasury":
      return pick("TREASURY_SECRET", keysFile?.keys.TREASURY_SECRET, [roles.TREASURY_PUBLIC]);
  }
}

/** A readable ScVal: numbers in full, addresses as strkeys, bytes in hex, maps and vectors expanded; strings and
 *  symbols escaped (they come from the envelope). */
export function renderScVal(v: xdr.ScVal): string {
  const k = v.switch().name;
  switch (k) {
    case "scvBool":
      return String(v.b());
    case "scvVoid":
      return "()";
    case "scvU32":
    case "scvI32":
    case "scvU64":
    case "scvI64":
    case "scvU128":
    case "scvI128":
    case "scvU256":
    case "scvI256":
    case "scvTimepoint":
    case "scvDuration":
      return String(scValToNative(v));
    case "scvBytes":
      return Buffer.from(v.bytes()).toString("hex");
    case "scvString":
      return `"${safe(v.str().toString()).replace(/"/g, '\\"')}"`;
    case "scvSymbol":
      return safe(v.sym().toString());
    case "scvAddress":
      return Address.fromScVal(v).toString();
    case "scvVec":
      return `[${(v.vec() ?? []).map(renderScVal).join(", ")}]`;
    case "scvMap":
      return `{${(v.map() ?? []).map((e) => `${renderScVal(e.key())}: ${renderScVal(e.val())}`).join(", ")}}`;
    default:
      return k.replace(/^scv/, "");
  }
}

if (import.meta.main) Deno.exit(await main(Deno.args, realCtx()));
