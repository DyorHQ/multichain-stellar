@testable import DyorLite
import StellarKit
import XCTest

/// The pure helpers the Stellar screens render (docs/DESIGN-stellar-parity.md §7.2): Top Tokens' tabs, a Moment's
/// state, the launchpad's figures, Activity's wording (never a stand-in name), the network fee row and the setup's
/// price, percents (R24), the media policy, StellarExpert links and the error copy of §6.13.
final class LiteHelpersTests: XCTestCase {
    private var saved: Locale!

    override func setUp() {
        saved = LiteL10n.locale
        LiteL10n.locale = Locale(identifier: "en_US")
    }

    override func tearDown() { LiteL10n.locale = saved }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - StellarPercent

    func testPercentsComeFromFractionsOnce() throws {
        XCTAssertTrue(StellarPercent(0.0123) == 1.23)
        XCTAssertEqual(StellarPercent(-0.013).value, -1.3)
        XCTAssertEqual(StellarPercent(0.031).value, 3.1)
        XCTAssertNil(StellarPercent(nil as Double?))
        XCTAssertNil(StellarPercent(Double.nan as Double?))
        let row = try decode(StellarMarketRow.self, Self.marketRow(id: "XLM", price: 0.19, change: -0.0123))
        XCTAssertEqual(row.change24hPercent, -1.23)
        XCTAssertNil(try decode(StellarMarketRow.self, Self.marketRow(id: "NEW", price: 0.1, change: nil)).change24hPercent)
        let market = try decode(EarnMarket.self, #"{"pool":"P","poolName":"Blend","asset":"A","code":"XLM","decimals":7,"supplyApy":0.031,"borrowApy":0.05,"utilization":0.42,"totalSupplied":1}"#)
        XCTAssertEqual(market.supplyApyPercent, 3.1)
        XCTAssertEqual(market.utilizationPercent, 42)
    }

    // MARK: - StellarMarketRanking

    static func marketRow(id: String, price: Double?, change: Double?) -> String {
        """
        {"id":"\(id)","kind":"registry","contract":"C\(id)","classic":null,"code":"\(id)","name":"\(id)","decimals":7,"logo":null,"image":null,
         "verified":true,"badges":[],"note":null,"priceUsd":\(price.map { "\($0)" } ?? "null"),"change24h":\(change.map { "\($0)" } ?? "null"),
         "isNew":\(change == nil),"volume24hUsd":null,"marketCapUsd":null,"priceSource":{"kind":"reference","market":null,"quote":null,"quotePrice":null,"at":null},
         "stale":false,"launch":null}
        """
    }

    func testTopTokensTabsSortAsMonadHomeDoes() throws {
        let specs: [(id: String, price: Double?, change: Double?)] = [("XLM", 0.19, -0.01), ("USDC", 1.0, 0.0001), ("ECAT", 0.0004, 0.12),
                                                                     ("DOG", 0.01, -0.2), ("NOPRICE", nil, 0.5), ("NEW", 0.2, nil)]
        let rows = try specs.map { try decode(StellarMarketRow.self, Self.marketRow(id: $0.id, price: $0.price, change: $0.change)) }
        func ids(_ tab: StellarMarketRanking.Tab) -> [String] { StellarMarketRanking.rows(rows, tab: tab).map(\.id) }
        XCTAssertEqual(ids(.popular), ["XLM", "USDC", "ECAT", "DOG", "NEW"], "the server's order; unpriced rows never show")
        XCTAssertEqual(ids(.hot), ["DOG", "ECAT", "XLM", "USDC", "NEW"], "by the size of the move either way; none counts as 0")
        XCTAssertEqual(ids(.gainers), ["ECAT", "USDC"])
        XCTAssertEqual(ids(.losers), ["DOG", "XLM"])
        XCTAssertEqual(StellarMarketRanking.Tab.allCases.map(\.rawValue), ["popular", "hot", "gainers", "losers"], "the app's HomeTokenTab raw values")
    }

    // MARK: - StellarMomentState

    func testAMomentsStateAtItsBoundaries() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let later = now.addingTimeInterval(60)
        XCTAssertEqual(StellarMomentState(maxEditions: 10, minted: 9, deadline: later, now: now), .collecting)
        XCTAssertEqual(StellarMomentState(maxEditions: 10, minted: 10, deadline: later, now: now), .soldOut)
        XCTAssertEqual(StellarMomentState(maxEditions: 10, minted: 9, deadline: now, now: now), .windowClosed, "closed at its deadline")
        XCTAssertEqual(StellarMomentState(maxEditions: 10, minted: 10, deadline: now, now: now), .soldOut, "sold out says so after the window too")
        XCTAssertEqual(StellarMomentState(maxEditions: 0, minted: 1_000_000, deadline: later, now: now), .collecting, "an open edition never sells out")
        XCTAssertEqual(StellarMomentState(maxEditions: 0, minted: 5, deadline: now.addingTimeInterval(-1), now: now), .windowClosed)

        func moment(deadline: String, state: String?, open: Bool) throws -> StellarMoment {
            try decode(StellarMoment.self, """
            {"id":3,"creator":"G","uri":"u","title":"Sunset","mediaUrl":null,"price":"10000000","quote":"C","maxEditions":10,"minted":3,
             "deadline":"\(deadline)","open":\(open),"createdAt":"2026-10-14T09:41:00.000Z","state":\(state.map { "\"\($0)\"" } ?? "null")}
            """)
        }
        XCTAssertEqual(StellarMomentState(try moment(deadline: "2033-05-18T04:00:00.000Z", state: "closed", open: false), now: now), .collecting,
                       "the deadline decides, whatever the server said when it was read")
        XCTAssertEqual(StellarMomentState(try moment(deadline: "soon", state: "closed", open: true), now: now), .windowClosed)
        XCTAssertEqual(StellarMomentState(try moment(deadline: "soon", state: nil, open: true), now: now), .collecting)

        XCTAssertEqual(StellarMomentState.collectLimit(maxEditions: 10, minted: 3, maxPerCollect: 20), 7)
        XCTAssertEqual(StellarMomentState.collectLimit(maxEditions: 100, minted: 3, maxPerCollect: 20), 20)
        XCTAssertEqual(StellarMomentState.collectLimit(maxEditions: 0, minted: 3, maxPerCollect: 20), 20, "an open edition: the contract's maximum")
        XCTAssertEqual(StellarMomentState.collectLimit(maxEditions: 10, minted: 10, maxPerCollect: 20), 1, "never a 1...0 range")
    }

    // MARK: - StellarLaunchMath

    static func launch(token: String, createdAt: String, progress: Double, cap: Double?, completed: Bool = false, graduated: Bool = false) -> String {
        """
        {"token":"\(token)","creator":"G","quote":"CQ","name":"\(token)","symbol":"\(token)","uri":"","supply":"1","quoteReserve":"1","tokenReserve":"1",
         "realQuote":"0","threshold":"1","progress":\(progress),"completed":\(completed),"graduated":\(graduated),"pair":null,"lastPrice":null,
         "volume":"0","trades":0,"createdAt":"\(createdAt)","marketCapUsd":\(cap.map { "\($0)" } ?? "null")}
        """
    }

    func testLaunchSortsProgressHoldersAndMinimum() throws {
        let specs: [(token: String, createdAt: String, progress: Double, cap: Double?)] = [
            ("AAA", "2026-10-14T09:00:00.000Z", 0.42, 3990.1),
            ("BBB", "2026-10-14T10:00:00.000Z", 0.9, nil),
            ("CCC", "2026-10-14T08:00:00.000Z", 0.1, 12_000.0),
            ("DDD", "2026-10-14T11:00:00.000Z", 0.42, nil),
        ]
        let launches = try specs.map { try decode(StellarLaunch.self, Self.launch(token: $0.token, createdAt: $0.createdAt, progress: $0.progress, cap: $0.cap)) }
        func order(_ sort: StellarLaunchMath.Sort) -> [String] { StellarLaunchMath.sorted(launches, by: sort).map(\.token) }
        XCTAssertEqual(order(.newest), ["DDD", "BBB", "AAA", "CCC"])
        XCTAssertEqual(order(.marketCap), ["CCC", "AAA", "DDD", "BBB"], "a cap with no USD price comes after every priced one")
        XCTAssertEqual(order(.nearGraduation), ["BBB", "DDD", "AAA", "CCC"], "equal progress: the newest first")
        XCTAssertEqual(StellarLaunchMath.Sort.marketCap.rawValue, "market_cap")

        let full = try decode(StellarLaunch.self, Self.launch(token: "F", createdAt: "x", progress: 0.97, cap: nil, completed: true))
        XCTAssertEqual(StellarLaunchMath.progress(full), 1)
        XCTAssertEqual(StellarLaunchMath.progressPercent(full), 100)
        let almost = try decode(StellarLaunch.self, Self.launch(token: "A", createdAt: "x", progress: 0.996, cap: nil))
        XCTAssertEqual(StellarLaunchMath.progressPercent(almost), 99, "never 100% before the curve is full")
        let odd = try decode(StellarLaunch.self, Self.launch(token: "O", createdAt: "x", progress: 1.7, cap: nil))
        XCTAssertEqual(StellarLaunchMath.progress(odd), 1)

        XCTAssertEqual(StellarLaunchMath.holdersText(5, complete: true), "5")
        XCTAssertEqual(StellarLaunchMath.holdersText(1234, complete: false), "1,234+")
        XCTAssertNil(StellarLaunchMath.holdersText(nil, complete: true))

        XCTAssertEqual(StellarLaunchMath.minOut(100), 99)
        XCTAssertEqual(StellarLaunchMath.minOut(18_938_032), 18_748_651)
        XCTAssertEqual(StellarLaunchMath.minOut(Int64.max), Int64.max / 100 * 99 + Int64.max % 100 * 99 / 100, "no overflow")
        XCTAssertEqual(StellarLaunchMath.minOut(0), 0)
    }

    // MARK: - StellarActivityPresenter

    private func item(_ json: String) throws -> StellarActivityItem { try decode(StellarActivityItem.self, json) }

    func testActivityWordsEveryKindAndNeverAStandIn() throws {
        let standIn = try XCTUnwrap(LiteFormat.standIns.sorted().first)
        let buy = try item(#"{"type":"tx","id":"h","kind":"launch_buy","summary":"Buy","status":"success","at":"2026-10-14T09:41:00.000Z","display":{"symbol":"\#(standIn)","quote":"XLM","amount":"20000000","minOut":"1"},"symbol":"\#(standIn)","ref":{"token":"CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"},"result":{"amountOut":"5000000000"},"feeCharged":"41210","feePayer":"user"}"#)
        let shown = StellarActivityPresenter.present(buy)
        XCTAssertEqual(shown.symbol, "arrow.down")
        XCTAssertEqual(shown.title, .bought(symbol: "CDLZ…CYSC"), "the short contract, never the stand-in")
        XCTAssertEqual(shown.subtitle, .trade(StellarActivityAmount(units: 5_000_000_000, code: "CDLZ…CYSC"), for: StellarActivityAmount(units: 20_000_000, code: "XLM")))
        XCTAssertEqual(shown.feeStroops, 41_210)
        XCTAssertFalse(shown.paidByDyorHQ)

        let swap = try item(#"{"type":"tx","id":"s","kind":"swap","summary":"Swap","status":"success","at":"2026-10-14T09:41:00.000Z","display":{"sell":"XLM","buy":"USDC","amountIn":"100000000","minOut":"18843341"},"result":{"amountOut":"18938032"},"feePayer":"sponsor","feeCharged":"100"}"#)
        let swapped = StellarActivityPresenter.present(swap)
        XCTAssertEqual(swapped.title, .swapped)
        XCTAssertEqual(swapped.subtitle, .swap(StellarActivityAmount(units: 100_000_000, code: "XLM"), to: StellarActivityAmount(units: 18_938_032, code: "USDC")))
        XCTAssertTrue(swapped.paidByDyorHQ)
        XCTAssertNil(swapped.feeStroops)

        let send = try item(#"{"type":"tx","id":"p","kind":"payment","summary":"Send","status":"success","at":"2026-10-14T09:41:00.000Z","display":{"asset":"XLM","amount":"10.5","to":"GABC"}}"#)
        XCTAssertEqual(StellarActivityPresenter.present(send).title, .sent(code: "XLM"))
        XCTAssertEqual(StellarActivityPresenter.present(send).subtitle, .to(address: "GABC", amount: StellarActivityAmount(units: 105_000_000, code: "XLM")))

        let collect = try item(#"{"type":"tx","id":"c","kind":"moment_collect","summary":"Collect","status":"success","at":"2026-10-14T09:41:00.000Z","display":{"momentId":7,"quantity":3,"total":"30000000","quote":"USDC","title":"Sunset"}}"#)
        XCTAssertEqual(StellarActivityPresenter.present(collect).title, .collected(title: "Sunset"))
        XCTAssertEqual(StellarActivityPresenter.present(collect).subtitle, .editions(3, total: StellarActivityAmount(units: 30_000_000, code: "USDC")))

        let cases: [(String, String, StellarActivityPresentation.Title)] = [
            (#""kind":"launch_create","display":{"symbol":"ECAT","name":"E Cat"}"#, "flame.fill", .launched(symbol: "ECAT")),
            (#""kind":"launch_sell","display":{"symbol":"ECAT","quote":"XLM","amount":"5"}"#, "arrow.up", .sold(symbol: "ECAT")),
            (#""kind":"launch_claim","display":{"symbol":"ECAT"}"#, "dollarsign.circle.fill", .collectedCreatorFees(symbol: "ECAT")),
            (#""kind":"launch_graduate","display":{"symbol":"ECAT"}"#, "checkmark.seal.fill", .graduated(symbol: "ECAT")),
            (#""kind":"moment_publish","display":{"title":"Sunset","price":"10000000","quote":"XLM"}"#, "camera.aperture", .published(title: "Sunset")),
            (#""kind":"earn_deposit","display":{"asset":"USDC","amount":"1"}"#, "leaf", .supplied(code: "USDC")),
            (#""kind":"earn_withdraw","display":{"asset":"native","amount":"1"}"#, "leaf", .withdrew(code: "XLM")),
            (#""kind":"bridge_out","display":{"amount":"1"}"#, "point.3.connected.trianglepath.dotted", .bridged(code: "USDC")),
            (#""kind":"trust","display":{"asset":"USDC"}"#, "checkmark.circle", .enabled(code: "USDC")),
            (#""kind":"activate""#, "checkmark.circle", .setUpAccount),
            (#""kind":"restore""#, "checkmark.circle", .restoredData),
            (#""kind":"faucet","display":{"amount":"10000"}"#, "checkmark.circle", .fundedWithFriendbot),
            (#""kind":"faucet""#, "checkmark.circle", .fundedWithFriendbot),
            (#""kind":"blend_borrow","title":"Borrowed USDC""#, "circle", .other("Borrowed USDC")),
        ]
        for (fields, symbol, title) in cases {
            let shown = StellarActivityPresenter.present(try item(#"{"type":"tx","id":"x","summary":"s","status":"success","at":"2026-10-14T09:41:00.000Z",\#(fields)}"#))
            XCTAssertEqual(shown.symbol, symbol, fields)
            XCTAssertEqual(shown.title, title, fields)
        }
        let bridgeIn = try item(#"{"type":"bridge","id":"b","kind":"monad_to_stellar","summary":"Moved","amount":"12500000","status":"completed","at":"2026-10-14T09:41:00.000Z"}"#)
        XCTAssertEqual(StellarActivityPresenter.present(bridgeIn).subtitle, .route(from: "Monad", to: "Stellar"))
        // Friendbot's grant (decision 7) says how much it brought, in XLM.
        let friendbot = try item(#"{"type":"tx","id":"f","kind":"faucet","summary":"Funded with Friendbot","status":"success","at":"2026-10-14T09:41:00.000Z","display":{"amount":"10000"}}"#)
        XCTAssertEqual(StellarActivityPresenter.present(friendbot).subtitle, .amount(StellarActivityAmount(units: 100_000_000_000, code: "XLM")))
        // A cash transfer from before cash was removed until mainnet: the neutral title, with its amount.
        let cash = try item(#"{"type":"cash","id":"c1","kind":"withdraw","summary":"Cashed out native","title":"Cashed out XLM","amount":"50","display":{"asset":"native"},"status":"completed","at":"2026-10-14T09:41:00.000Z"}"#)
        XCTAssertEqual(StellarActivityPresenter.present(cash).title, .other("Transaction"))
        XCTAssertEqual(StellarActivityPresenter.present(cash).subtitle, .amount(StellarActivityAmount(units: 500_000_000, code: "XLM")))

        // Whatever an item holds, no word of the presentation is an old server's stand-in, and no name is empty.
        let kinds = ["launch_buy", "launch_sell", "launch_create", "launch_claim", "launch_graduate", "moment_publish", "moment_collect", "swap",
                     "payment", "trust", "earn_deposit", "earn_withdraw", "blend_borrow"]
        for raw in LiteFormat.standIns.sorted() + [""] {
            for kind in kinds {
                let shown = StellarActivityPresenter.present(try item(#"{"type":"tx","id":"t","kind":"\#(kind)","summary":"Buy \#(raw) with 2 XLM","status":"success","at":"2026-10-14T09:41:00.000Z","title":"Bought \#(raw)","subtitle":"\#(raw)","symbol":"\#(raw)","name":"\#(raw)","display":{"symbol":"\#(raw)","asset":"\#(raw)","sell":"\#(raw)","buy":"\#(raw)","quote":"\#(raw)","amount":"1","amountIn":"1","price":"1","total":"1","name":"\#(raw)","title":"\#(raw)"},"result":{"amountOut":"3"}}"#))
                let words = "\(shown)"
                for standIn in LiteFormat.standIns { XCTAssertFalse(words.contains(standIn), "\(kind): \(shown)") }
                XCTAssertFalse(words.contains("\"\""), "an empty name: \(kind): \(shown)")
            }
        }
    }

    /// An item a newer server words in a way this build doesn't know, or one that doesn't name what its words need: the
    /// server's own words while none of them is a stand-in, else "Transaction". Amounts carry a code or aren't shown.
    func testActivityFallsBackToCleanWords() throws {
        func shown(_ fields: String) throws -> StellarActivityPresentation {
            StellarActivityPresenter.present(try item(#"{"type":"tx","id":"x","status":"success","at":"2026-10-14T09:41:00.000Z",\#(fields)}"#))
        }
        XCTAssertEqual(try shown(#""kind":"blend_borrow","summary":"Borrow 5 USDC""#).title, .other("Borrow 5 USDC"))
        XCTAssertEqual(try shown(#""kind":"blend_borrow","summary":"Buy TOKEN with 2 XLM""#).title, .other("Transaction"), "an old server's stand-in in a sentence")
        XCTAssertEqual(try shown(#""kind":"blend_borrow","title":"Bought $TOKEN","summary":"Borrow 5 USDC""#).title, .other("Borrow 5 USDC"))
        XCTAssertNil(try shown(#""kind":"blend_borrow","summary":"s","subtitle":"for TOKEN""#).subtitle)

        // Known kinds that don't name their coin, Moment or asset.
        XCTAssertEqual(try shown(#""kind":"launch_buy","summary":"Buy with 2 XLM","display":{"amount":"20000000","quote":"XLM"}"#).title, .other("Buy with 2 XLM"))
        XCTAssertEqual(try shown(#""kind":"moment_publish","summary":"Publish TOKEN","display":{"price":"1","quote":"XLM"}"#).title, .other("Transaction"))
        XCTAssertEqual(try shown(#""kind":"payment","summary":"","display":{"amount":"1"}"#).title, .other("Transaction"))
        XCTAssertEqual(try shown(#""kind":"trust","summary":"Enable""#).title, .other("Enable"))

        // A swap's or a trade's amount whose asset isn't named isn't shown with an empty code.
        let swap = try shown(#""kind":"swap","summary":"Swap","display":{"amountIn":"100000000","minOut":"1"},"result":{"amountOut":"5"}"#)
        XCTAssertEqual(swap.title, .swapped)
        XCTAssertNil(swap.subtitle)
        let buy = try shown(#""kind":"launch_buy","summary":"Buy","display":{"symbol":"ECAT","amount":"20000000"},"result":{"amountOut":"5000000000"}"#)
        XCTAssertEqual(buy.title, .bought(symbol: "ECAT"))
        XCTAssertEqual(buy.subtitle, .amount(StellarActivityAmount(units: 5_000_000_000, code: "ECAT")), "what it cost has no quote named: only what it brought")
        // A swap never borrows the item's own symbol for a side it doesn't name.
        let oneSided = try shown(#""kind":"swap","summary":"Swap","symbol":"ECAT","display":{"sell":"XLM","amountIn":"10"},"result":{"amountOut":"5"}"#)
        XCTAssertNil(oneSided.subtitle)
        // A payment names its asset by the server's resolved symbol when the display has its contract.
        let token = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
        XCTAssertEqual(try shown(#""kind":"payment","summary":"Send","symbol":"ECAT","display":{"asset":"\#(token)","amount":"1"}"#).title, .sent(code: "ECAT"))
        XCTAssertEqual(try shown(#""kind":"payment","summary":"Send","display":{"asset":"\#(token)","amount":"1"}"#).title, .sent(code: "CDLZ…CYSC"))
    }

    // MARK: - StellarFeeSummary

    /// A verifier vector's transaction (StellarKit's shared vectors) as a built plan step.
    private static func vector(_ name: String) throws -> (step: String, pinned: PinnedContracts) {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("StellarKit/Tests/StellarCoreTests/Vectors/verifier.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let v = try XCTUnwrap(vectors.first { $0["name"] as? String == name })
        let step = v["step"] as? [String: Any] ?? [:]
        var json: [String: Any] = ["id": name, "label": name, "status": "built", "xdr": v["envelope"]!, "intent": v["intent"]!,
                                   "stepKind": (v["intent"] as? [String: Any])?["kind"] ?? "x"]
        json["feePayer"] = step["feePayer"]
        json["sponsorReason"] = step["sponsorReason"]
        let policy = v["feePolicy"] as! [String: String]
        let pinned = PinnedContracts(network: .testnet, sponsor: v["sponsor"] as! String, launchTokenWasmHash: v["launchTokenWasmHash"] as! String,
                                     roles: ["all": v["allowed"] as! [String]],
                                     feePolicy: FeePolicy(maxFee: Int64(policy["maxFee"]!)!, maxInclusionFeePerOp: Int64(policy["maxInclusionPerOp"]!)!,
                                                          starterInnerFeeMax: Int64(policy["starterInnerFeeMax"]!)!))
        return (String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!, pinned)
    }

    private func fees(_ steps: [String], pinned: PinnedContracts) throws -> PlanFees {
        let plan = try decode(PlanView.self, #"{"planId":"p","kind":"k","expiresAt":"2030-01-01T00:00:00.000Z","steps":[\#(steps.joined(separator: ","))]}"#)
        return try PlanFees(plan: plan, pinned: pinned)
    }

    private let unbuiltSwap = #"{"id":"u","label":"Swap","status":"pending","stepKind":"swap_soroswap","maxFee":"500000"}"#

    func testTheNetworkFeeRowSaysWhatThePhoneWorkedOut() throws {
        let (trust, pinned) = try Self.vector("user-paid trust ok")
        XCTAssertEqual(StellarFeeSummary(try fees([trust], pinned: pinned)).value, .upTo(stroops: 100))
        XCTAssertEqual(StellarFeeSummary(try fees([trust, unbuiltSwap], pinned: pinned)).value, .upToAndMore(stroops: 100, steps: 1))
        XCTAssertEqual(StellarFeeSummary(try fees([unbuiltSwap], pinned: pinned)).value, .pricedAsSigned)
        XCTAssertNil(StellarFeeSummary(try fees([trust], pinned: pinned)).sponsorReason)

        let (activate, sponsorPinned) = try Self.vector("activate ok")
        let setup = StellarFeeSummary(try fees([activate], pinned: sponsorPinned))
        XCTAssertEqual(setup.value, .paidByDyorHQ)
        XCTAssertEqual(setup.sponsorReason, .setup)
        XCTAssertTrue(try fees([activate], pinned: sponsorPinned).sponsorVerified)
        let both = StellarFeeSummary(try fees([activate, trust], pinned: sponsorPinned))
        XCTAssertEqual(both.value, .upTo(stroops: 100), "the user's own step is what the row prices")
        XCTAssertEqual(both.sponsorReason, .setup)

        let (starter, starterPinned) = try Self.vector("starter step within the cap")
        XCTAssertEqual(StellarFeeSummary(try fees([starter], pinned: starterPinned)).sponsorReason, .starterSwap)
        XCTAssertEqual(StellarFeeSummary.xlm(154_000), 0.0154)
    }

    /// The setup's Enable USDC runs at no more than the fee shown before the Set Up tap (§8.14).
    func testTheSetupRunsAtNoMoreThanTheFeeShownBeforeTheTap() throws {
        let (trust, pinned) = try Self.vector("user-paid trust ok")
        let unbuilt = { (fee: Int) in
            #"{"id":"trust","label":"Enable USDC","status":"pending","stepKind":"trust","maxFee":"\#(fee)","feePayer":"user","reserveDelta":1}"#
        }
        let plan = { (step: String) in
            try self.decode(PlanView.self, #"{"planId":"p","kind":"trust","expiresAt":"2030-01-01T00:00:00.000Z","steps":[\#(step)]}"#)
        }
        let shown = try fees([unbuilt(1_000)], pinned: pinned)

        // Not built yet: its ceiling comes down to the figure shown, and it must be built within it.
        let higher = try plan(unbuilt(50_000))
        XCTAssertEqual(try LiteSession.confirmed(try PlanFees(plan: higher, pinned: pinned), plan: higher, by: shown, pinned: pinned).maxFee("trust"), 1_000)
        let lower = try plan(unbuilt(500))
        XCTAssertEqual(try LiteSession.confirmed(try PlanFees(plan: lower, pinned: pinned), plan: lower, by: shown, pinned: pinned).maxFee("trust"), 500,
                       "a lower ceiling stays")

        // Built at once: its own fee (100 stroops) against the figure shown.
        let built = try plan(trust)
        let priced = try PlanFees(plan: built, pinned: pinned)
        XCTAssertEqual(try LiteSession.confirmed(priced, plan: built, by: shown, pinned: pinned), priced)
        XCTAssertThrowsError(try LiteSession.confirmed(priced, plan: built, by: try fees([unbuilt(99)], pinned: pinned), pinned: pinned)) { error in
            XCTAssertEqual(error as? PlanRunner.Failure, .feeAboveConfirmed(step: "user-paid trust ok"))
        }
        XCTAssertEqual(try LiteSession.confirmed(priced, plan: built, by: nil, pinned: pinned), priced, "nothing shown: the plan's own figures")
    }

    // MARK: - LiteMediaPolicy

    private let base = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/")!
    private let render = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/render/image/public/lite-media/")!
    private let upload = "uploads/GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6/0f8fad5b-d9cb-469f-a165-70867728950e"

    func testOnlyDyorHQsOwnUploadsLoad() {
        let photo = base.absoluteString + upload + ".jpg"
        XCTAssertEqual(LiteMediaPolicy.imageSources(photo, base: base, renderBase: render, pixels: 300).map(\.absoluteString),
                       [render.absoluteString + upload + ".jpg?width=300&resize=contain&quality=70", photo])
        XCTAssertEqual(LiteMediaPolicy.imageSources(photo, base: base, renderBase: render, pixels: 1024).map(\.absoluteString), [photo], "above 768: the original")
        XCTAssertEqual(LiteMediaPolicy.imageSources(base.absoluteString + upload + ".gif", base: base, renderBase: render, pixels: 300).count, 1, "a gif isn't rendered")
        XCTAssertEqual(LiteMediaPolicy.imageSources(photo, base: base, renderBase: nil, pixels: 300).map(\.absoluteString), [photo], "Debug: originals only")

        let refused = [
            "https://evil.example/" + upload + ".jpg",
            "http://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/" + upload + ".jpg",
            base.absoluteString + upload + ".jpg?x=1",
            base.absoluteString + upload + ".jpg#f",
            base.absoluteString + upload + ".svg",
            base.absoluteString + upload + ".mp4",
            base.absoluteString + "uploads/../" + upload + ".jpg",
            base.absoluteString + "uploads/GNOTANADDRESS/0f8fad5b-d9cb-469f-a165-70867728950e.jpg",
            base.absoluteString + "launches/GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6/0f8fad5b-d9cb-469f-a165-70867728950e.jpg",
            base.absoluteString + upload.uppercased() + ".jpg",
            base.absoluteString + upload + ".jpg/x",
            "https://user@fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/" + upload + ".jpg",
            "https://fmnjqrguvopusfufmirs.supabase.co:444/storage/v1/object/public/lite-media/" + upload + ".jpg",
            base.absoluteString + upload + ".jpg" + String(repeating: "a", count: 2100),
            "ipfs://bafy/" + upload + ".jpg",
            "",
        ]
        for uri in refused { XCTAssertEqual(LiteMediaPolicy.imageSources(uri, base: base, renderBase: render, pixels: 100), [], uri) }

        XCTAssertEqual(LiteMediaPolicy.videoURL(base.absoluteString + upload + ".mp4", base: base)?.absoluteString, base.absoluteString + upload + ".mp4")
        XCTAssertNotNil(LiteMediaPolicy.videoURL(base.absoluteString + upload + ".mov", base: base))
        XCTAssertNil(LiteMediaPolicy.videoURL(photo, base: base))

        // Debug's loopback stand-in over plain http; plain http to anywhere else never.
        let local = URL(string: "http://127.0.0.1:8000/lite/v1/local-media/lite-media/")!
        XCTAssertEqual(LiteMediaPolicy.imageSources(local.absoluteString + upload + ".png", base: local, renderBase: nil, pixels: nil).count, 1)
        XCTAssertEqual(LiteMediaPolicy.imageSources("http://127.0.0.1:9000/lite/v1/local-media/lite-media/" + upload + ".png", base: local, renderBase: nil, pixels: nil), [], "another port")
        let plain = URL(string: "http://media.example/lite-media/")!
        XCTAssertEqual(LiteMediaPolicy.imageSources(plain.absoluteString + upload + ".png", base: plain, renderBase: nil, pixels: nil), [])
    }

    // MARK: - StellarExplorer

    func testExplorerLinksAreBuiltFromThePinnedNetwork() {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertEqual(StellarExplorer.transaction(hash, network: .testnet)?.absoluteString, "https://stellar.expert/explorer/testnet/tx/\(hash)")
        XCTAssertEqual(StellarExplorer.transaction(hash.uppercased(), network: .mainnet)?.absoluteString, "https://stellar.expert/explorer/public/tx/\(hash)")
        XCTAssertNil(StellarExplorer.transaction("abc", network: .testnet))
        XCTAssertNil(StellarExplorer.transaction(String(repeating: "zz", count: 32), network: .testnet))
        XCTAssertEqual(StellarExplorer.account(TestAccount.passkeyAddress, network: .testnet)?.absoluteString,
                       "https://stellar.expert/explorer/testnet/account/\(TestAccount.passkeyAddress)")
        XCTAssertNil(StellarExplorer.account("GABC", network: .testnet), "a checksum that fails")
        let contract = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
        XCTAssertEqual(StellarExplorer.contract(contract, network: .testnet)?.absoluteString, "https://stellar.expert/explorer/testnet/contract/\(contract)")
        XCTAssertNil(StellarExplorer.contract(TestAccount.passkeyAddress, network: .testnet))
        XCTAssertEqual(StellarExplorer.asset("XLM", network: .testnet)?.absoluteString, "https://stellar.expert/explorer/testnet/asset/XLM")
        XCTAssertEqual(StellarExplorer.asset("USDC:\(TestAccount.passkeyAddress)", network: .testnet)?.absoluteString,
                       "https://stellar.expert/explorer/testnet/asset/USDC-\(TestAccount.passkeyAddress)")
        XCTAssertEqual(StellarExplorer.asset(contract, network: .testnet)?.absoluteString, "https://stellar.expert/explorer/testnet/contract/\(contract)")
        XCTAssertNil(StellarExplorer.asset("US/DC:\(TestAccount.passkeyAddress)", network: .testnet))
    }

    // MARK: - LiteErrorText

    func testEveryErrorCodeHasItsCopy() {
        func copy(_ code: String, _ detail: [String: String] = [:], status: Int = 409) -> String {
            LiteErrorText.describe(LiteAPIError.server(status: status, code: code, message: "the server's words", detail: detail))
        }
        XCTAssertEqual(copy("not_enough_xlm_for_fee"), "Not enough XLM for the network fee.")
        XCTAssertEqual(copy("tx_rejected", ["code": "tx_insufficient_fee"]), "Not enough XLM for the network fee.")
        XCTAssertEqual(copy("tx_rejected", ["code": "tx_insufficient_balance"]), "Not enough XLM for the network fee.")
        XCTAssertEqual(copy("not_enough_xlm_for_reserve"), "Not enough XLM for Stellar's minimum balance.")
        XCTAssertEqual(copy("tx_rejected", ["code": "op_low_reserve"]), "Not enough XLM for Stellar's minimum balance.")
        XCTAssertEqual(copy("tx_rejected", ["code": "CHANGE_TRUST_LOW_RESERVE"]), "Not enough XLM for Stellar's minimum balance.")
        XCTAssertEqual(copy("not_enough_xlm", ["minBalance": "15000000"]), "Not enough XLM. 1.5 XLM stays in your account.")
        XCTAssertEqual(copy("tx_rejected", ["code": "op_underfunded", "minBalance": "15000000"]), "Not enough funds for this.", "which asset, only the run knows")
        XCTAssertEqual(copy("not_enough_xlm"), "Not enough XLM.")
        XCTAssertEqual(copy("fee_too_high", ["fee": "31000000", "max": "30000000"], status: 422),
                       "Not signed: the network fee is unusually high right now (3.1 XLM). Nothing was sent. Try again in a minute.")
        XCTAssertEqual(copy("sponsor_limit", status: 429), "DyorHQ's free setup is busy today. Try again tomorrow.")
        XCTAssertEqual(copy("already_set_up"), "Your account is already set up.")
        XCTAssertEqual(copy("unsupported_asset", status: 400), "DyorHQ doesn't support that token on Stellar.")
        XCTAssertEqual(copy("look_alike_symbol", status: 400), "That ticker looks like another token's. Choose another.")
        XCTAssertEqual(copy("muxed_unsupported", status: 400), "Muxed (M…) addresses aren't supported. Use the G… address and the memo you were given.")
        XCTAssertEqual(copy("recipient_missing", ["assetCode": "USDC"]), "This account doesn't exist yet, so it can't receive USDC.")
        XCTAssertEqual(copy("recipient_missing"), "This account doesn't exist yet, so it can't receive this token.", "never a made-up asset")
        for standIn in LiteFormat.standIns {
            XCTAssertEqual(copy("recipient_missing", ["assetCode": standIn]), "This account doesn't exist yet, so it can't receive this token.", "never a stand-in")
        }
        XCTAssertEqual(copy("recipient_no_trust", ["asset": "EURC"]), "This account hasn't enabled EURC, so it can't receive it.", "the id when there's no code")
        XCTAssertEqual(copy("recipient_no_trust"), "This account hasn't enabled this token, so it can't receive it.")
        XCTAssertEqual(copy("recipient_no_trust", ["assetCode": "EURC"]), "This account hasn't enabled EURC, so it can't receive it.")
        XCTAssertEqual(copy("launch.slippage", status: 422), "The price moved past your 1% limit. Nothing was sent. Review again for a new price.")
        XCTAssertEqual(copy("launch.closed", status: 422), "This curve isn't taking trades now.")
        XCTAssertEqual(copy("launch.disabled", status: 422), "New launches are paused.")
        XCTAssertEqual(copy("launch.nothing_to_claim", status: 422), "Nothing to claim yet.")
        XCTAssertEqual(copy("moment.closed", status: 422), "This Moment's collect window has closed.")
        XCTAssertEqual(copy("moment.sold_out", status: 422), "This Moment is sold out.")
        XCTAssertEqual(copy("moment.price_too_low", ["minPrice": "10000000", "quoteCode": "XLM"], status: 422), "The price is below the minimum (1 XLM).")
        XCTAssertEqual(copy("trust.missing", ["assetCode": "USDC"], status: 422), "Enable USDC first.")
        XCTAssertEqual(copy("trust.missing", status: 422), "Enable this token first.", "XLM needs no trustline: never \"Enable XLM first.\"")
        XCTAssertEqual(copy("trust.missing", ["asset": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"], status: 422), "Enable CDLZ…CYSC first.")
        XCTAssertEqual(copy("upload_budget", status: 429), "You've uploaded a lot today. Try again tomorrow.")
        XCTAssertEqual(copy("bridge_relay_limit", status: 429), "You've bridged in many times today. Try again tomorrow.")
        XCTAssertEqual(copy("tx_rejected", ["code": "op_no_destination"], status: 422), "the server's words", "Stellar's other refusals: the server's words")
        XCTAssertEqual(copy("refresh_reused", status: 401), "Sign in on Stellar to continue.")
        XCTAssertEqual(copy("something_new"), "the server's words")

        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.transport("offline")), "No connection. Check your network and try again.")
        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.decoding("the sign-in challenge")), "The sign-in didn't pass this iPhone's checks. Nothing was signed.")
        XCTAssertEqual(LiteErrorText.describe(PlanRunner.Failure.feeAboveConfirmed(step: "Swap")),
                       "Not signed: the network fee for Swap went up since you confirmed. Nothing was sent.")
        XCTAssertEqual(LiteErrorText.describe(PlanRunner.Failure.overLimit(asset: "C")), "Not signed: this would spend more than you confirmed. Nothing was sent.")
        XCTAssertEqual(LiteErrorText.describe(PlanRunner.Failure.refused(step: "Swap", reason: "The memo is not the one you confirmed.")),
                       "Not signed: Swap didn't pass the checks (The memo is not the one you confirmed.). Nothing was sent.")
        // Stellar's result once it applied a step (WP-10's TxStatus.error): an operation's code exists only then.
        func onChain(_ code: String?) -> String { LiteErrorText.describe(PlanRunner.Failure.failedOnChain(step: "Swap", hash: "h", error: code)) }
        XCTAssertEqual(onChain("op_low_reserve"), "Not enough XLM for Stellar's minimum balance.")
        XCTAssertEqual(onChain("CHANGE_TRUST_LOW_RESERVE"), "Not enough XLM for Stellar's minimum balance.")
        XCTAssertEqual(onChain("tx_insufficient_balance"), "Not enough XLM for the network fee.")
        XCTAssertEqual(onChain("tx_insufficient_fee"), "Not enough XLM for the network fee.")
        XCTAssertEqual(onChain("op_underfunded"), "Not enough funds for this.")
        XCTAssertEqual(onChain("op_no_trust"), "Swap failed on the network (op_no_trust).", "a code with no words of its own")
        XCTAssertEqual(onChain(nil), "Swap failed on the network.")
        XCTAssertEqual(LiteErrorText.describe(PlanRunner.Failure.timedOut(step: "Swap", hash: "h")), "Swap was sent; confirmation not seen yet.")
        XCTAssertEqual(LiteErrorText.describe(LiteSession.Failure.cancelled), "Not finished. Try again.")
        XCTAssertEqual(LiteErrorText.describe(CancellationError()), "Not finished. Try again.")
        // Friendbot's one claim (decision 7) and a v1 ticker the server refuses, in the phone's own words.
        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.server(status: 429, code: "faucet_used", message: "You already claimed your test XLM.")),
                       "You already claimed your test XLM.")
        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.server(status: 422, code: "bad_symbol", message: "x")), "Use 2 to 10 letters or digits for the symbol.")
    }

    /// A step that failed on the network for want of funds names what the run spends: XLM's own words (§6.13), another
    /// asset by its code, and neither when the run spends several.
    func testAShortfallOnTheNetworkNamesWhatTheRunSpends() throws {
        let plan = try decode(PlanView.self, FakeLite.plan(id: "p", steps: [("s1", "payment", "Send", 10_000)]))
        let fees = try PlanFees(plan: plan, pinned: .testnet)
        func action(spending codes: [String]) -> PreparedAction {
            PreparedAction(plan: plan, limits: [:], title: "Send", titles: [:], section: .spot, reference: nil, fees: fees,
                           summary: .send(amount: 1, code: "XLM", to: "G"), spends: codes)
        }
        let underfunded = PlanRunner.Failure.failedOnChain(step: "Send", hash: "h", error: "op_underfunded")
        XCTAssertEqual(LiteErrorText.describe(underfunded, for: action(spending: ["XLM"])), "Not enough XLM.")
        XCTAssertEqual(LiteErrorText.describe(underfunded, for: action(spending: ["USDC"])), "Not enough USDC.")
        XCTAssertEqual(LiteErrorText.describe(underfunded, for: action(spending: ["USDC", "XLM"])), "Not enough funds for this.")
        XCTAssertEqual(LiteErrorText.describe(PlanRunner.Failure.failedOnChain(step: "Send", hash: "h", error: "op_low_reserve"), for: action(spending: ["USDC"])),
                       "Not enough XLM for Stellar's minimum balance.", "the reserve is always XLM")
        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.transport("x"), for: action(spending: ["XLM"])), "No connection. Check your network and try again.")
    }

    /// StellarKit refuses a fee above the pinned caps with its own English and no fee; §4.6 words every such refusal as a
    /// fee that is unusually high right now, without the step's server label. Run through StellarKit's own checks (the
    /// shared vectors), so the words matched stay StellarKit's.
    func testAFeeAboveTheCapsIsUnusuallyHigh() throws {
        let unusual = "Not signed: the network fee is unusually high right now. Nothing was sent. Try again in a minute."
        for name in ["soroban fee over the cap", "inclusion over the cap", "soroban inclusion over the cap", "starter step with an inner fee above the cap"] {
            let (step, pinned) = try Self.vector(name)
            XCTAssertThrowsError(try fees([step], pinned: pinned), name) { error in
                XCTAssertEqual(LiteErrorText.describe(error), unusual, "\(name): \(error)")
            }
        }
        // A step not built yet, whose ceiling is above the pinned cap.
        XCTAssertThrowsError(try fees([#"{"id":"u","label":"Swap","status":"pending","stepKind":"swap_soroswap","maxFee":"40000000"}"#], pinned: .testnet)) { error in
            XCTAssertEqual(LiteErrorText.describe(error), unusual)
        }
        // Any other check keeps its own words.
        let (other, otherPinned) = try Self.vector("resource fee above fee")
        XCTAssertThrowsError(try fees([other], pinned: otherPinned)) { error in
            XCTAssertNotEqual(LiteErrorText.describe(error), unusual)
        }
    }

    /// The copy in every language the package ships (the catalog compiled into the bundle by Xcode's build).
    func testErrorCopyIsTranslated() throws {
        guard LiteL10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "fr") != nil else {
            throw XCTSkip("the catalog is compiled into the bundle by Xcode's build (xcodebuild), not by swift build")
        }
        LiteL10n.locale = Locale(identifier: "fr_FR")
        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.server(status: 409, code: "not_enough_xlm_for_fee", message: "x")), "Pas assez de XLM pour les frais de réseau.")
        LiteL10n.locale = Locale(identifier: "es_ES")
        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.server(status: 409, code: "not_enough_xlm", message: "x", detail: ["minBalance": "15000000"])),
                       "No hay suficiente XLM. 1,5 XLM se quedan en tu cuenta.")
        LiteL10n.locale = Locale(identifier: "ko_KR")
        XCTAssertEqual(LiteSession.Failure.cancelled.errorDescription, "완료되지 않았습니다. 다시 시도하십시오.")
        LiteL10n.locale = Locale(identifier: "zh-Hans_CN")
        XCTAssertEqual(LiteErrorText.describe(LiteAPIError.server(status: 422, code: "moment.sold_out", message: "x")), "此 Moment 已售罄。")
    }
}
