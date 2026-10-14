// The functions' environment (docs/DESIGN-stellar-parity.md §6.14) and the network policy it selects (§4.2).
import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { setTestEnv, SPONSOR } from "../fixtures/routes/harness.ts";

setTestEnv();
const { env } = await import("../../supabase/functions/_shared/env.ts");
const { MAINNET, networkByName, TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { DEPLOYMENTS } = await import("../../supabase/functions/_shared/deployments/index.ts");

const KEEPER = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(4) as any);

/** Runs `fn` with these variables set (undefined: unset), then puts every one back. */
function withEnv<T>(vars: Record<string, string | undefined>, fn: () => T): T {
  const before = Object.fromEntries(Object.keys(vars).map((k) => [k, Deno.env.get(k)]));
  const apply = (vs: Record<string, string | undefined>) => {
    for (const [k, v] of Object.entries(vs)) v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
  };
  apply(vars);
  try {
    return fn();
  } finally {
    apply(before);
  }
}

// Secrets are compared with ===, never with assertEquals, so a failure prints no key.

Deno.test("testnet without KEEPER_SECRET: the sponsor pays protocol upkeep, with one warning", () => {
  const warn = console.warn;
  const warnings: string[] = [];
  console.warn = (...args: unknown[]) => void warnings.push(args.join(" "));
  try {
    withEnv({ LITE_NETWORK: "testnet", KEEPER_SECRET: undefined }, () => {
      for (let i = 0; i < 3; i++) assert(env.keeperSecret === SPONSOR.secret(), "the keeper is the sponsor");
    });
  } finally {
    console.warn = warn;
  }
  assertEquals(warnings.length, 1);
  assert(warnings[0].includes("KEEPER_SECRET is not set"));
});

Deno.test("testnet with KEEPER_SECRET: the keeper's own key", () => {
  withEnv({ LITE_NETWORK: "testnet", KEEPER_SECRET: KEEPER.secret() }, () => assert(env.keeperSecret === KEEPER.secret()));
});

Deno.test("mainnet needs a keeper key of its own", () => {
  withEnv({ LITE_NETWORK: "mainnet", KEEPER_SECRET: undefined }, () => {
    assertThrows(() => env.keeperSecret, Error, "KEEPER_SECRET is not set");
  });
  withEnv({ LITE_NETWORK: "mainnet", KEEPER_SECRET: SPONSOR.secret() }, () => {
    assertThrows(() => env.keeperSecret, Error, "must differ from SPONSOR_SECRET");
  });
  withEnv({ LITE_NETWORK: "mainnet", KEEPER_SECRET: KEEPER.secret() }, () => assert(env.keeperSecret === KEEPER.secret()));
});

Deno.test("an unknown LITE_NETWORK throws instead of meaning testnet", () => {
  for (const name of ["Testnet", "mainnett", "public", "futurenet"]) {
    withEnv({ LITE_NETWORK: name }, () => assertThrows(() => env.network, Error, `Unknown network "${name}"`));
    assertThrows(() => networkByName(name), Error, "testnet or mainnet");
  }
  withEnv({ LITE_NETWORK: undefined }, () => assertEquals(env.network.name, "testnet"));
  withEnv({ LITE_NETWORK: "mainnet" }, () => assertEquals(env.network.name, "mainnet"));
});

Deno.test("LITE_ACTIVATION: friendbot by default on testnet, sponsored to rehearse mainnet; mainnet is always sponsored", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_ACTIVATION: undefined }, () => assertEquals(env.network.activation, "friendbot"));
  withEnv({ LITE_NETWORK: "testnet", LITE_ACTIVATION: "sponsored" }, () => assertEquals(env.network.activation, "sponsored"));
  withEnv({ LITE_NETWORK: "mainnet", LITE_ACTIVATION: undefined }, () => assertEquals(env.network.activation, "sponsored"));
  withEnv({ LITE_NETWORK: "mainnet", LITE_ACTIVATION: "friendbot" }, () => assertThrows(() => env.network, Error, "always sponsored"));
  withEnv({ LITE_NETWORK: "testnet", LITE_ACTIVATION: "free" }, () => assertThrows(() => env.network, Error, "friendbot or sponsored"));
});

Deno.test("LITE_DEPLOYMENT picks the contracts: the network's own by default, never another network's", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_DEPLOYMENT: undefined }, () => {
    const net = env.network;
    assertEquals(net.deployment?.id, "testnet");
    assertEquals([net.contracts.launchpad, net.contracts.moments], [DEPLOYMENTS.testnet!.launchpad, DEPLOYMENTS.testnet!.moments]);
  });
  withEnv({ LITE_NETWORK: "testnet", LITE_DEPLOYMENT: "staging" }, () => assertThrows(() => env.network, Error, 'Unknown deployment "staging"'));
  withEnv({ LITE_NETWORK: "mainnet", LITE_DEPLOYMENT: undefined }, () => {
    assertEquals([env.network.deployment, env.network.contracts.launchpad, env.network.contracts.moments], [null, null, null]);
  });
  withEnv({ LITE_NETWORK: "mainnet", LITE_DEPLOYMENT: "testnet" }, () => assertThrows(() => env.network, Error, "is on testnet, not mainnet"));
  // The testnet registry entry and the TESTNET constant (gen-pinned.ts, gen-vectors.ts) agree.
  assertEquals(TESTNET.contracts.launchpad, DEPLOYMENTS.testnet!.launchpad);
});

Deno.test("sponsorship limits: §6.14 defaults per network, and a number when set", () => {
  const unset = {
    LITE_SPONSOR_ACTIVATIONS_PER_DAY: undefined,
    LITE_SPONSOR_STARTERS_PER_DAY: undefined,
    LITE_SPONSOR_PER_IP_PER_DAY: undefined,
    LITE_SPONSOR_DAILY_FEE_CAP: undefined,
    LITE_SPONSOR_MAX_ATTEMPTS: undefined,
    LITE_SPONSOR_MIN_XLM: undefined,
    LITE_KEEPER_MIN_XLM: undefined,
  };
  const read = () => [env.sponsorActivationsPerDay, env.sponsorStartersPerDay, env.sponsorPerIpPerDay, env.sponsorDailyFeeCap, env.sponsorMaxAttempts, env.sponsorMinXlm, env.keeperMinXlm];
  withEnv({ ...unset, LITE_NETWORK: "testnet" }, () => assertEquals(read(), [1000, 1000, 5, 1_000_000_000n, 3, 100, 100]));
  withEnv({ ...unset, LITE_NETWORK: "mainnet" }, () => assertEquals(read(), [200, 200, 3, 200_000_000n, 3, 100, 100]));
  withEnv({ ...unset, LITE_SPONSOR_PER_IP_PER_DAY: "7" }, () => assertEquals(env.sponsorPerIpPerDay, 7));
  withEnv({ ...unset, LITE_SPONSOR_PER_IP_PER_DAY: "lots" }, () => assertThrows(() => env.sponsorPerIpPerDay, Error, "whole number"));
});

Deno.test("the local stack's settings are refused off testnet", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_LOCAL_STORAGE_DIR: "/tmp/lite-media", LITE_PUBLIC_BASE: "http://127.0.0.1:20200/lite" }, () => {
    assertEquals([env.localStorageDir, env.publicBase], ["/tmp/lite-media", "http://127.0.0.1:20200/lite"]);
  });
  withEnv({ LITE_NETWORK: "mainnet", LITE_LOCAL_STORAGE_DIR: "/tmp/lite-media" }, () => assertThrows(() => env.localStorageDir, Error, "local testnet stack only"));
  withEnv({ LITE_NETWORK: "mainnet", LITE_PUBLIC_BASE: "http://127.0.0.1" }, () => assertThrows(() => env.publicBase, Error, "local testnet stack only"));
});

Deno.test("the sponsor's old fee knobs are gone: the cap is the network's maxFee", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_MAX_FEE_PER_TX: "1", LITE_DAILY_FEE_BUDGET: "1" }, () => {
    assertEquals([env.maxFeePerTx, env.dailyFeeBudget], [30_000_000n, 500_000_000n]);
  });
  assert(!("soroswapApiKey" in env) && !("monadRelayerKey" in env));
});

Deno.test("fee policy (§4.2): testnet's values, mainnet's copies", () => {
  const stroops = (p: typeof TESTNET.feePolicy) => Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v.toString()]));
  const expected = {
    maxFee: "30000000",
    maxInclusionPerOp: "200000",
    starterInnerFeeMax: "1000000",
    activationMaxFee: "100000",
    starterThreshold: "500000",
    starterMinXlmOut: "10000000",
    fundingFloor: "1000000",
  };
  assertEquals(stroops(TESTNET.feePolicy), expected);
  assertEquals(stroops(MAINNET.feePolicy), expected);
  assertEquals(TESTNET.ttlPolicy, { thresholdDays: 10, extendToDays: 30, perRun: 400, idleDays: 90 });
  assertEquals(MAINNET.ttlPolicy, { thresholdDays: 30, extendToDays: 150, perRun: 400, idleDays: 90 });
  assertEquals([TESTNET.phoneRpcUrl, TESTNET.explorer, TESTNET.faucet], ["https://soroban-testnet.stellar.org", "https://stellar.expert/explorer/testnet", { amount: "10000" }]);
  assertEquals([MAINNET.faucet, MAINNET.pricing.kind, MAINNET.pricing.note, MAINNET.explorer], [null, "market", null, "https://stellar.expert/explorer/public"]);
  assertEquals(TESTNET.reference, { provider: "Kraken", markets: { XLM: "XLMUSD", USDC: "USDCUSD" } });
  for (const net of [TESTNET, MAINNET]) {
    for (const a of net.assets) assert(a.priceRef === "XLM" || a.priceRef === "USDC", `${net.name} ${a.id} priceRef`);
    for (const code of net.assets.map((a) => a.code)) assert(net.reservedSymbols.includes(code), `${code} reserved`);
  }
  assertEquals(TESTNET.assets.filter((a) => !a.listed).map((a) => a.id), ["BUSDC"]);
});
