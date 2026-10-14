// GET /v1/config: the network, its contracts and policy, and what the app pins against them (public; §6.2). Where the
// app's own pins overlap (fee caps, RPC, media base, explorer), the pins win.
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { json, PUBLIC_CACHE, Router } from "../../_shared/http.ts";
import { contractAllowlist } from "../../_shared/networks.ts";
import { sponsor } from "../../_shared/stellar.ts";

export function register(router: Router): void {
  router.on("GET /v1/config", async () => {
    const net = env.network;
    const fees = net.feePolicy;
    const cfg = await sql()`select value from lite.app_config where key = 'lite'`;
    return json({
      network: net.name,
      passphrase: net.passphrase,
      rpcUrl: net.rpcUrl,
      horizonUrl: net.horizonUrl,
      activation: net.activation,
      sponsor: sponsor().publicKey(),
      deployment: { id: net.deployment?.id ?? env.deployment, launchpad: net.contracts.launchpad, moments: net.contracts.moments },
      explorer: net.explorer,
      // Users pay their own network fees; DyorHQ sponsors only setup and, where activation is sponsored, a first swap
      // into XLM (§4.1).
      fees: {
        payer: "user",
        maxFee: fees.maxFee,
        maxInclusionPerOp: fees.maxInclusionPerOp,
        starterInnerFeeMax: fees.starterInnerFeeMax,
        starterSwap: net.activation === "sponsored",
        fundingFloor: fees.fundingFloor,
      },
      faucet: net.faucet,
      limits: net.limits,
      pricing: { kind: net.pricing.kind, source: net.reference.provider, network: net.pricing.network, note: net.pricing.note },
      assets: net.assets,
      contracts: net.contracts,
      allowlist: contractAllowlist(net),
      anchors: net.anchors,
      bridge: { routes: net.bridge.routes, monad: net.bridge.monad ? { chainId: net.bridge.monad.chainId, usdc: net.bridge.monad.usdc } : null },
      flags: cfg[0]?.value ?? { enabled: false },
      minBuild: env.minBuild,
    }, 200, PUBLIC_CACHE);
  });
}
