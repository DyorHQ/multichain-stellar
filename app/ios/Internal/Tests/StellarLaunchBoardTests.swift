// Stellar's Launch board and My Launchpad (docs/DESIGN-stellar-parity.md §8.10.1, §8.10.4; docs/DESIGN-stellar-contracts-v2.md
// §21): the sort chips' server sorts, the server's order and the phone's until it lands, search, the retired launchpad's
// coins listed apart, the cards' market cap, every claim My Launchpad offers and who it pays, the fee tiles, and the
// source rules the board keeps.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarLaunchBoardTests: XCTestCase {
    private typealias Board = StellarLaunchBoardModel

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static let xlm = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
    private static let me = "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN"
    private static let someoneElse = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"

    /// A board row as the API writes it.
    private func coinJSON(_ token: String, symbol: String, name: String? = nil, generation: Int? = 2, createdAt: String = "2026-10-15T10:00:00.000Z",
                          progress: Double = 0.2, completed: Bool = false, graduated: Bool = false, phase: String = "curve",
                          marketCapQuote: String? = "41700", marketCapUsd: Double? = nil, quote: String = StellarLaunchBoardTests.xlm, quoteCode: String? = "XLM") -> String {
        """
        {"token": "\(token)", "creator": "\(Self.me)", "quote": "\(quote)", "name": "\(name ?? symbol.capitalized)", "symbol": "\(symbol)",
         "uri": "", "supply": "10000000000000000", "quoteReserve": "0", "tokenReserve": "0", "realQuote": "0", "threshold": "93000000000",
         "progress": \(progress), "completed": \(completed), "graduated": \(graduated), "volume": "0", "trades": 0, "createdAt": "\(createdAt)",
         "phase": "\(phase)", "quoteCode": \(quoteCode.map { "\"\($0)\"" } ?? "null"), "marketCapQuote": \(marketCapQuote.map { "\"\($0)\"" } ?? "null"),
         "marketCapUsd": \(marketCapUsd.map { "\($0)" } ?? "null"), "generation": \(generation.map(String.init) ?? "null")}
        """
    }

    private func coin(_ token: String, symbol: String, generation: Int? = 2, createdAt: String = "2026-10-15T10:00:00.000Z", progress: Double = 0.2,
                      completed: Bool = false, graduated: Bool = false, phase: String = "curve", marketCapQuote: String? = "41700",
                      marketCapUsd: Double? = nil, quoteCode: String? = "XLM") throws -> StellarLaunch {
        try decode(StellarLaunch.self, coinJSON(token, symbol: symbol, generation: generation, createdAt: createdAt, progress: progress, completed: completed,
                                                graduated: graduated, phase: phase, marketCapQuote: marketCapQuote, marketCapUsd: marketCapUsd, quoteCode: quoteCode))
    }

    // MARK: - The board

    func testTheSortChipsAskForTheServersSorts() {
        XCTAssertEqual(StellarLaunchpadView.serverSort(.newest).rawValue, "newest")
        XCTAssertEqual(StellarLaunchpadView.serverSort(.marketCap).rawValue, "market_cap")
        XCTAssertEqual(StellarLaunchpadView.serverSort(.progress).rawValue, "near_graduation")
    }

    func testTheBoardShowsTheServersOrderOnceItsSortWasRead() throws {
        // The server's market cap order, which the phone would order otherwise (no USD figure on the first).
        let first = try coin("CA1", symbol: "AAA", marketCapUsd: nil)
        let second = try coin("CA2", symbol: "BBB", marketCapUsd: 9_000)
        let board = Board.Lists(explore: [first, second], graduated: [])
        let request = Board.Request(sort: .marketCap, query: nil)
        XCTAssertEqual(Board.lists(board: board, boardSort: .marketCap, search: nil, request: request).explore.map(\.token), ["CA1", "CA2"],
                       "Market Cap matches the server's order")
        // Another sort, not read yet: the coins on screen sorted on the phone as the server sorts them, until it lands.
        let near = try coin("CA3", symbol: "CCC", progress: 0.9)
        let board2 = Board.Lists(explore: [first, near], graduated: [])
        XCTAssertEqual(Board.lists(board: board2, boardSort: .newest, search: nil, request: Board.Request(sort: .nearGraduation, query: nil)).explore.map(\.token),
                       ["CA3", "CA1"])
    }

    func testASearchShowsTheServersAnswerAndFiltersOnThePhoneUntilItLands() throws {
        let cat = try coin("CA1", symbol: "ECAT")
        let dog = try coin("CA2", symbol: "DOGE")
        let board = Board.Lists(explore: [cat, dog], graduated: [])
        let request = Board.Request(sort: .newest, query: "cat")
        XCTAssertEqual(Board.lists(board: board, boardSort: .newest, search: nil, request: request).explore.map(\.token), ["CA1"],
                       "until the server answers, the board's coins whose name or ticker contains the search")
        let answer = Board.Search(query: "cat", sort: .newest, lists: Board.Lists(explore: [cat, try coin("CA9", symbol: "CATS")], graduated: []))
        XCTAssertEqual(Board.lists(board: board, boardSort: .newest, search: answer, request: request).explore.map(\.token), ["CA1", "CA9"],
                       "the server's answer, which finds coins the board didn't list")
        XCTAssertEqual(Board.lists(board: board, boardSort: .newest, search: answer, request: Board.Request(sort: .newest, query: nil)).explore.map(\.token),
                       ["CA1", "CA2"], "no search: the board itself")
        XCTAssertEqual(Board.matching([cat, dog], "CA2").map(\.token), ["CA2"], "a token id finds its coin")
    }

    func testTheSearchSentIsTrimmedAndCappedAtTheServersLimit() {
        XCTAssertNil(Board.query("   "))
        XCTAssertEqual(Board.query("  cat "), "cat")
        XCTAssertEqual(Board.query(String(repeating: "a", count: 80))?.count, 64)
    }

    func testRetiredLaunchesAreListedApartAndCompletedCurvesStayInExplore() throws {
        let live = try coin("CA1", symbol: "LIVE")
        let full = try coin("CA2", symbol: "FULL", progress: 1, completed: true, phase: "completed")
        let oldCurve = try coin("CA3", symbol: "OLD", generation: 1)
        let oldGraduated = try coin("CA4", symbol: "OLDG", generation: 1, completed: true, graduated: true, phase: "graduated")
        let graduated = try coin("CA5", symbol: "GRAD", completed: true, graduated: true, phase: "graduated")
        let legacy = try coin("CA6", symbol: "PRE", generation: nil)
        let sections = Board.sections(Board.Lists(explore: [live, full, oldCurve, legacy], graduated: [graduated, oldGraduated]))
        XCTAssertEqual(sections.explore.map(\.token), ["CA1", "CA2"], "a completed curve waiting to graduate stays in Explore")
        XCTAssertEqual(sections.graduated.map(\.token), ["CA5"])
        XCTAssertEqual(sections.retired.map(\.token), ["CA3", "CA6", "CA4"], "v1's coins, and a row from a server before v2 (all v1's)")
        XCTAssertTrue(Board.isRetired(oldCurve))
        XCTAssertFalse(Board.isRetired(live))
    }

    func testTheCardsMarketCapIsInTheQuoteAssetOrADash() throws {
        XCTAssertEqual(StellarLaunchCard.marketCap(try coin("CA1", symbol: "ECAT", marketCapQuote: nil)), "—", "unread, never 0")
        XCTAssertTrue(StellarLaunchCard.marketCap(try coin("CA1", symbol: "ECAT", marketCapQuote: "41700")).hasSuffix(" XLM"))
        XCTAssertFalse(StellarLaunchCard.marketCap(try coin("CA1", symbol: "ECAT", marketCapQuote: "41700", quoteCode: nil)).hasSuffix(" "))
    }

    func testAPageOverTheBoardIsTheCoinsWhicheverWayItWasOpened() throws {
        let row = try coin("CA1", symbol: "ECAT")
        XCTAssertEqual(StellarLaunchPage.launch(row).token, "CA1")
        XCTAssertEqual(StellarLaunchPage.token("CA1").hashValue, StellarLaunchPage.launch(row).hashValue)
        XCTAssertNotEqual(StellarLaunchPage.token("CA1"), StellarLaunchPage.launch(row))
    }

    func testTheSavedBoardKeepsBothSectionsAndTheirSort() throws {
        let saved = Board.Saved(lists: Board.Lists(explore: [try coin("CA1", symbol: "ECAT")], graduated: [try coin("CA2", symbol: "GRAD", graduated: true)]),
                                sort: StellarLaunchMath.Sort.marketCap.rawValue)
        let read = try JSONDecoder().decode(Board.Saved.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(read.lists, saved.lists)
        XCTAssertEqual(StellarLaunchMath.Sort(rawValue: read.sort), .marketCap)
    }

    // MARK: - My Launchpad

    /// launchpad-v2's state of a launch in XLM, as the account (the recipient or not) reads it.
    private func state(_ token: String, recipient: String = StellarLaunchBoardTests.me, creatorFees: String = "0", sharing: Bool = true, pendingQuote: String? = "0",
                       pendingToken: String? = "0", owed: String = "0", quote: String = StellarLaunchBoardTests.xlm, code: String = "XLM") throws -> StellarLaunchStateV2 {
        let venue = #"{"id": 0, "kind": "Soroswap", "name": "Soroswap", "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526", "enabled": true, "feeFraction": 0}"#
        return try decode(StellarLaunchStateV2.self, """
            {"status": {"token": "\(token)", "phase": "curve", "completedAt": null, "stuck": false, "stuckSince": null, "markStuckAt": null,
                        "fallbackAt": null, "rescueAdminAt": null, "rescuePublicAt": null, "venue": \(venue), "fallback": \(venue), "venueLocked": false,
                        "fallbackAllowed": false, "pool": null, "graduatedVenue": null, "refund": null, "failure": null,
                        "actions": {"buy": true, "sell": true, "graduate": false, "graduateFallback": false, "markStuck": false, "rescue": false, "refund": false}},
             "quote": {"id": "\(code)", "code": "\(code)", "contract": "\(quote)"}, "recipient": "\(recipient)", "pendingTakeover": null,
             "creatorFees": "\(creatorFees)",
             "rewards": {"sharing": \(sharing), "eligible": null, "queuedQuote": "0", "queuedToken": "0", "releasableFromLedger": null,
                         "pendingQuote": \(pendingQuote.map { "\"\($0)\"" } ?? "null"), "pendingToken": \(pendingToken.map { "\"\($0)\"" } ?? "null")},
             "you": {"isRecipient": \(recipient == Self.me), "creatorOwed": "\(owed)"}}
            """)
    }

    private func mine(held: [(token: String, symbol: String, generation: Int)], created: [(token: String, symbol: String, generation: Int, unclaimed: String)],
                      byQuote: String = "[]") throws -> StellarMyLaunchpad {
        let heldJSON = held.map { item in
            """
            {"token": "\(item.token)", "balance": "12000000000000", "valueUsd": 9.48, "costBasisQuote": "500000000", "pnlQuote": "-2400000",
             "pnlUsd": -0.02, "onCurve": true, "launch": \(coinJSON(item.token, symbol: item.symbol, generation: item.generation))}
            """
        }.joined(separator: ",")
        let createdJSON = created.map { item in
            """
            {"launch": \(coinJSON(item.token, symbol: item.symbol, generation: item.generation)),
             "creatorFees": {"unclaimed": "\(item.unclaimed)", "claimed": "0", "quote": "XLM", "unclaimedUsd": 0.5, "claimedUsd": 0}}
            """
        }.joined(separator: ",")
        return try decode(StellarMyLaunchpad.self, #"{"held": [\#(heldJSON)], "created": [\#(createdJSON)], "fees": {"byQuote": \#(byQuote)}, "activity": []}"#)
    }

    func testEveryClaimIsListedOncePerCoinOrAssetWithItsOwnPath() throws {
        let mine = try mine(held: [("CV2HELD", "HELD", 2), ("CV1HELD", "OLDH", 1)],
                            created: [("CV2MINE", "MINE", 2, "1000000"), ("CV1MINE", "OLDM", 1, "2500000"), ("CV2GONE", "GONE", 2, "5000000")])
        let states = [
            // Mine, the recipient: its creator fees as launchpad v2 books them now, and fees owed to me in XLM.
            "CV2MINE": try state("CV2MINE", creatorFees: "3000000", owed: "700000"),
            // I hold it: rewards in XLM and in the coin; the same XLM owed figure (owed fees are per asset).
            "CV2HELD": try state("CV2HELD", pendingQuote: "4000000", pendingToken: "120000000000", owed: "700000"),
            // Mine, but its fee recipient changed: its creator fees are the new recipient's.
            "CV2GONE": try state("CV2GONE", recipient: Self.someoneElse, creatorFees: "5000000"),
        ]
        let claims = StellarLaunchClaim.claims(mine, states: states, account: Self.me, code: { $0 })
        XCTAssertEqual(claims.map(\.id), ["creator-CV2MINE", "creator-CV1MINE", "rewards-CV2HELD", "owed-\(Self.xlm)"])
        XCTAssertEqual(claims[0].kind, .creator(token: "CV2MINE", symbol: "MINE", retired: false))
        XCTAssertEqual(claims[0].amount, StellarFormat.amount(3_000_000, code: "XLM"), "launchpad v2's booked fees, not the server's older figure")
        XCTAssertNil(claims[0].usd, "the server's dollar figure was for another amount")
        XCTAssertEqual(claims[1].kind, .creator(token: "CV1MINE", symbol: "OLDM", retired: true), "the retired launchpad's claim, through v1")
        XCTAssertTrue(claims[1].retired)
        XCTAssertEqual(claims[1].usd, 0.5)
        XCTAssertEqual(claims[2].amount, "\(StellarFormat.units(4_000_000, compact: true)) XLM + \(StellarFormat.units(120_000_000_000, compact: true)) HELD",
                       "rewards in both assets")
        guard case .owed(let asset, let units) = claims[3].kind else { return XCTFail("owed fees") }
        XCTAssertEqual(asset.contract, Self.xlm)
        XCTAssertEqual(units, 700_000)
        XCTAssertTrue(claims.allSatisfy { $0.to == Self.me })
    }

    func testAV2CoinsCreatorFeesUseTheServersFigureWhileItsStateIsUnread() throws {
        let mine = try mine(held: [], created: [("CV2MINE", "MINE", 2, "1000000")])
        let claims = StellarLaunchClaim.claims(mine, states: [:], account: Self.me, code: { $0 })
        XCTAssertEqual(claims.map(\.id), ["creator-CV2MINE"])
        XCTAssertEqual(claims.first?.usd, 0.5)
        XCTAssertTrue(StellarLaunchClaim.claims(try self.mine(held: [], created: [("CV2MINE", "MINE", 2, "0")]), states: [:], account: Self.me, code: { $0 }).isEmpty,
                      "nothing to claim, no row")
    }

    func testRewardsShowOnlyWithFeeSharingAndSomethingClaimable() throws {
        XCTAssertEqual(StellarLaunchClaim.rewards(try state("CA1", pendingQuote: "0", pendingToken: "0"), symbol: "ECAT"), [])
        XCTAssertEqual(StellarLaunchClaim.rewards(try state("CA1", pendingQuote: nil, pendingToken: nil), symbol: "ECAT"), [], "no viewer")
        XCTAssertEqual(StellarLaunchClaim.rewards(try state("CA1", sharing: false, pendingQuote: "5"), symbol: "ECAT"), [])
        XCTAssertEqual(StellarLaunchClaim.rewards(try state("CA1", pendingToken: "10000000"), symbol: "ECAT").map(\.code), ["ECAT"])
    }

    func testTheFeeTilesAddReceivedAndClaimablePerQuoteAsset() throws {
        let fees = try decode(StellarMyLaunchpad.Fees.self, """
            {"byQuote": [{"quote": "XLM", "received": "9300000", "claimable": "700000", "receivedUsd": 0.18, "claimableUsd": 0.02},
                         {"quote": "USDC", "received": "0", "claimable": "15000000", "receivedUsd": null, "claimableUsd": 1.5}]}
            """)
        let lines = StellarLaunchFeeLines(fees: fees, code: { $0 })
        XCTAssertEqual(lines.total.map(\.amount), [StellarFormat.amount(10_000_000, code: "XLM"), StellarFormat.amount(15_000_000, code: "USDC")])
        XCTAssertEqual(lines.received.map(\.id), ["XLM", "USDC"], "XLM first, as the server orders them")
        XCTAssertEqual(lines.total.first?.usd ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(lines.total.last?.usd, "a part without a dollar figure leaves the total without one")
        XCTAssertEqual(StellarLaunchFeeLines.usd(lines.claimable) ?? 0, 1.52, accuracy: 1e-9)
        XCTAssertNil(StellarLaunchFeeLines.usd([]))
    }

    func testThePortfolioIsTheHeldCoinsValueOrADashWhenNoneIsPriced() throws {
        XCTAssertEqual(StellarLaunchpadProfileView.portfolioUSD(try mine(held: [], created: [])), 0)
        XCTAssertEqual(StellarLaunchpadProfileView.portfolioUSD(try mine(held: [("CA1", "ECAT", 2), ("CA2", "DOGE", 1)], created: [])) ?? 0, 18.96, accuracy: 1e-9)
    }

    func testLaunchpadV2sCoinsAreReadOnceAndTheRetiredOnesSplitOff() throws {
        let mine = try mine(held: [("CA1", "ECAT", 2), ("CA2", "OLD", 1)], created: [("CA1", "ECAT", 2, "0"), ("CA3", "MINE", 2, "0")])
        XCTAssertEqual(StellarLaunchpadProfileModel.v2Tokens(mine), ["CA1", "CA3"])
        let split = StellarLaunchpadProfileModel.split(mine.held, by: \.launch)
        XCTAssertEqual(split.live.map(\.token), ["CA1"])
        XCTAssertEqual(split.retired.map(\.token), ["CA2"])
    }

    // MARK: - Source rules

    private func source(_ name: String) throws -> String {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() } // StellarLaunchBoardTests.swift → Tests → Internal → ios
        return try String(contentsOf: folder.appendingPathComponent("DyorHQ/Lite/Launch/\(name)"), encoding: .utf8)
    }

    func testTheBoardAndMyLaunchpadAreNoLongerSeams() throws {
        for name in ["StellarLaunchpadView.swift", "StellarLaunchpadProfileView.swift"] {
            let text = try source(name)
            XCTAssertFalse(text.contains("SEAM("), name)
            XCTAssertFalse(text.contains("LiteLegacyScreens"), name)
            XCTAssertTrue(text.hasPrefix("// Stellar copy of ios/DyorHQ/Launchpad/"), "\(name) names its Monad source")
        }
    }

    func testNoContractIdIsWrittenIntoTheBoardOrMyLaunchpad() throws {
        let contract = try NSRegularExpression(pattern: #""C[A-Z2-7]{55}""#)
        for name in ["StellarLaunchpadView.swift", "StellarLaunchpadProfileView.swift"] {
            let text = try source(name)
            XCTAssertNil(contract.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(name): ids come from the API")
        }
    }
}
