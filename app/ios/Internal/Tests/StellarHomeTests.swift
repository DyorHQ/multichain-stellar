// Stellar Home (docs/DESIGN-stellar-parity.md §8.2; decisions 6 and 7): the total waits for every part and the split is
// the server's totals, a part that fails keeps its last figures, saved figures show before the first read and go at
// sign-out, Top Tokens rank as Monad's and never list a test asset, a look-alike or a retired launch, their change
// capsule is compact, My Holdings' rows, the add-funds card's phases (Friendbot once, no cash), and the source rules Home
// keeps.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarHomeTests: XCTestCase {
    private let owner = Address(data: Data(repeating: 3, count: 20))!
    private let stellar = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"
    private let pool = "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5"
    private let xlmContract = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
    private let usdcContract = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"
    private let coin = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V"

    private static let allRead: [LitePart: LiteReadStatus] = [.spot: .read, .earn: .read, .launch: .read, .moments: .read]

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func temporarySaved() -> StellarSaved {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stellar-home-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return StellarSaved(screens: SavedScreens(directory: folder, build: "test"))
    }

    private func number(_ value: Double?) -> String { value.map { "\($0)" } ?? "null" }

    /// `/v1/holdings` for the account: 64.7 XLM ($12.30), a Blend position ($19.01), a launch coin ($0.37) and two editions
    /// of one Moment ($0); a part the server couldn't read is empty, with no total.
    private func holdings(failed: Set<String> = [], asOf: String = "2026-10-15T09:41:00.000Z") throws -> StellarHoldings {
        let ok = { (part: String) in !failed.contains(part) }
        let complete = failed.isEmpty
        let spot = ok("spot") ? """
            {"id": "XLM", "kind": "registry", "contract": "\(xlmContract)", "classic": "native", "code": "XLM", "name": "Stellar Lumens",
             "decimals": 7, "balance": "647000000", "enabled": true, "verified": true, "badges": [], "note": "Test XLM", "logo": "XLM",
             "priceUsd": 0.1901, "valueUsd": 12.3, "change24h": -0.0123},
            {"id": "USDC", "kind": "registry", "contract": "\(usdcContract)", "classic": "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5",
             "code": "USDC", "name": "USD Coin", "decimals": 7, "balance": "0", "enabled": true, "verified": true, "badges": [], "note": null,
             "logo": "USDC", "priceUsd": 0.9999, "valueUsd": 0, "change24h": 0.0001}
            """ : ""
        let earn = ok("earn") ? """
            {"pool": "\(pool)", "poolName": "Blend TestnetV2", "asset": "\(xlmContract)", "code": "XLM", "supplied": "1000000000",
             "deposited": "1000000000", "withdrawn": "0", "earned": "10000000", "earnedComplete": true, "supplyApy": 0.031, "valueUsd": 19.01}
            """ : ""
        let launch = ok("launch") ? """
            {"token": "\(coin)", "symbol": "ECAT", "name": "E2E Cat", "image": null, "balance": "12000000000000", "priceUsd": 0.00000003,
             "valueUsd": 0.37, "change24h": 0.12, "phase": "curve", "progress": 0.42, "costBasisUsd": 0.4, "pnlUsd": -0.03, "stale": false}
            """ : ""
        let editions = ok("moments") ? """
            {"tokenId": 7, "momentId": 3, "title": "Sunset", "posterUrl": null, "mediaUrl": null, "mediaType": "image", "contract": "\(pool)"},
            {"tokenId": 8, "momentId": 3, "title": "Sunset", "posterUrl": null, "mediaUrl": null, "mediaType": "image", "contract": "\(pool)"}
            """ : ""
        let parts = ["spot", "earn", "launch", "moments"].map { "\"\($0)\": \"\(ok($0) ? "ok" : "failed")\"" }.joined(separator: ", ")
        return try decode(StellarHoldings.self, """
            {"address": "\(stellar)", "exists": true, "asOf": "\(asOf)",
             "pricing": {"kind": "reference", "source": "Kraken", "network": "mainnet", "note": null}, "xlm": null,
             "spot": [\(spot)], "earn": [\(earn)], "launch": [\(launch)], "moments": {"count": \(ok("moments") ? 2 : 0), "editions": [\(editions)]},
             "totals": {"spot": \(number(ok("spot") ? 12.3 : nil)), "earn": \(number(ok("earn") ? 19.01 : nil)),
                        "launch": \(number(ok("launch") ? 0.37 : nil)), "moments": \(number(ok("moments") ? 0 : nil)),
                        "total": \(number(complete ? 31.68 : nil)), "complete": \(complete)},
             "change24h": {"usd": -0.42, "pct": -0.013, "complete": \(complete)},
             "parts": {\(parts)}, "view": "public"}
            """)
    }

    /// `/v1/portfolio` over `period`, read two minutes ago: a saved Total Volume shows for a day after its read.
    private func portfolio(volume: Double, period: String = "all",
                           asOf: String = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))) throws -> StellarPortfolio {
        let stats = #"{"volume": \#(volume), "fees": 0, "pnl": 0, "claimedFees": 0, "trades": 1, "pnlComplete": true, "networkFeesXlm": "0", "networkFeesUsd": 0}"#
        let zero = #"{"volume": 0, "fees": 0, "pnl": 0, "claimedFees": 0, "trades": 0, "pnlComplete": true, "networkFeesXlm": "0", "networkFeesUsd": 0}"#
        return try decode(StellarPortfolio.self, """
            {"period": "\(period)", "since": null, "asOf": "\(asOf)",
             "pricing": {"kind": "reference", "source": "Kraken", "network": "mainnet", "note": null},
             "totals": \(stats), "sections": {"spot": \(stats), "earn": \(zero), "launch": \(zero), "moments": \(zero), "bridge": \(zero)},
             "activity": [], "coverage": {"from": null, "note": null}}
            """)
    }

    /// A model showing the account, its saved figures in `saved`.
    private func model(_ saved: StellarSaved, stellar: String? = nil) -> StellarHomeModel {
        let model = StellarHomeModel(saved: saved)
        model.showSaved(owner: owner, stellar: stellar ?? self.stellar)
        return model
    }

    /// Waits until the account's Home is saved with every part (saves are written off the main thread, in order).
    private func waitForSave(_ saved: StellarSaved, volume: Bool = false) async throws {
        for _ in 0..<300 {
            if let file = saved.load(StellarHomeModel.Saved.self, .home, owner: owner)?.value, file.readAt.count == 4, !volume || !file.volumes.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Home was never saved")
    }

    // MARK: - The balance card

    func testTheTotalWaitsForEveryPartAndTheSplitIsTheServersTotals() throws {
        let model = model(temporarySaved())
        XCTAssertNil(model.total, "nothing read: a placeholder, never $0.00")
        let read = try holdings()
        model.take(read, statuses: [.spot: .read, .earn: .read, .launch: .read, .moments: .unread])
        XCTAssertNil(model.total, "Moments unread: the total waits")
        XCTAssertNil(model.spotValue, "Spot waits for Launch and Moments too (HomeReadState)")
        XCTAssertEqual(model.earnValue, 19.01)
        XCTAssertNil(model.change24hPercent)

        model.take(read, statuses: Self.allRead)
        XCTAssertEqual(try XCTUnwrap(model.total), 31.68, accuracy: 1e-9)
        XCTAssertEqual(model.availableBalance, 12.3, "Avail. Balance is the Spot total (R23)")
        XCTAssertEqual(model.availableBalance, model.split?.spot, "and equals the Spot split")
        XCTAssertEqual(model.inUse, 19.01, "In Use is the Earn total (R23)")
        XCTAssertEqual(model.momentsValue, 0, "editions have no market")
        XCTAssertEqual(model.change24hPercent, -1.3, "the server's fraction as a percent (R24)")
        XCTAssertEqual(model.changeAmount, -0.42)
        XCTAssertEqual(model.holdings.map(\.id), ["XLM"], "a zero balance isn't a holding")
        XCTAssertNotNil(model.updatedAt)
        XCTAssertNil(model.error(statuses: Self.allRead, marketsFailure: nil))
    }

    func testAPartThatFailsKeepsItsLastFiguresAndSaysSo() throws {
        let model = model(temporarySaved())
        model.take(try holdings(), statuses: Self.allRead)
        var statuses = Self.allRead
        statuses[.earn] = .failed
        model.take(try holdings(failed: ["earn"]), statuses: statuses)
        XCTAssertEqual(model.earn.map(\.code), ["XLM"], "the positions last read stay")
        XCTAssertEqual(model.inUse, 19.01)
        XCTAssertEqual(try XCTUnwrap(model.total), 31.68, accuracy: 1e-9)
        XCTAssertEqual(model.error(statuses: statuses, marketsFailure: nil), tr("Your balances couldn't be read just now — showing the last ones read."))

        // Never read: the tab says so, with Retry, and the total waits.
        let fresh = self.model(temporarySaved())
        let failed: [LitePart: LiteReadStatus] = [.spot: .failed, .earn: .failed, .launch: .failed, .moments: .failed]
        fresh.take(nil, statuses: failed)
        XCTAssertEqual(fresh.reads.failed, [.spot, .perps, .launch, .moments])
        XCTAssertNil(fresh.total)
        XCTAssertEqual(fresh.error(statuses: failed, marketsFailure: nil), tr(StellarHomeModel.unreadMessage(.spot)))
        XCTAssertEqual(fresh.error(statuses: [:], marketsFailure: "Markets down"), "Markets down", "then the markets' failure")
    }

    func testANeedsSignInPartIsNeitherReadNorFailed() throws {
        let model = model(temporarySaved())
        model.take(try holdings(), statuses: [.spot: .read, .earn: .needsSignIn, .launch: .read, .moments: .read])
        XCTAssertEqual(model.reads.status(.perps), .reading)
        XCTAssertNil(model.total)
    }

    // MARK: - Saved figures

    func testSavedFiguresShowBeforeTheFirstReadAndGoAtSignOut() async throws {
        let saved = temporarySaved()
        let first = model(saved)
        first.take(try holdings(asOf: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))), statuses: Self.allRead)
        first.takeVolumes([.all: try portfolio(volume: 42)])
        try await waitForSave(saved, volume: true)

        // A cold launch: the figures are there before any read, each said to be saved.
        let relaunched = model(saved)
        XCTAssertEqual(try XCTUnwrap(relaunched.total), 31.68, accuracy: 1e-9)
        XCTAssertTrue(relaunched.reads.isSaved(.spot))
        XCTAssertNotNil(relaunched.savedAt, "a SavedLine says when they were read")
        XCTAssertEqual(relaunched.inUse, 19.01, "the Earn total is saved")
        XCTAssertTrue(relaunched.earn.isEmpty, "its positions never are")
        XCTAssertEqual(relaunched.change24hPercent, -1.3)
        XCTAssertEqual(relaunched.savedVolumes[.all]?.usd, 42, "Total Volume too")
        // A read replaces them: no longer said to be saved.
        relaunched.take(try holdings(), statuses: Self.allRead)
        XCTAssertNil(relaunched.savedAt)

        // Another Stellar account under the same Monad account sees none of them.
        let other = model(saved, stellar: "GBQ4LKCDNTRJWJTWV2WOUO5M3HKFQGZTRRJMWPJ5YRHJ5AM2ZYQB7ZKD")
        XCTAssertNil(other.total)
        XCTAssertFalse(other.reads.hasFigures(.spot))

        // Sign-out: the file goes, and the figures on screen with it.
        saved.forget(owner)
        relaunched.forget()
        XCTAssertNil(relaunched.total)
        XCTAssertTrue(relaunched.holdings.isEmpty)
        let afterSignOut = model(saved)
        XCTAssertNil(afterSignOut.total)
        XCTAssertTrue(afterSignOut.savedVolumes.isEmpty)
    }

    /// Stellar has no Bridge for now: Total Volume is Portfolio's cumulative volume, its four sections added up, never the
    /// server's total, which counts a past bridge too.
    func testTotalVolumeLeavesOutAPastBridgeAsPortfolioDoes() async throws {
        func stats(_ volume: Double) -> String {
            #"{"volume": \#(volume), "fees": 0, "pnl": 0, "claimedFees": 0, "trades": 1, "pnlComplete": true, "networkFeesXlm": "0", "networkFeesUsd": 0}"#
        }
        let asOf = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
        let read = try decode(StellarPortfolio.self, """
            {"period": "all", "since": null, "asOf": "\(asOf)",
             "pricing": {"kind": "reference", "source": "Kraken", "network": "mainnet", "note": null},
             "totals": \(stats(54.5)), "sections": {"spot": \(stats(30)), "earn": \(stats(10)), "launch": \(stats(2)), "moments": \(stats(0)), "bridge": \(stats(12.5))},
             "activity": [], "coverage": {"from": null, "note": null}}
            """)
        let saved = temporarySaved()
        let first = model(saved)
        first.take(try holdings(asOf: asOf), statuses: Self.allRead)
        first.takeVolumes([.all: read])
        try await waitForSave(saved, volume: true)
        XCTAssertEqual(model(saved).savedVolumes[.all]?.usd, 42, "Spot, Earn, Launch and Moments: the past bridge's 12.5 isn't counted")
        XCTAssertEqual(StellarPortfolioModel.totals(read).volume, 42, "the figure Portfolio's Cumulative Volume shows")
    }

    // MARK: - Top Tokens

    private func market(_ id: String, code: String, price: Double?, change: Double?, badges: [String] = [], isNew: Bool = false,
                        kind: String = "registry") -> String {
        """
        {"id": "\(id)", "kind": "\(kind)", "contract": "\(xlmContract)", "classic": null, "code": "\(code)", "name": "\(code) name", "decimals": 7,
         "logo": null, "image": null, "verified": true, "badges": [\(badges.map { "\"\($0)\"" }.joined(separator: ", "))], "note": null,
         "priceUsd": \(number(price)), "change24h": \(number(change)), "isNew": \(isNew), "volume24hUsd": null, "marketCapUsd": null,
         "priceSource": {"kind": "reference", "market": "Kraken", "at": null}, "stale": false, "launch": null}
        """
    }

    func testTopTokensRankAsMonadsAndNeverListATestAssetOrALookAlike() throws {
        let rows = try decode([StellarMarketRow].self, "[" + [
            market("XLM", code: "XLM", price: 0.19, change: -0.0123),
            market("USDC", code: "USDC", price: 0.9999, change: 0.0001),
            market("BUSDC", code: "USDC", price: 0.9999, change: 0.0001, badges: ["testAsset"]),
            market("FAKE", code: "USDC", price: 1, change: 0.5, badges: ["launch", "lookAlike"]),
            market("CHECK", code: "CHECK", price: nil, change: nil, badges: ["launch"]),
            market("ECAT", code: "ECAT", price: 0.00002, change: 0.25, badges: ["launch"]),
            market("NEWC", code: "NEWC", price: 0.00001, change: nil, badges: ["launch"], isNew: true),
        ].joined(separator: ",") + "]")
        XCTAssertEqual(StellarHomeModel.topTokens(rows, tab: .popular).map(\.id), ["XLM", "USDC", "ECAT", "NEWC"], "unpriced rows never show")
        XCTAssertEqual(StellarHomeModel.topTokens(rows, tab: .hot).map(\.id), ["ECAT", "XLM", "USDC", "NEWC"])
        XCTAssertEqual(StellarHomeModel.topTokens(rows, tab: .gainers).map(\.id), ["ECAT", "USDC"])
        XCTAssertEqual(StellarHomeModel.topTokens(rows, tab: .losers).map(\.id), ["XLM"])
        for tab in HomeTokenTab.allCases {
            XCTAssertFalse(StellarHomeModel.topTokens(rows, tab: tab).contains { ["BUSDC", "FAKE", "CHECK"].contains($0.id) }, tab.rawValue)
        }
        XCTAssertEqual(rows.first?.change24hPercent, -1.23, "ChangeBadge takes the percent")
    }

    /// Monad's Top Tokens hide retired launches: a coin of the retired v1 launchpad never shows in any tab, and a launch
    /// shows only once the launch board says it is launchpad v2's. Registry rows don't wait for it.
    func testTopTokensNeverListARetiredLaunch() throws {
        let rows = try decode([StellarMarketRow].self, "[" + [
            market("XLM", code: "XLM", price: 0.19, change: -0.0123),
            market("OLD", code: "ECAT", price: 0.00003, change: 0.4, badges: ["launch"], kind: "launch"),
            market("LIVE", code: "QALNCH", price: 0.00002, change: 0.25, badges: ["launch"], kind: "launch"),
            market("UNREAD", code: "NEWC", price: 0.00001, change: -0.1, badges: ["launch"], kind: "launch"),
        ].joined(separator: ",") + "]")
        let generations = ["OLD": 1, "LIVE": 2]
        for tab in HomeTokenTab.allCases {
            let ids = StellarHomeModel.topTokens(rows, tab: tab, generations: generations).map(\.id)
            XCTAssertFalse(ids.contains("OLD"), "a v1 launch never shows: \(tab.rawValue)")
            XCTAssertFalse(ids.contains("UNREAD"), "nor one whose launchpad isn't known yet: \(tab.rawValue)")
        }
        XCTAssertEqual(StellarHomeModel.topTokens(rows, tab: .popular, generations: generations).map(\.id), ["XLM", "LIVE"])
        XCTAssertEqual(StellarHomeModel.topTokens(rows, tab: .popular, generations: [:]).map(\.id), ["XLM"], "registry rows never wait")
        XCTAssertEqual(StellarLaunchGenerations.unknown(rows, known: generations), ["UNREAD"])

        // The board's rows say which launchpad: one that doesn't say is the retired one's, as the board reads it.
        let launches = try decode([StellarLaunch].self, "[" + [launchRow("OLD", generation: "1"), launchRow("LIVE", generation: "2"),
                                                                launchRow("UNREAD", generation: "null")].joined(separator: ",") + "]")
        let learned = StellarLaunchGenerations()
        learned.record(launches)
        XCTAssertEqual(learned.known, ["OLD": 1, "LIVE": 2, "UNREAD": 1])
        XCTAssertEqual(StellarHomeModel.topTokens(rows, tab: .popular, generations: learned.known).map(\.id), ["XLM", "LIVE"])
    }

    /// A board row (`GET /v1/launches`) for the launch `token`, of launchpad `generation` ("null" for an older server's).
    private func launchRow(_ token: String, generation: String) -> String {
        """
        {"token": "\(token)", "creator": "\(stellar)", "quote": "\(xlmContract)", "name": "E2E Cat", "symbol": "ECAT", "uri": "",
         "supply": "10000000000000000", "quoteReserve": "0", "tokenReserve": "0", "realQuote": "0", "threshold": "43245553200",
         "progress": 0, "completed": false, "graduated": false, "volume": "0", "trades": 0, "createdAt": "2026-10-15T09:41:00Z",
         "generation": \(generation)}
        """
    }

    /// The change capsule never needs a second line: whole percents from 100%, thousands from 10,000%.
    func testTheChangeBadgeIsCompact() {
        XCTAssertEqual(StellarChangeBadge.text(2.0123), NumberStyle.percent(2.0123))
        XCTAssertEqual(StellarChangeBadge.text(-0.3), NumberStyle.percent(-0.3))
        XCTAssertEqual(StellarChangeBadge.text(775.12), "+775%")
        XCTAssertEqual(StellarChangeBadge.text(-99.5), NumberStyle.percent(-99.5))
        XCTAssertEqual(StellarChangeBadge.text(12_345), "+\(NumberStyle.number(12_345, compact: true))%")
        XCTAssertEqual(StellarChangeBadge.text(.infinity), "—")
    }

    // MARK: - My Holdings

    func testEarnIsReadInPerpsPlace() {
        XCTAssertEqual(StellarHoldingCategory.allCases, [.spot, .earn, .launch, .moments])
        XCTAssertEqual(StellarHoldingCategory.allCases.map(\.part), [.spot, .perps, .launch, .moments])
        XCTAssertEqual(StellarHoldingCategory.spot.label, HoldingCategory.spot.label)
        XCTAssertEqual(StellarHoldingCategory.launch.label, HoldingCategory.launchpad.label)
        XCTAssertFalse(StellarHoldingCategory.earn.label.isEmpty)
    }

    func testRowsShowProgressEarningsAndOneRowPerMoment() throws {
        let read = try holdings()
        let coin = try XCTUnwrap(read.launch.first)
        XCTAssertEqual(StellarLaunchHoldingRow.percent(coin), 42)
        let full = try decode(StellarHoldings.LaunchHolding.self, """
            {"token": "\(self.coin)", "symbol": "ECAT", "name": "E2E Cat", "image": null, "balance": "1", "priceUsd": null, "valueUsd": null,
             "change24h": null, "phase": "curve", "progress": 0.996, "costBasisUsd": null, "pnlUsd": null, "stale": false}
            """)
        XCTAssertEqual(StellarLaunchHoldingRow.percent(full), 99, "floored: never 100% before the curve is full")

        let position = try XCTUnwrap(read.earn.first)
        XCTAssertEqual(try XCTUnwrap(StellarEarnPositionRow.earnedUsd(position)), 0.1901, accuracy: 1e-12, "1 XLM earned of 100 supplied worth $19.01")
        let publicView = try decode(EarnPosition.self, #"{"pool": "\#(pool)", "asset": "\#(xlmContract)", "code": "XLM", "supplied": "1000000000", "earned": null, "valueUsd": 19.01}"#)
        XCTAssertNil(StellarEarnPositionRow.earnedUsd(publicView), "unknown in the public view, never $0")

        let board = try decode([StellarMoment].self, """
            [{"id": 3, "creator": "\(stellar)", "uri": "ipfs://x", "title": "Sunset", "mediaUrl": null, "price": "10000000", "quote": "\(usdcContract)",
              "maxEditions": 100, "minted": 2, "deadline": "2099-01-01T00:00:00.000Z", "open": true, "createdAt": "2026-10-14T00:00:00.000Z"},
             {"id": 5, "creator": "\(stellar)", "uri": "ipfs://y", "title": null, "mediaUrl": null, "price": "10000000", "quote": "\(usdcContract)",
              "maxEditions": 0, "minted": 1, "deadline": "2026-10-01T00:00:00.000Z", "open": false, "createdAt": "2026-09-14T00:00:00.000Z"}]
            """)
        let editions = read.moments.editions + [try decode(StellarEdition.self, #"{"tokenId": 9, "momentId": 5, "title": null, "contract": "\#(pool)"}"#)]
        let rows = StellarHomeModel.momentHoldings(editions, board: board, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(rows.map(\.momentId), [3, 5])
        XCTAssertEqual(rows.map(\.editions), [2, 1])
        XCTAssertEqual(rows.map(\.title), ["Sunset", nil])
        XCTAssertEqual(rows.map(\.state), [.collecting, .windowClosed])
        XCTAssertNil(StellarHomeModel.momentHoldings(editions, board: [], now: Date()).first?.state, "no board row, no state said")
    }

    // MARK: - The add-funds card

    private func account(xlm: String = "0", usdc: String = "0", needsXlm: Bool = true, starterSwap: String? = "unavailable",
                         claimed: Bool? = false) throws -> AccountView {
        try decode(AccountView.self, """
            {"address": "\(stellar)", "exists": true, "network": "testnet", "activation": "friendbot", "sponsor": "\(stellar)",
             "balances": [
               {"asset": "XLM", "code": "XLM", "name": "Stellar Lumens", "contract": "\(xlmContract)", "classic": "native", "decimals": 7,
                "balance": "\(xlm)", "enabled": true, "note": null, "kind": "native", "verified": true, "logo": "XLM"},
               {"asset": "USDC", "code": "USDC", "name": "USD Coin", "contract": "\(usdcContract)", "classic": "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5",
                "decimals": 7, "balance": "\(usdc)", "enabled": true, "note": null, "kind": "classic", "verified": true, "logo": "USDC"}],
             "firstFunding": {"needsXlm": \(needsXlm), "suggestXlm": "10000000", "starterSwap": \(starterSwap.map { "\"\($0)\"" } ?? "null"),
                              "faucet": {"amount": "10000", "claimed": \(claimed.map { "\($0)" } ?? "null")}}}
            """)
    }

    private let prices = ["XLM": 0.19, "USDC": 1.0]

    private func reading(_ account: AccountView, testnet: Bool = true, traded: Bool? = false) throws -> StellarFunding.Reading {
        try XCTUnwrap(StellarFunding.reading(account, prices: prices, isTestnet: testnet, traded: traded))
    }

    func testAnEmptyAccountGetsAddFundsWithFriendbotOnceOnTestnet() throws {
        let now = Date()
        let empty = try reading(try account())
        guard case .addFunds(let offer) = StellarFunding.next(after: .checking, reading: empty, previous: nil, now: now) else {
            return XCTFail("an empty account: Add funds")
        }
        XCTAssertEqual(offer.friendbot, "10000", "testnet, never claimed: Fund with Friendbot")
        XCTAssertEqual(offer.suggestXlm, 10_000_000)
        XCTAssertNil(offer.starterUSDC)
        XCTAssertNil(StellarFunding.offer(try reading(try account(claimed: true))).friendbot, "claimed: never again")
        XCTAssertNil(StellarFunding.offer(try reading(try account(claimed: nil))).friendbot, "unknown (the public view): not offered")
        XCTAssertNil(StellarFunding.offer(try reading(try account(), testnet: false)).friendbot, "mainnet has no faucet")
        XCTAssertEqual(StellarFunding.grant("2500"), NumberStyle.number(2500), "the server's amount, in the app language's digits")
        XCTAssertEqual(StellarFunding.grant("x"), "x", "an amount it can't read is shown as sent")
    }

    func testOtherFundsWithoutXLMAskForXLMAndOfferTheStarterSwapOnlyWhenAvailable() throws {
        let short = try reading(try account(usdc: "52300000"))
        guard case .needsXLM(let offer) = StellarFunding.next(after: .checking, reading: short, previous: nil, now: Date()) else {
            return XCTFail("$5.23 of USDC and no XLM: Get XLM for network fees")
        }
        XCTAssertNil(offer.starterUSDC, "unavailable: no starter swap")
        let available = StellarFunding.offer(try reading(try account(usdc: "52300000", starterSwap: "available")))
        XCTAssertEqual(available.starterUSDC, 52_300_000)
        // Dust of USDC is no funds: Add funds.
        guard case .addFunds = StellarFunding.next(after: .checking, reading: try reading(try account(usdc: "5000")), previous: nil, now: Date()) else {
            return XCTFail("$0.0005 of USDC: Add funds")
        }
    }

    func testADepositArrivesThenTheFirstTradeIsOfferedUntilTheAccountTrades() throws {
        let now = Date()
        let empty = try reading(try account())
        let funded = try reading(try account(xlm: "100000000000", needsXlm: false, claimed: true))
        let addFunds = StellarFunding.next(after: .checking, reading: empty, previous: nil, now: now)
        let arrived = StellarFunding.next(after: addFunds, reading: funded, previous: empty, now: now)
        XCTAssertEqual(arrived, .arrived(StellarFunding.Arrival(code: "XLM", units: 100_000_000_000, decimals: 7), since: now))
        XCTAssertEqual(StellarFunding.next(after: arrived, reading: nil, previous: funded, now: now), arrived, "holds a moment")
        let later = now.addingTimeInterval(FirstFunding.arrivalPause)
        XCTAssertEqual(StellarFunding.next(after: arrived, reading: nil, previous: funded, now: later), .firstTrade(StellarFunding.firstTrade))
        XCTAssertEqual(StellarFunding.firstTrade, StellarFunding.Trade(sell: "XLM", buy: "USDC"))
        var traded = funded
        traded.traded = true
        XCTAssertEqual(StellarFunding.next(after: .firstTrade(StellarFunding.firstTrade), reading: traded, previous: funded, now: later), .done)
        XCTAssertEqual(StellarFunding.next(after: .done, reading: empty, previous: nil, now: later), .done, "never back")
    }

    func testAFundedAccountSeesTheFirstTradeOnlyWhenItsHistoryIsKnownEmpty() throws {
        let funded = try account(xlm: "100000000000", needsXlm: false, claimed: true)
        XCTAssertEqual(StellarFunding.next(after: .checking, reading: try reading(funded, traded: false), previous: nil, now: Date()), .firstTrade(StellarFunding.firstTrade))
        XCTAssertEqual(StellarFunding.next(after: .checking, reading: try reading(funded, traded: true), previous: nil, now: Date()), .done)
        XCTAssertEqual(StellarFunding.next(after: .checking, reading: try reading(funded, traded: nil), previous: nil, now: Date()), .done, "history unknown: no card")
        XCTAssertEqual(StellarFunding.next(after: .checking, reading: nil, previous: nil, now: Date()), .checking, "a failed read decides nothing")
    }

    func testSetupAndFundingAreNoTrade() throws {
        func item(_ type: String, _ kind: String) throws -> StellarActivityItem {
            try decode(StellarActivityItem.self, #"{"type": "\#(type)", "id": "\#(UUID().uuidString)", "kind": "\#(kind)", "summary": "", "status": "success", "at": "2026-10-15T09:41:00.000Z"}"#)
        }
        let setup = [try item("tx", "activate"), try item("tx", "trust"), try item("tx", "faucet"), try item("bridge", "monad_to_stellar")]
        XCTAssertFalse(StellarFunding.hasTraded(setup))
        XCTAssertTrue(StellarFunding.hasTraded(setup + [try item("tx", "swap")]))
        XCTAssertTrue(StellarFunding.hasTraded([try item("tx", "launch_buy")]))
    }

    func testClosingTheCardIsRememberedForTheAddress() throws {
        let suite = "stellar-home-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let watch = StellarFundingWatch()
        watch.close(address: stellar, defaults: defaults)
        XCTAssertEqual(watch.phase, .done)
        XCTAssertTrue(defaults.bool(forKey: StellarFundingWatch.closedKey(stellar)))
        XCTAssertTrue(StellarFundingWatch.closedKey(stellar).hasPrefix("lite."), "every Lite default starts with lite. (§3.10 rule 9)")
    }

    // MARK: - Source rules

    /// Home's sources (ios/DyorHQ/Lite/Home), read from this checkout.
    private func homeSources() throws -> [(name: String, text: String)] {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() } // StellarHomeTests.swift → Tests → Internal → ios
        folder.appendPathComponent("DyorHQ/Lite/Home")
        let names = ["StellarHomeView.swift", "StellarHomeModel.swift", "StellarHomeRows.swift", "StellarAddFundsCard.swift"]
        return try names.map { ($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) }
    }

    func testHomeIsNoLongerASeamAndHasNoLockNoCashAndNoActivityCard() throws {
        for (name, text) in try homeSources() {
            XCTAssertFalse(text.contains("SEAM("), name)
            XCTAssertFalse(text.contains("LiteLegacyScreens"), name)
            for gone in ["StellarCashSheet", "Add cash", "Cash out", "unlock", "Unlock", "StellarActivityRow", "env.history"] {
                XCTAssertFalse(text.contains(gone), "\(name): \(gone)")
            }
        }
    }

    /// Stellar has no Bridge for now (owner, 2026-10-16): Home's actions are Monad's but the Bridge, Deposit, Withdraw and
    /// Transfer, in Monad's row (equal widths, its spacing), and nothing on Home, the add-funds card included, opens a
    /// bridge. Monad's Home keeps its Bridge.
    func testHomesActionsAreDepositWithdrawAndTransferAndNothingOpensABridge() throws {
        let sources = Dictionary(uniqueKeysWithValues: try homeSources().map { ($0.name, $0.text) })
        let view = try XCTUnwrap(sources["StellarHomeView.swift"])
        let start = try XCTUnwrap(view.range(of: "private var quickActions: some View {"))
        let end = try XCTUnwrap(view.range(of: "// MARK: Allocation", range: start.upperBound..<view.endIndex))
        let row = String(view[start.upperBound..<end.lowerBound])
        XCTAssertTrue(row.contains("HStack(spacing: 10) {"), "Monad's row and spacing")
        let tile = try NSRegularExpression(pattern: #"StellarHomeAction\(title: "([^"]+)""#)
        let titles = tile.matches(in: view, range: NSRange(view.startIndex..., in: view)).map { String(view[Range($0.range(at: 1), in: view)!]) }
        XCTAssertEqual(titles, ["Deposit", "Withdraw", "Transfer"], "the row's tiles, and no other on Home")
        XCTAssertEqual(tile.numberOfMatches(in: row, range: NSRange(row.startIndex..., in: row)), 3, "all three in the row")
        XCTAssertTrue(try XCTUnwrap(sources["StellarHomeRows.swift"]).contains(".frame(maxWidth: .infinity)"), "each tile takes an equal share of the row")
        for (name, text) in sources {
            for gone in ["StellarBridgeView", "showBridge", "onBridge", "Bridge from Monad", "point.3.connected.trianglepath.dotted", ".bridge"] {
                XCTAssertFalse(text.contains(gone), "\(name): \(gone)")
            }
        }
        var monad = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { monad.deleteLastPathComponent() } // StellarHomeTests.swift → Tests → Internal → ios
        let monadHome = try String(contentsOf: monad.appending(path: "DyorHQ/Home/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(monadHome.contains(#"HomeAction(title: "Bridge", symbol: "point.3.connected.trianglepath.dotted") { showBridge = true }"#),
                      "Monad's Home keeps its Bridge")
    }

    func testPasteboardDefaultsAndCoinValueRules() throws {
        let coinValue = try NSRegularExpression(pattern: #"priceNumber|LaunchpadMath\.marketCap\(|\b(launch|\$0|\$1)\.(price|marketCap)\b"#)
        for (name, text) in try homeSources() {
            XCTAssertNil(coinValue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), name)
            for line in text.components(separatedBy: "\n") where line.contains("UIPasteboard") {
                XCTAssertTrue(line.contains("UIPasteboard.general.string = address.checksummed"), "\(name): \(line)")
            }
        }
    }
}
