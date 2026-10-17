// Stellar's Swap (docs/DESIGN-stellar-parity.md §8.6.1, §8.6.2, §4.5): the review builds the venue on screen and binds the
// minimum the screen shows, only the answer to the request on screen is shown or reviewed, a route the phone would
// refuse to sign is never offered and neither is Aquarius (decision O7), quotes refresh every 15 seconds or at expiry,
// a custom slippage is capped to what a Stellar swap takes, Max and the percent buttons keep XLM's fee and minimum
// balance back, the starter swap fills the whole balance, a coin on its curve is never quoted, Swap History shows what
// each swap really brought in a read of its own, the review's rows in Monad's order with no "To" for the account
// itself, the source rules Swap keeps, and, against a Lite server on testnet, swaps that settle.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

/// The account's store as Swap sees it, with every answer set by the test and every request counted.
@MainActor
private final class FakeSwapSource: StellarSwapSource {
    let address = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"
    var config: LiteConfig?
    var account: AccountView?
    var holdings: StellarHoldings?
    var fees: StellarFees?
    var activity: [StellarActivityItem] = []
    var activityStatus: LiteReadStatus = .read
    /// The quotes to answer, in order; the last one answers every request after it.
    var quotes: [SwapQuote] = []
    private(set) var quoted: [(sell: String, buy: String, amount: Int64, slippageBps: Int)] = []
    private(set) var built: [String?] = []
    private(set) var maxAsked: [(stepKind: String, newReserves: Int)] = []
    private(set) var activityAsked: [(section: String?, kind: String?, period: VolumePeriodKey?)] = []

    struct Built: Error {}
    struct NoRoute: Error {}

    /// As `LiteStore.maxAmount`: XLM's `XLMReserve.maxSend` for the step kind's estimate.
    func maxAmount(asset: String, stepKind: String, newReserves: Int) -> Int64 {
        maxAsked.append((stepKind, newReserves))
        guard let position = account?.xlm, let reserve = XLMReserve(position) else { return 0 }
        let fee = fees?.estimate(stepKind) ?? StellarFeeDefaults.estimate(stepKind) ?? 0
        return reserve.maxSend(feeEstimate: fee, newReserves: newReserves)
    }

    func swapQuote(sell: String, buy: String, amount: Int64, slippageBps: Int) async throws -> SwapQuote {
        quoted.append((sell, buy, amount, slippageBps))
        guard let next = quotes.first else { throw NoRoute() }
        if quotes.count > 1 { quotes.removeFirst() }
        return next
    }

    /// Records the venue the review asked to build; the plan itself is the store's (`LiteStore.swapPlan`).
    func swapPlan(_ quote: SwapQuote, venue: String?) async throws -> PreparedAction {
        built.append(venue)
        throw Built()
    }

    func readActivity(section: String?, kind: String?, period: VolumePeriodKey?) async -> (items: [StellarActivityItem], status: LiteReadStatus) {
        activityAsked.append((section, kind, period))
        return (activityStatus == .read ? activity : [], activityStatus)
    }
}

@MainActor
final class StellarSwapTests: XCTestCase {
    private let xlmContract = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
    private let usdcContract = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"
    private let usdcClassic = "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"
    private let eurcContract = "CCUUDM434BMZMYWYDITHFXHDMIVTGGD6T2I5UKNX5BSLXLW7HVR4MCGZ"
    private let eurcClassic = "EURC:GB3Q6QDZYTHWT7E5PVS3W7FUT5GVAFC5KSZFFLPU25GO7VTC3NM2ZTVO"
    private let coin = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Stop: Error {}

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let suite = "stellar-swap-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `/v1/account`: `xlm` stroops of XLM, a base reserve of 0.5 XLM, and USDC enabled (one subentry) or not.
    private func account(xlm: Int64 = 100_000_000_000, usdc: Int64 = 0, usdcEnabled: Bool = true) throws -> AccountView {
        let subentries = usdcEnabled ? 1 : 0
        let minBalance = Int64(2 + subentries) * 5_000_000
        let usdcRow = usdcEnabled ? """
            , {"asset": "USDC", "code": "USDC", "name": "USD Coin", "contract": "\(usdcContract)", "classic": "\(usdcClassic)", "decimals": 7,
               "balance": "\(usdc)", "enabled": true, "kind": "classic", "verified": true}
            """ : ""
        return try decode(AccountView.self, """
            {"address": "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH", "exists": true, "network": "testnet", "activation": "friendbot",
             "sponsor": "", "balances": [{"asset": "XLM", "code": "XLM", "name": "Stellar Lumens", "contract": "\(xlmContract)", "classic": "native",
             "decimals": 7, "balance": "\(xlm)", "enabled": true, "kind": "native", "verified": true}\(usdcRow)],
             "xlm": {"balance": "\(xlm)", "minBalance": "\(minBalance)", "sellingLiabilities": "0", "spendable": "\(max(0, xlm - minBalance))",
                     "baseReserve": "5000000", "reserves": {"base": \(2 + subentries), "subentries": \(subentries), "sponsoring": 0, "sponsored": 0}}}
            """)
    }

    /// `/v1/fees` with the server's default estimates: 0.001 XLM on the Stellar DEX, 0.05 XLM through Soroban.
    private func fees() throws -> StellarFees {
        try decode(StellarFees.self, """
            {"network": "testnet", "baseReserve": "5000000", "baseFee": "100", "inclusionFee": {"classic": "100", "soroban": "100"},
             "estimates": {"swap_sdex": "10000", "swap_soroswap": "500000", "swap_aquarius": "500000", "trust": "10000"}, "estimateBasis": {}}
            """)
    }

    /// `/v1/config`'s registry: XLM and USDC by their ids, contracts and classic assets (EURC isn't one of them).
    private func config() throws -> LiteConfig {
        let asset = { (id: String, contract: String, classic: String) in
            "{\"id\": \"\(id)\", \"code\": \"\(id)\", \"name\": \"\(id)\", \"decimals\": 7, \"contract\": \"\(contract)\", \"classic\": \"\(classic)\"}"
        }
        return try decode(LiteConfig.self, """
            {"network": "testnet", "passphrase": "Test SDF Network ; September 2015", "rpcUrl": "https://soroban-testnet.stellar.org",
             "horizonUrl": "https://horizon-testnet.stellar.org", "activation": "friendbot", "sponsor": "",
             "assets": [\(asset("XLM", xlmContract, "native")), \(asset("USDC", usdcContract, usdcClassic))],
             "contracts": {"soroswapRouter": "CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD", "blendPools": []},
             "allowlist": {}, "bridge": {"routes": []}, "flags": {"enabled": true}, "minBuild": 1}
            """)
    }

    /// A Top Tokens row: a registry asset, or a DyorHQ coin in `phase`.
    private func row(_ id: String, code: String, contract: String, classic: String?, price: Double? = nil, phase: String? = nil) throws -> StellarMarketRow {
        try decode(StellarMarketRow.self, """
            {"id": "\(id)", "kind": "\(phase == nil ? "registry" : "launch")", "contract": "\(contract)", "classic": \(classic.map { "\"\($0)\"" } ?? "null"),
             "code": "\(code)", "name": "\(code) name", "decimals": 7, "logo": null, "image": null, "verified": true,
             "badges": \(phase == nil ? "[]" : "[\"launch\"]"), "note": null, "priceUsd": \(price.map { "\($0)" } ?? "null"), "change24h": null,
             "isNew": false, "volume24hUsd": null, "marketCapUsd": null, "priceSource": {"kind": "reference"}, "stale": false,
             "launch": \(phase.map { "{\"phase\": \"\($0)\", \"progress\": 0.4}" } ?? "null")}
            """)
    }

    private func markets() throws -> [StellarMarketRow] {
        [try row("XLM", code: "XLM", contract: xlmContract, classic: "native", price: 0.25),
         try row("USDC", code: "USDC", contract: usdcContract, classic: usdcClassic, price: 1),
         try row("EURC", code: "EURC", contract: eurcContract, classic: eurcClassic, price: 1.1)]
    }

    /// `/v1/swap/quote` for 10 XLM → USDC at 1% (or what `sell`, `buy`, `amountIn` and `slippageBps` say): each route's
    /// venue, amount out, minimum, and whether it is the best; a route's path when `paths` names one for its venue (XLM →
    /// USDC direct otherwise).
    private func quote(_ routes: [(venue: String, out: Int64, minOut: Int64)], expiresIn: TimeInterval = 60, needsEnable: [String] = [],
                       paths: [String: [String]] = [:], impacts: [String: Int] = ["soroswap": 42], sell: String = "XLM", buy: String = "USDC",
                       amountIn: Int64 = 100_000_000, slippageBps: Int = 100) throws -> SwapQuote {
        let rows = routes.enumerated().map { index, route in
            let path = paths[route.venue] ?? (route.venue == "sdex" ? ["native", usdcClassic] : [xlmContract, usdcContract])
            return """
            {"venue": "\(route.venue)", "amountOut": "\(route.out)", "minOut": "\(route.minOut)", "priceImpactBps": \(impacts[route.venue].map(String.init) ?? "null"),
             "path": [\(path.map { "\"\($0)\"" }.joined(separator: ", "))], "best": \(index == 0)}
            """
        }
        let best = try XCTUnwrap(routes.first)
        return try decode(SwapQuote.self, """
            {"quoteId": "\(UUID().uuidString.lowercased())", "sell": "\(sell)", "buy": "\(buy)", "amountIn": "\(amountIn)", "slippageBps": \(slippageBps),
             "best": {"venue": "\(best.venue)", "amountOut": "\(best.out)", "path": [], "minOut": "\(best.minOut)"}, "alternatives": [],
             "expiresAt": "\(iso(now.addingTimeInterval(expiresIn)))", "routes": [\(rows.joined(separator: ", "))],
             "needsEnable": [\(needsEnable.map { "\"\($0)\"" }.joined(separator: ", "))], "starterSwap": {"eligible": false, "reason": null}}
            """)
    }

    /// A model on `source`, with the account and Top Tokens read.
    private func model(_ source: FakeSwapSource) throws -> StellarSwapModel {
        let model = StellarSwapModel(defaults: try temporaryDefaults())
        source.account = try source.account ?? account()
        source.fees = try source.fees ?? fees()
        model.attach(source)
        model.markets = try markets()
        return model
    }

    /// One round of quoting: the pause after the edit, the quote, then a stop at the first refresh.
    private func quoteOnce(_ model: StellarSwapModel) async {
        await model.quote(sleep: { wait in if wait != .milliseconds(400) { throw Stop() } }, now: { self.now })
    }

    // MARK: - Venues

    func testTheChosenVenueIsTheOneBuilt() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("sdex", 18_938_032, 18_748_651), ("soroswap", 18_900_000, 18_711_000)])]
        let model = try model(source)
        model.amountText = "10"
        await quoteOnce(model)
        XCTAssertEqual(source.quoted.map(\.amount), [100_000_000])
        XCTAssertEqual(model.routes.map(\.venue), ["sdex", "soroswap"], "one row per venue, the best first")
        XCTAssertEqual(model.shownRoute?.venue, "sdex", "the best is preselected")

        // Review without a pick builds the best, named: never the server's choice at build time.
        let best = try XCTUnwrap(model.review)
        _ = try? await model.plan(for: best)
        XCTAssertEqual(source.built, ["sdex"])

        model.pick("soroswap")
        let picked = try XCTUnwrap(model.review)
        XCTAssertEqual(picked.route.venue, "soroswap")
        XCTAssertEqual(picked.route.minimum, 18_711_000, "the minimum the footer shows, which the store binds")
        XCTAssertEqual(picked.amountIn, 100_000_000)
        _ = try? await model.plan(for: picked)
        XCTAssertEqual(source.built, ["sdex", "soroswap"], "the venue picked is the one built")
    }

    /// Owner bug 1a: testnet's Aquarius quoted XLM → USDC best through AQUA and USDT, tokens off the allowlist, so Review
    /// built a route both verifiers refuse and every swap failed. Swap never offers such a route, whichever venue quotes
    /// it: the best left is the one preselected, named Best, and built.
    func testARouteThroughATokenThePhoneWouldRefuseIsNeverOffered() async throws {
        let aqua = "CDNVQW44C3HALYNVQ4SOBXY5EWYTGVYXX6JPESOLQDABJI5FC5LTRRUE"
        let usdt = "CBL6KD2LFMLAUKFFWNNXWOXFN73GAXLEA4WMJRLQ5L76DMYTM3KWQVJN"
        let source = FakeSwapSource()
        source.quotes = [try quote([("soroswap", 76_955_448, 76_185_893), ("sdex", 44_593_109, 44_147_177)],
                                   paths: ["soroswap": [xlmContract, aqua, usdt, usdcContract]], amountIn: 500_000_000)]
        let model = try model(source)
        model.amountText = "50"
        await quoteOnce(model)
        XCTAssertEqual(model.routes.map(\.venue), ["sdex"], "Soroswap's route goes through AQUA and USDT")
        XCTAssertEqual(model.routes.map(\.best), [true], "the best left is the best")
        XCTAssertEqual(model.shownRoute?.venue, "sdex", "and is preselected")
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.route.minimum, 44_147_177)
        _ = try? await model.plan(for: review)
        XCTAssertEqual(source.built, ["sdex"], "never the route the verifiers refuse")

        // A chain on pinned tokens only stays offered, and the Stellar DEX's path never counts: it runs no token code.
        let pinned = PinnedContracts.testnet.allContracts
        XCTAssertTrue(StellarSwapModel.signable(venue: "aquarius", path: [xlmContract, usdcContract], listed: pinned))
        XCTAssertTrue(StellarSwapModel.signable(venue: "soroswap", path: [xlmContract, "CAQCFVLOBK5GIULPNZRGATJJMIZL5BSP7X5YJVMGCPTUEPFM4AVSRCJU", coin], listed: pinned),
                      "through a pinned token to the coin chosen")
        XCTAssertFalse(StellarSwapModel.signable(venue: "soroswap", path: [xlmContract, coin, usdcContract], listed: pinned))
        XCTAssertTrue(StellarSwapModel.signable(venue: "sdex", path: ["native", eurcClassic, usdcClassic], listed: pinned))
    }

    /// Owner bug 8: an Aquarius route showed an impact read along another chain (64% for a direct pool's 0.85%). Aquarius
    /// is off for swaps (decision O7): whatever a server quotes, no Aquarius route, impact or review shows, and the best
    /// left is the one preselected and built.
    func testAquariusIsNeverOfferedWhileItIsOff() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("aquarius", 32_244_608_678, 31_922_162_591), ("sdex", 31_000_000_000, 30_690_000_000),
                                    ("soroswap", 3_000_000_000, 2_970_000_000)], impacts: ["aquarius": 6_417, "soroswap": 42],
                                   amountIn: 50_000_000_000)]
        let model = try model(source)
        model.amountText = "5000"
        await quoteOnce(model)
        XCTAssertEqual(model.routes.map(\.venue), ["sdex", "soroswap"])
        XCTAssertEqual(model.routes.map(\.best), [true, false], "the Stellar DEX is the best Swap offers")
        XCTAssertEqual(model.routes.compactMap(\.priceImpactBps), [42], "Soroswap's own impact only, never Aquarius's 64.17%")
        let review = try XCTUnwrap(model.review)
        _ = try? await model.plan(for: review)
        XCTAssertEqual(source.built, ["sdex"])
        XCTAssertFalse(StellarSwapModel.venues.contains("aquarius"))
        XCTAssertFalse(StellarSwapModel.swapStepKinds.contains("swap_aquarius"), "Max keeps back what an offered venue costs")

        // An older server's answer whose only route is Aquarius's offers nothing.
        let legacy = try decode(SwapQuote.self, """
            {"quoteId": "q", "sell": "XLM", "buy": "USDC", "amountIn": "100000000", "slippageBps": 100,
             "best": {"venue": "aquarius", "amountOut": "19000000", "path": ["\(xlmContract)", "\(usdcContract)"], "minOut": "18810000"},
             "alternatives": [], "expiresAt": "\(iso(now))"}
            """)
        XCTAssertTrue(StellarSwapModel.routes(legacy, listed: PinnedContracts.testnet.allContracts).isEmpty)
    }

    func testAPickIsKeptUntilAnAnswerDoesntQuoteIt() throws {
        let both = StellarSwapModel.routes(try quote([("sdex", 2, 1), ("soroswap", 2, 1)]), listed: PinnedContracts.testnet.allContracts)
        let sdexOnly = StellarSwapModel.routes(try quote([("sdex", 2, 1)]), listed: PinnedContracts.testnet.allContracts)
        let picked = StellarVenueSelection(venue: "soroswap", picked: true)
        XCTAssertEqual(picked.following(both), picked, "a refresh that still quotes it keeps it")
        XCTAssertEqual(picked.following(sdexOnly), StellarVenueSelection(venue: "sdex"), "given back to the best")
        XCTAssertEqual(StellarVenueSelection(venue: "soroswap").following(both).venue, "sdex", "not picked: it follows the best")
    }

    func testTheMinimumIsTheRoutesNeverBelowTheQuoteLessSlippage() {
        XCTAssertEqual(StellarSwapModel.minimum(quoted: 18_938_032, minOut: 18_000_000, slippageBps: 100), 18_748_651, "the slippage floor")
        XCTAssertEqual(StellarSwapModel.minimum(quoted: 18_938_032, minOut: 18_800_000, slippageBps: 100), 18_800_000, "the route's own when higher")
        XCTAssertEqual(StellarSwapModel.minimum(quoted: 0, minOut: nil, slippageBps: 100), 0, "nothing quoted: nothing the store would accept")
        XCTAssertEqual(StellarSwapModel.minimum(quoted: .max, minOut: nil, slippageBps: 100), Int64.max / 10_000 * 9_900 + (Int64.max % 10_000) * 9_900 / 10_000)
    }

    func testAnOlderServersQuoteOffersOnlyItsBestRoute() throws {
        let legacy = try decode(SwapQuote.self, """
            {"quoteId": "q", "sell": "XLM", "buy": "USDC", "amountIn": "100000000", "slippageBps": 100,
             "best": {"venue": "sdex", "amountOut": "19000000", "path": ["native", "\(usdcClassic)"], "minOut": "18810000"},
             "alternatives": [{"venue": "soroswap", "amountOut": "18000000", "path": []}], "expiresAt": "\(iso(now))"}
            """)
        let routes = StellarSwapModel.routes(legacy, listed: PinnedContracts.testnet.allContracts)
        XCTAssertEqual(routes.map(\.venue), ["sdex"], "without routes the store binds the best route's minimum only")
        XCTAssertEqual(routes.first?.minimum, 18_810_000)
    }

    // MARK: - Refreshing

    func testQuotesRefreshEvery15SecondsOrAtExpiry() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("sdex", 18_938_032, 18_748_651)], expiresIn: 60), try quote([("sdex", 18_950_000, 18_760_500)], expiresIn: 5)]
        let model = try model(source)
        model.amountText = "10"
        var waits: [Duration] = []
        await model.quote(sleep: { wait in
            waits.append(wait)
            if waits.count == 3 { throw Stop() }
        }, now: { self.now })
        XCTAssertEqual(waits, [.milliseconds(400), .seconds(15), .seconds(5)], "after an edit, then every 15 s, or at expiry when sooner")
        XCTAssertEqual(source.quoted.count, 2)
        XCTAssertEqual(model.shownRoute?.amountOut, 18_950_000, "the refresh replaced the answer")

        XCTAssertEqual(StellarSwapModel.refreshDelay(expiresAt: iso(now.addingTimeInterval(-3)), now: now), .seconds(1), "expired: at once, not in a loop")
        XCTAssertEqual(StellarSwapModel.refreshDelay(expiresAt: "soon", now: now), .seconds(15))
    }

    func testAnEditHidesTheOldAnswerUntilItsOwnLands() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("sdex", 18_938_032, 18_748_651)])]
        let model = try model(source)
        model.amountText = "10"
        await quoteOnce(model)
        XCTAssertNotNil(model.review)
        model.amountText = "11"
        XCTAssertNil(model.currentResult, "an answer to 10 XLM is never shown for 11")
        XCTAssertNil(model.review)
        XCTAssertTrue(model.awaitingQuote)
    }

    /// The review binds the answer's amount as the spend and its route's minimum (`LiteStore.swapPlan`), so only the
    /// answer to the request on screen counts: an answer for another amount, direction, asset or slippage is never shown
    /// or reviewed, and the next refresh asks again.
    func testOnlyTheAnswerForTheRequestOnScreenIsShownOrReviewed() async throws {
        let routes: [(venue: String, out: Int64, minOut: Int64)] = [("sdex", 94_690_160, 93_743_258)]
        let wrong = [
            ("another amount", try quote(routes)), // 10 XLM, for the 50 typed
            ("the other direction", try quote(routes, sell: "USDC", buy: "XLM", amountIn: 500_000_000)),
            ("another asset", try quote(routes, buy: "EURC", amountIn: 500_000_000)),
            ("another slippage", try quote(routes, amountIn: 500_000_000, slippageBps: 1_000)),
        ]
        for (what, answer) in wrong {
            let source = FakeSwapSource()
            source.quotes = [answer]
            let model = try model(source)
            model.amountText = "50"
            var waits: [Duration] = []
            await model.quote(sleep: { wait in
                waits.append(wait)
                if waits.count == 2 { throw Stop() }
            }, now: { self.now })
            XCTAssertEqual(source.quoted.map(\.amount), [500_000_000], what)
            XCTAssertNil(model.currentResult, what)
            XCTAssertTrue(model.routes.isEmpty, what)
            XCTAssertNil(model.shownRoute, "\(what): no amount under You Receive")
            XCTAssertNil(model.review, "\(what): nothing to review")
            XCTAssertEqual(model.currentError, StellarSwapModel.unanswered, what)
            XCTAssertEqual(waits, [.milliseconds(400), .seconds(15)], "\(what): asked again at the next refresh")
        }

        // The same request, with each side named as the server names it: its registry id for a contract or a CODE:ISSUER,
        // and a classic asset the registry doesn't list by CODE:ISSUER for its contract.
        let source = FakeSwapSource()
        source.config = try config()
        let model = try model(source)
        model.select(usdcContract, for: .receive)
        model.amountText = "50"
        source.quotes = [try quote(routes, amountIn: 500_000_000)]
        await quoteOnce(model)
        XCTAssertEqual(source.quoted.last?.buy, usdcContract)
        XCTAssertNotNil(model.review, "USDC's contract, answered as USDC")
        model.select(usdcClassic, for: .receive)
        await quoteOnce(model)
        XCTAssertNotNil(model.review, "USDC's CODE:ISSUER, answered as USDC")
        model.select(eurcContract, for: .receive)
        source.quotes = [try quote(routes, buy: eurcClassic, amountIn: 500_000_000)]
        await quoteOnce(model)
        XCTAssertNotNil(model.review, "EURC's contract, answered as EURC:ISSUER")
        XCTAssertFalse(model.answers(try quote(routes, buy: eurcClassic, amountIn: 500_000_000), sell: "XLM", buy: usdcContract, amount: 500_000_000,
                                     slippageBps: 100))

        // A review is built only from the answer to its own request.
        let review = try XCTUnwrap(model.review)
        let stale = StellarSwapReview(quote: try quote(routes, buy: eurcClassic), route: review.route, sell: review.sell, buy: review.buy,
                                      amountIn: review.amountIn, slippageBps: review.slippageBps)
        do {
            _ = try await model.plan(for: stale)
            XCTFail("a plan for another amount")
        } catch {
            XCTAssertEqual(error as? PlanRunner.Failure, .refused(step: tr("Swap"), reason: "the quote isn't for the amount you typed"))
        }
        XCTAssertTrue(source.built.isEmpty, "never asked to build it")
    }

    func testAFailedQuoteSaysWhyAndCantBeReviewed() async throws {
        let source = FakeSwapSource()
        let model = try model(source)
        model.amountText = "10"
        await quoteOnce(model)
        XCTAssertNotNil(model.currentError)
        XCTAssertNil(model.review)
        XCTAssertTrue(model.routes.isEmpty)
    }

    /// A server that answers only with routes the phone would refuse to sign (before it kept to the allowlist itself, a
    /// venue alone could answer a pair through AQUA and USDT) has offered no route: Swap says so in Monad's
    /// words, offers nothing to review, and asks again at the next refresh. The server's own "no route" reads the same.
    func testAnAnswerWithNoRouteThePhoneWouldSignReadsAsNoRoute() async throws {
        let aqua = "CDNVQW44C3HALYNVQ4SOBXY5EWYTGVYXX6JPESOLQDABJI5FC5LTRRUE"
        let usdt = "CBL6KD2LFMLAUKFFWNNXWOXFN73GAXLEA4WMJRLQ5L76DMYTM3KWQVJN"
        let source = FakeSwapSource()
        source.quotes = [try quote([("soroswap", 76_955_448, 76_185_893)], paths: ["soroswap": [xlmContract, aqua, usdt, usdcContract]],
                                   amountIn: 500_000_000)]
        let model = try model(source)
        model.amountText = "50"
        var waits: [Duration] = []
        await model.quote(sleep: { wait in
            waits.append(wait)
            if waits.count == 2 { throw Stop() }
        }, now: { self.now })
        XCTAssertEqual(model.currentError, StellarSwapModel.noRoute)
        XCTAssertTrue(model.routes.isEmpty)
        XCTAssertNil(model.shownRoute)
        XCTAssertNil(model.review, "nothing to review")
        XCTAssertFalse(model.awaitingQuote, "the answer is in: no spinner")
        XCTAssertEqual(waits, [.milliseconds(400), .seconds(15)], "asked again at the next refresh")
        XCTAssertTrue(source.built.isEmpty)

        let none = LiteAPIError.server(status: 404, code: "no_route", message: "No route from XLM to USDC right now.")
        XCTAssertEqual(StellarSwapModel.describe(none), StellarSwapModel.noRoute)
        let offline = LiteAPIError.transport("offline")
        XCTAssertEqual(StellarSwapModel.describe(offline), LiteErrorText.describe(offline))
    }

    // MARK: - Max, percents and the amount

    func testMaxOfXLMKeepsTheFeeAndTheMinimumBalance() async throws {
        let source = FakeSwapSource()
        let model = try model(source)
        // 10,000 XLM with USDC enabled: 1.5 XLM is kept, and the costliest venue's fee (0.05 XLM) with a quarter more.
        model.applyMax()
        XCTAssertEqual(Set(source.maxAsked.map(\.stepKind)), Set(StellarSwapModel.swapStepKinds))
        XCTAssertEqual(source.maxAsked.map(\.newReserves), [0, 0], "USDC is enabled: nothing to hold back for it")
        XCTAssertEqual(model.maxIn, 99_984_375_000, "9,998.4375 XLM (§4.5)")
        XCTAssertEqual(model.amountText, "9998.43", "rounded down to six significant digits")
        XCTAssertFalse(model.insufficient)
        XCTAssertEqual(model.actionTitle, tr("Review Swap"))
        XCTAssertEqual(model.lockedXLM, 15_000_000, "1.5 XLM locked, under the balance")

        model.amountText = "9998.44"
        XCTAssertTrue(model.insufficient, "more than Max is more than can be swapped, though less than the balance")
        XCTAssertEqual(model.actionTitle, tr("Insufficient \("XLM")"))
        model.amountText = ""
        XCTAssertEqual(model.actionTitle, tr("Enter an Amount"))
    }

    func testMaxHoldsTheReserveAndTheTrustlineFeeOfAnAssetToEnable() throws {
        let source = FakeSwapSource()
        let model = try model(source)
        model.select("EURC", for: .receive)
        XCTAssertTrue(model.needsEnable, "EURC isn't enabled: its trustline is part of the review")
        let reserve = try XCTUnwrap(model.baseReserve)
        XCTAssertEqual(reserve, 5_000_000)
        let max = try XCTUnwrap(model.maxIn)
        XCTAssertEqual(source.maxAsked.last?.newReserves, 1)
        XCTAssertEqual(max, 99_985_000_000 - 625_000 - 5_000_000 - 12_500, "the swap's fee, the new reserve, and the trustline's fee")
        let position = try XCTUnwrap(model.xlmReserve)
        XCTAssertGreaterThanOrEqual(position.balance - max - 625_000 - 12_500 - 5_000_000, position.minBalance, "the account keeps its minimum balance")

        // USDC is enabled already.
        model.select("USDC", for: .receive)
        XCTAssertFalse(model.needsEnable)
    }

    func testPercentsAreSharesOfTheSpendableXLMAndOfOtherBalances() throws {
        let source = FakeSwapSource()
        source.account = try account(usdc: 250_000_000)
        let model = try model(source)
        model.applyPercent(50)
        XCTAssertEqual(model.amountText, "4999.25", "half of 9,998.5 spendable XLM, never of the balance")
        model.applyPercent(100)
        XCTAssertEqual(model.amountText, "9998.43", "100% is Max")
        model.select("USDC", for: .pay)
        model.applyPercent(25)
        XCTAssertEqual(model.amountText, "6.25")
        model.applyMax()
        XCTAssertEqual(model.amountText, "25", "any other asset: its whole balance, exact")
    }

    // MARK: - Entries, the starter swap and the curve

    func testTheStarterSwapFillsTheWholeBalanceOnceItIsRead() throws {
        let source = FakeSwapSource()
        let model = try model(source)
        source.account = nil
        model.apply(StellarSwapRequest(sell: "USDC", buy: "XLM", starter: true))
        XCTAssertEqual(model.sell, "USDC")
        XCTAssertEqual(model.buy, "XLM")
        XCTAssertEqual(model.amountText, "", "the balance isn't read yet")
        source.account = try account(usdc: 250_000_000)
        model.fillMaxIfRead()
        XCTAssertEqual(model.amountText, "25")
        model.amountText = "3"
        model.fillMaxIfRead()
        XCTAssertEqual(model.amountText, "3", "once only")
    }

    func testAnEntrySetsEitherSideAndNeverTheSameAssetTwice() throws {
        let model = try model(FakeSwapSource())
        model.apply(StellarSwapRequest(sell: nil, buy: "XLM"))
        XCTAssertEqual([model.sell, model.buy], ["USDC", "XLM"], "buying what was sold swaps the sides")
        model.apply(StellarSwapRequest(sell: "EURC", buy: nil))
        XCTAssertEqual([model.sell, model.buy], ["EURC", "XLM"])
        XCTAssertFalse(model.fillsMaxWhenRead)
    }

    func testFlipCarriesTheQuotedAmount() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("sdex", 18_938_032, 18_748_651)])]
        let model = try model(source)
        model.amountText = "10"
        await quoteOnce(model)
        model.flip()
        XCTAssertEqual([model.sell, model.buy], ["USDC", "XLM"])
        XCTAssertEqual(model.amountText, "1.8938", "the quoted output, rounded down")
        XCTAssertNil(model.currentResult)
    }

    func testACoinOnItsCurveIsNeverQuoted() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("soroswap", 1, 1)], paths: ["soroswap": [xlmContract, coin]], buy: coin)]
        let model = try model(source)
        model.markets += [try row(coin, code: "ECAT", contract: coin, classic: nil, phase: "curve")]
        model.select(coin, for: .receive)
        model.amountText = "10"
        await quoteOnce(model)
        XCTAssertTrue(source.quoted.isEmpty, "no venue routes a curve")
        XCTAssertEqual(model.curveToken?.code, "ECAT")
        XCTAssertNil(model.review)
        XCTAssertFalse(model.awaitingQuote)

        model.markets[model.markets.count - 1] = try row(coin, code: "ECAT", contract: coin, classic: nil, phase: "graduated")
        XCTAssertNil(model.curveToken)
        await quoteOnce(model)
        XCTAssertEqual(source.quoted.count, 1, "a graduated coin trades on Swap")
        XCTAssertNotNil(model.review)
        XCTAssertFalse(model.needsEnable, "a coin lives on Soroban: no trustline")
    }

    func testTheSidesShowWhatTheSectionReadAboutThem() throws {
        let model = try model(FakeSwapSource())
        model.amountText = "10"
        XCTAssertEqual(model.tokenIn.classic, "native", "XLM's mark, by what it is")
        XCTAssertEqual(try XCTUnwrap(model.payUSD), 2.5, accuracy: 1e-9)
        XCTAssertEqual(model.token(usdcContract).code, "USDC", "a registry asset by its contract")
        XCTAssertEqual(model.token(eurcClassic).code, "EURC")
        let unknown = model.token("CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526")
        XCTAssertEqual(unknown.code, "CAAQ…C526", "nothing read about it: its short id")
        XCTAssertFalse(unknown.verified)
        XCTAssertEqual(StellarSwapModel.shortCode("native"), "XLM")
        XCTAssertEqual(StellarSwapRoute.name("sdex"), "Stellar DEX")
        XCTAssertEqual(StellarSwapRoute.name("soroswap"), "Soroswap")
    }

    /// A side Top Tokens doesn't list (a coin pasted into the search) is looked up once, then read again on Top Tokens'
    /// cadence: its price follows its pool, and a coin that graduates while Swap is on screen is quoted from then on.
    func testASideLookedUpIsReadAgainSoItsPriceAndPhaseFollowTheMarket() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("soroswap", 1, 1)], paths: ["soroswap": [xlmContract, coin]], buy: coin)]
        let model = StellarSwapModel(defaults: try temporaryDefaults())
        source.account = try account()
        source.fees = try fees()
        var answers = [try row(coin, code: "ECAT", contract: coin, classic: nil, price: 0.002, phase: "curve"),
                       try row(coin, code: "ECAT", contract: coin, classic: nil, price: 0.003, phase: "graduated")]
        var lookedUp: [String] = []
        model.attach(source) { id in
            lookedUp.append(id)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        model.markets = try markets()
        model.select(coin, for: .receive)
        model.amountText = "10"
        await model.learnSides()
        XCTAssertEqual(model.tokenOut.code, "ECAT")
        XCTAssertEqual(model.tokenOut.priceUsd, 0.002)
        XCTAssertEqual(model.curveToken?.code, "ECAT")
        await model.learnSides()
        XCTAssertEqual(lookedUp, [coin], "learnSides looks a side up once")

        await model.refreshFound()
        XCTAssertEqual(lookedUp, [coin, coin], "only the side that was looked up, read again")
        XCTAssertEqual(model.tokenOut.priceUsd, 0.003)
        XCTAssertNil(model.curveToken, "graduated since: Swap quotes it")
        await quoteOnce(model)
        XCTAssertEqual(source.quoted.count, 1)
    }

    func testTheRoutesAssetsReadByCode() async throws {
        let source = FakeSwapSource()
        source.quotes = [try quote([("sdex", 2, 1), ("soroswap", 2, 1)])]
        let model = try model(source)
        model.amountText = "10"
        await quoteOnce(model)
        XCTAssertEqual(model.routes.map(model.pathText), ["XLM → USDC", "XLM → USDC"])
    }

    // MARK: - Slippage

    /// Owner bug: a custom 15% (or 0.004%) made every quote fail, and Swap stayed broken each time it opened, the value
    /// being saved. A Stellar swap takes 0.01% to 10%: Monad's sheet, given that range, caps a custom value to it (and says
    /// so), takes the rest as Monad does, and a value an earlier build saved outside it is never used.
    func testACustomSlippageIsCappedToWhatAStellarSwapTakes() async throws {
        let range = StellarSwapModel.slippageRange
        XCTAssertEqual(range, 1...1_000, "/v1/swap/quote takes 1 to 1,000 bps")
        XCTAssertEqual(SlippageSheet.customBps("15", range: range), 1_000, "above 10%: 10%")
        XCTAssertEqual(SlippageSheet.customBps("0.004", range: range), 1, "under 0.01%: 0.01%")
        XCTAssertEqual(SlippageSheet.customBps("0.5", range: range), 50, "inside the range, as Monad takes it")
        XCTAssertEqual(SlippageSheet.customBps("10", range: range), 1_000)
        // Every value above 0 is capped, as the sheet says: 60% was ignored (the slippage stayed at the 6% its first digit
        // set), 75% read as 7% and 99% as 9%.
        for above in ["60", "75", "99", "50.5", "1000", "1e30"] { XCTAssertEqual(SlippageSheet.customBps(above, range: range), 1_000, above) }
        // The decimal pad types the region's separator: "2,5" (fr, es) is 2.5%, not nothing.
        XCTAssertEqual(SlippageSheet.customBps("2,5", range: range), 250)
        XCTAssertEqual(SlippageSheet.customBps("0,5", range: range), 50)
        XCTAssertEqual(SlippageSheet.customBps("15,5", range: range), 1_000)
        for ignored in ["0", "0,0", "-1", "", "abc", "inf", "nan", "1,2,3"] { XCTAssertNil(SlippageSheet.customBps(ignored, range: range), ignored) }
        XCTAssertEqual(SlippageSheet.customBps("15", range: nil), 1_500, "Monad's sheet is unchanged")
        XCTAssertEqual(SlippageSheet.customBps("0.004", range: nil), 0)
        XCTAssertNil(SlippageSheet.customBps("60", range: nil), "Monad's sheet takes at most 50%")
        XCTAssertNil(SlippageSheet.customBps("2,5", range: nil))

        // A value saved outside the range by an earlier build reads as the default, and the quote asks for that.
        let defaults = try temporaryDefaults()
        let source = FakeSwapSource()
        for (saved, read) in [(1_500, 100), (0, 100), (-5, 100), (1_000, 1_000), (1, 1)] {
            defaults.set(saved, forKey: StellarSwapModel.slippageKey(source.address))
            XCTAssertEqual(StellarSwapModel.storedSlippage(for: source.address, defaults: defaults), read, "saved \(saved)")
        }
        defaults.set(1_500, forKey: StellarSwapModel.slippageKey(source.address))
        source.account = try account()
        source.fees = try fees()
        source.quotes = [try quote([("sdex", 18_938_032, 18_748_651)])]
        let model = StellarSwapModel(defaults: defaults)
        model.attach(source)
        model.markets = try markets()
        model.amountText = "10"
        await quoteOnce(model)
        XCTAssertEqual(source.quoted.map(\.slippageBps), [100])
        XCTAssertNotNil(model.review)

        // The highest a swap takes is quoted and reviewed like any other.
        model.slippageBps = try XCTUnwrap(SlippageSheet.customBps("15", range: range))
        source.quotes = [try quote([("sdex", 18_938_032, 17_044_228)], slippageBps: 1_000)]
        await quoteOnce(model)
        XCTAssertEqual(source.quoted.last?.slippageBps, 1_000)
        XCTAssertEqual(model.review?.route.minimum, 17_044_228)
        XCTAssertEqual(model.review?.slippageBps, 1_000)
    }

    func testSlippageIsKeptPerAddressUnderLite() throws {
        let defaults = try temporaryDefaults()
        let source = FakeSwapSource()
        let model = StellarSwapModel(defaults: defaults)
        model.attach(source)
        XCTAssertEqual(model.slippageBps, 100, "1% until the person picks another")
        model.slippageBps = 300
        model.saveSlippage()
        let again = StellarSwapModel(defaults: defaults)
        again.attach(source)
        XCTAssertEqual(again.slippageBps, 300)
        XCTAssertTrue(StellarSwapModel.slippageKey(source.address).hasPrefix("lite."), "every Lite default starts with lite. (§3.10 rule 9)")
        XCTAssertTrue(StellarSwapModel.slippageKey(source.address).hasSuffix(source.address), "per address")
    }

    // MARK: - Swap History

    private func item(_ id: String, status: String = "success", at: String, sell: String = "XLM", buy: String = "USDC", amountOut: String? = "18938032") throws -> StellarActivityItem {
        try decode(StellarActivityItem.self, """
            {"type": "tx", "id": "\(id)", "kind": "swap", "summary": "Swap 10 XLM for at least 1.8843341 USDC", "status": "\(status)", "at": "\(at)",
             "display": {"venue": "soroswap", "sell": "\(sell)", "buy": "\(buy)", "amountIn": "100000000", "minOut": "18843366"}, "section": "spot",
             "hash": "\(id)", "feeCharged": "41210", "feePayer": "user", "result": \(amountOut.map { "{\"amountOut\": \"\($0)\"}" } ?? "null")}
            """)
    }

    func testSwapHistoryShowsWhatEachSwapReallyBrought() async throws {
        let source = FakeSwapSource()
        let hash = String(repeating: "c3", count: 32)
        source.activity = [
            try item("a1", at: "2026-10-14T09:11:00.000Z", amountOut: nil),
            try item(hash, at: "2026-10-15T09:11:00.000Z"),
            try item("f1", status: "failed", at: "2026-10-15T10:11:00.000Z"),
            try item("p1", status: "pending", at: "2026-10-15T11:11:00.000Z"),
            try item("s1", at: "2026-10-13T09:11:00Z", sell: "USDC", buy: coin),
        ]
        let model = try model(source)
        model.markets += [try row(coin, code: "ECAT", contract: coin, classic: nil, phase: "graduated")]
        await model.loadHistory(.week)
        XCTAssertEqual(source.activityAsked.count, 1, "a read of its own: the shared Activity list is never Swap History's")
        XCTAssertNil(source.activityAsked.first?.section, "every swap, a graduated coin's included")
        XCTAssertEqual(source.activityAsked.first?.kind, "swap")
        XCTAssertEqual(source.activityAsked.first?.period, .week)
        XCTAssertEqual(model.history.map(\.id), [hash, "a1", "s1"], "settled swaps only, newest first")
        let real = StellarFormat.amount(18_938_032, code: "USDC", compact: true)
        XCTAssertEqual(model.history.first?.text, "\(StellarFormat.amount(100_000_000, code: "XLM", compact: true)) → \(real)", "the real amount out")
        XCTAssertFalse(model.history.contains { $0.text.contains(StellarFormat.amount(18_843_366, code: "USDC", compact: true)) }, "never the minimum")
        XCTAssertEqual(model.history[1].text, "\(StellarFormat.amount(100_000_000, code: "XLM", compact: true)) → USDC", "a result not read: no amount, never 0")
        XCTAssertTrue(model.history[2].text.hasSuffix("ECAT"), "a coin by its symbol, never its contract")
        XCTAssertEqual(model.history.first?.hash, hash)

        // A failed read keeps the range's own answer, and never shows it for another range.
        source.activityStatus = .failed
        await model.loadHistory(.week)
        XCTAssertEqual(model.historyStatus, .failed)
        XCTAssertEqual(model.history.count, 3)
        await model.loadHistory(.month)
        XCTAssertTrue(model.history.isEmpty)

        source.activityStatus = .needsSignIn
        let fresh = try self.model(source)
        await fresh.loadHistory(.day)
        XCTAssertEqual(fresh.historyStatus, .needsSignIn, "a passkey account with no session: the sign-in row, and no prompt")
        XCTAssertTrue(fresh.history.isEmpty)
    }

    // MARK: - Against a Lite server on testnet

    /// Owner bug 1a end to end, against a Lite server on testnet (TEST_RUNNER_LITE_API, a package's local stack). A fresh
    /// account is set up as the app does it (a silent sign-in, Friendbot, Enable USDC), then Swap's model on the account's
    /// own store, as the screen drives it, swaps XLM → USDC and back (the whole USDC balance), and last a Max XLM → USDC:
    /// each quoted, planned for the venue on screen with the minimum the screen showed bound, verified, signed and sent,
    /// and settled with what it brought, its fee paid by the user (Horizon's fee_account). After the Max the account
    /// keeps its minimum balance, its balances moved by what the swap spent, brought and paid, and Swap History shows the
    /// swap with its real amount while the shared Activity list stays as it was. With TEST_RUNNER_LITE_SWAP_COIN (a
    /// graduated DyorHQ coin's contract), Swap buys the coin with XLM and the store sells it back, as Swap's review
    /// builds it. It spends Friendbot's test XLM on an account it makes itself.
    func testSwapsSettleOnTestnet() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let base = variables["LITE_API"].flatMap(URL.init(string:)) else { throw XCTSkip("LITE_API not set") }
        let (session, store, address) = try await liveAccount(base: base)
        let horizon = try XCTUnwrap(store.config?.horizonUrl)
        let reads = session.publicReads

        let model = StellarSwapModel(defaults: try temporaryDefaults())
        model.attach(store) { try await reads.market($0).row }
        model.markets = reads.markets
        XCTAssertEqual([model.sell, model.buy], ["XLM", "USDC"])

        // 10 XLM for USDC, then all of that USDC back: both directions, each venue the best on screen.
        model.amountText = "10"
        var account = try XCTUnwrap(store.account)
        let (_, toUSDC) = try await swapOnTestnet(model, store: store)
        try await expectFeePaidBy(address, hash: toUSDC.hash, horizon: horizon)
        account = try await settledAccount(store, after: account)
        model.flip()
        XCTAssertEqual([model.sell, model.buy], ["USDC", "XLM"])
        model.applyMax()
        XCTAssertEqual(model.amountIn, account.balance("USDC"), "Max of USDC: the whole balance")
        let (_, toXLM) = try await swapOnTestnet(model, store: store)
        try await expectFeePaidBy(address, hash: toXLM.hash, horizon: horizon)
        account = try await settledAccount(store, after: account)
        XCTAssertEqual(account.balance("USDC"), 0, "all of it swapped")

        if let coin = variables["LITE_SWAP_COIN"], StrKey.isValid(.contract, coin) {
            // A graduated coin, bought with 10 XLM on Swap: Soroswap routes it.
            model.select("XLM", for: .pay)
            model.select(coin, for: .receive)
            XCTAssertEqual([model.sell, model.buy], ["XLM", coin])
            model.amountText = "10"
            await model.learnSides()
            XCTAssertNil(model.curveToken, "a graduated coin trades on Swap")
            let (coinReview, bought) = try await swapOnTestnet(model, store: store)
            XCTAssertEqual(coinReview.route.venue, "soroswap")
            let coins = try XCTUnwrap(bought.result?.amountOut.flatMap { Int64($0) })
            try await expectFeePaidBy(address, hash: bought.hash, horizon: horizon)

            // Sold back through the store, as Swap's review builds it: its best route, the minimum it quotes bound.
            let back = try await store.swapQuote(sell: coin, buy: "XLM", amount: coins, slippageBps: 300)
            let route = try XCTUnwrap(StellarSwapModel.routes(back, listed: PinnedContracts.testnet.allContracts).first)
            let action = try await store.swapPlan(back, venue: route.venue)
            XCTAssertEqual(action.bindings.minimums.values.first, route.minimum)
            let results = try await store.run(action, reason: "Confirm Swap")
            let sold = try XCTUnwrap(results.last)
            XCTAssertEqual([sold.status, sold.feePayer], ["success", "user"])
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(sold.result?.amountOut.flatMap { Int64($0) }), route.minimum)
            try await expectFeePaidBy(address, hash: sold.hash, horizon: horizon)
            account = try await settledAccount(store, after: account)
        }

        // Max XLM → USDC: what the account can swap and still pay the fee and keep its minimum balance.
        model.select("XLM", for: .pay)
        model.select("USDC", for: .receive)
        let before = account
        model.applyMax()
        let max = try XCTUnwrap(model.maxIn)
        XCTAssertGreaterThan(model.amountIn, 0)
        XCTAssertLessThanOrEqual(model.amountIn, max)
        let (review, swapped) = try await swapOnTestnet(model, store: store)
        XCTAssertEqual(review.amountIn, model.amountIn)
        let usdcOut = try XCTUnwrap(swapped.result?.amountOut.flatMap { Int64($0) })
        try await expectFeePaidBy(address, hash: swapped.hash, horizon: horizon)

        let after = try await settledAccount(store, after: before)
        let position = try XCTUnwrap(after.xlm)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(Int64(position.balance)), try XCTUnwrap(Int64(position.minBalance)), "the account keeps its minimum balance")
        XCTAssertEqual(after.balance("USDC") - before.balance("USDC"), usdcOut, "what the swap brought, in the balance")
        let fee = try XCTUnwrap(swapped.feeCharged.flatMap { Int64($0) })
        XCTAssertEqual(before.balance("XLM") - after.balance("XLM"), review.amountIn + fee, "the XLM swapped and the network fee, nothing else")

        // Swap History: the swap with what it really brought, in a read of its own.
        let shared = store.activity
        let sharedStatus = store.status(.activity)
        await model.loadHistory(.day)
        XCTAssertEqual(model.historyStatus, .read)
        let row = try XCTUnwrap(model.history.first { $0.hash == swapped.hash }, "\(model.history)")
        XCTAssertEqual(row.text, "\(StellarFormat.amount(review.amountIn, code: "XLM", compact: true)) → \(StellarFormat.amount(usdcOut, code: "USDC", compact: true))")
        XCTAssertTrue(model.history.contains { $0.hash == toUSDC.hash } && model.history.contains { $0.hash == toXLM.hash }, "every swap of the day")
        XCTAssertEqual(store.activity, shared)
        XCTAssertEqual(store.status(.activity), sharedStatus)
    }

    /// The starter swap (§4.3, §8.6.2) against a Lite server that rehearses mainnet's setup (TEST_RUNNER_LITE_API_SPONSORED, a
    /// local stack started with --activation sponsored). DyorHQ sets a fresh account up with no XLM of its own; a funder
    /// of the test's own (Friendbot made it) buys USDC on Swap and sends it 3. Swap, opened as the add-funds card opens it
    /// (the whole USDC balance for XLM), reviews "Paid by DyorHQ" only because the phone proved it, and the sponsor pays
    /// the swap on chain. The next swap is the account's own: "Up to … XLM", paid by the account.
    func testTheStarterSwapIsPaidByDyorHQOnceThenTheAccountPays() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let base = variables["LITE_API_SPONSORED"].flatMap(URL.init(string:)) else { throw XCTSkip("LITE_API_SPONSORED not set") }
        let (session, store, address) = try await liveAccount(base: base)
        let config = try XCTUnwrap(store.config)
        XCTAssertEqual(config.activation, "sponsored")
        XCTAssertEqual(store.account?.xlm?.spendable, "0", "DyorHQ set the account up: no XLM of its own")

        let (funderSession, funder, _) = try await liveAccount(base: base, friendbot: true)
        let bought = StellarSwapModel(defaults: try temporaryDefaults())
        bought.attach(funder)
        bought.markets = funderSession.publicReads.markets
        bought.amountText = "40"
        _ = try await swapOnTestnet(bought, store: funder)
        let send = try await funder.sendPlan(asset: "USDC", to: address, amount: 30_000_000, memo: nil)
        let sent = try await funder.run(send, reason: "Confirm Send")
        XCTAssertEqual(sent.last?.status, "success")
        await store.refreshAccount()
        XCTAssertEqual(store.account?.balance("USDC"), 30_000_000)

        // The add-funds card's Swap: USDC for XLM, the whole balance.
        let model = StellarSwapModel(defaults: try temporaryDefaults())
        model.attach(store)
        model.markets = session.publicReads.markets
        model.apply(StellarSwapRequest(sell: "USDC", buy: "XLM", starter: true))
        XCTAssertEqual(model.amountIn, 30_000_000, "the starter swap sells all of it")
        await model.quote(sleep: { wait in if wait != .milliseconds(400) { throw Stop() } })
        let review = try XCTUnwrap(model.review, "no review: \(model.currentError ?? "no quote")")
        XCTAssertEqual(review.quote.starterSwap?.eligible, true)
        let starter = try await model.plan(for: review)
        XCTAssertTrue(starter.sponsorVerified, "the phone proved DyorHQ pays it")
        XCTAssertEqual(StellarFormat.feeSummary(StellarFeeSummary(starter.fees)), StellarFormat.sponsoredFee, "Max network fee: Paid by DyorHQ")
        XCTAssertEqual(StellarFeeSummary(starter.fees).sponsorReason, .starterSwap)
        let firstRun = try await store.run(starter, reason: "Confirm Swap")
        let first = try XCTUnwrap(firstRun.last)
        XCTAssertEqual([first.status, first.feePayer], ["success", "sponsor"])
        try await expectFeePaidBy(config.sponsor, hash: first.hash, horizon: config.horizonUrl)

        // The next swap is the account's own: 1 XLM for USDC, priced and paid by the account.
        await store.refreshAccount()
        XCTAssertGreaterThan(Int64(store.account?.xlm?.spendable ?? "0") ?? 0, 10_000_000)
        model.select("XLM", for: .pay)
        model.select("USDC", for: .receive)
        model.amountText = "1"
        await model.quote(sleep: { wait in if wait != .milliseconds(400) { throw Stop() } })
        let next = try XCTUnwrap(model.review, "no review: \(model.currentError ?? "no quote")")
        XCTAssertEqual(next.quote.starterSwap?.eligible, false)
        let own = try await model.plan(for: next)
        XCTAssertFalse(own.sponsorVerified)
        guard case .upTo(let stroops) = StellarFeeSummary(own.fees).value else { return XCTFail("\(StellarFeeSummary(own.fees))") }
        XCTAssertEqual(StellarFormat.feeSummary(StellarFeeSummary(own.fees)), tr("Up to \(StellarFormat.xlm(stroops: stroops))"))
        let secondRun = try await store.run(own, reason: "Confirm Swap")
        let second = try XCTUnwrap(secondRun.last)
        XCTAssertEqual([second.status, second.feePayer], ["success", "user"])
        try await expectFeePaidBy(address, hash: second.hash, horizon: config.horizonUrl)
    }

    /// A fresh account on the Lite server at `base`, set up as the app sets one up: a silent sign-in, the account (Friendbot
    /// on testnet, DyorHQ where activation is sponsored) and Enable USDC; then its figures and Top Tokens read. With
    /// `friendbot`, Friendbot makes the account first, as an imported wallet's is already there. Removed from this iPhone
    /// when the test ends.
    private func liveAccount(base: URL, friendbot: Bool = false) async throws -> (LiteSession, LiteStore, String) {
        let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let address = try StellarSigner(seed: seed).address
        let activated = LiteSession.activatedKey(address)
        let signedOut = LiteSession.signedOutKey(address)
        addTeardownBlock {
            StellarKeychain.erase(account: address)
            UserDefaults.standard.removeObject(forKey: activated)
            UserDefaults.standard.removeObject(forKey: signedOut)
        }
        if friendbot {
            let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: "https://friendbot.stellar.org/?addr=\(address)")))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Friendbot")
        }
        let keys = GatedSeedKeyProvider(address: address, methodLabel: "Email & Password", network: "testnet", appLockApplies: { false },
                                        seed: { seed }, ownerCheck: StellarOwnerCheck(canAuthenticate: { true }, authenticate: { _ in true }))
        let session = LiteSession(env: LiteEnvironment(apiURL: base, pinned: .testnet, buildNumber: 1_000_000), stellarAddress: address, monad: nil,
                                  keys: keys)
        await session.run()
        XCTAssertEqual(session.state, .waiting(.setUp))
        await session.setUp(invite: nil)
        XCTAssertEqual(session.state, .ready, "steps: \(session.steps)")
        let store = try XCTUnwrap(session.store)
        async let account: Void = store.refreshAccount()
        async let fees: Void = store.refreshFees()
        await session.publicReads.refreshMarkets()
        _ = await (account, fees)
        return (session, store, address)
    }

    /// What Review and Confirm do with what is on screen: one quote, the plan for the venue shown (the minimum the quotes
    /// footer showed is the one bound), and the run, settled.
    private func swapOnTestnet(_ model: StellarSwapModel, store: LiteStore) async throws -> (StellarSwapReview, TxStatus) {
        await model.quote(sleep: { wait in if wait != .milliseconds(400) { throw Stop() } })
        let position = store.account?.xlm.map { "balance \($0.balance), spendable \($0.spendable), min \($0.minBalance)" } ?? "no XLM position"
        let review = try XCTUnwrap(model.review, "no review: \(model.currentError ?? "no quote") \(model.actionTitle); amount \(model.amountIn), max \(model.maxIn.map(String.init) ?? "nil"), enable \(model.needsEnable), \(position)")
        let action = try await model.plan(for: review)
        XCTAssertEqual(Array(action.bindings.minimums.values), [review.route.minimum], "the minimum shown is the one bound")
        XCTAssertEqual(action.limits.values.first, review.amountIn, "the amount typed is the one spent")
        let intents = action.plan.steps.compactMap(\.intent)
        XCTAssertNil(StellarBoundRows.recipient(action.bindings, intents: intents), "no To row: it pays the account")
        // You pay and Minimum received name the sides as Swap showed them (a coin by its symbol, not its contract).
        for asset in action.limits.keys {
            XCTAssertEqual(StellarBoundRows.name(asset, store: store, named: review.named, intents: intents).code, review.sell.code, "You pay")
        }
        for asset in (intents.last?.receive ?? [:]).keys {
            XCTAssertEqual(StellarBoundRows.name(asset, store: store, named: review.named, intents: intents).code, review.buy.code, "Minimum received")
        }
        XCTAssertEqual(action.plan.steps.last.map { $0.label }, "Swap via \(review.route.venue == "sdex" ? "SDEX" : StellarSwapRoute.name(review.route.venue))",
                       "the venue on screen is the one built")
        let results = try await store.run(action, reason: "Confirm Swap")
        let settled = try XCTUnwrap(results.last)
        XCTAssertEqual(settled.status, "success")
        XCTAssertEqual(settled.feePayer, "user")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(settled.result?.amountOut.flatMap { Int64($0) }), review.route.minimum, "at least the minimum")
        return (review, settled)
    }

    /// The account as the server reads it once a settled swap shows in it: its XLM balance no longer `previous`'s. Horizon,
    /// which `/v1/account` reads, can be a ledger behind the transaction the run saw settle.
    private func settledAccount(_ store: LiteStore, after previous: AccountView) async throws -> AccountView {
        for _ in 0..<15 {
            await store.refreshAccount()
            if let account = store.account, account.balance("XLM") != previous.balance("XLM") { return account }
            try await Task.sleep(for: .seconds(1))
        }
        return try XCTUnwrap(store.account)
    }

    /// Horizon says `address` paid the transaction's fee.
    private func expectFeePaidBy(_ address: String, hash: String, horizon: String) async throws {
        let url = try XCTUnwrap(URL(string: "\(horizon)/transactions/\(hash)"))
        let (data, _) = try await URLSession.shared.data(from: url)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["fee_account"] as? String, address, "Horizon's fee_account")
    }

    // MARK: - The review

    /// The review's "To" row is for a plan that pays an address the user typed or confirmed. A swap's plan is held to the
    /// account itself (`.own`: the run refuses any other address), so its review lists no "To" with the user's own G….
    func testTheReviewShowsNoToRowForAPlanHeldToTheAccountItself() throws {
        let me = FakeSwapSource().address
        let friend = "GDQNY3PBOJOKYZSRMK2S7LHHGWZIUISD4QORETLMXEWXBI7KFZZMKTL3"
        let swap = try decode(Intent.self, """
            {"kind": "swap", "summary": "Swap 10 XLM for at least 1.8 USDC", "spend": {"\(xlmContract)": "100000000"},
             "receive": {"\(usdcContract)": "18000000"}, "to": "\(me)"}
            """)
        let send = try decode(Intent.self, """
            {"kind": "payment", "summary": "Send 5 USDC", "spend": {"\(usdcContract)": "50000000"}, "to": "\(friend)"}
            """)
        XCTAssertNil(StellarBoundRows.recipient(PlanBindings(minimums: [usdcContract: 18_000_000]), intents: [swap]), "a swap pays the account itself")
        XCTAssertEqual(StellarBoundRows.recipient(PlanBindings(destination: .confirmed(to: friend, memo: nil)), intents: [send]), friend,
                       "a send shows the address typed, whole")
        XCTAssertEqual(StellarBoundRows.recipient(PlanBindings(destination: .unchecked), intents: [send]), friend)
    }

    /// Monad's review rows in Monad's order (§8.6.1, SwapView.swift's SwapConfirmation): You pay, You receive, Minimum
    /// received, Venue, Route, Slippage. You pay and Minimum received are the plan's own rows (`receives` puts them).
    func testTheReviewListsMonadsRowsInMonadsOrder() throws {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() }
        let sheet = try String(contentsOf: folder.appendingPathComponent("DyorHQ/Lite/Wallet/StellarConfirmationSheet.swift"), encoding: .utf8)
        let order = ["parts: [.spends]", "DetailRow(\"You receive\", verbatim: receives)", "parts: [.minimums], minimumReceived: true", "details",
                     "parts: [.destination]"]
        let start = try XCTUnwrap(sheet.range(of: "if let receives {"))
        var at = start.upperBound
        for part in order {
            let found = try XCTUnwrap(sheet.range(of: part, range: at..<sheet.endIndex), part)
            at = found.upperBound
        }
        XCTAssertTrue(sheet.contains("minimumReceived ? Text(\"Minimum received\") : Text(\"Minimum\")"), "Monad's label for the bound minimum")
        let view = try XCTUnwrap(try swapSources().first { $0.name == "StellarSwapView.swift" }?.text)
        let receives = try XCTUnwrap(view.range(of: "receives: StellarFormat.amount(route.amountOut, code: review.buy.code, decimals: review.buy.decimals),"))
        let confirmation = try XCTUnwrap(view.range(of: "named: review.named) {", range: receives.upperBound..<view.endIndex))
        let rest = view[confirmation.upperBound...]
        let venue = try XCTUnwrap(rest.range(of: "DetailRow(\"Venue\""))
        let route = try XCTUnwrap(rest.range(of: "DetailRow(\"Route\""))
        let slippage = try XCTUnwrap(rest.range(of: "DetailRow(\"Slippage\", NumberStyle.basisPoints(review.slippageBps))"))
        XCTAssertTrue(venue.lowerBound < route.lowerBound && route.lowerBound < slippage.lowerBound)
        XCTAssertFalse(rest.prefix(upTo: slippage.upperBound).contains("You receive"), "You receive is the sheet's, after You pay")
    }

    /// Monad's review names both sides by symbol in You pay, You receive and Minimum received. You pay and Minimum
    /// received are the plan's rows, keyed by contract: for a side the registry doesn't list (a graduated DyorHQ coin, a
    /// pasted classic asset) they read the short contract ("CBGQ…3X2V") while You receive said "ECAT". They read what Swap
    /// showed, by the id and the contract the phone derives from it, never a plan's display strings.
    func testTheReviewNamesBothSidesAsSwapShowedThem() async throws {
        let source = FakeSwapSource()
        source.config = try config()
        source.quotes = [try quote([("soroswap", 4_000_000_000, 3_960_000_000)], paths: ["soroswap": [xlmContract, coin]], buy: coin)]
        let model = try model(source)
        model.markets += [try row(coin, code: "ECAT", contract: coin, classic: nil, phase: "graduated")]
        model.select(coin, for: .receive)
        model.amountText = "10"
        await quoteOnce(model)
        let review = try XCTUnwrap(model.review)
        // The plan's step, as /v1/swap/build names it (backend swap.ts swapIntent): spends and receives by contract, and a
        // display with the server's codes, which the rows never read.
        let buy = try decode(Intent.self, """
            {"kind": "swap", "summary": "Swap 10 XLM for at least 396 ECAT", "spend": {"\(xlmContract)": "100000000"},
             "receive": {"\(coin)": "3960000000"}, "to": "\(source.address)",
             "display": {"venue": "soroswap", "sell": "XLM", "buy": "SERVER", "amountIn": "100000000", "minOut": "3960000000"}}
            """)
        XCTAssertEqual(StellarBoundRows.name(coin, store: nil, named: [:], intents: [buy]).code, "CBGQ…3X2V", "what the review showed before")
        XCTAssertEqual(StellarBoundRows.name(coin, store: nil, named: review.named, intents: [buy]), StellarBoundRows.Name(code: "ECAT", decimals: 7),
                       "Minimum received names the coin as You receive does")
        XCTAssertEqual(StellarBoundRows.name("XLM", store: nil, named: review.named, intents: [buy]).code, "XLM")

        // Sold back: You pay names the coin by the contract the plan's limit is keyed by, its id (`LiteStore.limit`).
        let sale = StellarSwapReview(quote: review.quote, route: review.route, sell: review.buy, buy: review.sell, amountIn: 4_000_000_000,
                                     slippageBps: review.slippageBps)
        XCTAssertEqual(StellarBoundRows.name(coin, store: nil, named: sale.named, intents: []).code, "ECAT", "You pay names the coin")

        // A classic asset the registry doesn't list, by its CODE:ISSUER: the plan keys what it brings by the asset's Stellar
        // Asset Contract, which the phone derives as the store binds it.
        let pasted = StellarSwapReview(quote: review.quote, route: review.route, sell: review.sell, buy: model.token(eurcClassic), amountIn: review.amountIn,
                                       slippageBps: review.slippageBps)
        XCTAssertEqual(LiteStore.assetContract(eurcClassic, network: .testnet), eurcContract)
        XCTAssertEqual(StellarBoundRows.name(eurcContract, store: nil, named: pasted.named, intents: []).code, "EURC")
        XCTAssertEqual(StellarBoundRows.name(eurcClassic, store: nil, named: pasted.named, intents: []).code, "EURC")
        XCTAssertEqual(StellarBoundRows.name("CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526", store: nil, named: pasted.named, intents: []).code,
                       "CAAQ…C526", "an asset neither side is: its short id")
    }

    // MARK: - Source rules

    /// Swap's sources (ios/DyorHQ/Lite/Trade), read from this checkout.
    private func swapSources() throws -> [(name: String, text: String)] {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() } // StellarSwapTests.swift → Tests → Internal → ios
        folder.appendPathComponent("DyorHQ/Lite/Trade")
        let names = ["StellarSwapView.swift", "StellarSwapModel.swift", "StellarSwapHistory.swift"]
        return try names.map { ($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) }
    }

    func testSwapIsNoLongerASeamAndUsesTheAppsOwnScreens() throws {
        let sources = try swapSources()
        for (name, text) in sources {
            XCTAssertFalse(text.contains("SEAM("), name)
            for gone in ["LiteLegacyScreens", "LiteChrome", "LiteStyle", "liteStyle", "ActivityLog", "Activity.record", "env.history", "UIPasteboard"] {
                XCTAssertFalse(text.contains(gone), "\(name): \(gone)")
            }
        }
        let view = try XCTUnwrap(sources.first { $0.name == "StellarSwapView.swift" }?.text)
        for part in ["StellarConfirmationSheet(title: \"Review Swap\", confirmTitle: \"Swap\"", "SlippageSheet(slippageBps:", "StellarSearchSheet(purpose:",
                     "StellarTradeModeSwitcher()", "AmountField(title:", ".navigationTitle(MenuItem.earnTitle)"] {
            XCTAssertTrue(view.contains(part), part)
        }
        let model = try XCTUnwrap(sources.first { $0.name == "StellarSwapModel.swift" }?.text)
        XCTAssertTrue(model.contains("source.swapPlan(review.quote, venue: review.route.venue)"), "the review builds the venue it shows")
        // Prices follow the market while Swap is on screen, as Home polls (§8.2.7).
        XCTAssertEqual(StellarSwapView.pricesInterval, .seconds(30))
        XCTAssertTrue(view.contains("""
                                do { try await Task.sleep(for: Self.pricesInterval) } catch { return }
                                await reads.refreshMarkets()
                                await model.refreshFound()
            """), "Top Tokens and the sides it doesn't list, every 30 s")
    }

    /// No Stellar screen opens the legacy swap sheet: Swap mode is this port, and every Swap entry (Home's search and
    /// add-funds card, a token page, a graduated coin, a Moment's coin, Portfolio, the side menu's Spot) opens it through
    /// `Router.openStellarSwap`. Only the token page's seam still hosts the old sheet, until its own port (WP-30) opens
    /// Swap mode instead.
    func testNoStellarScreenOpensTheLegacySwapSheet() throws {
        var lite = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { lite.deleteLastPathComponent() } // StellarSwapTests.swift → Tests → Internal → ios
        lite.appendPathComponent("DyorHQ/Lite")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: lite, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            guard text.contains("LiteLegacyScreens.swap(") else { continue }
            XCTAssertTrue(text.contains("SEAM(WP-30)"), "\(file.lastPathComponent) opens the legacy swap sheet")
        }
        XCTAssertGreaterThan(read, 50, "every Stellar screen was read")
    }

    func testCoinValueRules() throws {
        let coinValue = try NSRegularExpression(pattern: #"priceNumber|LaunchpadMath\.marketCap\(|\b(launch|\$0|\$1)\.(price|marketCap)\b"#)
        for (name, text) in try swapSources() {
            XCTAssertNil(coinValue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), name)
        }
    }
}
