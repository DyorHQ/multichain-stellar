// The preflight (CT-11a lead decision L-e, finding F9) against a mocked chain, the multisig check (B11a) and the
// envelope format. No network.
import { assert, assertEquals, assertRejects, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Keypair, xdr } from "@stellar/stellar-sdk";
import {
  type AccountInfo,
  allNeededPass,
  type ChainReader,
  ENVELOPE_FORMAT,
  fmtUnits,
  parseEnvelope,
  preflight,
  readOnlyChain,
  renderCheck,
  simulationError,
  singleSignerMeetsMedium,
  STROOPS_PER_XLM,
  toStroops,
} from "./preflight-v2.ts";
import type { V2Roles } from "./v2-profile.ts";

const kp = (n: number) => Keypair.fromRawEd25519Seed(Buffer.alloc(32, n));
const USDC = "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5";
const QA = `DYORQA:${kp(9).publicKey()}`;
const XLM = (n: number) => BigInt(n) * STROOPS_PER_XLM;

function acct(id: string, xlm: bigint, trust: string[] = []): AccountInfo {
  return {
    id,
    sequence: "1",
    xlm,
    trustlines: trust.map((asset) => ({ asset, balance: 0n, authorized: true })),
    signers: [{ key: id, weight: 1 }],
    thresholds: { low: 0, med: 0, high: 0 },
  };
}

function chainOf(accounts: AccountInfo[]): ChainReader {
  const m = new Map(accounts.map((a) => [a.id, a]));
  const no = () => Promise.reject(new Error("not used"));
  return {
    passphrase: "Test SDF Network ; September 2015",
    account: (id) => Promise.resolve(m.get(id) ?? null),
    latestLedger: () => Promise.resolve(1),
    contractWasmHash: no,
    instanceStorage: no,
    codeExists: no,
    view: no,
  };
}

const ADMIN = kp(1).publicKey();
const GUARD = kp(2).publicKey();
const TREAS = kp(3).publicKey();
const PLAT = kp(4).publicKey();
const roles: V2Roles = {
  ADMIN_PUBLIC: ADMIN,
  GOVERNANCE_PUBLIC: ADMIN,
  LAUNCHPAD_GUARDIAN_PUBLIC: GUARD,
  MOMENTS_GUARDIAN_PUBLIC: GUARD,
  TREASURY_PUBLIC: TREAS,
  PLATFORM_PUBLIC: PLAT,
};

const base = (accounts: AccountInfo[], treasuryAssets = [USDC], min = XLM(1_000)) =>
  preflight({ chain: chainOf(accounts), roles, deployer: ADMIN, treasuryAssets, platformAssets: [USDC], minDeployerXlm: min, assetNames: new Map([[USDC, "USDC"], [QA, "DYORQA"]]) });

Deno.test("a complete testnet setup passes the preflight", async () => {
  const lines = await base([acct(ADMIN, XLM(10_000)), acct(GUARD, XLM(10_000)), acct(TREAS, XLM(10_000), [USDC]), acct(PLAT, XLM(5), [USDC])]);
  assert(allNeededPass(lines), lines.map(renderCheck).join("\n"));
  assertEquals(lines.map((l) => l.label), [
    "admin + Moments governance account exists",
    "launchpad guardian + Moments guardian account exists",
    "treasury account exists",
    "Moments platform account exists",
    "treasury trusts USDC",
    "Moments platform trusts USDC",
    "deployer holds at least 1,000 XLM",
  ]);
});

Deno.test("a treasury without a USDC trustline is refused (claim_protocol_fees is all-or-nothing, F9)", async () => {
  const lines = await base([acct(ADMIN, XLM(10_000)), acct(GUARD, XLM(1)), acct(TREAS, XLM(10)), acct(PLAT, XLM(5), [USDC])]);
  assert(!allNeededPass(lines));
  const bad = lines.filter((l) => !l.ok);
  assertEquals(bad.map((l) => l.label), ["treasury trusts USDC"]);
  assertStringIncludes(renderCheck(bad[0]), `✗ treasury trusts USDC: ${TREAS} has no USDC trustline`);
});

Deno.test("on testnet-qa the treasury must also trust the QA asset", async () => {
  const accounts = [acct(ADMIN, XLM(10_000)), acct(GUARD, XLM(1)), acct(TREAS, XLM(10), [USDC]), acct(PLAT, XLM(5), [USDC])];
  const lines = await base(accounts, [USDC, QA]);
  assertEquals(lines.filter((l) => !l.ok).map((l) => l.label), ["treasury trusts DYORQA"]);
  accounts[2].trustlines.push({ asset: QA, balance: 0n, authorized: true });
  assert(allNeededPass(await base(accounts, [USDC, QA])));
  // An unauthorized trustline doesn't count.
  accounts[2].trustlines[1].authorized = false;
  assert(!allNeededPass(await base(accounts, [USDC, QA])));
});

Deno.test("the Moments platform must trust USDC; a missing role account and a poor deployer are refused", async () => {
  const lines = await base([acct(ADMIN, XLM(999)), acct(TREAS, XLM(10), [USDC]), acct(PLAT, XLM(5))]);
  assertEquals(lines.filter((l) => !l.ok).map((l) => l.label), [
    "launchpad guardian + Moments guardian account exists",
    "Moments platform trusts USDC",
    "deployer holds at least 1,000 XLM",
  ]);
  // 2,500 XLM with --fund-aqua-float.
  const rich = [acct(ADMIN, XLM(2_000)), acct(GUARD, XLM(1)), acct(TREAS, XLM(10), [USDC]), acct(PLAT, XLM(5), [USDC])];
  assert(allNeededPass(await base(rich)));
  assert(!allNeededPass(await base(rich, [USDC], XLM(2_500))));
});

Deno.test("platform = treasury is checked once", async () => {
  const shared: V2Roles = { ...roles, PLATFORM_PUBLIC: TREAS };
  const lines = await preflight({
    chain: chainOf([acct(ADMIN, XLM(10_000)), acct(GUARD, XLM(1)), acct(TREAS, XLM(10), [USDC])]),
    roles: shared,
    deployer: ADMIN,
    treasuryAssets: [USDC],
    platformAssets: [USDC],
    minDeployerXlm: XLM(1_000),
  });
  assert(allNeededPass(lines));
  assertEquals(lines.filter((l) => l.label.includes("trusts")).length, 1);
  assertEquals(lines[2].label, "treasury + Moments platform account exists");
});

Deno.test("a 2-signer account with medium threshold 1 is refused: one signer meets it alone", () => {
  const two = (med: number, w1 = 1, w2 = 1): AccountInfo => ({
    ...acct(ADMIN, XLM(1)),
    signers: [{ key: ADMIN, weight: w1 }, { key: GUARD, weight: w2 }],
    thresholds: { low: 1, med, high: 2 },
  });
  assert(singleSignerMeetsMedium(two(1)));
  assert(singleSignerMeetsMedium(two(0)));
  assert(singleSignerMeetsMedium(two(2, 2, 1)), "a weight-2 signer meets 2 alone");
  assert(!singleSignerMeetsMedium(two(2)));
  assert(!singleSignerMeetsMedium(acct(ADMIN, XLM(1))), "a single-signer account isn't multi-signer");
  assert(!singleSignerMeetsMedium({ ...two(1), signers: [{ key: ADMIN, weight: 1 }, { key: GUARD, weight: 0 }] }));
});

Deno.test("a read-only chain refuses everything that sends", async () => {
  const ro = readOnlyChain(chainOf([]));
  await assertRejects(() => ro.friendbot(ADMIN), Error, "read-only");
  await assertRejects(() => ro.submit({} as never), Error, "read-only");
  await assertRejects(() => ro.prepare({} as never), Error, "read-only");
  await assertRejects(() => ro.sourceAccount(ADMIN), Error, "read-only");
  assertEquals(await ro.account(ADMIN), null);
});

Deno.test("envelope files are recognised, and anything else is refused", () => {
  const e = { format: ENVELOPE_FORMAT, networkPassphrase: "x", role: "admin", source: ADMIN, contract: "C", function: "f", description: "", builtAt: "", xdr: "AAAA" };
  assertEquals(parseEnvelope(JSON.stringify(e)).role, "admin");
  assertThrows(() => parseEnvelope("AAAAAgAAAAA="), Error, "not JSON");
  assertThrows(() => parseEnvelope(JSON.stringify({ ...e, format: "other" })), Error, "format other");
  assertThrows(() => parseEnvelope(JSON.stringify({ ...e, xdr: "" })), Error, "no xdr");
});

Deno.test("numbers and simulation errors read plainly", () => {
  assertEquals(toStroops("12.34"), 123_400_000n);
  assertEquals(toStroops("0.0000001"), 1n);
  assertEquals(fmtUnits(43_245_553_200n), "4,324.55532");
  assertEquals(fmtUnits(100_000_000n), "10");
  assertEquals(simulationError("HostError: Error(Contract, #10134)\nEvent log: …"), "contract error #10134");
  assertEquals(simulationError("HostError: Error(Auth, InvalidAction)"), "host error Auth/InvalidAction");
  void xdr;
});
