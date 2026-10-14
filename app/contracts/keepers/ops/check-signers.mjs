#!/usr/bin/env node
// The keeper signer check (build 17 K4; owner rules: one key per unit, never a custody key, funding 30 / 10 / 5 MON
// with minimums 10 / 3 / 1). Read-only: it reads public addresses, balances and Safe owners, never sends, and never
// prints a password or a keystore.
//
//   node check-signers.mjs grad=0x… sweeps=0x… buybacks=0x…   addresses already derived (entrypoint.sh at boot)
//   node check-signers.mjs --keystores DIR                     derives each address with `cast wallet address` from
//                                                              DIR/<unit>.keystore and DIR/<unit>.password (the layout
//                                                              entrypoint.sh writes: /run/dyor-keeper on the Machine)
//   options: --signers FILE (default ops/keeper-signers.json), --rpc-url URL (repeatable; default KEEPER_RPC_URLS,
//            else rpc3 then rpc4), --no-chain (records and pins only), --require-funding (a low or unread balance
//            fails the check: for the owner before a send flag goes to 1)
//
// Each signer is checked against:
//  - the other units: each unit needs its own key (nonces and spend caps are per key);
//  - the deployment records: never an address a record names in a role (owner, governance, guardian, treasury, fees
//    recipient, platform, deployer), and never a signer of an owner or governance Safe (getOwners() on chain);
//  - its pin in keeper-signers.json: the keystore must derive exactly the pinned address; a unit with no pin runs dry
//    runs only;
//  - its funding: the balance against the unit's minimum.
// Output, one line each: "OK <unit> <address> …", "FORBIDDEN <unit> <reason>" (never use this key),
// "UNPINNED <unit> <reason>" (dry runs only), "LOW <unit> <reason>" (top it up), "NOTE <text>".
// Exit 0 when every unit may send, 1 when one may not (or, with --require-funding, is underfunded or unread), 2 on a
// usage error, 3 when the check itself failed.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { formatEther, parseEther } from "viem";
import { makeRpcClient, DEFAULT_RPC_URLS } from "../lib/rpc.mjs";
import { redact } from "../lib/redact.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_DEPLOYMENTS = join(HERE, "..", "..", "deployments");
export const DEFAULT_SIGNERS = join(HERE, "keeper-signers.json");
export const SIGNING_UNITS = Object.freeze(["grad", "sweeps", "buybacks"]);
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const ROLE_KEY = /owner|governance|guardian|treasury|recipient|deployer|platform/i;
const SAFE_KEY = /^(owner|governance)$/i;
const getOwnersAbi = [{ type: "function", name: "getOwners", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] }];

/** Every address a deployment record names in a role: Map(lowercase address -> ["143.json owner", …]). Also returns
    the owner / governance addresses, which may be Safes. */
export function roleAddresses(records) {
  const roles = new Map();
  const safes = new Set();
  const walk = (file, obj, path) => {
    for (const [k, v] of Object.entries(obj ?? {})) {
      if (typeof v === "string" && ADDRESS.test(v) && ROLE_KEY.test(k)) {
        const a = v.toLowerCase();
        if (!roles.has(a)) roles.set(a, []);
        roles.get(a).push(`${file} ${path}${k}`);
        if (SAFE_KEY.test(k)) safes.add(a);
      } else if (v && typeof v === "object") {
        walk(file, v, `${path}${k}.`);
      }
    }
  };
  for (const [file, record] of records) walk(file, record, "");
  return { roles, safes: [...safes] };
}

export function readRecords(dir = DEFAULT_DEPLOYMENTS) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => [f, JSON.parse(readFileSync(join(dir, f), "utf8"))]);
}

/** keeper-signers.json -> Map(unit -> { address (lowercase, or "" when not pinned), minBalance (wei), fund, … }). */
export function readPins(file = DEFAULT_SIGNERS) {
  const json = JSON.parse(readFileSync(file, "utf8"));
  const pins = new Map();
  for (const [unit, p] of Object.entries(json?.units ?? {})) {
    const address = String(p?.address ?? "");
    if (address && !ADDRESS.test(address)) throw new Error(`${file}: the ${unit} address ${JSON.stringify(address)} is not an address`);
    pins.set(unit, { address: address.toLowerCase(), fund: String(p.fund), minBalance: parseEther(String(p.minBalance)), maxSpendPerDay: String(p.maxSpendPerDay) });
  }
  return pins;
}

/**
 * `units`: [[unit, address], …]. `roles`: from roleAddresses. `safeSigners`: Map(lowercase signer -> Safe address).
 * `pins`: from readPins (optional). Returns [{ unit, address, ok, reason, unpinned? }]: `ok` false means the key must
 * never be used; `unpinned` means it may run dry runs only.
 */
export function checkSigners(units, { roles = new Map(), safeSigners = new Map(), pins } = {}) {
  const seen = new Map();
  for (const [unit, address] of units) {
    const a = String(address).toLowerCase();
    if (!seen.has(a)) seen.set(a, []);
    seen.get(a).push(unit);
  }
  return units.map(([unit, address]) => {
    if (!ADDRESS.test(String(address))) return { unit, address, ok: false, reason: `${JSON.stringify(address)} is not an address` };
    const a = address.toLowerCase();
    const shared = seen.get(a).filter((u) => u !== unit);
    if (shared.length) return { unit, address, ok: false, reason: `${address} is also the ${shared.join(", ")} keeper: each unit needs its own key (nonces and spend caps are per key)` };
    if (roles.has(a)) return { unit, address, ok: false, reason: `${address} is a custody or protocol address (${roles.get(a).join("; ")}): never a keeper key` };
    if (safeSigners.has(a)) return { unit, address, ok: false, reason: `${address} signs for the Safe ${safeSigners.get(a)}: never a keeper key` };
    if (pins) {
      const pin = pins.get(unit);
      if (!pin) return { unit, address, ok: false, reason: `keeper-signers.json has no ${unit} unit` };
      if (!pin.address) return { unit, address, ok: true, unpinned: true, reason: `${address}: keeper-signers.json pins no ${unit} address yet, so this unit runs dry runs only (pin it in a reviewed commit)` };
      if (pin.address !== a) return { unit, address, ok: false, reason: `the ${unit} keystore derives ${address}, but keeper-signers.json pins ${pin.address}: the wrong key, or the pin is out of date` };
    }
    return { unit, address, ok: true };
  });
}

/** "LOW …" reasons, or "" when the balance meets the unit's minimum. */
export function fundingNote(unit, address, balance, pin) {
  if (!pin) return "";
  if (balance >= pin.minBalance) return "";
  return `${address} holds ${formatEther(balance)} MON, below the ${unit} minimum of ${formatEther(pin.minBalance)} MON: top it up to ${pin.fund} MON`;
}

/** Map(lowercase signer -> Safe) for every candidate that answers getOwners(); `failed` lists the ones that could not be
    read (an RPC failure) — an EOA or a non-Safe contract simply has no owners. */
export async function readSafeSigners(client, candidates) {
  const signers = new Map();
  const failed = [];
  for (const safe of candidates) {
    let code;
    try {
      code = await client.getCode({ address: safe });
    } catch {
      failed.push(safe);
      continue;
    }
    if (!code || code === "0x") continue;
    try {
      const owners = await client.readContract({ address: safe, abi: getOwnersAbi, functionName: "getOwners" });
      for (const o of owners) signers.set(o.toLowerCase(), safe);
    } catch (e) {
      if (!/revert|returned no data|does not have the function/i.test(`${e?.shortMessage ?? ""} ${e?.message ?? ""}`)) failed.push(safe);
    }
  }
  return { signers, failed };
}

export function parseUnits(argv) {
  return argv.map((arg) => {
    const m = /^([a-z]+)=(.*)$/.exec(arg);
    if (!m) throw new Error(`expected unit=0xADDRESS, got ${JSON.stringify(arg)}`);
    return [m[1], m[2]];
  });
}

function castBin(env) {
  if (env.CAST_BIN) return env.CAST_BIN;
  const home = join(homedir(), ".foundry", "bin", "cast");
  return existsSync(home) ? home : "cast";
}

/**
 * Derives each signing unit's address from DIR/<unit>.keystore with DIR/<unit>.password. A unit with neither file is
 * left out; one that cannot be opened becomes an "unusable" entry. cast's output and errors are never printed.
 */
export function deriveFromKeystores(dir, { cast = "cast", spawn = spawnSync } = {}) {
  const units = [];
  const unusable = [];
  for (const unit of SIGNING_UNITS) {
    const keystore = join(dir, `${unit}.keystore`);
    const password = join(dir, `${unit}.password`);
    if (!existsSync(keystore) && !existsSync(password)) continue;
    if (!existsSync(keystore) || !existsSync(password)) {
      unusable.push([unit, `${unit}.keystore and ${unit}.password must both be in ${dir}`]);
      continue;
    }
    const r = spawn(cast, ["wallet", "address", "--keystore", keystore, "--password-file", password], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 60_000 });
    const address = String(r.stdout ?? "").trim().split("\n").pop()?.trim() ?? "";
    if (r.status !== 0 || !ADDRESS.test(address)) unusable.push([unit, "cast could not open the keystore with its password"]);
    else units.push([unit, address]);
  }
  return { units, unusable };
}

export async function main(argv, { env = process.env, out = console.log, makeClient = makeRpcClient, spawn = spawnSync } = {}) {
  let o;
  let units;
  let unusable = [];
  try {
    const parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      options: {
        keystores: { type: "string" },
        signers: { type: "string", default: DEFAULT_SIGNERS },
        deployments: { type: "string", default: DEFAULT_DEPLOYMENTS },
        "rpc-url": { type: "string", multiple: true },
        "no-chain": { type: "boolean", default: false },
        "require-funding": { type: "boolean", default: false },
      },
    });
    o = parsed.values;
    if (o.keystores) {
      if (parsed.positionals.length) throw new Error("give --keystores DIR or unit=0xADDRESS arguments, not both");
      ({ units, unusable } = deriveFromKeystores(o.keystores, { cast: castBin(env), spawn }));
      if (!units.length && !unusable.length) throw new Error(`no <unit>.keystore in ${o.keystores}`);
    } else {
      units = parseUnits(parsed.positionals);
      if (!units.length) throw new Error("usage: check-signers.mjs grad=0x… sweeps=0x… buybacks=0x…  |  check-signers.mjs --keystores DIR");
    }
  } catch (e) {
    console.error(`check-signers: ${redact(e.message)}`);
    return 2;
  }
  const pins = readPins(o.signers);
  const { roles, safes } = roleAddresses(readRecords(o.deployments));
  let safeSigners = new Map();
  const balances = new Map();
  let client;
  if (!o["no-chain"]) {
    const urls = o["rpc-url"]?.length ? o["rpc-url"] : env.KEEPER_RPC_URLS ? env.KEEPER_RPC_URLS.split(/\s+/).filter(Boolean) : [...DEFAULT_RPC_URLS];
    try {
      ({ client } = makeClient(urls, { timeoutMs: 10_000 }));
      const r = await readSafeSigners(client, safes);
      safeSigners = r.signers;
      if (r.failed.length) out(`NOTE could not read the owners of ${r.failed.join(", ")} (RPC): checked against the records only`);
    } catch {
      out("NOTE the RPC could not be reached: checked against the records only");
      client = undefined;
    }
  }
  let blocked = 0;
  for (const [unit, reason] of unusable) {
    blocked++;
    out(`FORBIDDEN ${unit} ${reason}`);
  }
  for (const r of checkSigners(units, { roles, safeSigners, pins })) {
    if (!r.ok) {
      blocked++;
      out(`FORBIDDEN ${r.unit} ${r.reason}`);
      continue;
    }
    const pin = pins.get(r.unit);
    let funding = "";
    if (client) {
      try {
        const balance = await client.getBalance({ address: r.address });
        balances.set(r.unit, balance);
        funding = ` holds ${formatEther(balance)} MON (minimum ${formatEther(pin.minBalance)})`;
      } catch {
        funding = " balance unread (RPC)";
      }
    }
    if (r.unpinned) {
      blocked++;
      out(`UNPINNED ${r.unit} ${r.reason}`);
    } else {
      out(`OK ${r.unit} ${r.address}${funding}`);
    }
    const low = balances.has(r.unit) ? fundingNote(r.unit, r.address, balances.get(r.unit), pin) : "";
    if (low) out(`LOW ${r.unit} ${low}`);
    if (o["require-funding"] && (low || !balances.has(r.unit))) blocked++;
  }
  return blocked ? 1 : 0;
}

/** Run as a command (not imported)? argv[1] is the path as given, which may run through a symlink (macOS /var, /tmp),
    while import.meta.url is the real path: compare real paths, or the check would silently do nothing. */
function isMain() {
  try {
    return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e) => {
      console.error(`check-signers failed: ${redact(String(e?.message ?? e).split("\n")[0], (process.env.KEEPER_RPC_URLS ?? "").split(/\s+/))}`);
      process.exit(3);
    },
  );
}
