// GET /v1/config: the network, its contracts and what the app pins against them (public).
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { json, Router } from "../../_shared/http.ts";
import { contractAllowlist } from "../../_shared/networks.ts";
import { sponsor } from "../../_shared/stellar.ts";

export function register(router: Router): void {
  router.on("GET /v1/config", async () => {
    const net = env.network;
    const cfg = await sql()`select value from lite.app_config where key = 'lite'`;
    return json({
      network: net.name,
      passphrase: net.passphrase,
      rpcUrl: net.rpcUrl,
      horizonUrl: net.horizonUrl,
      activation: net.activation,
      sponsor: sponsor().publicKey(),
      assets: net.assets,
      contracts: net.contracts,
      allowlist: contractAllowlist(net),
      anchors: net.anchors,
      bridge: { routes: net.bridge.routes, monad: net.bridge.monad ? { chainId: net.bridge.monad.chainId, usdc: net.bridge.monad.usdc } : null },
      flags: cfg[0]?.value ?? { enabled: false },
      minBuild: env.minBuild,
    });
  });
}
