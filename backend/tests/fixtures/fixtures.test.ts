// The fixtures are examples of the contract: each one type-checks as the response it stands for (_shared/contract.ts),
// with literal unions widened as a JSON import infers them, and every fixture in api/ is listed here. The phone decodes
// the same files (StellarKit LiteClientTests.testDecodesApiFixtures, after sync.sh).
//
//   deno test --allow-read --config backend/supabase/functions/deno.json backend/tests/fixtures/
import { assertEquals } from "jsr:@std/assert@1";
import type * as C from "../../supabase/functions/_shared/contract.ts";

import account from "./api/account.json" with { type: "json" };
import accountActivate from "./api/account-activate.json" with { type: "json" };
import accountFaucet from "./api/account-faucet.json" with { type: "json" };
import accountLegacy from "./api/account.legacy.json" with { type: "json" };
import accountMissing from "./api/account.missing.json" with { type: "json" };
import activity from "./api/activity.json" with { type: "json" };
import activityLegacy from "./api/activity.legacy.json" with { type: "json" };
import assets from "./api/assets.json" with { type: "json" };
import authChallenge from "./api/auth-challenge.json" with { type: "json" };
import authVerify from "./api/auth-verify.json" with { type: "json" };
import bridgeClaimed from "./api/bridge-claimed.json" with { type: "json" };
import bridgeQuote from "./api/bridge-quote.json" with { type: "json" };
import bridgeQuoteLegacy from "./api/bridge-quote.legacy.json" with { type: "json" };
import bridgeSource from "./api/bridge-source.json" with { type: "json" };
import bridgeStartIn from "./api/bridge-start-in.json" with { type: "json" };
import bridgeStartOut from "./api/bridge-start-out.json" with { type: "json" };
import bridgeStatus from "./api/bridge-status.json" with { type: "json" };
import cashAnchors from "./api/cash-anchors.json" with { type: "json" };
import cashTrack from "./api/cash-track.json" with { type: "json" };
import config from "./api/config.json" with { type: "json" };
import configLegacy from "./api/config.legacy.json" with { type: "json" };
import earnHistory from "./api/earn-history.json" with { type: "json" };
import earnMarkets from "./api/earn-markets.json" with { type: "json" };
import earnMarketsLegacy from "./api/earn-markets.legacy.json" with { type: "json" };
import earnPositions from "./api/earn-positions.json" with { type: "json" };
import earnPositionsLegacy from "./api/earn-positions.legacy.json" with { type: "json" };
import economics from "./api/economics.json" with { type: "json" };
import error from "./api/error.json" with { type: "json" };
import errorContract from "./api/error-contract.json" with { type: "json" };
import errorLegacy from "./api/error.legacy.json" with { type: "json" };
import fees from "./api/fees.json" with { type: "json" };
import holdings from "./api/holdings.json" with { type: "json" };
import holdingsPartial from "./api/holdings.partial.json" with { type: "json" };
import launch from "./api/launch.json" with { type: "json" };
import launchMetadata from "./api/launch-metadata.json" with { type: "json" };
import launchQuote from "./api/launch-quote.json" with { type: "json" };
import launchQuoteSellLegacy from "./api/launch-quote-sell.legacy.json" with { type: "json" };
import launchQuoteLegacy from "./api/launch-quote.legacy.json" with { type: "json" };
import launchLegacy from "./api/launch.legacy.json" with { type: "json" };
import launches from "./api/launches.json" with { type: "json" };
import launchesLegacy from "./api/launches.legacy.json" with { type: "json" };
import launchpadMe from "./api/launchpad-me.json" with { type: "json" };
import market from "./api/market.json" with { type: "json" };
import marketHistory from "./api/market-history.json" with { type: "json" };
import markets from "./api/markets.json" with { type: "json" };
import mediaUploadUrl from "./api/media-upload-url.json" with { type: "json" };
import moment from "./api/moment.json" with { type: "json" };
import momentMetadata from "./api/moment-metadata.json" with { type: "json" };
import momentMetadataLegacy from "./api/moment-metadata.legacy.json" with { type: "json" };
import momentLegacy from "./api/moment.legacy.json" with { type: "json" };
import moments from "./api/moments.json" with { type: "json" };
import momentsMine from "./api/moments-mine.json" with { type: "json" };
import momentsOwned from "./api/moments-owned.json" with { type: "json" };
import momentsOwnedLegacy from "./api/moments-owned.legacy.json" with { type: "json" };
import momentsLegacy from "./api/moments.legacy.json" with { type: "json" };
import plan from "./api/plan.json" with { type: "json" };
import planSend from "./api/plan-send.json" with { type: "json" };
import planLegacy from "./api/plan.legacy.json" with { type: "json" };
import portfolio from "./api/portfolio.json" with { type: "json" };
import prices from "./api/prices.json" with { type: "json" };
import recipient from "./api/recipient.json" with { type: "json" };
import swapQuote from "./api/swap-quote.json" with { type: "json" };
import swapQuoteLegacy from "./api/swap-quote.legacy.json" with { type: "json" };
import txStatus from "./api/tx-status.json" with { type: "json" };
import txStatusLegacy from "./api/tx-status.legacy.json" with { type: "json" };
import txSubmit from "./api/tx-submit.json" with { type: "json" };

/** A contract type as a JSON import infers it: literals widened, tuples as arrays, and a property may read as
 *  undefined (the import types a key that only some array elements have as `?: undefined` in the others). */
type Wire<T> = T extends string ? string
  : T extends number ? number
  : T extends boolean ? boolean
  : T extends null | undefined ? T
  : T extends readonly (infer U)[] ? Wire<U>[]
  : T extends object ? { [K in keyof T]: Wire<T[K]> | undefined }
  : T;

const fixtures: Record<string, unknown> = {
  "account": account satisfies Wire<C.AccountView>,
  "account-activate": accountActivate satisfies Wire<C.ActivationResult>,
  "account-faucet": accountFaucet satisfies Wire<C.FaucetResult>,
  "account.legacy": accountLegacy satisfies Wire<C.AccountView>,
  "account.missing": accountMissing satisfies Wire<C.AccountView>,
  "activity": activity satisfies Wire<C.Activity>,
  "activity.legacy": activityLegacy satisfies Wire<C.Activity>,
  "assets": assets satisfies Wire<C.AssetSearch>,
  "auth-challenge": authChallenge satisfies Wire<C.AuthChallenge>,
  "auth-verify": authVerify satisfies Wire<C.AuthResult>,
  "bridge-claimed": bridgeClaimed satisfies Wire<C.ResponseOf<"POST /v1/bridge/:id/claimed">>,
  "bridge-quote": bridgeQuote satisfies Wire<C.BridgeQuote>,
  "bridge-quote.legacy": bridgeQuoteLegacy satisfies Wire<C.BridgeQuote>,
  "bridge-source": bridgeSource satisfies Wire<C.ResponseOf<"POST /v1/bridge/:id/source">>,
  "bridge-start-in": bridgeStartIn satisfies Wire<C.BridgeStart>,
  "bridge-start-out": bridgeStartOut satisfies Wire<C.BridgeStart>,
  "bridge-status": bridgeStatus satisfies Wire<C.BridgeStatus>,
  "cash-anchors": cashAnchors satisfies Wire<C.CashAnchors>,
  "cash-track": cashTrack satisfies Wire<C.CashTracked>,
  "config": config satisfies Wire<C.LiteConfig>,
  "config.legacy": configLegacy satisfies Wire<C.LiteConfig>,
  "earn-history": earnHistory satisfies Wire<C.EarnHistory>,
  "earn-markets": earnMarkets satisfies Wire<C.EarnMarkets>,
  "earn-markets.legacy": earnMarketsLegacy satisfies Wire<C.EarnMarkets>,
  "earn-positions": earnPositions satisfies Wire<C.EarnPositions>,
  "earn-positions.legacy": earnPositionsLegacy satisfies Wire<C.EarnPositions>,
  "economics": economics satisfies Wire<C.Economics>,
  "error": error satisfies Wire<C.ErrorBody>,
  "error-contract": errorContract satisfies Wire<C.ErrorBody>,
  "error.legacy": errorLegacy satisfies Wire<C.ErrorBody>,
  "fees": fees satisfies Wire<C.Fees>,
  "holdings": holdings satisfies Wire<C.Holdings>,
  "holdings.partial": holdingsPartial satisfies Wire<C.Holdings>,
  "launch": launch satisfies Wire<C.LaunchDetail>,
  "launch-metadata": launchMetadata satisfies Wire<C.MetadataUri>,
  "launch-quote": launchQuote satisfies Wire<C.TradeQuote>,
  "launch-quote-sell.legacy": launchQuoteSellLegacy satisfies Wire<C.TradeQuote>,
  "launch-quote.legacy": launchQuoteLegacy satisfies Wire<C.TradeQuote>,
  "launch.legacy": launchLegacy satisfies Wire<C.LaunchDetail>,
  "launches": launches satisfies Wire<C.LaunchBoard>,
  "launches.legacy": launchesLegacy satisfies Wire<C.LaunchBoard>,
  "launchpad-me": launchpadMe satisfies Wire<C.MyLaunchpad>,
  "market": market satisfies Wire<C.MarketDetail>,
  "market-history": marketHistory satisfies Wire<C.PriceHistory>,
  "markets": markets satisfies Wire<C.Markets>,
  "media-upload-url": mediaUploadUrl satisfies Wire<C.UploadTicket>,
  "moment": moment satisfies Wire<C.MomentDetail>,
  "moment-metadata": momentMetadata satisfies Wire<C.MomentMetadata>,
  "moment-metadata.legacy": momentMetadataLegacy satisfies Wire<C.MomentMetadata>,
  "moment.legacy": momentLegacy satisfies Wire<C.MomentDetail>,
  "moments": moments satisfies Wire<C.MomentFeed>,
  "moments-mine": momentsMine satisfies Wire<C.MyMoments>,
  "moments-owned": momentsOwned satisfies Wire<C.OwnedEditions>,
  "moments-owned.legacy": momentsOwnedLegacy satisfies Wire<C.OwnedEditions>,
  "moments.legacy": momentsLegacy satisfies Wire<C.MomentFeed>,
  "plan": plan satisfies Wire<C.PlanView>,
  "plan-send": planSend satisfies Wire<C.PlanView>,
  "plan.legacy": planLegacy satisfies Wire<C.PlanView>,
  "portfolio": portfolio satisfies Wire<C.Portfolio>,
  "prices": prices satisfies Wire<C.Prices>,
  "recipient": recipient satisfies Wire<C.Recipient>,
  "swap-quote": swapQuote satisfies Wire<C.SwapQuote>,
  "swap-quote.legacy": swapQuoteLegacy satisfies Wire<C.SwapQuote>,
  "tx-status": txStatus satisfies Wire<C.TxStatus>,
  "tx-status.legacy": txStatusLegacy satisfies Wire<C.TxStatus>,
  "tx-submit": txSubmit satisfies Wire<C.Submitted>,
};

Deno.test("every fixture in api/ is typed against the contract", () => {
  const files = [...Deno.readDirSync(new URL("./api/", import.meta.url))].map((e) => e.name.replace(/\.json$/, "")).sort();
  assertEquals(files, Object.keys(fixtures).sort());
});
