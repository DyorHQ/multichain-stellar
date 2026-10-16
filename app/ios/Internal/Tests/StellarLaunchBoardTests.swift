// Stellar's Launch board and My Launchpad (docs/DESIGN-stellar-parity.md §8.10.1, §8.10.4, §8.10.5; docs/DESIGN-stellar-
// contracts-v2.md §21): the sort chips' server sorts, the server's order and the phone's until it lands (or when a read
// fails), search, every page of a section, launchpad v2's coins only on the board (the retired launchpad's are reached
// from My Launchpad), a launched coin's page opened once the board lists it, the cards' market cap, every claim My
// Launchpad offers and whether it is the latest read's, what a claim's plan pays and to whom, Claim All's order (each
// later claim built again before it is sent), its set-aside claims, retries and stop, the state reads a few at a time,
// the fee tiles, and the source rules the board keeps.
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

    func testTheBoardListsLaunchpadV2sCoinsOnlyAndCompletedCurvesStayInExplore() throws {
        let live = try coin("CA1", symbol: "LIVE")
        let full = try coin("CA2", symbol: "FULL", progress: 1, completed: true, phase: "completed")
        let oldCurve = try coin("CA3", symbol: "OLD", generation: 1)
        let oldGraduated = try coin("CA4", symbol: "OLDG", generation: 1, completed: true, graduated: true, phase: "graduated")
        let graduated = try coin("CA5", symbol: "GRAD", completed: true, graduated: true, phase: "graduated")
        let legacy = try coin("CA6", symbol: "PRE", generation: nil)
        let sections = Board.sections(Board.Lists(explore: [live, full, oldCurve, legacy], graduated: [graduated, oldGraduated]))
        XCTAssertEqual(sections.explore.map(\.token), ["CA1", "CA2"], "a completed curve waiting to graduate stays in Explore")
        XCTAssertEqual(sections.graduated.map(\.token), ["CA5"], "the retired launchpad's graduated coins aren't listed either")
        XCTAssertTrue(Board.isRetired(oldCurve))
        XCTAssertTrue(Board.isRetired(legacy), "a row from a server before v2 is v1's")
        XCTAssertFalse(Board.isRetired(live))
        XCTAssertFalse(Board.listsOnBoard(oldGraduated))
        XCTAssertTrue(Board.listsOnBoard(full))
        // Only v1's coins: the board has nothing to list ("No Launches Yet", never a Retired section).
        XCTAssertTrue(Board.sections(Board.Lists(explore: [oldCurve, legacy], graduated: [oldGraduated])).isEmpty)
        XCTAssertFalse(sections.isEmpty)
    }

    func testASearchNeverFindsTheRetiredLaunchpadsCoins() throws {
        let v2 = try coin("CA1", symbol: "ECAT")
        let v1 = try coin("CA2", symbol: "OCAT", generation: 1)
        let v1Graduated = try coin("CA3", symbol: "GCAT", generation: 1, completed: true, graduated: true, phase: "graduated")
        let request = Board.Request(sort: .newest, query: "cat")
        // The phone's search of the board, before the server answers.
        let onPhone = Board.lists(board: Board.Lists(explore: [v2, v1], graduated: [v1Graduated]), boardSort: .newest, search: nil, request: request)
        XCTAssertEqual(Board.sections(onPhone), Board.Sections(graduated: [], explore: [v2]))
        // The server's answer, which has every generation's.
        let answer = Board.Search(query: "cat", sort: .newest, lists: Board.Lists(explore: [v1, v2], graduated: [v1Graduated]))
        XCTAssertEqual(Board.sections(Board.lists(board: Board.Lists(), boardSort: nil, search: answer, request: request)),
                       Board.Sections(graduated: [], explore: [v2]))
        XCTAssertEqual(Board.sections(Board.Lists(explore: [v1], graduated: [v1Graduated])).isEmpty, true, "found nothing: says so")
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

    func testASearchWhoseExploreReadFailsKeepsItsCoinsInTheirOwnOrder() throws {
        let newer = try coin("CA1", symbol: "CAT1", createdAt: "2026-10-15T12:00:00.000Z", marketCapUsd: 10)
        let bigger = try coin("CA2", symbol: "CAT2", createdAt: "2026-10-15T10:00:00.000Z", marketCapUsd: 9_000)
        let offline = URLError(.notConnectedToInternet)
        // "cat" on Newest, then Market Cap, whose read fails: Explore keeps Newest's answer, labelled as Newest.
        let newest = Board.searched(query: "cat", sort: .newest, explore: .success([newer, bigger]), graduated: .success([]), previous: nil,
                                    board: Board.Lists(), boardSort: nil)
        XCTAssertEqual(newest.sort, .newest)
        let failed = Board.searched(query: "cat", sort: .marketCap, explore: .failure(offline), graduated: .failure(offline), previous: newest,
                                    board: Board.Lists(), boardSort: nil)
        XCTAssertEqual(failed.sort, .newest, "the order the coins are in, not the chip asked for")
        XCTAssertEqual(failed.lists, newest.lists)
        XCTAssertEqual(Board.lists(board: Board.Lists(), boardSort: nil, search: failed, request: Board.Request(sort: .marketCap, query: "cat")).explore.map(\.token),
                       ["CA2", "CA1"], "under the Market Cap chip, sorted by market cap on the phone")
        // No answer to this search yet: the board's matches, in the board's own order.
        let fromBoard = Board.searched(query: "cat", sort: .marketCap, explore: .failure(offline), graduated: .success([]), previous: nil,
                                       board: Board.Lists(explore: [newer, bigger]), boardSort: .newest)
        XCTAssertEqual(fromBoard.sort, .newest)
        XCTAssertEqual(Board.searched(query: "cat", sort: .marketCap, explore: .failure(offline), graduated: .success([]), previous: nil,
                                      board: Board.Lists(explore: [newer]), boardSort: nil).sort, nil, "a board not read yet is in no order")
        // A read that lands is the server's order for its chip, as it is.
        let landed = Board.searched(query: "cat", sort: .marketCap, explore: .success([newer, bigger]), graduated: .failure(offline), previous: newest,
                                    board: Board.Lists(), boardSort: nil)
        XCTAssertEqual(landed.sort, .marketCap)
        XCTAssertEqual(Board.lists(board: Board.Lists(), boardSort: nil, search: landed, request: Board.Request(sort: .marketCap, query: "cat")).explore.map(\.token),
                       ["CA1", "CA2"])
    }

    private func page(_ tokens: [String], next: String?) throws -> StellarLaunchBoard {
        let rows = tokens.map { coinJSON($0, symbol: "S\($0.suffix(1))") }.joined(separator: ",")
        return try decode(StellarLaunchBoard.self, #"{"launches": [\#(rows)], "nextCursor": \#(next.map { "\"\($0)\"" } ?? "null"), "counts": {"explore": 3, "graduated": 0}, "view": "public"}"#)
    }

    func testTheBoardReadsEveryPageOfASectionAndKeepsEachCoinOnce() async throws {
        let first = try page(["CA1", "CA2"], next: "page-2")
        // A launch made between the two reads moved the pages along: CA2 shows again.
        let second = try page(["CA2", "CA3"], next: nil)
        var cursors: [String?] = []
        let coins = try await Board.pages { cursor in
            cursors.append(cursor)
            return cursor == nil ? first : second
        }
        XCTAssertEqual(coins.map(\.token), ["CA1", "CA2", "CA3"], "every page, in the server's order, each coin once")
        XCTAssertEqual(cursors, [nil, "page-2"])
        var reads = 0
        let capped = try await Board.pages(maxPages: 3) { _ in
            reads += 1
            return first
        }
        XCTAssertEqual(reads, 3, "at most maxPages pages")
        XCTAssertEqual(capped.map(\.token), ["CA1", "CA2"])
        XCTAssertEqual(Board.maxPages, 20)
    }

    // MARK: - After a launch

    func testACoinJustLaunchedOpensOnceTheBoardListsIt() async throws {
        let launched = try coin("CNEW", symbol: "NEW")
        var reads = 0
        // The server lists the launch from the third read on.
        let row = await Board.firstRow(attempts: Board.launchedReads, pause: .milliseconds(1)) {
            reads += 1
            return reads >= 3 ? launched : nil
        }
        XCTAssertEqual(row, launched)
        XCTAssertEqual(reads, 3, "no read after the row showed")
        XCTAssertEqual(Board.launchedPage("CNEW", row: row), .launch(launched), "its page opens with its row")

        // Never listed within the reads: its page opens by its token, and reads the coin itself.
        reads = 0
        let never = await Board.firstRow(attempts: 4, pause: .milliseconds(1)) {
            reads += 1
            return nil
        }
        XCTAssertNil(never)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(Board.launchedPage("CNEW", row: never), .token("CNEW"))
        XCTAssertEqual(Board.launchedReads, 6)
        XCTAssertEqual(Board.launchedPause, .seconds(2))
    }

    func testTheWaitForALaunchedCoinEndsWhenItsTaskIsCancelled() async {
        let reads = Gauge()
        let wait = Task { @MainActor in
            await Board.firstRow(attempts: 5, pause: .seconds(30)) {
                reads.enter()
                return nil
            }
        }
        // Let the first read run, then cancel during the pause: no second read, no row.
        while reads.now == 0 { await Task.yield() }
        wait.cancel()
        let row = await wait.value
        XCTAssertNil(row)
        XCTAssertEqual(reads.now, 1)
    }

    func testTheLaunchedCoinsRowIsFoundOnTheBoardOrTheSearchAndNeverAsARetiredCoin() throws {
        let launched = try coin("CNEW", symbol: "NEW")
        let other = try coin("CA1", symbol: "AAA")
        XCTAssertEqual(Board.row("CNEW", in: [Board.Lists(explore: [other, launched])]), launched)
        XCTAssertEqual(Board.row("CNEW", in: [Board.Lists(explore: [other]), Board.Lists(explore: [launched])]), launched, "the search's answer")
        XCTAssertNil(Board.row("CNEW", in: [Board.Lists(explore: [other])]))
        XCTAssertNil(Board.row("COLD", in: [Board.Lists(explore: [try coin("COLD", symbol: "OLD", generation: 1)])]), "never a coin the board doesn't list")
    }

    func testDoneAfterALaunchOpensTheNewCoinsPageOverTheBoard() throws {
        let text = try source("StellarLaunchpadView.swift")
        XCTAssertTrue(text.contains("StellarCreateLaunchView { token in"), "Create hands the board the coin it launched")
        XCTAssertTrue(text.contains("if let token { launchedToken = token }"))
        XCTAssertTrue(text.contains(".task(id: launchedToken) { await openLaunched() }"), "the board waits for its row, then opens its page")
        XCTAssertTrue(text.contains("open(StellarLaunchBoardModel.launchedPage(token, row: row))"))
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
        let claims = StellarLaunchClaim.claims(mine, states: states, fresh: Set(states.keys), mineCurrent: true, code: { $0 })
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
        XCTAssertTrue(claims.allSatisfy(\.current), "every figure is the latest read's")
    }

    func testAV2CoinsCreatorFeesUseTheServersFigureWhileItsStateIsUnread() throws {
        let mine = try mine(held: [], created: [("CV2MINE", "MINE", 2, "1000000")])
        let claims = StellarLaunchClaim.claims(mine, states: [:], fresh: [], mineCurrent: true, code: { $0 })
        XCTAssertEqual(claims.map(\.id), ["creator-CV2MINE"])
        XCTAssertEqual(claims.first?.usd, 0.5)
        XCTAssertEqual(claims.first?.current, true, "the latest read's server figure; the review checks who the plan pays")
        XCTAssertTrue(StellarLaunchClaim.claims(try self.mine(held: [], created: [("CV2MINE", "MINE", 2, "0")]), states: [:], fresh: [], mineCurrent: true,
                                                code: { $0 }).isEmpty,
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

    func testClaimsFromAnEarlierReadSayAsLastReadAndStayOutOfClaimAll() throws {
        let mine = try mine(held: [("CV2HELD", "HELD", 2)], created: [("CV2MINE", "MINE", 2, "1000000"), ("CV1MINE", "OLDM", 1, "2500000")])
        let states = ["CV2MINE": try state("CV2MINE", creatorFees: "3000000"), "CV2HELD": try state("CV2HELD", pendingQuote: "4000000")]
        // CV2HELD's state is kept from an earlier load (its read failed this time); CV2MINE's was read now.
        let claims = StellarLaunchClaim.claims(mine, states: states, fresh: ["CV2MINE"], mineCurrent: true, code: { $0 })
        XCTAssertEqual(claims.map(\.id), ["creator-CV2MINE", "creator-CV1MINE", "rewards-CV2HELD"])
        XCTAssertEqual(claims.map(\.current), [true, true, false])
        XCTAssertEqual(StellarLaunchClaim.claimAll(claims).map(\.id), ["creator-CV2MINE", "creator-CV1MINE"], "Claim All sends the latest read's claims only")
        // What was saved, or what stays after a read that failed: nothing is the latest read's.
        let saved = StellarLaunchClaim.claims(mine, states: states, fresh: [], mineCurrent: false, code: { $0 })
        XCTAssertEqual(saved.map(\.id), claims.map(\.id), "still listed, each claimable on its own row")
        XCTAssertTrue(StellarLaunchClaim.claimAll(saved).isEmpty)
    }

    func testOwedFeesAreTheLatestReadsFigureForTheirAsset() throws {
        let mine = try mine(held: [("CV2A", "AAA", 2)], created: [("CV2B", "BBB", 2, "0")])
        // An earlier read said 0.07 XLM owed; this load read 0 through another coin of the same quote: nothing owed now.
        let none = StellarLaunchClaim.claims(mine, states: ["CV2A": try state("CV2A", owed: "700000"), "CV2B": try state("CV2B", owed: "0")],
                                             fresh: ["CV2B"], mineCurrent: true, code: { $0 })
        XCTAssertTrue(none.isEmpty)
        // Only the earlier read knows: listed as last read.
        let kept = StellarLaunchClaim.claims(mine, states: ["CV2A": try state("CV2A", owed: "700000")], fresh: [], mineCurrent: true, code: { $0 })
        XCTAssertEqual(kept.map(\.id), ["owed-\(Self.xlm)"])
        XCTAssertEqual(kept.first?.current, false)
    }

    func testAClaimsReviewShowsWhatItsPlanPaysAndToWhom() throws {
        let creator = StellarLaunchClaim(kind: .creator(token: "CA1", symbol: "ECAT", retired: false), amount: "9 XLM", usd: nil, current: false)
        let built: [String: StellarJSON] = ["generation": .number(2), "token": .string("CA1"), "symbol": .string("ECAT"), "quote": .string("XLM"),
                                            "amount": .string("3000000"), "to": .string(Self.me)]
        XCTAssertEqual(creator.amount(in: built), StellarFormat.amount(3_000_000, code: "XLM"), "the plan's figure, not the row's older one")
        XCTAssertEqual(creator.payee(in: built, account: Self.me), Self.me)
        XCTAssertNil(creator.refusal(in: built, account: Self.me))
        var elsewhere = built
        elsewhere["to"] = .string(Self.someoneElse)
        XCTAssertEqual(creator.payee(in: elsewhere, account: Self.me), Self.someoneElse, "the fee recipient the plan pays")
        XCTAssertNotNil(creator.refusal(in: elsewhere, account: Self.me), "someone else's payout, at the account's network fee: refused")
        XCTAssertNil(creator.amount(in: nil))
        XCTAssertNil(creator.amount(in: ["amount": .null, "quote": .string("XLM")]), "an older server's plan: the row's figure stays")

        let rewards = StellarLaunchClaim(kind: .rewards(token: "CA1", symbol: "ECAT"), amount: "1 XLM", usd: nil, current: true)
        let pending: [String: StellarJSON] = ["quote": .string("XLM"), "symbol": .string("ECAT"), "pendingQuote": .string("4000000"),
                                              "pendingToken": .string("120000000000")]
        XCTAssertEqual(rewards.amount(in: pending), "\(StellarFormat.units(4_000_000, compact: true)) XLM + \(StellarFormat.units(120_000_000_000, compact: true)) ECAT")
        XCTAssertEqual(rewards.payee(in: pending, account: Self.me), Self.me, "claim(user) pays the account that claims")
        XCTAssertNil(rewards.refusal(in: pending, account: Self.me))

        let owed = StellarLaunchClaim(kind: .owed(asset: try state("CA1").quote, units: 1), amount: "0 XLM", usd: nil, current: true)
        let owedPlan: [String: StellarJSON] = ["asset": .string("XLM"), "assetContract": .string(Self.xlm), "amount": .string("700000"), "to": .string(Self.me)]
        XCTAssertEqual(owed.amount(in: owedPlan), StellarFormat.amount(700_000, code: "XLM"))
        XCTAssertEqual(owed.payee(in: owedPlan, account: Self.me), Self.me)
    }

    func testMyLaunchpadReadsAFewCoinsStatesAtATime() async throws {
        let tokens = (1...10).map { "CA\($0)" }
        let read = try state("CA1")
        let gauge = Gauge()
        let result = await StellarLaunchpadProfileModel.readStates(tokens, limit: 3) { token in
            gauge.enter()
            defer { gauge.leave() }
            try await Task.sleep(for: .milliseconds(5))
            if token == "CA4" { throw URLError(.timedOut) }
            return token == "CA5" ? nil : read
        }
        XCTAssertEqual(gauge.most, 3, "never more than the limit at once")
        XCTAssertEqual(result.read, Set(tokens).subtracting(["CA4"]), "a coin launchpad v2 doesn't know (no state) was read")
        XCTAssertEqual(Set(result.states.keys), Set(tokens).subtracting(["CA4", "CA5"]))
        XCTAssertEqual(StellarLaunchpadProfileModel.stateReadLimit, 4)
    }

    // MARK: - Claim All

    private typealias ClaimAll = StellarClaimAllModel<FakePlan>

    private func claim(_ token: String, _ symbol: String) -> StellarLaunchClaim {
        StellarLaunchClaim(kind: .creator(token: token, symbol: symbol, retired: false), amount: "1 XLM", usd: nil, current: true)
    }

    private var threeClaims: [StellarLaunchClaim] { [claim("CA1", "AAA"), claim("CA2", "BBB"), claim("CA3", "CCC")] }

    private func claimAll(_ script: ClaimScript, estimate: Int64? = nil) -> ClaimAll {
        ClaimAll(claims: threeClaims, account: Self.me, build: { try script.build($0) }, estimate: { _ in estimate })
    }

    func testClaimAllBuildsEveryClaimForTheReviewAndSetsAsideTheOnesThatCantGo() async {
        let script = ClaimScript()
        script.buildFailures["creator-CA2"] = URLError(.timedOut)
        script.payees["creator-CA3"] = Self.someoneElse
        let model = claimAll(script)
        await model.prepare()
        XCTAssertEqual(script.log, ["build AAA", "build BBB", "build CCC"], "each plan, in order")
        XCTAssertEqual(model.pending.map(\.subject), ["AAA"], "Claim All goes on with the claims that can go")
        XCTAssertNotNil(model.problems["creator-CA2"], "a plan that couldn't be built says why")
        XCTAssertNotNil(model.problems["creator-CA3"], "a plan that pays someone else is set aside")
        XCTAssertEqual(model.amount(model.claims[0]), StellarFormat.amount(5_000_000, code: "XLM"), "what the plan pays")
        // Try Again builds only the claims set aside.
        script.buildFailures = [:]
        script.payees = [:]
        script.log = []
        await model.prepare()
        XCTAssertEqual(script.log, ["build BBB", "build CCC"])
        XCTAssertEqual(model.pending.map(\.subject), ["AAA", "BBB", "CCC"])
        XCTAssertTrue(model.problems.isEmpty)
    }

    func testClaimAllSendsTheFirstPlanAsBuiltAndBuildsEachLaterOneAgainJustBeforeIt() async {
        let script = ClaimScript()
        let model = claimAll(script)
        await model.prepare()
        script.log = []
        await model.confirm(send: { await script.send($0, $1) })
        // A plan built before AAA's transaction holds the sequence number AAA used: each later claim is built again.
        XCTAssertEqual(script.log, ["send AAA#1", "build BBB", "send BBB#2", "build CCC", "send CCC#2"])
        XCTAssertTrue(model.isDone)
        XCTAssertEqual(model.settled, ["creator-CA1", "creator-CA2", "creator-CA3"])
    }

    func testClaimAllCarriesOnFromAFailedClaimWithAFreshPlanAndNeverResendsASettledOne() async {
        let script = ClaimScript()
        script.outcomes["creator-CA2"] = [.failed("Unlock was cancelled.", reachedNetwork: false)]
        let model = claimAll(script)
        await model.prepare()
        script.log = []
        await model.confirm(send: { await script.send($0, $1) })
        XCTAssertEqual(script.log, ["send AAA#1", "build BBB", "send BBB#2"], "a failure stops the run there")
        XCTAssertEqual(model.failure, ClaimAll.Failure(id: "creator-CA2", message: "Unlock was cancelled.", reachedNetwork: false))
        XCTAssertEqual(model.pending.map(\.subject), ["BBB", "CCC"])
        XCTAssertFalse(model.isDone)
        script.log = []
        await model.confirm(send: { await script.send($0, $1) })
        XCTAssertEqual(script.log, ["build BBB", "send BBB#3", "build CCC", "send CCC#2"], "carries on from the failed claim, built afresh")
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.isDone)
    }

    func testClaimAllNeverSendsAgainAClaimThatReachedTheNetwork() async {
        let script = ClaimScript()
        script.outcomes["creator-CA2"] = [.failed("BBB failed on the network.", reachedNetwork: true)]
        let model = claimAll(script)
        await model.prepare()
        await model.confirm(send: { await script.send($0, $1) })
        XCTAssertTrue(model.stopped)
        script.log = []
        await model.confirm(send: { await script.send($0, $1) })
        await model.prepare()
        XCTAssertEqual(script.log, [], "the sheet only closes")
        XCTAssertEqual(model.settled, ["creator-CA1"])
    }

    func testAClaimBuiltAgainAboveTheFeeTheReviewShowedIsSetAsideAndTheOthersGo() async {
        let script = ClaimScript()
        script.fees["creator-CA2"] = [10_000, 20_000]
        let strict = claimAll(script)
        await strict.prepare()
        XCTAssertEqual(strict.cap("creator-CA2"), 10_000, "without an estimate, the plan's own fee")
        script.log = []
        await strict.confirm(send: { await script.send($0, $1) })
        XCTAssertEqual(script.log, ["send AAA#1", "build BBB", "build CCC", "send CCC#2"], "BBB is never sent above what was confirmed")
        XCTAssertNotNil(strict.problems["creator-CA2"])
        XCTAssertTrue(strict.isDone, "the others went through; BBB can be tried again")

        // With the kind's estimate the review showed "Up to" that estimate: the rebuilt plan fits under it.
        let other = ClaimScript()
        other.fees["creator-CA2"] = [10_000, 20_000]
        let estimated = claimAll(other, estimate: 500_000)
        await estimated.prepare()
        XCTAssertEqual(estimated.cap("creator-CA2"), 500_000)
        XCTAssertEqual(estimated.caps, [500_000, 500_000, 500_000])
        await estimated.confirm(send: { await other.send($0, $1) })
        XCTAssertEqual(estimated.settled.count, 3)
    }

    func testClaimAllsShortageCountsEachClaimsMostAndTheReserves() {
        let position = XLMReserve(balance: 10_900_000, baseReserve: 5_000_000)
        let short = StellarXLMShortage.of(claims: [500_000, 500_000], reserves: 0, position: position)
        XCTAssertEqual(short, StellarXLMShortage(fee: true, need: 1_000_000, spendable: 900_000, minBalance: 10_000_000))
        XCTAssertNil(StellarXLMShortage.of(claims: [500_000, 400_000], reserves: 0, position: position))
        XCTAssertEqual(StellarXLMShortage.of(claims: [400_000], reserves: 1, position: position)?.fee, false, "the fees fit, the reserve doesn't")
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

/// A claim plan as Claim All's tests build it: which build of its claim it was, and its fee.
private struct FakePlan: StellarClaimPlan, Equatable {
    let build: Int
    let claimDisplay: [String: StellarJSON]?
    let claimFee: Int64
    var claimStepKind: String? = "launch_v2_claim"
    var claimSteps = 1
    var claimReserves = 0
}

/// What Claim All's tests answer each build and send with, and the order they came in.
@MainActor
private final class ClaimScript {
    var log: [String] = []
    var builds: [String: Int] = [:]
    var buildFailures: [String: Error] = [:]
    /// Each build's fee, by claim, in order (the last repeats); 10,000 stroops otherwise.
    var fees: [String: [Int64]] = [:]
    var payees: [String: String] = [:]
    /// Each send's outcome, by claim, in order; settled once these run out.
    var outcomes: [String: [StellarClaimAllModel<FakePlan>.Outcome]] = [:]

    func build(_ claim: StellarLaunchClaim) throws -> FakePlan {
        let count = (builds[claim.id] ?? 0) + 1
        builds[claim.id] = count
        log.append("build \(claim.subject)")
        if let error = buildFailures[claim.id] { throw error }
        let fee = fees[claim.id].map { $0[min(count - 1, $0.count - 1)] } ?? 10_000
        let display: [String: StellarJSON] = ["quote": .string("XLM"), "amount": .string("5000000"),
                                              "to": .string(payees[claim.id] ?? "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN")]
        return FakePlan(build: count, claimDisplay: display, claimFee: fee)
    }

    func send(_ claim: StellarLaunchClaim, _ plan: FakePlan) async -> StellarClaimAllModel<FakePlan>.Outcome {
        log.append("send \(claim.subject)#\(plan.build)")
        guard var queue = outcomes[claim.id], !queue.isEmpty else { return .settled }
        let outcome = queue.removeFirst()
        outcomes[claim.id] = queue
        return outcome
    }
}

/// How many reads run at once, and the most that ever did.
@MainActor
private final class Gauge {
    private(set) var now = 0
    private(set) var most = 0

    func enter() {
        now += 1
        most = max(most, now)
    }

    func leave() { now -= 1 }
}
