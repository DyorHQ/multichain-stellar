// The fixtures are examples of the contract: each one type-checks as the response it stands for (_shared/contract.ts),
// exactly as a route would have to write it, so a field the contract lacks, a missing one or a value outside a literal
// union fails. Importing the JSON can't check that (an import isn't a fresh literal, so extra fields pass, and its
// strings are widened), so the test writes every fixture into one module as a literal and type-checks that module with
// `deno run --check`. Every fixture in api/ is listed here. The phone decodes the same files (StellarKit
// LiteClientTests.testDecodesApiFixtures, after sync.sh).
//
//   deno test --allow-read --allow-run --config backend/supabase/functions/deno.json backend/tests/fixtures/
import { assert, assertEquals } from "jsr:@std/assert@1";

/** Each fixture and the type it answers as, written over `C`, the contract. */
const fixtures: Record<string, string> = {
  "account": "C.AccountView",
  "account-activate": "C.ActivationResult",
  "account-faucet": "C.FaucetResult",
  "account.legacy": "C.AccountView",
  "account.missing": "C.AccountView",
  "account.public": "C.AccountView",
  "activity": "C.Activity",
  "activity.legacy": "C.Activity",
  "assets": "C.AssetSearch",
  "auth-challenge": "C.AuthChallenge",
  "auth-refresh": "C.AuthResult",
  "auth-verify": "C.AuthResult",
  "auth-verify.legacy": "C.AuthResult",
  "bridge-claimed": `C.ResponseOf<"POST /v1/bridge/:id/claimed">`,
  "bridge-quote": "C.BridgeQuote",
  "bridge-quote.legacy": "C.BridgeQuote",
  "bridge-source": `C.ResponseOf<"POST /v1/bridge/:id/source">`,
  "bridge-start-in": "C.BridgeStart",
  "bridge-start-out": "C.BridgeStart",
  "bridge-status": "C.BridgeStatus",
  "config": "C.LiteConfig",
  "config.legacy": "C.LiteConfig",
  "earn-history": "C.EarnHistory",
  "earn-markets": "C.EarnMarkets",
  "earn-markets.legacy": "C.EarnMarkets",
  "earn-positions": "C.EarnPositions",
  "earn-positions.legacy": "C.EarnPositions",
  "earn-positions.public": "C.EarnPositions",
  "economics": "C.Economics",
  "error": "C.ErrorBody",
  "error-address-required": "C.ErrorBody",
  "error-contract": "C.ErrorBody",
  "error-refresh-reused": "C.ErrorBody",
  "error.legacy": "C.ErrorBody",
  "fees": "C.Fees",
  "holdings": "C.Holdings",
  "holdings.partial": "C.Holdings",
  "holdings.public": "C.Holdings",
  "launch": "C.LaunchDetail",
  "launch-metadata": "C.MetadataUri",
  "launch-quote": "C.TradeQuote",
  "launch-quote-sell.legacy": "C.TradeQuote",
  "launch-quote.legacy": "C.TradeQuote",
  "launch.legacy": "C.LaunchDetail",
  "launch.public": "C.LaunchDetail",
  "launches": "C.LaunchBoard",
  "launches.legacy": "C.LaunchBoard",
  "launchpad-me": "C.MyLaunchpad",
  "market": "C.MarketDetail",
  "market-history": "C.PriceHistory",
  "markets": "C.Markets",
  "media-upload-url": "C.UploadTicket",
  "moment": "C.MomentDetail",
  "moment-metadata": "C.MomentMetadata",
  "moment-metadata.legacy": "C.MomentMetadata",
  "moment-v2": "C.MomentDetailV2",
  "moment-v2.public": "C.MomentDetailV2",
  "moment.legacy": "C.MomentDetail",
  "moment.public": "C.MomentDetail",
  "moments": "C.MomentFeed",
  "moments-mine": "C.MyMoments",
  "moments-owned": "C.OwnedEditions",
  "moments-owned.legacy": "C.OwnedEditions",
  "moments-owned.public": "C.OwnedEditions",
  "moments-v2": "C.MomentFeedV2",
  "moments-v2-mine": "C.MyMomentsV2",
  "moments-v2-owned": "C.OwnedMomentsV2",
  "moments-v2-owned.public": "C.OwnedMomentsV2",
  "moments.legacy": "C.MomentFeed",
  "plan": "C.PlanView",
  "plan-send": "C.PlanView",
  "plan.legacy": "C.PlanView",
  "portfolio": "C.Portfolio",
  "prices": "C.Prices",
  "recipient": "C.Recipient",
  "swap-quote": "C.SwapQuote",
  "swap-quote.legacy": "C.SwapQuote",
  "tx-status": "C.TxStatus",
  "tx-status.legacy": "C.TxStatus",
  "tx-submit": "C.Submitted",
};

const api = new URL("./api/", import.meta.url);
const contract = new URL("../../supabase/functions/_shared/contract.ts", import.meta.url);
const config = new URL("../../supabase/functions/deno.json", import.meta.url);

Deno.test("every fixture in api/ is listed", () => {
  const files = [...Deno.readDirSync(api)].map((e) => e.name.replace(/\.json$/, "")).sort();
  assertEquals(files, Object.keys(fixtures).sort());
});

Deno.test("every fixture type-checks exactly as its contract type", async () => {
  // `export const f<n> = <fixture> satisfies <type>;`, each fixture on lines of its own, so an error's line names it.
  const lines = [`import type * as C from "${contract.href}";`];
  const named: string[] = [];
  Object.entries(fixtures).forEach(([name, type], n) => {
    const literal = Deno.readTextFileSync(new URL(`${name}.json`, api)).trimEnd().split("\n");
    literal[0] = `export const f${n} = ${literal[0]}`;
    literal[literal.length - 1] += ` satisfies ${type};`;
    for (const line of literal) {
      lines.push(line);
      named[lines.length] = name;
    }
  });
  const child = new Deno.Command(Deno.execPath(), {
    args: ["run", "--check", "--quiet", "--config", decodeURIComponent(config.pathname), "-"],
    env: { NO_COLOR: "1" },
    stdin: "piped",
    stdout: "null",
    stderr: "piped",
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(lines.join("\n") + "\n"));
  await writer.close();
  const { success, stderr } = await child.output();
  const report = new TextDecoder().decode(stderr);
  const failing = [...new Set([...report.matchAll(/\$deno\$stdin\.\w+:(\d+):\d+/g)].map((m) => named[Number(m[1])]))];
  assert(success, `fixtures that don't match the contract: ${failing.join(", ") || "(see below)"}\n\n${report}`);
});
