import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LiteClient
import StellarCore
import XCTest

/// The API fixtures: backend/tests/fixtures/api, one per response (today's payloads as `<name>.legacy.json`), copied
/// to Fixtures/ by backend/tests/fixtures/sync.sh. They are read from the source tree, so the target declares no
/// resources.
enum ApiFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name + ".json")) }

    static func decode<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    static var names: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
}

final class ApiFixtureTests: XCTestCase {
    /// How a fixture is read: decoded as the client decodes it, then encoded back.
    private typealias RoundTrip = (Data) throws -> Data

    private static func roundTrip<T: Codable>(_ type: T.Type) -> RoundTrip {
        { data in try JSONEncoder().encode(JSONDecoder().decode(T.self, from: data)) }
    }

    // The bodies LiteAPI unwraps (its own wrappers are private). A list comes under one of these keys.
    private struct Listed<T: Codable>: Codable { let moments: [T]?; let editions: [T]?; let items: [T]?; let positions: [T]?; let anchors: [T]?; let results: [T]?; let view: String? }
    private struct EarnMarkets: Codable { let markets: [EarnMarket]; let note: String? }
    private struct Metadata: Codable { let uri: String; let posterUrl: String? }
    private struct Active: Codable { let status: String; let account: AccountView }
    private struct ErrorEnvelope: Codable {
        struct Inner: Codable { let code: String; let message: String; let detail: AnyJSON? }
        let error: Inner
    }

    /// Every fixture, the type it is read as, and the fields the phone deliberately doesn't keep (key paths, `[]` for
    /// an array's elements).
    private static let fixtures: [String: (RoundTrip, unmodelled: [String])] = [
        "auth-challenge": (roundTrip(AuthChallenge.self), []),
        "auth-verify": (roundTrip(AuthResult.self), []),
        "auth-verify.legacy": (roundTrip(AuthResult.self), []),
        "auth-refresh": (roundTrip(AuthResult.self), []),
        "config": (roundTrip(LiteConfig.self), ["contracts.soroswapFactory", "contracts.aquariusRouter", "contracts.cctp"]),
        "config.legacy": (roundTrip(LiteConfig.self), ["contracts.soroswapFactory", "contracts.aquariusRouter", "contracts.cctp"]),
        "fees": (roundTrip(StellarFees.self), []),
        "account": (roundTrip(AccountView.self), []),
        "account.legacy": (roundTrip(AccountView.self), []),
        "account.missing": (roundTrip(AccountView.self), []),
        "account.public": (roundTrip(AccountView.self), []),
        "account-activate": ({ data in
            let result = try JSONDecoder().decode(ActivationResult.self, from: data)
            XCTAssertNil(result.plan)
            XCTAssertNotNil(result.account)
            return try JSONEncoder().encode(JSONDecoder().decode(Active.self, from: data))
        }, []),
        "account-faucet": (roundTrip(AnyJSON.self), []),
        "recipient": (roundTrip(StellarRecipient.self), []),
        "plan": (roundTrip(PlanView.self), ["steps[].builtAt"]),
        "plan.legacy": (roundTrip(PlanView.self), ["steps[].builtAt"]),
        "plan-send": (roundTrip(PlanView.self), ["steps[].builtAt"]),
        "tx-submit": (roundTrip(TxStatus.self), []),
        "tx-status": (roundTrip(TxStatus.self), []),
        "tx-status.legacy": (roundTrip(TxStatus.self), []),
        "swap-quote": (roundTrip(SwapQuote.self), []),
        "swap-quote.legacy": (roundTrip(SwapQuote.self), []),
        "markets": (roundTrip(StellarMarkets.self), []),
        "market": (roundTrip(StellarMarketDetail.self), []),
        "market-history": (roundTrip(StellarPriceHistory.self), []),
        "assets": (roundTrip(Listed<StellarAssetResult>.self), []),
        "prices": (roundTrip(StellarPrices.self), []),
        "holdings": (roundTrip(StellarHoldings.self), []),
        "holdings.partial": (roundTrip(StellarHoldings.self), []),
        // StellarHoldings (Models+Portfolio.swift) doesn't keep the public view's `view` yet.
        "holdings.public": (roundTrip(StellarHoldings.self), ["view"]),
        "portfolio": (roundTrip(StellarPortfolio.self), []),
        "launches": (roundTrip(StellarLaunchBoard.self), []),
        "launches.legacy": (roundTrip(StellarLaunchBoard.self), []),
        "launch": (roundTrip(StellarLaunchDetail.self), []),
        "launch.legacy": (roundTrip(StellarLaunchDetail.self), []),
        "launch.public": (roundTrip(StellarLaunchDetail.self), []),
        "launch-quote": (roundTrip(TradeQuote.self), []),
        "launch-quote.legacy": (roundTrip(TradeQuote.self), []),
        "launch-quote-sell.legacy": (roundTrip(TradeQuote.self), []),
        "launch-metadata": (roundTrip(Metadata.self), []),
        "economics": (roundTrip(StellarEconomics.self), []),
        "launchpad-me": (roundTrip(StellarMyLaunchpad.self), []),
        "moments": (roundTrip(Listed<StellarMoment>.self), []),
        "moments.legacy": (roundTrip(Listed<StellarMoment>.self), []),
        "moment": (roundTrip(StellarMomentDetail.self), []),
        "moment.legacy": (roundTrip(StellarMomentDetail.self), []),
        "moment.public": (roundTrip(StellarMomentDetail.self), []),
        "moments-owned": (roundTrip(Listed<StellarEdition>.self), []),
        "moments-owned.legacy": (roundTrip(Listed<StellarEdition>.self), []),
        "moments-owned.public": (roundTrip(Listed<StellarEdition>.self), []),
        "moments-mine": (roundTrip(StellarMomentsMine.self), []),
        "moment-metadata": (roundTrip(Metadata.self), []),
        "moment-metadata.legacy": (roundTrip(Metadata.self), []),
        "media-upload-url": (roundTrip(UploadTicket.self), []),
        "earn-markets": (roundTrip(EarnMarkets.self), []),
        "earn-markets.legacy": (roundTrip(EarnMarkets.self), []),
        "earn-positions": (roundTrip(Listed<EarnPosition>.self), []),
        "earn-positions.legacy": (roundTrip(Listed<EarnPosition>.self), []),
        "earn-positions.public": (roundTrip(Listed<EarnPosition>.self), []),
        "earn-history": (roundTrip(StellarEarnHistory.self), []),
        "activity": (roundTrip(Listed<StellarActivityItem>.self), []),
        "activity.legacy": (roundTrip(Listed<StellarActivityItem>.self), []),
        "bridge-quote": (roundTrip(StellarBridgeQuote.self), []),
        "bridge-quote.legacy": (roundTrip(StellarBridgeQuote.self), []),
        "bridge-start-in": (roundTrip(BridgeStart.self), []),
        "bridge-start-out": (roundTrip(BridgeStart.self), ["plan.steps[].builtAt"]),
        "bridge-status": (roundTrip(BridgeStatus.self), ["route"]),
        "bridge-source": (roundTrip(AnyJSON.self), []),
        "bridge-claimed": (roundTrip(AnyJSON.self), []),
        "cash-anchors": (roundTrip(Listed<AnchorInfo>.self), []),
        "cash-track": (roundTrip(AnyJSON.self), []),
        "error": (roundTrip(ErrorEnvelope.self), []),
        "error.legacy": (roundTrip(ErrorEnvelope.self), []),
        "error-contract": (roundTrip(ErrorEnvelope.self), []),
        "error-refresh-reused": (roundTrip(ErrorEnvelope.self), []),
        "error-address-required": (roundTrip(ErrorEnvelope.self), []),
    ]

    /// Every fixture decodes, today's payloads included, and keeps every field it carries: an optional whose name is
    /// misspelt would decode as nil without a word, so each model is encoded back and its fields compared.
    func testDecodesApiFixtures() throws {
        let names = ApiFixtures.names
        XCTAssertGreaterThanOrEqual(names.count, 60, "run backend/tests/fixtures/sync.sh")
        XCTAssertEqual(Set(names), Set(Self.fixtures.keys), "every fixture has a decoder here, and every decoder a fixture")
        for name in names {
            guard let fixture = Self.fixtures[name] else { continue }
            let data = try ApiFixtures.data(name)
            let encoded: Data
            do {
                encoded = try fixture.0(data)
            } catch {
                XCTFail("\(name).json doesn't decode: \(error)")
                continue
            }
            let missing = try Self.paths(JSONSerialization.jsonObject(with: data)).subtracting(Self.paths(JSONSerialization.jsonObject(with: encoded)))
                .filter { path in !fixture.unmodelled.contains { path == $0 || path.hasPrefix($0 + ".") || path.hasPrefix($0 + "[]") } }
            XCTAssertEqual(missing.sorted(), [], "\(name).json: fields the model drops")
        }
    }

    /// The fields added for the parity API read as their values; today's payloads leave them nil.
    func testNewFieldsDecodeAndOldPayloadsLeaveThemNil() throws {
        let config = try ApiFixtures.decode("config", as: LiteConfig.self)
        XCTAssertEqual(config.inviteRequired, false)
        XCTAssertEqual(config.fees?.maxFee, "30000000")
        XCTAssertEqual(config.limits?.momentWindowSecs, [3600, 2592000])
        XCTAssertEqual(config.pricing?.source, "Kraken")
        XCTAssertEqual(config.faucet?.amount, "10000")
        XCTAssertEqual(config.asset("BUSDC")?.listed, false)
        XCTAssertEqual(config.asset("BUSDC")?.priceRef, "USDC")
        let oldConfig = try ApiFixtures.decode("config.legacy", as: LiteConfig.self)
        XCTAssertNil(oldConfig.inviteRequired)
        XCTAssertNil(oldConfig.fees)
        XCTAssertNil(oldConfig.deployment)
        XCTAssertNil(oldConfig.asset("XLM")?.priceRef)

        let account = try ApiFixtures.decode("account", as: AccountView.self)
        XCTAssertEqual(account.view, "owner")
        XCTAssertEqual(account.firstFunding?.starterSwap, "unavailable")
        XCTAssertEqual(account.xlm?.spendable, "99985000000")
        XCTAssertEqual(account.xlm?.reserves.subentries, 1)
        XCTAssertEqual(account.firstFunding?.faucet?.usedToday, false)
        XCTAssertEqual(account.balances.last?.kind, "launch")
        XCTAssertNil(try ApiFixtures.decode("account.legacy", as: AccountView.self).xlm)
        XCTAssertNil(try ApiFixtures.decode("account.legacy", as: AccountView.self).view)
        let missing = try ApiFixtures.decode("account.missing", as: AccountView.self)
        XCTAssertFalse(missing.exists)
        XCTAssertNil(missing.xlm)
        XCTAssertEqual(missing.firstFunding?.needsXlm, true)

        let send = try ApiFixtures.decode("plan-send", as: PlanView.self)
        XCTAssertEqual(send.steps[0].intent?.to, send.steps[0].intent?.display?["to"]?.text)
        XCTAssertEqual(send.steps[0].intent?.memo, Intent.Memo(type: "text", value: "invoice 42"))
        let plan = try ApiFixtures.decode("plan", as: PlanView.self)
        XCTAssertEqual(plan.fees?.newReserves, 1)
        XCTAssertEqual(plan.steps.map(\.stepKind), ["trust", "swap_soroswap"])
        XCTAssertEqual(plan.steps.map(\.reserveDelta), [1, 0])
        let oldPlan = try ApiFixtures.decode("plan.legacy", as: PlanView.self)
        XCTAssertNil(oldPlan.fees)
        XCTAssertNil(oldPlan.steps[0].maxFee)
        XCTAssertNil(oldPlan.steps[0].intent?.to)

        XCTAssertEqual(try ApiFixtures.decode("tx-status", as: TxStatus.self).result?.amountOut, "18938032")
        XCTAssertNil(try ApiFixtures.decode("tx-status.legacy", as: TxStatus.self).feeCharged)

        let quote = try ApiFixtures.decode("swap-quote", as: SwapQuote.self)
        XCTAssertEqual(quote.routes?.filter(\.best).map(\.venue), ["soroswap"])
        XCTAssertEqual(quote.starterSwap?.eligible, false)
        XCTAssertNil(try ApiFixtures.decode("swap-quote.legacy", as: SwapQuote.self).routes)

        let board = try ApiFixtures.decode("launches", as: StellarLaunchBoard.self)
        XCTAssertEqual(board.counts?.explore, 12)
        XCTAssertEqual(board.launches.map(\.phase), ["completed", "curve"])
        let oldBoard = try ApiFixtures.decode("launches.legacy", as: StellarLaunchBoard.self)
        XCTAssertNil(oldBoard.counts)
        XCTAssertNil(oldBoard.launches[0].marketCapQuote)

        let launch = try ApiFixtures.decode("launch", as: StellarLaunchDetail.self)
        XCTAssertEqual(launch.stats?.holders, 5)
        XCTAssertEqual(launch.creatorFees?.unclaimed, "3900000")
        XCTAssertEqual(launch.trades.compactMap(\.venue), ["curve", "curve"])
        XCTAssertEqual(launch.launch.links?.website, "https://ecat.dyorhq.fun")
        XCTAssertNil(try ApiFixtures.decode("launch.legacy", as: StellarLaunchDetail.self).pricePoints)
        XCTAssertEqual(try ApiFixtures.decode("launch-quote", as: TradeQuote.self).refund, "0")

        let economics = try ApiFixtures.decode("economics", as: StellarEconomics.self)
        XCTAssertEqual(economics.launchpad?.snipeSchedule, [9800, 2500, 300, 30])
        XCTAssertEqual(economics.moments?.quotes.map(\.asset), ["XLM", "USDC"])

        let moment = try ApiFixtures.decode("moment", as: StellarMomentDetail.self)
        XCTAssertEqual(moment.moment.state, "collecting")
        XCTAssertEqual(moment.collectorsSummary?.largest?.editions, 2)
        XCTAssertEqual(moment.you?.editions, [9])
        XCTAssertNil(try ApiFixtures.decode("moment.legacy", as: StellarMomentDetail.self).moment.posterUrl)
        let mine = try ApiFixtures.decode("moments-mine", as: StellarMomentsMine.self)
        XCTAssertEqual(mine.created.map(\.id), [3])
        XCTAssertEqual(mine.created.first?.proceeds, "28500000")
        XCTAssertEqual(mine.totals.earnedByQuote["XLM"], "28500000")

        let holdings = try ApiFixtures.decode("holdings.partial", as: StellarHoldings.self)
        XCTAssertNil(holdings.totals.total)
        XCTAssertFalse(holdings.totals.complete)
        XCTAssertEqual(holdings.parts["launch"], "failed")
        XCTAssertEqual(try ApiFixtures.decode("holdings", as: StellarHoldings.self).earn.first?.earned, "12340")

        let positions = try ApiFixtures.decode("earn-positions.legacy", as: Listed<EarnPosition>.self).positions ?? []
        XCTAssertNotNil(positions.first?.bTokens)
        XCTAssertNil(positions.first?.earned)

        let activity = try ApiFixtures.decode("activity", as: Listed<StellarActivityItem>.self).items ?? []
        XCTAssertEqual(activity.first?.ref?.token, activity.first?.display?["token"]?.text)
        XCTAssertEqual(activity.first?.result?.amountOut, "12000000000000")
        let oldActivity = try ApiFixtures.decode("activity.legacy", as: Listed<StellarActivityItem>.self).items ?? []
        XCTAssertEqual(oldActivity.compactMap(\.section), [])
        XCTAssertNotNil(oldActivity.first?.display)

        let history = try ApiFixtures.decode("market-history", as: StellarPriceHistory.self)
        XCTAssertEqual(history.range, .day)
        XCTAssertEqual(history.points.last?.usd, 0.1901)
        XCTAssertNil(try ApiFixtures.decode("bridge-quote", as: StellarBridgeQuote.self).etaSeconds)
    }

    /// Sessions (refresh tokens) and the public views of the viewer routes: on-chain facts kept, DyorHQ's history nil.
    func testSessionsAndPublicViewsDecode() throws {
        let verify = try ApiFixtures.decode("auth-verify", as: AuthResult.self)
        XCTAssertEqual(verify.refreshToken?.hasPrefix("lrt_"), true)
        XCTAssertNotNil(verify.refreshExpiresAt.flatMap(ISO8601DateFormatter.lite.date(from:)))
        let refreshed = try ApiFixtures.decode("auth-refresh", as: AuthResult.self)
        XCTAssertNotEqual(refreshed.token, verify.token)
        XCTAssertNotEqual(refreshed.refreshToken, verify.refreshToken)
        let legacy = try ApiFixtures.decode("auth-verify.legacy", as: AuthResult.self)
        XCTAssertNil(legacy.refreshToken)
        XCTAssertNil(legacy.refreshExpiresAt)

        let account = try ApiFixtures.decode("account.public", as: AccountView.self)
        XCTAssertEqual(account.view, "public")
        XCTAssertEqual(account.xlm?.spendable, "99985000000")
        XCTAssertEqual(account.firstFunding?.needsXlm, false)
        XCTAssertNil(account.firstFunding?.starterSwap)
        XCTAssertNil(account.firstFunding?.faucet?.usedToday)
        XCTAssertEqual(account.firstFunding?.faucet?.amount, "10000")

        let holdings = try ApiFixtures.decode("holdings.public", as: StellarHoldings.self)
        XCTAssertEqual(holdings.earn.first?.supplied, "1000012340")
        XCTAssertNil(holdings.earn.first?.earned)
        XCTAssertEqual(holdings.earn.first?.earnedComplete, false)
        XCTAssertEqual(holdings.launch.first?.balance, "12000000000000")
        XCTAssertNil(holdings.launch.first?.costBasisUsd)
        XCTAssertNotNil(holdings.totals.total)

        let positions = try ApiFixtures.decode("earn-positions.public", as: Listed<EarnPosition>.self)
        XCTAssertEqual(positions.view, "public")
        XCTAssertNil(positions.positions?.first?.deposited)
        XCTAssertEqual(try ApiFixtures.decode("earn-positions", as: Listed<EarnPosition>.self).view, "owner")
        XCTAssertEqual(try ApiFixtures.decode("moments-owned.public", as: Listed<StellarEdition>.self).editions?.map(\.tokenId), [7, 8])

        let launch = try ApiFixtures.decode("launch.public", as: StellarLaunchDetail.self)
        XCTAssertEqual(launch.view, "public")
        XCTAssertEqual(launch.you?.balance, "12000000000000")
        XCTAssertNil(launch.you?.costBasisQuote)
        XCTAssertNil(launch.you?.pnlQuote)
        XCTAssertEqual(try ApiFixtures.decode("launch", as: StellarLaunchDetail.self).view, "owner")

        let moment = try ApiFixtures.decode("moment.public", as: StellarMomentDetail.self)
        XCTAssertEqual(moment.view, "public")
        XCTAssertEqual(moment.you?.editions, [9])
        XCTAssertNil(moment.you?.spent)
        XCTAssertEqual(try ApiFixtures.decode("moment", as: StellarMomentDetail.self).you?.spent, "10000000")
        XCTAssertNil(try ApiFixtures.decode("moment.legacy", as: StellarMomentDetail.self).view)
    }

    /// Every key path that holds a value ("steps[].intent.kind"); nulls add nothing.
    private static func paths(_ json: Any, _ prefix: String = "") -> Set<String> {
        var out = Set<String>()
        if let object = json as? [String: Any] {
            for (key, value) in object where !(value is NSNull) {
                let path = prefix.isEmpty ? key : prefix + "." + key
                out.insert(path)
                out.formUnion(paths(value, path))
            }
        } else if let array = json as? [Any] {
            for element in array { out.formUnion(paths(element, prefix + "[]")) }
        }
        return out
    }
}

// MARK: - Routes

/// LiteAPI against a stub server: each method asks for the route the contract names, sends the session token only to
/// the routes that need it (never to config, fees or markets), and reads the route's fixture.
final class LiteAPIRouteTests: XCTestCase {
    private let base = "https://lite.test/functions/v1/lite"
    private var api: LiteAPI!

    override func setUp() async throws {
        api = LiteAPI(baseURL: URL(string: base)!, session: StubServer.session)
        await api.restore(token: "fixture-session-token", expiresAt: Date().addingTimeInterval(3600))
    }

    func testPublicReadsSendNoToken() async throws {
        try await expect("GET", "/v1/config", token: false, fixture: "config") { _ = try await $0.config() }
        try await expect("GET", "/v1/fees", token: false, fixture: "fees") { _ = try await $0.fees() }
        try await expect("GET", "/v1/markets", token: false, fixture: "markets") { _ = try await $0.markets() }
        try await expect("GET", "/v1/markets/XLM", token: false, fixture: "market") { _ = try await $0.market("XLM") }
        try await expect("GET", "/v1/markets/XLM/history?range=week", token: false, fixture: "market-history") {
            _ = try await $0.marketHistory("XLM", range: .week)
        }
        try await expect("GET", "/v1/economics", token: false, fixture: "economics") { _ = try await $0.economics() }
        try await expect("GET", "/v1/earn/markets", token: false, fixture: "earn-markets") { _ = try await $0.earnMarkets() }
        try await expect("GET", "/v1/earn/history?pool=CPOOL&asset=CXLM&range=week", token: false, fixture: "earn-history") {
            _ = try await $0.earnHistory(pool: "CPOOL", asset: "CXLM", range: .week)
        }
        try await expect("GET", "/v1/prices", token: false, fixture: "prices") { _ = try await $0.prices() }
    }

    /// Without a session, the viewer routes ask for the viewer's public view, and the session routes ask nothing.
    func testViewerReadsWithoutASessionAskForThePublicView() async throws {
        api = LiteAPI(baseURL: URL(string: base)!, session: StubServer.session)
        let viewer = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"
        try await expect("GET", "/v1/launches?section=explore&sort=newest", token: false, fixture: "launches") {
            _ = try await $0.launchBoard(section: "explore", sort: "newest")
        }
        await api.setViewer(address: viewer)
        try await expect("GET", "/v1/account?address=\(viewer)", token: false, fixture: "account.public") {
            let account = try await $0.account()
            XCTAssertEqual(account.view, "public")
        }
        try await expect("GET", "/v1/holdings?address=\(viewer)", token: false, fixture: "holdings.public") { _ = try await $0.holdings() }
        try await expect("GET", "/v1/earn/positions?address=\(viewer)", token: false, fixture: "earn-positions.public") { _ = try await $0.earnPositions() }
        try await expect("GET", "/v1/moments/owned?address=\(viewer)", token: false, fixture: "moments-owned.public") { _ = try await $0.ownedEditions() }
        try await expect("GET", "/v1/launches?section=explore&sort=newest&address=\(viewer)", token: false, fixture: "launches") {
            _ = try await $0.launchBoard(section: "explore", sort: "newest")
        }
        try await expect("GET", "/v1/launches?sort=new&address=\(viewer)", token: false, fixture: "launches.legacy") { _ = try await $0.launches(sort: "new") }
        try await expect("GET", "/v1/launches/CTOKEN?candles=5m&address=\(viewer)", token: false, fixture: "launch.public") { _ = try await $0.launch("CTOKEN") }
        try await expect("GET", "/v1/moments?address=\(viewer)", token: false, fixture: "moments") { _ = try await $0.moments() }
        try await expect("GET", "/v1/moments/3?address=\(viewer)", token: false, fixture: "moment.public") { _ = try await $0.moment(3) }
        try await expect("GET", "/v1/assets?q=ECAT&address=\(viewer)", token: false, fixture: "assets") { _ = try await $0.searchAssets("ECAT") }

        StubServer.serve(try ApiFixtures.data("portfolio"))
        do {
            _ = try await api.portfolio(period: .week)
            XCTFail("a session read went out without a session")
        } catch LiteAPIError.notSignedIn {}
        XCTAssertNil(StubServer.taken())
    }

    func testSignedInReads() async throws {
        try await expect("GET", "/v1/account", fixture: "account") { _ = try await $0.account() }
        try await expect("GET", "/v1/holdings", fixture: "holdings") { _ = try await $0.holdings() }
        try await expect("GET", "/v1/portfolio?period=month", fixture: "portfolio") { _ = try await $0.portfolio(period: .month) }
        try await expect("GET", "/v1/recipient/GABC?asset=USDC:GISSUER", fixture: "recipient") {
            _ = try await $0.recipient("GABC", asset: "USDC:GISSUER")
        }
        try await expect("GET", "/v1/assets?q=E2E%20Cat%20%26%20co", fixture: "assets") {
            let results = try await $0.searchAssets("E2E Cat & co")
            XCTAssertEqual(results.count, 4)
        }
        try await expect("GET", "/v1/launches?section=explore&sort=near_graduation&cursor=page-2", fixture: "launches") {
            let board = try await $0.launchBoard(section: "explore", sort: "near_graduation", cursor: "page-2")
            XCTAssertEqual(board.nextCursor, "page-2")
        }
        try await expect("GET", "/v1/launches?sort=new", fixture: "launches.legacy") { _ = try await $0.launches(sort: "new") }
        try await expect("GET", "/v1/launches/CTOKEN?candles=5m", fixture: "launch") { _ = try await $0.launch("CTOKEN") }
        try await expect("GET", "/v1/launchpad/me", fixture: "launchpad-me") { _ = try await $0.myLaunchpad() }
        try await expect("GET", "/v1/moments", fixture: "moments.legacy") { _ = try await $0.moments() }
        try await expect("GET", "/v1/moments?filter=collecting&limit=20", fixture: "moments") {
            _ = try await $0.moments(filter: "collecting", limit: 20)
        }
        try await expect("GET", "/v1/moments/3", fixture: "moment") { _ = try await $0.moment(3) }
        try await expect("GET", "/v1/moments/owned", fixture: "moments-owned") { _ = try await $0.ownedEditions() }
        try await expect("GET", "/v1/moments/mine", fixture: "moments-mine") { _ = try await $0.myMoments() }
        try await expect("GET", "/v1/earn/positions", fixture: "earn-positions") { _ = try await $0.earnPositions() }
        try await expect("GET", "/v1/activity", fixture: "activity.legacy") { _ = try await $0.activity() }
        try await expect("GET", "/v1/activity?section=launch&period=day&limit=50", fixture: "activity") {
            let items = try await $0.activity(section: "launch", period: .day, limit: 50)
            XCTAssertEqual(items.count, 4)
        }
        try await expect("GET", "/v1/tx/abc", fixture: "tx-status") { _ = try await $0.txStatus("abc") }
        try await expect("GET", "/v1/launches/CTOKEN", fixture: "launch") { _ = try await $0.launch("CTOKEN", candles: nil) }
        try await expect("GET", "/v1/cash/anchors?country=GH", fixture: "cash-anchors") { _ = try await $0.anchors(country: "GH") }
    }

    /// A pasted value stays one path segment: it can't add a query, a fragment or a route of its own.
    func testPathValuesAreEscaped() async throws {
        try await expect("GET", "/v1/recipient/GABC%3Fasset%3DXLM?asset=USDC", fixture: "recipient") {
            _ = try await $0.recipient("GABC?asset=XLM", asset: "USDC")
        }
        try await expect("GET", "/v1/markets/XLM%23top", token: false, fixture: "market") { _ = try await $0.market("XLM#top") }
        try await expect("GET", "/v1/markets/GABC%2F..%2F..%2Faccount/history?range=day", token: false, fixture: "market-history") {
            _ = try await $0.marketHistory("GABC/../../account", range: .day)
        }
        for id in ["", ".", ".."] {
            StubServer.serve(try ApiFixtures.data("market"))
            do {
                _ = try await api.market(id)
                XCTFail("\"\(id)\" didn't throw")
            } catch LiteAPIError.decoding {}
            XCTAssertNil(StubServer.taken(), "\"\(id)\" was sent")
        }
    }

    func testActions() async throws {
        let swap = try await expect("POST", "/v1/swap/build", fixture: "plan") { _ = try await $0.buildSwap(quoteId: "q1", venue: "sdex") }
        XCTAssertEqual(StubServer.json(swap), ["quoteId": "q1", "venue": "sdex"])
        let best = try await expect("POST", "/v1/swap/build", fixture: "plan") { _ = try await $0.buildSwap(quoteId: "q1") }
        XCTAssertEqual(StubServer.json(best), ["quoteId": "q1"])
        try await expect("POST", "/v1/swap/quote", fixture: "swap-quote") { _ = try await $0.quoteSwap(sell: "XLM", buy: "USDC", amount: 1, slippageBps: 50) }
        try await expect("POST", "/v1/send", fixture: "plan-send") { _ = try await $0.send(asset: "USDC", to: "G", amount: 1) }
        let metadata = try await expect("POST", "/v1/launches/metadata", fixture: "launch-metadata") {
            _ = try await $0.launchMetadata(name: "E2E Cat", symbol: "ECAT", website: "https://ecat.dyorhq.fun")
        }
        XCTAssertEqual(StubServer.json(metadata), ["name": "E2E Cat", "symbol": "ECAT", "website": "https://ecat.dyorhq.fun"])
        try await expect("POST", "/v1/launches/CTOKEN/quote", fixture: "launch-quote") { _ = try await $0.quoteTrade(token: "CTOKEN", buy: true, amount: 1) }
        let moment = try await expect("POST", "/v1/moments/metadata", fixture: "moment-metadata") {
            let r = try await $0.momentMetadata(title: "Harbour", description: nil, mediaUrl: "https://m/v.mp4", mediaType: "video", posterUrl: "https://m/p.jpg", place: "Accra", takenOn: "2026-10-13")
            XCTAssertNotNil(r.posterUrl)
        }
        XCTAssertEqual(StubServer.json(moment)?["posterUrl"], "https://m/p.jpg")
        try await expect("POST", "/v1/bridge/quote", fixture: "bridge-quote") { _ = try await $0.bridgeQuote(toStellar: true, amount: "12500000") }
        try await expect("POST", "/v1/bridge/start", fixture: "bridge-start-out") {
            _ = try await $0.bridgeStart(toStellar: false, amount: "125000000", monadAddress: "0x1")
        }
        try await expect("GET", "/v1/bridge/b1", fixture: "bridge-status") { _ = try await $0.bridgeStatus(id: "b1") }
    }

    /// A contract's refusal is reported by its stable code; any other refusal by the API's. Each carries its facts.
    func testErrorsCarryTheirCodes() async throws {
        let cases: [(String, Int, String, [String: String]?)] = [
            ("error-contract", 422, "launch.slippage", ["contractCode": "launch.slippage", "raw": "HostError: Error(Contract, #7)"]),
            ("error", 409, "not_enough_xlm_for_fee", ["need": "510000", "spendable": "400000"]),
            ("error.legacy", 429, "budget_exhausted", nil),
            ("error-address-required", 400, "address_required", nil),
        ]
        for (fixture, status, code, detail) in cases {
            StubServer.serve(try ApiFixtures.data(fixture), status: status)
            do {
                _ = try await api.quoteTrade(token: "CTOKEN", buy: true, amount: 1)
                XCTFail("\(fixture) didn't throw")
            } catch let LiteAPIError.server(gotStatus, gotCode, message, gotDetail) {
                XCTAssertEqual(gotStatus, status)
                XCTAssertEqual(gotCode, code)
                XCTAssertFalse(message.isEmpty)
                XCTAssertEqual(gotDetail, detail, fixture)
            }
        }
        // Numbers and booleans in a detail are written out; nested values are left out.
        StubServer.serve(Data(#"{"error":{"code":"fee_too_high","message":"High.","detail":{"fee":"40000000","n":3,"ok":true,"x":{"y":1}}}}"#.utf8), status: 422)
        do {
            _ = try await api.quoteTrade(token: "CTOKEN", buy: true, amount: 1)
            XCTFail("fee_too_high didn't throw")
        } catch let error as LiteAPIError {
            XCTAssertEqual(error.detail, ["fee": "40000000", "n": "3", "ok": "true"])
        }
    }

    /// Serves `fixture`, runs `call`, and checks the one request it made.
    @discardableResult
    private func expect(_ method: String, _ route: String, token: Bool = true, fixture: String, file: StaticString = #filePath, line: UInt = #line,
                        _ call: (LiteAPI) async throws -> Void) async throws -> URLRequest {
        StubServer.serve(try ApiFixtures.data(fixture))
        try await call(api)
        let request = try XCTUnwrap(StubServer.taken(), "no request", file: file, line: line)
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(request.url?.absoluteString, base + route, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization") != nil, token, "\(route): token sent", file: file, line: line)
        return request
    }
}

/// One canned answer at a time, and the request that took it.
final class StubServer: URLProtocol {
    private static let lock = NSLock()
    private static var answer: (status: Int, body: Data)?
    private static var request: URLRequest?
    private static var bodies: [URL: Data] = [:]

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }()

    static func serve(_ body: Data, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        answer = (status, body)
        request = nil
    }

    static func taken() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
    }

    /// A request's JSON body as strings.
    static func json(_ request: URLRequest) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        guard let url = request.url, let data = bodies[url] else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.request = request
        if let url = request.url { Self.bodies[url] = Self.read(request) }
        let (status, body) = Self.answer ?? (500, Data())
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The body as sent: URLSession hands it to a protocol as a stream.
    private static func read(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
