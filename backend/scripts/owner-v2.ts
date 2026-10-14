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
//           admin-v2.ts, then asks "Sign and submit? [y/N]" in a terminal, signs, submits and waits.
//
// No secret is ever printed: keys are read by the script and only addresses are shown.
import { Buffer } from "node:buffer";
import { Address, Asset, FeeBumpTransaction, type Keypair, Operation, scValToNative, type Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";
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
    const live = await aquariusLiveCheck(chain, await loadAquariusFixtures(ctx.root));
    for (const l of live.lines) add(line(l.ok, `Aquarius ${l.label} matches fixtures.json`, l.ok ? l.fixture : `live ${l.live ?? "unreadable"}, fixture ${l.fixture}: CT-03's gate must be re-run, or deploy with --aquarius off`));
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

/** Contract labels for the summary: v1 from deployments/testnet.json, v2 from testnet-v2.json when it exists. */
async function contractNames(ctx: OwnerCtx): Promise<Map<string, string>> {
  const m = new Map<string, string>();
  const v1 = (await readJson(`${ctx.deploymentsDir}/testnet.json`)) as V1Deployment | null;
  if (v1) {
    m.set(v1.launchpad, "v1 launchpad");
    m.set(v1.moments, "v1 Moments");
  }
  const v2 = await readJson(`${ctx.deploymentsDir}/testnet-v2.json`);
  for (const [k, v] of Object.entries((v2?.contracts ?? {}) as Record<string, string>)) m.set(v, k);
  for (const a of TESTNET.assets) m.set(a.contract, `${a.id} SAC`);
  return m;
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
    else throw new Error(`unknown argument ${args[i]}\n${USAGE}`);
  }
  if (!file || !(SIGNING_ROLES as readonly string[]).includes(role)) throw new Error(USAGE);
  refuseRoleEnv(ctx.env);

  const env = parseEnvelope(await Deno.readTextFile(file));
  if (env.networkPassphrase !== TESTNET.passphrase) {
    throw new Error(`refused: the envelope is for the network "${env.networkPassphrase}", not testnet`);
  }
  let parsed: Transaction | FeeBumpTransaction;
  try {
    parsed = TransactionBuilder.fromXDR(env.xdr, TESTNET.passphrase);
  } catch {
    throw new Error("refused: the envelope's XDR can't be read");
  }
  if (parsed instanceof FeeBumpTransaction) throw new Error("refused: a fee-bump envelope");
  const tx = parsed;

  const { key, addresses, from } = await roleKey(ctx, role as SigningRole);
  if (!addresses.includes(tx.source)) {
    throw new Error(
      `refused: the envelope's source is ${tx.source}, not the ${role} key's address (${addresses.join(" or ")}). ` +
        `If ${tx.source} is your own ${role} key: ${from}`,
    );
  }
  if (env.role !== role) say(`note: the envelope was built for --as ${env.role}`);

  const names = await contractNames(ctx);
  say(`Envelope ${file}`);
  say(`  network      testnet ✓`);
  say(`  built        ${env.builtAt ?? "?"}: ${env.description ?? ""}`);
  say(`  source       ${tx.source} (${role}) ✓`);
  say(`  max fee      ${fmtUnits(BigInt(tx.fee))} XLM (${BigInt(tx.fee).toLocaleString("en-US")} stroops)`);
  say(`  sequence     ${tx.sequence}`);
  const maxTime = Number(tx.timeBounds?.maxTime ?? 0);
  const expired = maxTime !== 0 && maxTime * 1000 < Date.now();
  say(`  valid until  ${maxTime === 0 ? "no limit" : new Date(maxTime * 1000).toISOString()}${expired ? " (expired: build it again)" : ""}`);
  say(`  signatures   ${tx.signatures.length}`);
  say(`  operations   ${tx.operations.length}`);
  tx.operations.forEach((op, i) => {
    for (const l of describeOperation(op, i + 1, names, tx.source)) say(l);
  });
  if (decodeOnly) return 0;

  if (expired) throw new Error("refused: the envelope has expired; build it again with admin-v2.ts");
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

/** A plain description of one operation: a contract call with its decoded arguments, or the classic operation. */
export function describeOperation(op: Transaction["operations"][number], n: number, names: Map<string, string>, txSource: string): string[] {
  const label = (a: string) => (names.has(a) ? `${a} (${names.get(a)})` : a);
  const out: string[] = [];
  const src = (op as { source?: string }).source;
  if (src && src !== txSource) out.push(`   ${n}. operation source ${src} (not the envelope's source: refuse to sign it unless you expect this)`);
  if (op.type === "invokeHostFunction") {
    const f = (op as any).func as xdr.HostFunction;
    switch (f.switch().name) {
      case "hostFunctionTypeInvokeContract": {
        const ic = f.invokeContract();
        const contract = Address.fromScAddress(ic.contractAddress()).toString();
        const fn = ic.functionName().toString();
        const args = ic.args();
        out.push(`   ${n}. contract ${label(contract)}`);
        out.push(`      call     ${fn}(${args.map(renderScVal).join(", ")})`);
        args.forEach((a, i) => out.push(`      arg ${i + 1}    ${a.switch().name.replace(/^scv/, "")} ${renderScVal(a)}`));
        break;
      }
      case "hostFunctionTypeUploadContractWasm":
        out.push(`   ${n}. upload a WASM of ${f.wasm().length} bytes`);
        break;
      default:
        out.push(`   ${n}. create a contract (${f.switch().name})`);
    }
    const auth = ((op as any).auth ?? []) as xdr.SorobanAuthorizationEntry[];
    for (const a of auth) {
      const c = a.credentials();
      out.push(`      auth     ${c.switch().name === "sorobanCredentialsSourceAccount" ? "the source account's signature" : `a separate signature by ${Address.fromScAddress(c.address().address()).toString()}`}`);
    }
    return out;
  }
  const o = op as any;
  const fields = Object.entries(o)
    .filter(([k]) => k !== "type" && k !== "source")
    .map(([k, v]) => `${k} ${v instanceof Asset ? (v.isNative() ? "XLM" : `${v.getCode()}:${v.getIssuer()}`) : String(v)}`);
  out.push(`   ${n}. ${op.type}${fields.length ? `: ${fields.join(", ")}` : ""}`);
  return out;
}

/** A readable ScVal: numbers in full, addresses as strkeys, bytes in hex, maps and vectors expanded. */
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
      return JSON.stringify(v.str().toString());
    case "scvSymbol":
      return v.sym().toString();
    case "scvAddress":
      return Address.fromScVal(v).toString();
    case "scvVec":
      return `[${(v.vec() ?? []).map(renderScVal).join(", ")}]`;
    case "scvMap":
      return `{${(v.map() ?? []).map((e) => `${e.key().switch().name === "scvSymbol" ? e.key().sym().toString() : renderScVal(e.key())}: ${renderScVal(e.val())}`).join(", ")}}`;
    default:
      return k.replace(/^scv/, "");
  }
}

if (import.meta.main) Deno.exit(await main(Deno.args, realCtx()));
