@testable import DyorLite
import StellarKit
import XCTest

/// `LaunchV2Store` (docs/DESIGN-stellar-contracts-v2.md §20.2–§21): launchpad v2's reads, the plan of each v2 action with
/// what the user confirms spending, the developer buy's figures on the phone, and the checks made before anything is
/// sent (the ticker, the build's v2 pins, terms that changed). The API is a fake server: `FakeLite` for the session and
/// the account, and v2's routes answered here with the API's shapes (backend _shared/launchpad_v2.ts).
@MainActor
final class LaunchV2StoreTests: XCTestCase {
    private var server: FakeLite!
    private var backend: TestBackend!
    private var vault: MemoryVault!
    private var defaults: UserDefaults!
    private var suite = ""
    private var tally: Tally!
    private var sessions: [LiteSession] = []
    /// v2's answers, by "METHOD /path"; anything else goes to `FakeLite`.
    private var routes: Routes!

    private static let xlm = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
    private static let usdc = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"
    private static let launchpad = "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW"
    private static let token = "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5"
    private static let durations: [String: Int] = [
        "grace": 3600, "fallbackDelay": 3600, "rescueAdmin": 604_800, "rescuePublic": 2_592_000, "lockedFallback": 86400,
        "takeoverDelay": 259_200, "takeoverWindow": 259_200, "timelock": 172_800, "timelockWindow": 604_800, "harvestInterval": 3600,
    ]

    /// testnet's pins with launchpad v2 and its durations, as gen-pinned writes them once the v2 deployment is pinned.
    private static let v2Pins = PinnedContracts(
        network: .testnet, sponsor: PinnedContracts.testnet.sponsor, launchTokenWasmHash: PinnedContracts.testnet.launchTokenWasmHash,
        roles: PinnedContracts.testnet.roles.merging(["launchpadV2": [launchpad]]) { $1 },
        feePolicy: PinnedContracts.testnet.feePolicy, rpcURL: PinnedContracts.testnet.rpcURL,
        durations: PinnedDurations(
            launch: .init(grace: 3600, fallbackDelay: 3600, rescueAdmin: 604_800, rescuePublic: 2_592_000, lockedFallback: 86400,
                          takeoverDelay: 259_200, takeoverWindow: 259_200, timelock: 172_800, timelockWindow: 604_800, harvestInterval: 3600),
            moments: .init(vestPeriod: 2_592_000, stuckExpiry: 604_800, pendingBackstop: 2_592_000, timelock: 172_800, timelockWindow: 604_800,
                           minWindow: 3600, maxWindow: 2_592_000, harvestInterval: 3600)))

    override func setUp() async throws {
        server = FakeLite()
        routes = Routes()
        StubServer.handle(host: server.host) { [server, routes] request in
            guard let mine = routes!["\(request.method) \(request.path)"] else { return server!.answer(request) }
            // v2's session routes, as the API guards them.
            if request.method == "POST", request.token == nil { return (401, FakeLite.error("unauthorized", "Sign in.")) }
            return mine
        }
        backend = TestBackend(api: server.api())
        vault = MemoryVault()
        suite = "lite.launchv2.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        tally = Tally()
    }

    override func tearDown() async throws {
        server.stop()
        defaults.removePersistentDomain(forName: suite)
        sessions = []
    }

    /// A ready seed account, with a live session saved, on `pinned`.
    private func ready(pinned: PinnedContracts = v2Pins) async throws -> (LiteSession, LaunchV2Store) {
        let keys = TestAccount.seedKeys(appLock: false, tally: tally)
        defaults.set(true, forKey: LiteSession.activatedKey(keys.address))
        vault.save(server.issueSession(), account: keys.address, network: "testnet")
        let env = LiteEnvironment(apiURL: server.base, pinned: pinned, buildNumber: 23)
        let session = LiteSession(env: env, stellarAddress: keys.address, monad: nil, keys: keys, setupKey: nil, backend: backend, vault: vault,
                                  defaults: defaults)
        sessions.append(session)
        await session.resumeAtLaunch()
        return (session, LaunchV2Store(store: try XCTUnwrap(session.store)))
    }

    private func serve(_ route: String, _ object: Any, status: Int = 200) throws {
        routes[route] = (status, try JSONSerialization.data(withJSONObject: object))
    }

    /// The last body `route` received.
    private func body(_ route: String) throws -> [String: Any] {
        let request = try XCTUnwrap(server.seen.last { "\($0.method) \($0.path)" == route }, route)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    // MARK: - The API's shapes

    private static func venue(_ id: Int = 0, kind: String = "Soroswap", name: String = "Soroswap") -> [String: Any] {
        ["id": id, "kind": kind, "name": name, "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526", "enabled": true, "feeFraction": 0]
    }

    private static func terms(quote: String = xlm, threshold: String = "43245553200", phantom: String = "20000000000") -> [String: Any] {
        ["supply": "10000000000000000", "feeBps": 100, "protocolShareBps": 5000, "maxCreatorFeeBps": 1000, "snipeSchedule": [9800, 2500, 300, 30],
         "snipeStepSecs": 5, "launchFee": "100000000", "feeAsset": xlm, "quote": quote, "phantom": phantom, "threshold": threshold,
         "venue": venue(), "fallback": venue(), "venueLocked": false, "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
         "tokenWasmHash": String(repeating: "02", count: 32), "durations": durations]
    }

    /// A launch's quote, as its state names it.
    private static func xlmQuote() throws -> StellarLaunchStateV2.Quote {
        try JSONDecoder().decode(StellarLaunchStateV2.Quote.self, from: Data(#"{"id": "XLM", "code": "XLM", "contract": "\#(xlm)"}"#.utf8))
    }

    private static func decodedTerms(quote: String = xlm) throws -> StellarLaunchTermsV2 {
        try JSONDecoder().decode(StellarLaunchTermsV2.self, from: JSONSerialization.data(withJSONObject: terms(quote: quote)))
    }

    private static var economics: [String: Any] {
        ["launchpad": [
            "contract": launchpad, "generation": 2, "launchesEnabled": true, "whitelistEnabled": false, "supply": "10000000000000000",
            "feeBps": 100, "protocolShareBps": 5000, "maxCreatorFeeBps": 1000, "snipeSchedule": [9800, 2500, 300, 30], "snipeStepSecs": 5,
            "launchFee": ["asset": "XLM", "contract": xlm, "amount": "100000000", "booked": true],
            "treasury": "GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
            "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ", "venues": [venue()],
            "quotes": [["asset": "XLM", "code": "XLM", "contract": xlm, "phantom": "20000000000", "threshold": "43245553200", "enabled": true,
                        "venuesAllowed": [Int](), "fallbackVenue": 0, "venueLocked": false, "defaultVenue": 0, "terms": terms()]],
            "durations": durations,
            "harvest": ["intervalSecs": 3600, "roundCapBps": 50, "harvestBps": 10000, "split": ["protocolBps": 5000, "creatorOrHoldersBps": 5000],
                        "splitPinnedPerLaunch": true, "sides": ["quote", "token"], "holdersPaidIn": ["quote", "token"], "treasuryLaunchTokens": "held"],
            "exclusionFloor": ["minPoolTokens": "10000000000", "minPendingQuote": "1000000", "minPendingTokens": "10000000000"],
            "aquariusFloat": NSNull(),
        ] as [String: Any], "moments": NSNull()]
    }

    /// A built step: its intent (with terms for a create), no transaction yet (priced from its ceiling).
    private static func plan(kind: String, display: [String: Any] = [:], terms: [String: Any]? = nil, spend: [String: String] = [:],
                             before: [[String: Any]] = [], backlog: [String: Any]? = nil) -> [String: Any] {
        var intent: [String: Any] = ["kind": kind, "summary": "The server's English", "spend": spend, "display": display]
        if let terms { intent["terms"] = terms }
        let main: [String: Any] = ["id": "s\(before.count + 1)", "label": "The server's label", "status": "built", "intent": intent,
                                   "maxFee": "4650100", "feePayer": "user", "reserveDelta": 0]
        var plan: [String: Any] = ["planId": "p-\(kind)", "kind": kind, "expiresAt": "2026-10-15T14:47:36.511Z", "steps": before + [main]]
        if let backlog { plan["harvestBacklog"] = backlog }
        return plan
    }

    // MARK: - The developer buy, on the phone

    func testTheFirstBuyFollowsTheContractsCurve() throws {
        let terms = try Self.decodedTerms()
        // 50 XLM with a 1% creator fee: 2% of fees, the rest at the curve's opening reserves (2,000 XLM phantom, 1B coins).
        XCTAssertEqual(LaunchV2Store.firstBuy(500_000_000, terms: terms, creatorFeeBps: 100),
                       LaunchV2FirstBuy(used: 500_000_000, fees: 10_000_000, tokensOut: 239_141_044_411_908, minOut: 236_749_633_967_788))
        XCTAssertEqual(LaunchV2Store.firstBuy(500_000_000, terms: terms, creatorFeeBps: 0)?.tokensOut, 241_522_322_517_687,
                       "the creator pays no early-buy tax")
        // A buy past the threshold takes only what fills the curve.
        XCTAssertEqual(LaunchV2Store.firstBuy(10_000_000_000_000, terms: terms, creatorFeeBps: 100),
                       LaunchV2FirstBuy(used: 44_128_115_511, fees: 882_562_311, tokensOut: 6_837_722_339_663_241, minOut: 6_769_345_116_266_608))
        XCTAssertNil(LaunchV2Store.firstBuy(0, terms: terms, creatorFeeBps: 100))
    }

    // MARK: - Reads

    func testEconomicsReadTheV2BlockOnly() async throws {
        let (_, launches) = try await ready()
        XCTAssertEqual(launches.economicsStatus, .unread)
        try serve("GET /v1/economics", Self.economics)
        await launches.refreshEconomics()
        XCTAssertEqual(launches.economicsStatus, .read)
        XCTAssertEqual(launches.economics?.launchFee.amount, "100000000")
        XCTAssertEqual(launches.economics?.venues.map(\.name), ["Soroswap"])
        // A server whose launchpad is still v1's: no v2 launchpad here, read.
        try serve("GET /v1/economics", ["launchpad": ["contract": Self.launchpad, "launchesEnabled": true], "moments": NSNull()])
        await launches.refreshEconomics()
        XCTAssertNil(launches.economics)
        XCTAssertEqual(launches.economicsStatus, .read)
        routes["GET /v1/economics"] = (500, FakeLite.error("internal", "Down."))
        await launches.refreshEconomics()
        XCTAssertEqual(launches.economicsStatus, .failed)
        XCTAssertNotNil(launches.economicsError)
    }

    func testARetiredLaunchHasNoV2State() async throws {
        let (_, launches) = try await ready()
        routes["GET /v1/launches/\(Self.token)/state"] = (404, FakeLite.error("not_found", "Launch not found."))
        let retired = try await launches.state(Self.token)
        XCTAssertNil(retired, "launchpad v2 doesn't know it: a v1 launch")
        routes["GET /v1/launches/\(Self.token)/state"] = (503, FakeLite.error("not_deployed", "Launchpad v2 isn't deployed on this network yet."))
        let undeployed = try await launches.state(Self.token)
        XCTAssertNil(undeployed)
        routes["GET /v1/launches/\(Self.token)/state"] = (500, FakeLite.error("internal", "Down."))
        do {
            _ = try await launches.state(Self.token)
            XCTFail("a failed read isn't a retired launch")
        } catch {}
    }

    func testQuotesKeepOnePercentAndARefundItsFixedFigure() async throws {
        let (_, launches) = try await ready()
        try serve("POST /v1/launches/\(Self.token)/quote", ["side": "buy", "used": "500000000", "tokensOut": "11952000000000", "fees": "2000000",
                                                             "baseFee": "1000000", "creatorFee": "1000000", "snipeFee": "0", "refund": "0"])
        let buy = try await launches.quote(token: Self.token, side: .buy, amount: 500_000_000)
        XCTAssertEqual(buy.out, 11_952_000_000_000)
        XCTAssertEqual(buy.minOut, 11_832_480_000_000)
        XCTAssertEqual(try body("POST /v1/launches/\(Self.token)/quote") as? [String: String], ["side": "buy", "amount": "500000000"])
        try serve("POST /v1/launches/\(Self.token)/quote", ["side": "refund", "quoteOut": "48050", "fees": "0", "rate": "0.000000048050614666"])
        let refund = try await launches.quote(token: Self.token, side: .refund, amount: 1_000_000_000_000)
        XCTAssertEqual(refund.out, 48050)
        XCTAssertEqual(refund.minOut, 48050, "a refund's rate is fixed")
    }

    // MARK: - Create

    func testATickerTheContractsRefuseIsRefusedBeforeAnythingIsSent() async throws {
        let (_, launches) = try await ready()
        server.forget()
        for symbol in ["A", "ÉCAT", "EC-AT", "TOOLONGTICKER"] {
            do {
                _ = try await launches.createPlan(LaunchV2Form(name: "E2E Cat", symbol: symbol, quote: "XLM", creatorFeeBps: 0),
                                                  terms: try Self.decodedTerms(), image: nil)
                XCTFail(symbol)
            } catch let LiteAPIError.server(_, code, _, _) {
                XCTAssertEqual(code, "bad_symbol", symbol)
            }
        }
        XCTAssertEqual(server.paths.filter { $0.hasPrefix("POST") }, [], "nothing was sent")
    }

    func testNothingIsBuiltWithoutTheV2Pins() async throws {
        let (_, launches) = try await ready(pinned: .testnet)
        XCTAssertFalse(launches.isPinned)
        server.forget()
        do {
            _ = try await launches.createPlan(LaunchV2Form(name: "E2E Cat", symbol: "ECAT", quote: "XLM", creatorFeeBps: 0),
                                              terms: try Self.decodedTerms(), image: nil)
            XCTFail("no v2 pins")
        } catch let LiteAPIError.server(_, code, _, _) {
            XCTAssertEqual(code, "launchpad_v2_unpinned")
        }
        do {
            _ = try await launches.claimPlan(token: Self.token, symbol: "ECAT")
            XCTFail("no v2 pins")
        } catch let LiteAPIError.server(_, code, _, _) {
            XCTAssertEqual(code, "launchpad_v2_unpinned")
        }
        XCTAssertFalse(server.paths.contains("POST /v1/launches/build"))
    }

    func testACreateWritesItsMetadataAndConfirmsTheFeeAndTheBuy() async throws {
        let (_, launches) = try await ready()
        try serve("POST /v1/launches/metadata", ["uri": "https://media.test/meta/ecat.json"])
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_create", display: ["symbol": "ECAT", "quote": "XLM", "initialBuy": "500000000"],
                                                       terms: Self.terms(), spend: [Self.xlm: "600000000"]))
        let terms = try Self.decodedTerms()
        let buy = try XCTUnwrap(LaunchV2Store.firstBuy(500_000_000, terms: terms, creatorFeeBps: 100))
        var form = LaunchV2Form(name: "E2E Cat", symbol: "ecat", website: "https://e2e.cat", quote: "XLM", creatorFeeBps: 100,
                                recipient: "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR", developerBuy: 500_000_000, minOut: buy.minOut)
        let action = try await launches.createPlan(form, terms: terms, image: nil)
        XCTAssertEqual(action.limits, [Self.xlm: 600_000_000], "the 10 XLM fee and the 50 XLM buy, both in XLM")
        XCTAssertEqual(action.section, .launch)
        XCTAssertNil(action.reference, "the new coin's page comes from what the launch returns")
        XCTAssertEqual(action.title(of: action.plan.steps[0]), "Launch ECAT and buy with 50 XLM")
        let metadata = try body("POST /v1/launches/metadata")
        XCTAssertEqual(metadata["symbol"] as? String, "ECAT")
        XCTAssertEqual(metadata["website"] as? String, "https://e2e.cat")
        let sent = try body("POST /v1/launches/build")
        XCTAssertEqual(sent["action"] as? String, "create")
        XCTAssertEqual(sent["symbol"] as? String, "ECAT")
        XCTAssertEqual(sent["uri"] as? String, "https://media.test/meta/ecat.json")
        XCTAssertEqual(sent["amount"] as? String, "500000000")
        XCTAssertEqual(sent["minOut"] as? String, String(buy.minOut))
        XCTAssertEqual(sent["holderSharing"] as? Bool, true, "sharing is on unless turned off")
        XCTAssertEqual(sent["creatorFeeBps"] as? Int, 100)
        XCTAssertEqual(sent["recipient"] as? String, "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR")

        // A USDC launch: the fee in XLM, the buy in USDC.
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_create", display: ["symbol": "ECAT"], terms: Self.terms(quote: Self.usdc)))
        form.quote = "USDC"
        form.developerBuy = 20_000_000
        let usdc = try await launches.createPlan(form, terms: try Self.decodedTerms(quote: Self.usdc), image: nil)
        XCTAssertEqual(usdc.limits, [Self.xlm: 100_000_000, Self.usdc: 20_000_000])
    }

    func testTermsThatChangedSinceTheyWereShownAreRefused() async throws {
        let (_, launches) = try await ready()
        try serve("POST /v1/launches/metadata", ["uri": "https://media.test/meta/ecat.json"])
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_create", display: ["symbol": "ECAT"], terms: Self.terms(threshold: "50000000000")))
        do {
            _ = try await launches.createPlan(LaunchV2Form(name: "E2E Cat", symbol: "ECAT", quote: "XLM", creatorFeeBps: 0),
                                              terms: try Self.decodedTerms(), image: nil)
            XCTFail("the threshold changed")
        } catch let LiteAPIError.server(_, code, _, _) {
            XCTAssertEqual(code, "launch_terms_changed")
        }
    }

    func testTermsThisBuildDoesntPinAreRefusedBeforeTheBuild() async throws {
        let (_, launches) = try await ready()
        var shorter = Self.terms()
        shorter["durations"] = Self.durations.merging(["rescuePublic": 600]) { $1 }
        let terms = try JSONDecoder().decode(StellarLaunchTermsV2.self, from: JSONSerialization.data(withJSONObject: shorter))
        server.forget()
        do {
            _ = try await launches.createPlan(LaunchV2Form(name: "E2E Cat", symbol: "ECAT", quote: "XLM", creatorFeeBps: 0), terms: terms, image: nil)
            XCTFail("other durations")
        } catch let LiteAPIError.server(_, code, _, _) {
            XCTAssertEqual(code, "launch_terms_unpinned")
        }
        XCTAssertFalse(server.paths.contains("POST /v1/launches/build"))
    }

    // MARK: - Trades and the other actions

    func testTradesConfirmWhatTheySpend() async throws {
        let (_, launches) = try await ready()
        let asset = try Self.xlmQuote()
        try serve("POST /v1/launches/\(Self.token)/quote", ["side": "buy", "used": "500000000", "tokensOut": "11952000000000", "fees": "2000000"])
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_buy", display: ["symbol": "ECAT", "amount": "500000000", "quote": "XLM"]))
        let buy = try await launches.tradePlan(try await launches.quote(token: Self.token, side: .buy, amount: 500_000_000), token: Self.token,
                                               symbol: "ECAT", asset: asset)
        XCTAssertEqual(buy.limits, [Self.xlm: 500_000_000])
        XCTAssertEqual(buy.reference, "stellar:launch/\(Self.token)")
        XCTAssertEqual(try body("POST /v1/launches/build") as? [String: String],
                       ["action": "buy", "token": Self.token, "amount": "500000000", "minOut": "11832480000000"])

        try serve("POST /v1/launches/\(Self.token)/quote", ["side": "sell", "quoteOut": "100000000", "fees": "2000000"])
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_sell", display: ["symbol": "ECAT", "amount": "11952000000000"]))
        let sell = try await launches.tradePlan(try await launches.quote(token: Self.token, side: .sell, amount: 11_952_000_000_000), token: Self.token,
                                                symbol: "ECAT", asset: asset)
        XCTAssertEqual(sell.limits, [Self.token: 11_952_000_000_000])

        try serve("POST /v1/launches/\(Self.token)/quote", ["side": "refund", "quoteOut": "48050", "fees": "0", "rate": "0.000000048050614666"])
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_refund", display: ["symbol": "ECAT", "amount": "1000000000000"]))
        let refund = try await launches.tradePlan(try await launches.quote(token: Self.token, side: .refund, amount: 1_000_000_000_000), token: Self.token,
                                                  symbol: "ECAT", asset: asset)
        XCTAssertEqual(refund.limits, [Self.token: 1_000_000_000_000], "the coins it burns")
        XCTAssertEqual(try body("POST /v1/launches/build") as? [String: String], ["action": "refund", "token": Self.token, "amount": "1000000000000"])
        XCTAssertEqual(refund.title(of: refund.plan.steps[0]), "Refund \(StellarAmount.format(1_000_000_000_000, maxFraction: 4)) ECAT",
                       "a kind the package's titles don't know reads the phone's words, never the server's")
    }

    func testARefundSettlesWithItsOwnWords() async throws {
        let (session, launches) = try await ready()
        var settled: [LiteSettledAction] = []
        session.onSettled = { settled.append($0) }
        try serve("POST /v1/launches/\(Self.token)/quote", ["side": "refund", "quoteOut": "48050", "fees": "0", "rate": "0.000000048050614666"])
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_refund"))
        let refund = try await launches.tradePlan(try await launches.quote(token: Self.token, side: .refund, amount: 1_000_000_000_000), token: Self.token,
                                                  symbol: "ECAT", asset: try Self.xlmQuote())
        _ = try await launches.store.run(refund, reason: "Confirm Refund")
        XCTAssertEqual(settled.map(\.kind), ["launch_refund"])
        XCTAssertEqual(settled.first?.title, "Refunded ECAT")
        XCTAssertEqual(settled.first?.reference, "stellar:launch/\(Self.token)")
    }

    func testEveryOtherActionAsksTheRightPlan() async throws {
        let (_, launches) = try await ready()
        let cases: [(String, () async throws -> PreparedAction)] = [
            ("graduate", { try await launches.graduatePlan(token: Self.token, symbol: "ECAT") }),
            ("graduate_fallback", { try await launches.graduatePlan(token: Self.token, symbol: "ECAT", fallback: true) }),
            ("mark_stuck", { try await launches.markStuckPlan(token: Self.token, symbol: "ECAT") }),
            ("rescue", { try await launches.rescuePlan(token: Self.token, symbol: "ECAT") }),
            ("claim", { try await launches.claimPlan(token: Self.token, symbol: "ECAT") }),
            ("claim_rewards", { try await launches.claimRewardsPlan(token: Self.token, symbol: "ECAT") }),
        ]
        for (action, build) in cases {
            try serve("POST /v1/launches/build", Self.plan(kind: "launch_\(action)"))
            let prepared = try await build()
            XCTAssertEqual(prepared.limits, [:], action)
            XCTAssertEqual(try body("POST /v1/launches/build") as? [String: String], ["action": action, "token": Self.token], action)
            XCTAssertNotEqual(prepared.title(of: prepared.plan.steps[0]), "The server's label", action)
        }
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_claim_owed"))
        let owed = try await launches.claimOwedPlan(asset: try Self.xlmQuote(), amount: 1_200_000)
        XCTAssertEqual(try body("POST /v1/launches/build") as? [String: String], ["action": "claim_owed", "asset": Self.xlm])
        XCTAssertNil(owed.reference)
    }

    func testARecipientChangeCarriesItsBacklog() async throws {
        let (_, launches) = try await ready()
        let harvest: [String: Any] = ["id": "s1", "label": "Collect ECAT's pool fees first", "status": "built",
                                      "intent": ["kind": "launch_harvest", "summary": "Collect", "spend": [String: String]()],
                                      "maxFee": "4650100", "feePayer": "user", "reserveDelta": 0]
        try serve("POST /v1/launches/build", Self.plan(kind: "launch_recipient_transfer", before: [harvest], backlog: [
            "residualQuote": "22251", "residualToken": "89005", "growthQuote": "44502", "growthToken": "178010", "roundsToDrain": 10,
            "nextHarvestAt": "2026-10-15T15:32:36.000Z", "drainedBy": "2026-10-16T00:32:36.000Z",
        ]))
        let to = "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG"
        let change = try await launches.recipientPlan(token: Self.token, symbol: "ECAT", change: .transfer(to: to))
        XCTAssertEqual(change.backlog?.roundsToDrain, 10)
        XCTAssertEqual(change.action.limits, [:])
        XCTAssertEqual(change.action.plan.steps.map { change.action.title(of: $0) }, ["Collect ECAT's pool fees first", "Change ECAT's fee recipient"])
        XCTAssertEqual(try body("POST /v1/launches/build") as? [String: String], ["action": "recipient_transfer", "token": Self.token, "to": to])

        try serve("POST /v1/launches/build", Self.plan(kind: "launch_recipient_cancel"))
        let veto = try await launches.recipientPlan(token: Self.token, symbol: "ECAT", change: .cancel)
        XCTAssertNil(veto.backlog)
        XCTAssertEqual(try body("POST /v1/launches/build") as? [String: String], ["action": "recipient_cancel", "token": Self.token])
    }

    // MARK: - The package's words

    /// Resources/LaunchV2.xcstrings: every entry with a note and the four languages, with its key's values.
    func testTheLaunchV2TableHasEveryLanguage() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("Sources/DyorLite/Resources/LaunchV2.xcstrings")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThanOrEqual(strings.count, 20)
        let specifier = try NSRegularExpression(pattern: #"%(?:\d+\$)?(@|lld)"#)
        func values(_ text: String) -> [String] {
            specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) }
        }
        for (key, entry) in strings {
            XCTAssertFalse((entry["comment"] as? String ?? "").isEmpty, key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
            for language in ["es", "fr", "ko", "zh-Hans"] {
                let unit = try XCTUnwrap(localizations[language]?["stringUnit"] as? [String: Any], "\(language): \(key)")
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertEqual(values(value), values(key), "\(language): \(key)")
                for name in ["DyorHQ", "Stellar"] where key.contains(name) { XCTAssertTrue(value.contains(name), "\(language): \(key)") }
            }
        }
    }
}

/// Answers by route, read from the fake server's thread and written by the test.
private final class Routes: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (status: Int, body: Data)] = [:]

    subscript(route: String) -> (status: Int, body: Data)? {
        get { lock.withLock { answers[route] } }
        set { lock.withLock { answers[route] = newValue } }
    }
}
