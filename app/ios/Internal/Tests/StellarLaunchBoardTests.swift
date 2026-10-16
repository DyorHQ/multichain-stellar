// Stellar's Launch board and My Launchpad (docs/DESIGN-stellar-parity.md §8.10.1, §8.10.4, §8.10.5; docs/DESIGN-stellar-
// contracts-v2.md §21): the sort chips' server sorts, the server's order and the phone's until it lands (or when a read
// fails), search, every page of a section, launchpad v2's coins only on the board (the retired launchpad's are reached
// from My Launchpad), a launched coin's page opened once the board itself lists it (and never over a page opened
// meanwhile, nor twice), the board's and My Launchpad's reads against a Lite server (no session for the board, the
// passkey offered for My Launchpad, failed reads kept as last read), the cards' market cap, every claim My Launchpad
// offers and whether it is the latest read's, what a claim's plan pays and to whom, Claim All's order (each later claim
// built again before it is sent), its set-aside claims, retries and stop, the state reads a few at a time, the fee tiles
// (Claimable is what the claims pay), and the source rules the board keeps.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarLaunchBoardTests: XCTestCase {
    private typealias Board = StellarLaunchBoardModel

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(BoardStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(BoardStub.self)
        super.tearDown()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static let xlm = BoardJSON.xlm
    private static let me = BoardJSON.me
    private static let someoneElse = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"

    /// A board row as the API writes it.
    private func coinJSON(_ token: String, symbol: String, name: String? = nil, generation: Int? = 2, createdAt: String = "2026-10-15T10:00:00.000Z",
                          progress: Double = 0.2, completed: Bool = false, graduated: Bool = false, phase: String = "curve",
                          marketCapQuote: String? = "41700", marketCapUsd: Double? = nil, quote: String = StellarLaunchBoardTests.xlm, quoteCode: String? = "XLM") -> String {
        BoardJSON.coin(token, symbol: symbol, name: name, generation: generation, createdAt: createdAt, progress: progress, completed: completed,
                       graduated: graduated, phase: phase, marketCapQuote: marketCapQuote, marketCapUsd: marketCapUsd, quote: quote, quoteCode: quoteCode)
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
        try decode(StellarLaunchBoard.self, BoardJSON.page(tokens.map { coinJSON($0, symbol: "S\($0.suffix(1))") }, next: next))
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

    func testDoneAfterALaunchOpensTheNewCoinsPageOnceTheBoardListsIt() async throws {
        let launched = try coin("CNEW", symbol: "NEW")
        let pages = StellarLaunchBoardPages()
        // Create's Done hands the board the coin; the board's task for it waits for its row, then pushes its page.
        pages.launched("CNEW")
        XCTAssertEqual(pages.launchedToken, "CNEW")
        var asked: [String] = []
        await pages.openLaunched { token in
            asked.append(token)
            return launched
        }
        XCTAssertEqual(asked, ["CNEW"])
        XCTAssertEqual(pages.path, [.launch(launched)], "its page, with its row")
        XCTAssertNil(pages.launchedToken, "the wait is over, and so is the board's task for it")
        // Never listed within the board's reads: its page opens by its token, and reads the coin itself.
        let unlisted = StellarLaunchBoardPages()
        unlisted.launched("CNEW")
        await unlisted.openLaunched { _ in nil }
        XCTAssertEqual(unlisted.path, [.token("CNEW")])
        // No coin waiting: nothing is read, nothing opens.
        let idle = StellarLaunchBoardPages()
        await idle.openLaunched { _ in
            XCTFail("no read")
            return nil
        }
        XCTAssertTrue(idle.path.isEmpty)
    }

    func testAPageOpenedOrClosedWhileTheBoardWaitsEndsTheWaitAndNothingMoreOpens() async throws {
        let launched = try coin("CNEW", symbol: "NEW")
        // A card's page, pushed by the stack while the board reads (as the review's View or a notification would).
        let pushed = StellarLaunchBoardPages()
        pushed.launched("CNEW")
        let gate = Gate()
        let wait = Task { @MainActor in await pushed.openLaunched { _ in await gate.pass(); return launched } }
        await gate.arrival()
        pushed.path.append(.token("COTHER"))
        XCTAssertNil(pushed.launchedToken, "the wait ended, and so does the board's task for it")
        gate.open()
        await wait.value
        XCTAssertEqual(pushed.path, [.token("COTHER")], "the new coin's page isn't pushed over it")

        // Back from a page while the board waits: the same.
        let back = StellarLaunchBoardPages()
        back.open(.token("CA1"))
        back.launched("CNEW")
        let backGate = Gate()
        let backWait = Task { @MainActor in await back.openLaunched { _ in await backGate.pass(); return launched } }
        await backGate.arrival()
        back.path = []
        backGate.open()
        await backWait.value
        XCTAssertTrue(back.path.isEmpty)

        // The board's task cancelled (the tab went off screen): nothing opens, and the coin still waits for the task's
        // next run.
        let away = StellarLaunchBoardPages()
        away.launched("CNEW")
        let awayGate = Gate()
        let awayWait = Task { @MainActor in await away.openLaunched { _ in await awayGate.pass(); return launched } }
        await awayGate.arrival()
        awayWait.cancel()
        awayGate.open()
        await awayWait.value
        XCTAssertTrue(away.path.isEmpty)
        XCTAssertEqual(away.launchedToken, "CNEW")
    }

    func testViewThenDoneOpensTheNewCoinsPageOnce() async throws {
        let launched = try coin("CNEW", symbol: "NEW")
        // View in Create's review: its cleanup asks the router for the coin's page, then hands the board the coin, and
        // the board opens the router's page once it sees it. The page is open: nothing waits.
        let view = StellarLaunchBoardPages()
        view.launched("CNEW")
        view.open(.token("CNEW"))
        XCTAssertNil(view.launchedToken)
        await view.openLaunched { _ in
            XCTFail("no read once the page is open")
            return launched
        }
        XCTAssertEqual(view.path, [.token("CNEW")])
        // The router's page first: the coin is on top already, so nothing waits for its row.
        let routed = StellarLaunchBoardPages()
        routed.open(.token("CNEW"))
        routed.launched("CNEW")
        XCTAssertNil(routed.launchedToken)
        // The board listed the coin before the router's page came: its page is on top, never pushed twice.
        let listed = StellarLaunchBoardPages()
        listed.launched("CNEW")
        await listed.openLaunched { _ in launched }
        listed.open(.token("CNEW"))
        XCTAssertEqual(listed.path, [.launch(launched)])
        // Another coin's page still opens over it.
        listed.open(.token("COTHER"))
        XCTAssertEqual(listed.path.map(\.token), ["CNEW", "COTHER"])
    }

    func testAnotherAccountTakingOverClearsThePagesAndTheWait() {
        let pages = StellarLaunchBoardPages()
        pages.open(.token("CA1"))
        pages.launched("CNEW")
        pages.reset()
        XCTAssertTrue(pages.path.isEmpty)
        XCTAssertNil(pages.launchedToken)
    }

    func testTheBoardsStackCreateAndRouterGoThroughItsPages() throws {
        let text = try source("StellarLaunchpadView.swift")
        XCTAssertTrue(text.contains("NavigationStack(path: $pages.path)"), "the stack's path is the pages': any change ends the wait")
        XCTAssertTrue(text.contains("StellarCreateLaunchView { token in"), "Create hands the board the coin it launched")
        XCTAssertTrue(text.contains("if let token { pages.launched(token) }"))
        XCTAssertTrue(text.contains(".task(id: pages.launchedToken) { await openLaunched() }"), "the board's task for the coin, ended with the wait")
        XCTAssertTrue(text.contains("model.launched(token, store: store, sort: request.sort, owner: account.address)"),
                      "the board itself is read for the new coin, never the search on screen")
        XCTAssertTrue(text.contains("pages.open(.token(token))"), "the router's coin opens through the pages")
        XCTAssertTrue(text.contains(".onChange(of: account.address) { _, _ in pages.reset() }"))
        XCTAssertFalse(text.contains("@State private var path"), "one path, the pages'")
    }

    // MARK: - My Launchpad

    /// launchpad-v2's state of a launch in XLM, as the account (the recipient or not) reads it.
    private func state(_ token: String, recipient: String = StellarLaunchBoardTests.me, creatorFees: String = "0", sharing: Bool = true, pendingQuote: String? = "0",
                       pendingToken: String? = "0", owed: String = "0", quote: String = StellarLaunchBoardTests.xlm, code: String = "XLM") throws -> StellarLaunchStateV2 {
        try decode(StellarLaunchStateV2.self, BoardJSON.state(token, recipient: recipient, creatorFees: creatorFees, sharing: sharing, pendingQuote: pendingQuote,
                                                              pendingToken: pendingToken, owed: owed, quote: quote, code: code))
    }

    private func mine(held: [(token: String, symbol: String, generation: Int)], created: [(token: String, symbol: String, generation: Int, unclaimed: String)],
                      byQuote: String = "[]") throws -> StellarMyLaunchpad {
        try decode(StellarMyLaunchpad.self, BoardJSON.mine(held: held, created: created, byQuote: byQuote))
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
        // The creator fees each pays, for the Claimable tile: none for holder rewards.
        XCTAssertEqual(claims.map(\.fee), [StellarLaunchClaim.Fee(quote: "XLM", units: 3_000_000), StellarLaunchClaim.Fee(quote: "XLM", units: 2_500_000), nil,
                                           StellarLaunchClaim.Fee(quote: "XLM", units: 700_000)])
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

    /// A coin's creator fees as My Launchpad's claim row for it pays them.
    private func feeClaim(_ token: String, quote: String, units: Int64, usd: Double?) -> StellarLaunchClaim {
        StellarLaunchClaim(kind: .creator(token: token, symbol: "S\(token.suffix(1))", retired: false), amount: StellarFormat.amount(units, code: quote), usd: usd,
                           current: true, fee: StellarLaunchClaim.Fee(quote: quote, units: units))
    }

    func testTheFeeTilesAddReceivedAndClaimablePerQuoteAsset() throws {
        let fees = try decode(StellarMyLaunchpad.Fees.self, """
            {"byQuote": [{"quote": "XLM", "received": "9300000", "claimable": "700000", "receivedUsd": 0.18, "claimableUsd": 0.02},
                         {"quote": "USDC", "received": "0", "claimable": "15000000", "receivedUsd": null, "claimableUsd": 1.5}]}
            """)
        // The claim rows pay what the server counts.
        let claims = [feeClaim("CA1", quote: "XLM", units: 700_000, usd: 0.02), feeClaim("CA2", quote: "USDC", units: 15_000_000, usd: 1.5)]
        let lines = StellarLaunchFeeLines(fees: fees, claims: claims, code: { $0 })
        XCTAssertEqual(lines.total.map(\.amount), [StellarFormat.amount(10_000_000, code: "XLM"), StellarFormat.amount(15_000_000, code: "USDC")])
        XCTAssertEqual(lines.received.map(\.id), ["XLM", "USDC"], "XLM first, as the server orders them")
        XCTAssertEqual(lines.total.first?.usd ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(lines.total.last?.usd, "a part without a dollar figure leaves the total without one")
        XCTAssertEqual(StellarLaunchFeeLines.usd(lines.claimable) ?? 0, 1.52, accuracy: 1e-9)
        XCTAssertNil(StellarLaunchFeeLines.usd([]))
    }

    func testTheClaimableTileCountsWhatTheAccountCanClaimNowOwedFeesIncluded() throws {
        // Two v2 coins launched in XLM: MINE, whose fee recipient the account still is (0.3 XLM booked), and GONE, whose
        // fees now go to someone else (the server still counts the 0.5 XLM booked for them). 0.07 XLM is owed to the
        // account from before that change.
        let mine = try mine(held: [], created: [("CV2MINE", "MINE", 2, "3000000"), ("CV2GONE", "GONE", 2, "5000000")],
                            byQuote: #"[{"quote": "XLM", "received": "9300000", "claimable": "8000000", "receivedUsd": 0.186, "claimableUsd": 0.16}]"#)
        let states = ["CV2MINE": try state("CV2MINE", creatorFees: "3000000", owed: "700000"),
                      "CV2GONE": try state("CV2GONE", recipient: Self.someoneElse, creatorFees: "5000000", owed: "700000")]
        let claims = StellarLaunchClaim.claims(mine, states: states, fresh: Set(states.keys), mineCurrent: true, code: { $0 })
        XCTAssertEqual(claims.map(\.id), ["creator-CV2MINE", "owed-\(Self.xlm)"])
        let lines = StellarLaunchFeeLines(fees: mine.fees, claims: claims, code: { $0 })
        XCTAssertEqual(lines.claimable.map(\.amount), [StellarFormat.amount(3_700_000, code: "XLM")], "MINE's fees and the owed ones, never GONE's")
        XCTAssertEqual(lines.received.map(\.amount), [StellarFormat.amount(9_300_000, code: "XLM")], "the server's")
        XCTAssertEqual(lines.total.map(\.amount), [StellarFormat.amount(13_000_000, code: "XLM")])
        // Priced at the server's XLM price (0.16 USD for 0.8 XLM).
        XCTAssertEqual(lines.claimable.first?.usd ?? 0, 0.074, accuracy: 1e-9)
        XCTAssertEqual(lines.total.first?.usd ?? 0, 0.26, accuracy: 1e-9)
        // Nothing the account can claim: 0, whatever the server books for another recipient.
        let none = StellarLaunchFeeLines(fees: mine.fees, claims: [], code: { $0 })
        XCTAssertEqual(none.claimable.map(\.amount), [StellarFormat.amount(0, code: "XLM")])
        XCTAssertEqual(none.claimable.first?.usd, 0)
        // Owed fees in a quote asset none of the account's coins uses come after the server's, unpriced.
        let usdc = try state("CA9", quote: "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA", code: "USDC").quote
        let owedUSDC = StellarLaunchClaim(kind: .owed(asset: usdc, units: 20_000_000), amount: "2 USDC", usd: nil, current: true,
                                          fee: StellarLaunchClaim.Fee(quote: "USDC", units: 20_000_000))
        let more = StellarLaunchFeeLines(fees: mine.fees, claims: claims + [owedUSDC], code: { $0 })
        XCTAssertEqual(more.claimable.map(\.id), ["XLM", "USDC"])
        XCTAssertEqual(more.claimable.last?.amount, StellarFormat.amount(20_000_000, code: "USDC"))
        XCTAssertEqual(more.received.last?.amount, StellarFormat.amount(0, code: "USDC"))
        XCTAssertNil(more.claimable.last?.usd, "no price for it")
        XCTAssertNil(more.total.last?.usd)
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

    // MARK: - Reads against a Lite server

    /// A session resumed as an account set up on this iPhone, against `server`: a seed account with its key here, which
    /// signs in silently, or (`seed` nil) an account with no key and no session here, as a passkey account in the public
    /// view, which nothing may prompt.
    private func resumed(_ server: BoardServer, seed: [UInt8]?) async throws -> LiteSession {
        let address = try StellarSigner(seed: seed ?? (0..<32).map { _ in UInt8.random(in: 0...255) }).address
        UserDefaults.standard.set(true, forKey: LiteSession.activatedKey(address))
        addTeardownBlock {
            server.stop()
            StellarKeychain.erase(account: address)
            UserDefaults.standard.removeObject(forKey: LiteSession.activatedKey(address))
        }
        let keys = seed.map { seed in
            GatedSeedKeyProvider(address: address, methodLabel: "Email & Password", network: "testnet", appLockApplies: { false }, seed: { seed })
        }
        let session = LiteSession(env: server.env, stellarAddress: address, monad: nil, keys: keys)
        // The store holds its session weakly: the test holds it until it ends.
        addTeardownBlock { withExtendedLifetime(session) {} }
        await session.resumeAtLaunch()
        return session
    }

    /// The store of a session `resumed` against `server`.
    private func resumedStore(_ server: BoardServer, seed: [UInt8]? = nil) async throws -> LiteStore {
        let session = try await resumed(server, seed: seed)
        return try XCTUnwrap(session.store)
    }

    func testTheBoardReadsEachSectionInFullAndTheTermsWithNoSession() async throws {
        let server = BoardServer { request, _ in
            guard request.path == "/v1/launches" else { return nil }
            switch (request.query["section"], request.query["cursor"]) {
            case ("explore", nil): return (200, BoardJSON.page([BoardJSON.coin("CA1", symbol: "AAA"), BoardJSON.coin("CA2", symbol: "BBB")], next: "page-2"))
            case ("explore", "page-2"): return (200, BoardJSON.page([BoardJSON.coin("CA3", symbol: "CCC")], next: nil))
            case ("graduated", _): return (200, BoardJSON.page([BoardJSON.coin("CG1", symbol: "GRAD", completed: true, graduated: true, phase: "graduated")], next: nil))
            default: return nil
            }
        }
        let store = try await resumedStore(server)
        let model = Board()
        let request = Board.Request(sort: .marketCap, query: nil)
        await model.load(store: store, request: request, owner: nil)
        XCTAssertEqual(model.board.explore.map(\.token), ["CA1", "CA2", "CA3"], "every page, in the server's order")
        XCTAssertEqual(model.board.graduated.map(\.token), ["CG1"])
        XCTAssertEqual(model.boardSort, .marketCap)
        XCTAssertEqual(model.lists(for: request).explore.map(\.token), ["CA1", "CA2", "CA3"], "Market Cap as the server ordered it")
        XCTAssertTrue(model.listed)
        XCTAssertNil(model.error)
        XCTAssertNil(model.savedAt)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.availability, .notDeployed, "launchpad v2's terms were read: this server has no v2 launchpad")
        let reads = server.requests.filter { $0.path == "/v1/launches" }
        XCTAssertEqual(reads.filter { $0.query["section"] == "explore" }.map { $0.query["sort"] }, ["market_cap", "market_cap"])
        XCTAssertEqual(reads.filter { $0.query["section"] == "graduated" }.map { $0.query["sort"] }, ["newest"], "Graduated is newest first")
        XCTAssertTrue(reads.allSatisfy { $0.query["q"] == nil })
        XCTAssertTrue(server.requests.contains { $0.path == "/v1/economics" })
        XCTAssertFalse(server.requests.contains { $0.path.hasPrefix("/v1/auth") }, "a viewer read: no sign-in")
    }

    func testABoardReadThatFailsKeepsTheCoinsShownAndSaysSoUntilOneGoesThrough() async throws {
        // Explore's second read fails; its third goes through.
        let server = BoardServer { request, attempt in
            guard request.path == "/v1/launches" else { return nil }
            if request.query["section"] == "graduated" { return (200, BoardJSON.page([], next: nil)) }
            if attempt == 1 { return (503, BoardJSON.error("rpc_unavailable", "The launches couldn't be read just now.")) }
            return (200, BoardJSON.page(attempt == 0 ? [BoardJSON.coin("CA1", symbol: "AAA")] : [BoardJSON.coin("CA2", symbol: "BBB"), BoardJSON.coin("CA1", symbol: "AAA")], next: nil))
        }
        let store = try await resumedStore(server)
        let model = Board()
        let request = Board.Request(sort: .newest, query: nil)
        await model.load(store: store, request: request, owner: nil)
        XCTAssertEqual(model.board.explore.map(\.token), ["CA1"])
        await model.load(store: store, request: request, owner: nil)
        XCTAssertEqual(model.board.explore.map(\.token), ["CA1"], "the coins shown stay listed")
        XCTAssertNotNil(model.error, "the board says so, with Retry")
        await model.load(store: store, request: request, owner: nil)
        XCTAssertEqual(model.board.explore.map(\.token), ["CA2", "CA1"])
        XCTAssertNil(model.error)
    }

    func testASearchLoadsTheServersAnswerForItsChipAndLeavesTheBoard() async throws {
        let newer = BoardJSON.coin("CC1", symbol: "CAT1", createdAt: "2026-10-15T12:00:00.000Z", marketCapUsd: 10)
        let bigger = BoardJSON.coin("CC2", symbol: "CAT2", createdAt: "2026-10-15T10:00:00.000Z", marketCapUsd: 9_000)
        // "cat" on Newest, then on Market Cap, whose Explore read fails.
        let server = BoardServer { request, _ in
            guard request.path == "/v1/launches" else { return nil }
            if request.query["section"] == "graduated" { return (200, BoardJSON.page([], next: nil)) }
            guard request.query["q"] == "cat" else { return (200, BoardJSON.page([BoardJSON.coin("CA1", symbol: "DOGE")], next: nil)) }
            if request.query["sort"] == "market_cap" { return (503, BoardJSON.error("rpc_unavailable", "The launches couldn't be read just now.")) }
            return (200, BoardJSON.page([newer, bigger], next: nil))
        }
        let store = try await resumedStore(server)
        let model = Board()
        await model.load(store: store, request: Board.Request(sort: .newest, query: nil), owner: nil)
        await model.load(store: store, request: Board.Request(sort: .newest, query: "cat"), owner: nil)
        XCTAssertEqual(model.search?.query, "cat")
        XCTAssertEqual(model.search?.sort, .newest)
        XCTAssertEqual(model.lists(for: Board.Request(sort: .newest, query: "cat")).explore.map(\.token), ["CC1", "CC2"], "the server's answer")
        XCTAssertEqual(model.board.explore.map(\.token), ["CA1"], "the board itself is left as it was")
        await model.load(store: store, request: Board.Request(sort: .marketCap, query: "cat"), owner: nil)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.search?.sort, .newest, "the coins kept are in Newest's order, and say so")
        XCTAssertEqual(model.lists(for: Board.Request(sort: .marketCap, query: "cat")).explore.map(\.token), ["CC2", "CC1"],
                       "under the Market Cap chip, sorted on the phone")
        let searches = server.requests.filter { $0.path == "/v1/launches" && $0.query["q"] == "cat" }
        XCTAssertEqual(searches.map { "\($0.query["section"] ?? "")/\($0.query["sort"] ?? "")" }.sorted(),
                       ["explore/market_cap", "explore/newest", "graduated/newest", "graduated/newest"])
    }

    func testALaunchedCoinIsWaitedForOnTheBoardItselfWhateverTheSearchOnScreen() async throws {
        // The board lists the new coin from its second read; the search on screen ("zzz") never finds it.
        let server = BoardServer { request, attempt in
            guard request.path == "/v1/launches" else { return nil }
            guard request.query["q"] == nil, request.query["section"] == "explore" else { return (200, BoardJSON.page([], next: nil)) }
            let old = BoardJSON.coin("CA1", symbol: "OLD")
            return (200, BoardJSON.page(attempt == 0 ? [old] : [BoardJSON.coin("CNEW", symbol: "NEW"), old], next: nil))
        }
        let store = try await resumedStore(server)
        let model = Board()
        await model.load(store: store, request: Board.Request(sort: .newest, query: "zzz"), owner: nil)
        let before = server.requests.count
        let row = await model.launched("CNEW", store: store, sort: .newest, owner: nil, attempts: 4, pause: .milliseconds(1))
        XCTAssertEqual(row?.token, "CNEW", "found on the board's second read")
        let waits = server.requests.dropFirst(before).filter { $0.path == "/v1/launches" }
        XCTAssertEqual(waits.count, 4, "two reads of both sections")
        XCTAssertTrue(waits.allSatisfy { $0.query["q"] == nil }, "the board itself, never the search")
        XCTAssertEqual(model.search?.query, "zzz", "the search on screen stays")
    }

    func testAFullReadOfTheBoardIsSavedForTheAccountAndShownFirstNextTime() async throws {
        let owner = try XCTUnwrap(Address(data: Data((0..<20).map { _ in UInt8.random(in: 0...255) })))
        addTeardownBlock { StellarSaved.shared.forget(owner) }
        let server = BoardServer { request, _ in
            guard request.path == "/v1/launches" else { return nil }
            return (200, BoardJSON.page(request.query["section"] == "explore" ? [BoardJSON.coin("CA1", symbol: "AAA")] : [], next: nil))
        }
        let store = try await resumedStore(server)
        await Board().load(store: store, request: Board.Request(sort: .marketCap, query: nil), owner: owner)
        // The save is written off the main thread.
        var saved = StellarSaved.shared.load(Board.Saved.self, .launchBoard, owner: owner)
        for _ in 0..<250 where saved == nil {
            try await Task.sleep(for: .milliseconds(20))
            saved = StellarSaved.shared.load(Board.Saved.self, .launchBoard, owner: owner)
        }
        XCTAssertEqual(saved?.value.sort, "market_cap")
        let next = Board()
        next.showSaved(owner: owner)
        XCTAssertEqual(next.board.explore.map(\.token), ["CA1"])
        XCTAssertEqual(next.boardSort, .marketCap)
        XCTAssertNotNil(next.savedAt, "said to be what was saved")
        XCTAssertTrue(next.listed, "never a first-read spinner over it")
    }

    func testMyLaunchpadOffersThePasskeyToAnAccountWithNoSessionNeverAnError() async throws {
        let server = BoardServer()
        let store = try await resumedStore(server)
        let model = StellarLaunchpadProfileModel()
        await model.load(store: store, owner: nil)
        XCTAssertTrue(model.needsSignIn)
        XCTAssertNil(model.error)
        XCTAssertNil(model.mine)
        XCTAssertFalse(model.reading, "nothing waits on a read")
        XCTAssertFalse(server.requests.contains { $0.path == "/v1/launchpad/me" || $0.path.hasPrefix("/v1/auth") }, "nothing is asked of anyone")
    }

    func testMyLaunchpadReadsItsHistoryThenEachV2CoinsStateAndSaysWhichCouldntBeRead() async throws {
        let server = BoardServer { request, attempt in
            switch request.path {
            case "/v1/launchpad/me":
                return (200, BoardJSON.mine(held: [("CV2HELD", "HELD", 2), ("CV1HELD", "OLDH", 1)], created: [("CV2MINE", "MINE", 2, "1000000")]))
            case "/v1/launches/CV2MINE/state":
                return (200, BoardJSON.state("CV2MINE", creatorFees: "3000000", owed: "700000"))
            case "/v1/launches/CV2HELD/state":
                // Its first read fails.
                if attempt == 0 { return (503, BoardJSON.error("rpc_unavailable", "Try again.")) }
                return (200, BoardJSON.state("CV2HELD", pendingQuote: "4000000", owed: "700000"))
            default:
                return nil
            }
        }
        let store = try await resumedStore(server, seed: (0..<32).map { _ in UInt8.random(in: 0...255) })
        let model = StellarLaunchpadProfileModel()
        await model.load(store: store, owner: nil)
        XCTAssertFalse(model.needsSignIn)
        XCTAssertNil(model.error)
        XCTAssertTrue(server.requests.contains { $0.path == "/v1/auth/verify" }, "the seed account signed in silently for its history")
        XCTAssertEqual(model.mine?.created.map(\.launch.token), ["CV2MINE"])
        XCTAssertTrue(model.mineCurrent)
        XCTAssertEqual(model.fresh, ["CV2MINE"])
        XCTAssertEqual(Set(model.states.keys), ["CV2MINE"])
        XCTAssertTrue(model.statesUnread, "holder rewards couldn't be read just now: said, with Retry")
        XCTAssertFalse(server.requests.contains { $0.path == "/v1/launches/CV1HELD/state" }, "the retired launchpad's coins have no v2 state")
        // Read again: every state answers.
        await model.load(store: store, owner: nil)
        XCTAssertFalse(model.statesUnread)
        XCTAssertEqual(model.fresh, ["CV2MINE", "CV2HELD"])
        let claims = StellarLaunchClaim.claims(try XCTUnwrap(model.mine), states: model.states, fresh: model.fresh, mineCurrent: model.mineCurrent, code: { $0 })
        XCTAssertEqual(claims.map(\.id), ["creator-CV2MINE", "rewards-CV2HELD", "owed-\(Self.xlm)"])
        XCTAssertEqual(StellarLaunchClaim.claimAll(claims).map(\.id), claims.map(\.id), "all the latest read's")
    }

    func testAMyLaunchpadReadThatFailsKeepsWhatWasShownAsLastReadAndOutOfClaimAll() async throws {
        // The history's second read fails; on its third, CV2MINE's state read fails.
        let server = BoardServer { request, attempt in
            switch request.path {
            case "/v1/launchpad/me":
                if attempt == 1 { return (503, BoardJSON.error("rpc_unavailable", "Your creator fees couldn't be read just now. Try again.")) }
                return (200, BoardJSON.mine(held: [], created: [("CV2MINE", "MINE", 2, "1000000")]))
            case "/v1/launches/CV2MINE/state":
                if attempt == 1 { return (503, BoardJSON.error("rpc_unavailable", "Try again.")) }
                return (200, BoardJSON.state("CV2MINE", creatorFees: "3000000"))
            default:
                return nil
            }
        }
        let store = try await resumedStore(server, seed: (0..<32).map { _ in UInt8.random(in: 0...255) })
        let model = StellarLaunchpadProfileModel()
        func claims() throws -> [StellarLaunchClaim] {
            StellarLaunchClaim.claims(try XCTUnwrap(model.mine), states: model.states, fresh: model.fresh, mineCurrent: model.mineCurrent, code: { $0 })
        }
        await model.load(store: store, owner: nil)
        XCTAssertEqual(try claims().map(\.current), [true])
        await model.load(store: store, owner: nil)
        XCTAssertNotNil(model.error, "the header says so, with Retry")
        XCTAssertNotNil(model.mine, "what was read stays")
        XCTAssertFalse(model.mineCurrent)
        XCTAssertTrue(model.fresh.isEmpty)
        XCTAssertEqual(try claims().map(\.current), [false], "as last read")
        XCTAssertTrue(StellarLaunchClaim.claimAll(try claims()).isEmpty, "Claim All sends only the latest read's")
        await model.load(store: store, owner: nil)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.mineCurrent)
        XCTAssertTrue(model.statesUnread)
        XCTAssertEqual(model.states["CV2MINE"]?.creatorFees, "3000000", "the state read before stays")
        XCTAssertEqual(try claims().map(\.current), [false], "its claim is as last read")
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

/// Holds a read until the test lets it go.
@MainActor
private final class Gate {
    private var held: CheckedContinuation<Void, Never>?
    private var opened = false

    /// The read's side: waits until `open()`.
    func pass() async {
        guard !opened else { return }
        await withCheckedContinuation { held = $0 }
    }

    /// The test's side: returns once a read waits here.
    func arrival() async {
        for _ in 0..<100_000 where held == nil { await Task.yield() }
    }

    func open() {
        opened = true
        held?.resume()
        held = nil
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

/// The API's JSON for the board's and My Launchpad's tests, as the server writes it.
private enum BoardJSON {
    static let xlm = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
    static let me = "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN"

    /// A board row.
    static func coin(_ token: String, symbol: String, name: String? = nil, generation: Int? = 2, createdAt: String = "2026-10-15T10:00:00.000Z",
                     progress: Double = 0.2, completed: Bool = false, graduated: Bool = false, phase: String = "curve",
                     marketCapQuote: String? = "41700", marketCapUsd: Double? = nil, quote: String = xlm, quoteCode: String? = "XLM") -> String {
        """
        {"token": "\(token)", "creator": "\(me)", "quote": "\(quote)", "name": "\(name ?? symbol.capitalized)", "symbol": "\(symbol)",
         "uri": "", "supply": "10000000000000000", "quoteReserve": "0", "tokenReserve": "0", "realQuote": "0", "threshold": "93000000000",
         "progress": \(progress), "completed": \(completed), "graduated": \(graduated), "volume": "0", "trades": 0, "createdAt": "\(createdAt)",
         "phase": "\(phase)", "quoteCode": \(quoteCode.map { "\"\($0)\"" } ?? "null"), "marketCapQuote": \(marketCapQuote.map { "\"\($0)\"" } ?? "null"),
         "marketCapUsd": \(marketCapUsd.map { "\($0)" } ?? "null"), "generation": \(generation.map(String.init) ?? "null")}
        """
    }

    /// One page of a board section: `rows` (from `coin`), and the next page's cursor.
    static func page(_ rows: [String], next: String?) -> String {
        #"{"launches": [\#(rows.joined(separator: ","))], "nextCursor": \#(next.map { "\"\($0)\"" } ?? "null"), "counts": {"explore": 3, "graduated": 0}, "view": "public"}"#
    }

    /// launchpad-v2's state of a launch, as the account (`me`, the fee recipient or not) reads it.
    static func state(_ token: String, recipient: String = me, creatorFees: String = "0", sharing: Bool = true, pendingQuote: String? = "0",
                      pendingToken: String? = "0", owed: String = "0", quote: String = xlm, code: String = "XLM") -> String {
        let venue = #"{"id": 0, "kind": "Soroswap", "name": "Soroswap", "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526", "enabled": true, "feeFraction": 0}"#
        return """
            {"status": {"token": "\(token)", "phase": "curve", "completedAt": null, "stuck": false, "stuckSince": null, "markStuckAt": null,
                        "fallbackAt": null, "rescueAdminAt": null, "rescuePublicAt": null, "venue": \(venue), "fallback": \(venue), "venueLocked": false,
                        "fallbackAllowed": false, "pool": null, "graduatedVenue": null, "refund": null, "failure": null,
                        "actions": {"buy": true, "sell": true, "graduate": false, "graduateFallback": false, "markStuck": false, "rescue": false, "refund": false}},
             "quote": {"id": "\(code)", "code": "\(code)", "contract": "\(quote)"}, "recipient": "\(recipient)", "pendingTakeover": null,
             "creatorFees": "\(creatorFees)",
             "rewards": {"sharing": \(sharing), "eligible": null, "queuedQuote": "0", "queuedToken": "0", "releasableFromLedger": null,
                         "pendingQuote": \(pendingQuote.map { "\"\($0)\"" } ?? "null"), "pendingToken": \(pendingToken.map { "\"\($0)\"" } ?? "null")},
             "you": {"isRecipient": \(recipient == me), "creatorOwed": "\(owed)"}}
            """
    }

    /// `/v1/launchpad/me`: the coins held and launched (with their creator fees in XLM), the fees by quote asset.
    static func mine(held: [(token: String, symbol: String, generation: Int)], created: [(token: String, symbol: String, generation: Int, unclaimed: String)],
                     byQuote: String = "[]") -> String {
        let heldJSON = held.map { item in
            """
            {"token": "\(item.token)", "balance": "12000000000000", "valueUsd": 9.48, "costBasisQuote": "500000000", "pnlQuote": "-2400000",
             "pnlUsd": -0.02, "onCurve": true, "launch": \(coin(item.token, symbol: item.symbol, generation: item.generation))}
            """
        }.joined(separator: ",")
        let createdJSON = created.map { item in
            """
            {"launch": \(coin(item.token, symbol: item.symbol, generation: item.generation)),
             "creatorFees": {"unclaimed": "\(item.unclaimed)", "claimed": "0", "quote": "XLM", "unclaimedUsd": 0.5, "claimedUsd": 0}}
            """
        }.joined(separator: ",")
        return #"{"held": [\#(heldJSON)], "created": [\#(createdJSON)], "fees": {"byQuote": \#(byQuote)}, "activity": []}"#
    }

    static func error(_ code: String, _ message: String) -> String {
        #"{"error": {"code": "\#(code)", "message": "\#(message)"}}"#
    }
}

/// A Lite server for one of the board's or My Launchpad's tests, on a host of its own under `.stellar-board.test`: the
/// config and fees a session reads as it resumes, launchpad v2's terms (none: this server has no v2 launchpad), a seed
/// account's silent sign-in, and what the test answers (`Answer`); 404 for anything else. It keeps every request.
private final class BoardServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        /// Below the API's base: "/v1/launches".
        let path: String
        let query: [String: String]
        let body: Data?
    }

    /// The test's answer to a request, given how many times the same request (method, path and query) came before: its
    /// status and JSON, or nil for the server's own.
    typealias Answer = @Sendable (Request, Int) -> (status: Int, body: String)?

    let host = "lite-\(UUID().uuidString.lowercased()).stellar-board.test"
    private let answer: Answer
    private let lock = NSLock()
    private var seen: [Request] = []
    private var issued = 0

    init(_ answer: @escaping Answer = { _, _ in nil }) {
        self.answer = answer
        BoardStub.serve(host: host) { [self] in respond($0) }
    }

    var env: LiteEnvironment { LiteEnvironment(apiURL: URL(string: "https://\(host)/lite")!, pinned: .testnet, buildNumber: 1000) }

    /// Every request, in order.
    var requests: [Request] { lock.withLock { seen } }

    func stop() { BoardStub.serve(host: host, nil) }

    private func respond(_ request: Request) -> (status: Int, body: Data) {
        let attempt = lock.withLock {
            let before = seen.filter { $0.method == request.method && $0.path == request.path && $0.query == request.query }.count
            seen.append(request)
            return before
        }
        if case let (status, body)? = answer(request, attempt) { return (status, Data(body.utf8)) }
        switch (request.method, request.path) {
        case ("GET", "/v1/config"): return (200, Data(config.utf8))
        case ("GET", "/v1/fees"): return (200, Data(Self.fees.utf8))
        case ("GET", "/v1/economics"): return (200, Data(#"{"launchpad": null, "moments": null}"#.utf8))
        case ("POST", "/v1/auth/challenge"):
            let address = request.body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["address"] ?? ""
            let nonce = "board-nonce-0123456789"
            let message = ["DyorHQ Lite sign-in", "Network: testnet", "Address: \(address)", "Nonce: \(nonce)", "Issued: \(Self.time(0))"].joined(separator: "\n")
            return (200, Self.json(["nonce": nonce, "message": message, "expiresAt": Self.time(300)]))
        case ("POST", "/v1/auth/verify"):
            let issued = lock.withLock {
                self.issued += 1
                return self.issued
            }
            var session: [String: Any] = ["token": "jwt\(issued)", "expiresAt": Self.time(3600), "refreshToken": "lrt_\(issued)",
                                          "refreshExpiresAt": Self.time(30 * 86_400)]
            session["tester"] = ["address": "G", "label": NSNull()]
            return (200, try! JSONSerialization.data(withJSONObject: session))
        default:
            return (404, Data(BoardJSON.error("not_found", "No such route.").utf8))
        }
    }

    private var config: String {
        """
        {"network":"testnet","passphrase":"Test SDF Network ; September 2015","rpcUrl":"http://127.0.0.1:9/rpc",
         "horizonUrl":"http://127.0.0.1:9/horizon","activation":"friendbot","sponsor":"\(PinnedContracts.testnet.sponsor)",
         "assets":[{"id":"XLM","code":"XLM","name":"Stellar Lumens","decimals":7,"contract":"\(BoardJSON.xlm)","classic":"native","note":null}],
         "contracts":{"launchpad":null,"moments":null,"soroswapRouter":"C","blendPools":[]},"allowlist":{},
         "bridge":{"routes":[],"monad":null},"flags":{"enabled":true},"minBuild":1,"inviteRequired":false,"faucet":{"amount":"10000"}}
        """
    }

    private static let fees = """
        {"network":"testnet","baseReserve":"5000000","baseFee":"100","inclusionFee":{"classic":"100","soroban":"150"},
         "estimates":{"launch_v2_claim":"500000"},"estimateBasis":{},"updatedAt":null}
        """

    private static func json(_ fields: [String: String]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }

    /// `seconds` from now, as the API writes times.
    private static func time(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
    }
}

/// Answers the requests to `.stellar-board.test` hosts (`URLSession.shared`, which `LiteAPI` uses, asks the registered
/// protocols), each with its host's server; every other request goes out as usual.
private final class BoardStub: URLProtocol {
    typealias Handler = @Sendable (BoardServer.Request) -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func serve(host: String, _ handler: Handler?) { lock.withLock { handlers[host] = handler } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".stellar-board.test") ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        let seen = BoardServer.Request(method: request.httpMethod ?? "GET", path: String(url.path.dropFirst("/lite".count)), query: query,
                                       body: Self.body(of: request))
        guard let handler = Self.lock.withLock({ Self.handlers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = handler(seen)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
