// The preflight (CT-11a lead decision L-e, finding F9) against a mocked chain, the multisig check (B11a), the
// envelope format, and the real chain's prepare() and liveUntil() against a stand-in RPC. No network.
import { assert, assertEquals, assertFalse, assertRejects, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Account, Address, BASE_FEE, Keypair, Operation, rpc, SorobanDataBuilder, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import {
  type AccountInfo,
  allNeededPass,
  type ChainReader,
  ENVELOPE_FORMAT,
  fitResources,
  fmtUnits,
  parseEnvelope,
  preflight,
  readOnlyChain,
  renderCheck,
  simulationError,
  singleSignerMeetsMedium,
  STROOPS_PER_XLM,
  testnetChain,
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
    liveUntil: no,
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
  // The file's own value isn't echoed (it could carry control characters).
  const odd = assertThrows(() => parseEnvelope(JSON.stringify({ ...e, format: "other\x1b[8m" })), Error, "its format isn't dyorhq-unsigned-envelope/1");
  assertFalse(odd.message.includes("other"));
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

// ------------------------------------------------------------------------------------------------ prepare() and limits

// Testnet's per-transaction limits as read on 2026-10-15 (CONFIG_SETTING_CONTRACT_COMPUTE_V0 and _LEDGER_COST_V0).
const LIMITS = { instructions: 400_000_000, diskReadBytes: 200_000, writeBytes: 132_096 };

Deno.test("declared resources get headroom but never exceed the network's per-transaction limits", () => {
  // The review's repro: a 115,332-byte WASM upload simulates 115,432 write bytes; 1.2× + 1,000 declared 139,519,
  // which the network refuses (its limit is 132,096). Capped now.
  const upload = fitResources({ instructions: 3_000_000, diskReadBytes: 500, writeBytes: 115_432 }, LIMITS);
  assertEquals(upload.writeBytes, 132_096);
  assertEquals(upload.instructions, 3_850_000);
  assertEquals(upload.diskReadBytes, 1_600);
  // Plenty of room: the usual headroom.
  assertEquals(fitResources({ instructions: 1_000_000, diskReadBytes: 10_000, writeBytes: 2_000 }, LIMITS), { instructions: 1_350_000, diskReadBytes: 13_000, writeBytes: 3_400 });
  // Instructions are capped the same way.
  assertEquals(fitResources({ instructions: 399_000_000, diskReadBytes: 0, writeBytes: 0 }, LIMITS).instructions, 400_000_000);
  // A simulation already above a limit can't be sent at all.
  assertThrows(() => fitResources({ instructions: 1, diskReadBytes: 1, writeBytes: 140_000 }, LIMITS), Error, "writeBytes 140000 > 132096");
});

/** A ledger-entry reply for a config setting, as the RPC client returns it. */
function configEntry(setting: xdr.ConfigSettingEntry) {
  return { key: xdr.LedgerKey.configSetting(new xdr.LedgerKeyConfigSetting({ configSettingId: setting.switch() })), val: xdr.LedgerEntryData.configSetting(setting), liveUntilLedgerSeq: undefined };
}

const i64 = (n: number) => xdr.Int64.fromString(String(n));
const COMPUTE = xdr.ConfigSettingEntry.configSettingContractComputeV0(
  new xdr.ConfigSettingContractComputeV0({ ledgerMaxInstructions: i64(600_000_000), txMaxInstructions: i64(LIMITS.instructions), feeRatePerInstructionsIncrement: i64(25), txMemoryLimit: 41_943_040 }),
);
const LEDGER_COST = xdr.ConfigSettingEntry.configSettingContractLedgerCostV0(
  new xdr.ConfigSettingContractLedgerCostV0({
    ledgerMaxDiskReadEntries: 1_000,
    ledgerMaxDiskReadBytes: 7_000_000,
    ledgerMaxWriteLedgerEntries: 800,
    ledgerMaxWriteBytes: 286_720,
    txMaxDiskReadEntries: 200,
    txMaxDiskReadBytes: LIMITS.diskReadBytes,
    txMaxWriteLedgerEntries: 200,
    txMaxWriteBytes: LIMITS.writeBytes,
    feeDiskReadLedgerEntry: i64(6_250),
    feeWriteLedgerEntry: i64(10_000),
    feeDiskRead1Kb: i64(1_786),
    sorobanStateTargetSizeBytes: i64(1),
    rentFee1KbSorobanStateSizeLow: i64(1),
    rentFee1KbSorobanStateSizeHigh: i64(1),
    sorobanStateRentFeeGrowthFactor: 1,
  }),
);

/** A stand-in RPC: config settings, and a simulation that reports `resources`. */
function fakeRpc(opts: { resources: [number, number, number]; settings?: "ok" | "missing" | "down" }) {
  const calls: string[] = [];
  const server = {
    getLedgerEntries(...keys: xdr.LedgerKey[]) {
      calls.push(`getLedgerEntries ${keys.map((k) => k.switch().name).join(",")}`);
      if (opts.settings === "down") return Promise.reject(new Error("503 Service Unavailable"));
      if (keys[0].switch().name === "configSetting") {
        return Promise.resolve({ latestLedger: 100, entries: opts.settings === "missing" ? [configEntry(COMPUTE)] : [configEntry(COMPUTE), configEntry(LEDGER_COST)] });
      }
      return Promise.resolve({ latestLedger: 100, entries: [] });
    },
    simulateTransaction() {
      calls.push("simulateTransaction");
      const [instructions, read, write] = opts.resources;
      return Promise.resolve({
        _parsed: true,
        id: "1",
        latestLedger: 100,
        events: [],
        minResourceFee: "100000",
        transactionData: new SorobanDataBuilder().setResources(instructions, read, write).setResourceFee(100_000),
        result: { auth: [], retval: xdr.ScVal.scvVoid() },
        cost: { cpuInsns: "0", memBytes: "0" },
      });
    },
  };
  return { server: server as never, calls };
}

const uploadTx = (bytes: number) =>
  new TransactionBuilder(new Account(kp(1).publicKey(), "1"), { fee: BASE_FEE, networkPassphrase: "Test SDF Network ; September 2015" })
    .addOperation(Operation.uploadContractWasm({ wasm: Buffer.alloc(bytes, 1) }))
    .setTimeout(60)
    .build();

const urls = { rpcUrl: "https://rpc.invalid", horizonUrl: "https://horizon.invalid", friendbotUrl: "https://friendbot.invalid" };

Deno.test("prepare() reads the limits from the network's config settings and keeps a large upload within them", async () => {
  const { server, calls } = fakeRpc({ resources: [3_000_000, 500, 115_432] });
  const chain = testnetChain(urls, { server });
  const prepared = await chain.prepare(uploadTx(115_332));
  const r = prepared.toEnvelope().v1().tx().ext().sorobanData().resources();
  assertEquals([r.instructions(), r.diskReadBytes(), r.writeBytes()], [3_850_000, 1_600, 132_096]);
  assertEquals(calls[0], "getLedgerEntries configSetting,configSetting");
  // The limits are read once.
  await chain.prepare(uploadTx(1_000));
  assertEquals(calls.filter((c) => c.startsWith("getLedgerEntries")).length, 1);
});

Deno.test("prepare() refuses when the limits can't be read, and when the simulation is already above one", async () => {
  for (const settings of ["down", "missing"] as const) {
    const { server, calls } = fakeRpc({ resources: [1_000, 100, 100], settings });
    await assertRejects(() => testnetChain(urls, { server }).prepare(uploadTx(10)), Error, "can't read the network's per-transaction limits");
    assertEquals(calls.filter((c) => c === "simulateTransaction"), [], "nothing is simulated or sent without the limits");
  }
  const { server } = fakeRpc({ resources: [1_000, 100, 140_000] });
  await assertRejects(() => testnetChain(urls, { server }).prepare(uploadTx(10)), Error, "writeBytes 140000 > 132096");
  void rpc;
});

Deno.test("liveUntil() reads each instance's and WASM's live-until ledger; a missing entry is null", async () => {
  const id = "CDZD53SNMXM4H7GUHHCCMCCS3W3VRNSG63NXB4OPVK7OELYYIGKC5I6I";
  const missing = "CCWP4LEV74P26RQ44EG4BBC2BD66YMDTFTR4UNCEINOSXEMG2GQA2YIR";
  const hash = "ab".repeat(32);
  const server = {
    getLedgerEntries(...keys: xdr.LedgerKey[]) {
      const entries = keys
        .filter((k) => k.switch().name === "contractCode" || Address.fromScAddress(k.contractData().contract()).toString() === id)
        .map((k) => ({ key: k, val: null, liveUntilLedgerSeq: k.switch().name === "contractCode" ? 700_000 : 600_000 }));
      return Promise.resolve({ latestLedger: 100, entries });
    },
  };
  const live = await testnetChain(urls, { server: server as never }).liveUntil([id, missing], [hash]);
  assertEquals([...live.entries()], [[id, 600_000], [missing, null], [hash, 700_000]]);
});
