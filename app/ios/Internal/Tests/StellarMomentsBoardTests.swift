// The Moments board and My Moments (docs/DESIGN-stellar-parity.md §8.11.1, §8.11.5; docs/DESIGN-stellar-contracts-v2.md
// §21): the filter at the window and completion boundaries, the retired v1 Moments under it at their sold-out and window
// boundaries, no untitled card, art only from DyorHQ's media, the progress a card shows, and My Moments' totals as GET
// /v1/moments/mine and GET /v1/moments/v2/mine state them, its coins and Claim All.
@testable import DyorHQ
import BigInt
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarMomentsBoardTests: XCTestCase {
    // MARK: - The filter (§8.11.1)

    /// A v2 Moment collects until its deadline: at the last second before it, it is under Collecting; at the deadline it
    /// moves to Closed, as the Moment page's phase does (`StellarMomentPhaseV2`).
    func testTheFilterFollowsTheWindowToTheSecond() throws {
        let row = try Self.row(state: "collecting", deadline: Self.deadline)
        let status = try Self.status(state: "collecting")
        let before = Self.deadlineDate.addingTimeInterval(-1)
        for (now, collecting) in [(before, true), (Self.deadlineDate, false), (Self.deadlineDate.addingTimeInterval(60), false)] {
            XCTAssertEqual(StellarMomentFilter.collecting.shows(row, at: now), collecting, "\(now)")
            XCTAssertEqual(StellarMomentFilter.closed.shows(row, at: now), !collecting, "\(now)")
            XCTAssertTrue(StellarMomentFilter.all.shows(row, at: now))
            XCTAssertEqual(StellarMomentPhaseV2(status, now: now).isCollecting, collecting, "the page agrees at \(now)")
            XCTAssertEqual(StellarMomentRowPhase(row, at: now), collecting ? .collecting : .windowClosed)
        }
    }

    /// The collect that completes a Moment (v2's sold-out: no edition cap, a threshold) closes it at once, its window
    /// still open: graduation pending, graduated and expired Moments are all Closed.
    func testACompletedMomentIsClosedBeforeItsDeadline() throws {
        let early = Self.deadlineDate.addingTimeInterval(-86_400)
        for state in ["graduation_pending", "graduated", "expired"] {
            let row = try Self.row(state: state, deadline: Self.deadline)
            XCTAssertFalse(StellarMomentFilter.collecting.shows(row, at: early), state)
            XCTAssertTrue(StellarMomentFilter.closed.shows(row, at: early), state)
            XCTAssertFalse(StellarMomentPhaseV2(try Self.status(state: state), now: early).isCollecting, "the page agrees for \(state)")
        }
        XCTAssertEqual(StellarMomentRowPhase(try Self.row(state: "graduation_pending", deadline: Self.deadline), at: early), .graduating)
        XCTAssertEqual(StellarMomentRowPhase(try Self.row(state: "graduated", deadline: Self.deadline), at: early), .graduated)
        XCTAssertEqual(StellarMomentRowPhase(try Self.row(state: "expired", deadline: Self.deadline), at: early), .expired)
    }

    /// A retired v1 Moment is never collected here: whatever `StellarMomentState` says at its sold-out and window
    /// boundaries, it is under All and Closed, never Collecting.
    func testARetiredMomentIsClosedAtEveryBoundary() throws {
        let before = Self.deadlineDate.addingTimeInterval(-1)
        let cases: [(maxEditions: Int, minted: Int, now: Date, state: StellarMomentState)] = [
            (10, 9, before, .collecting),
            (10, 10, before, .soldOut),
            (10, 9, Self.deadlineDate, .windowClosed),
            (10, 10, Self.deadlineDate, .soldOut),
            (0, 1_000, before, .collecting),
        ]
        for c in cases {
            let moment = try Self.retired(maxEditions: c.maxEditions, minted: c.minted)
            XCTAssertEqual(StellarMomentState(moment, now: c.now), c.state, "\(c)")
            XCTAssertFalse(StellarMomentFilter.collecting.shows(retired: moment), "\(c)")
            XCTAssertTrue(StellarMomentFilter.closed.shows(retired: moment), "\(c)")
            XCTAssertTrue(StellarMomentFilter.all.shows(retired: moment), "\(c)")
        }
    }

    /// A deadline the phone can't read leaves the indexer's own `open` to say.
    func testAnUnreadableDeadlineFallsBackToTheIndexer() throws {
        XCTAssertTrue(StellarMomentFilter.isCollecting(try Self.row(state: "collecting", deadline: "soon", open: true), at: Self.deadlineDate))
        XCTAssertFalse(StellarMomentFilter.isCollecting(try Self.row(state: "collecting", deadline: "soon", open: false), at: Self.deadlineDate))
    }

    // MARK: - Cards (§8.11.1)

    func testNoUntitledMomentIsListed() throws {
        let titled = try Self.row(title: "Harbour at dusk", name: "Dusk")
        let nameOnly = try Self.row(title: nil, name: "Dusk")
        // A title of blanks and a line break (written escaped, as JSON carries it).
        let blank = try Self.row(title: #"  \n"#, name: " ")
        XCTAssertEqual(StellarMomentBoard.visible([titled, nameOnly, blank]).map(StellarMomentBoard.title), ["Harbour at dusk", "Dusk"])
        let retired = [try Self.retired(title: "Makola"), try Self.retired(title: nil), try Self.retired(title: " ")]
        XCTAssertEqual(StellarMomentBoard.visible(retired: retired).map(StellarMomentBoard.title), ["Makola"])
    }

    /// A card's art loads only from DyorHQ's own uploads under the build's pinned media base; a poster anywhere else
    /// draws the letters.
    func testACardsArtComesOnlyFromDyorHQsMedia() throws {
        let base = try XCTUnwrap(URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/"))
        let upload = "\(base.absoluteString)uploads/\(Self.creator)/41019444-f54f-4a9e-ac88-2667a92257fa.jpg"
        let own = try Self.row(poster: upload)
        XCTAssertEqual(StellarImages.sources(own.image, pointSize: 170, mediaBase: base, renderBase: nil).map(\.url.absoluteString), [upload])
        for elsewhere in ["https://example.com/uploads/\(Self.creator)/41019444-f54f-4a9e-ac88-2667a92257fa.jpg",
                          "\(base.absoluteString)launches/\(Self.creator)/41019444-f54f-4a9e-ac88-2667a92257fa.jpg",
                          "\(base.absoluteString)uploads/\(Self.creator)/41019444-f54f-4a9e-ac88-2667a92257fa.jpg?x=1"] {
            XCTAssertEqual(StellarImages.sources(try Self.row(poster: elsewhere).image, pointSize: 170, mediaBase: base, renderBase: nil), [], elsewhere)
        }
    }

    func testACardShowsItsProgressUntilItGraduates() throws {
        let row = try Self.row(state: "collecting", progress: 0.756)
        XCTAssertEqual(StellarMomentBoard.percent(row), 75, "whole percent, rounded down")
        XCTAssertEqual(StellarMomentBoard.percent(try Self.row(progress: 1.4)), 100)
        XCTAssertTrue(StellarMomentBoard.showsProgress(row))
        XCTAssertTrue(StellarMomentBoard.showsProgress(try Self.row(state: "graduation_pending", progress: 1)))
        XCTAssertFalse(StellarMomentBoard.showsProgress(try Self.row(state: "graduated", progress: 1)))
        XCTAssertFalse(StellarMomentBoard.showsProgress(try Self.row(state: "expired", progress: 0.4)))
        XCTAssertEqual(StellarMomentBoard.editions(try Self.retired(maxEditions: 10, minted: 3)), "3/10")
        XCTAssertEqual(StellarMomentBoard.editions(try Self.retired(maxEditions: 0, minted: 3)), "3")
    }

    // MARK: - My Moments (§8.11.5, contracts v2 §21)

    /// Each route's totals alone are the tiles' figures: GET /v1/moments/mine for the retired Moments, GET
    /// /v1/moments/v2/mine for v2's.
    func testTheTilesAreEachMyMomentsRoutesTotals() throws {
        let legacy = try JSONDecoder().decode(StellarMomentsMine.self, from: Data(Self.mine.utf8))
        let retired = StellarMyMomentsModel.HistoryTotals(v2: nil, v1: legacy.totals)
        XCTAssertEqual([retired.editions, retired.moments], [legacy.totals.editions, legacy.totals.moments])
        XCTAssertEqual(retired.spent, "\(StellarFormat.units("30000000")) USDC · \(StellarFormat.units("125000000")) XLM")
        XCTAssertEqual(retired.earned, "\(StellarFormat.units("95000000")) XLM")
        let mine = try JSONDecoder().decode(StellarMyMomentsV2.self, from: Data(try Self.mineV2().utf8))
        let live = StellarMyMomentsModel.HistoryTotals(v2: mine.totals, v1: nil)
        XCTAssertEqual([live.editions, live.moments], [mine.totals.editions, mine.totals.moments])
        XCTAssertEqual(live.spent, "\(StellarFormat.units("350000000")) USDC")
        XCTAssertEqual(live.earned, "\(StellarFormat.units("200000000")) USDC")
    }

    /// Both generations together: editions and Moments added up, and what was spent and earned added up per quote.
    func testTheTilesAddBothGenerationsUp() throws {
        let legacy = try JSONDecoder().decode(StellarMomentsMine.self, from: Data(Self.mine.utf8))
        let mine = try JSONDecoder().decode(StellarMyMomentsV2.self, from: Data(try Self.mineV2().utf8))
        let totals = StellarMyMomentsModel.HistoryTotals(v2: mine.totals, v1: legacy.totals)
        XCTAssertEqual(totals.editions, 3 + 1)
        XCTAssertEqual(totals.moments, 2 + 1)
        XCTAssertEqual(totals.spentByQuote, ["USDC": 380_000_000, "XLM": 125_000_000])
        XCTAssertEqual(totals.earnedByQuote, ["USDC": 200_000_000, "XLM": 95_000_000])
        XCTAssertEqual(totals.spent, "\(StellarFormat.units("380000000")) USDC · \(StellarFormat.units("125000000")) XLM")
        XCTAssertTrue(totals.hasAny)
        XCTAssertFalse(StellarMyMomentsModel.HistoryTotals(v2: nil, v1: nil).hasAny)
        XCTAssertEqual(StellarMyMomentsModel.HistoryTotals.written([:]), "0")
        XCTAssertEqual(StellarMyMomentsModel.HistoryTotals.written(["XLM": 0]), "0", "a zero amount isn't listed")
        let unknown = StellarMyMomentsModel.HistoryTotals.written([Self.nftA: 10_000_000])
        XCTAssertEqual(unknown, "\(StellarFormat.units("10000000")) \(try XCTUnwrap(StellarAccountID(Self.nftA)).short)", "an asset the API doesn't know, by its contract shortened")
    }

    /// The tiles wait for both histories; a passkey account with no session is offered its passkey rather than an error,
    /// and a network without one generation counts the other alone.
    func testTheTilesWaitForBothHistories() throws {
        let legacy = try JSONDecoder().decode(StellarMomentsMine.self, from: Data(Self.mine.utf8))
        let mine = try JSONDecoder().decode(StellarMyMomentsV2.self, from: Data(try Self.mineV2().utf8))
        typealias Model = StellarMyMomentsModel
        XCTAssertEqual(Model.history(v2: .needsSignIn, v1: .failed("offline")), .needsSignIn)
        XCTAssertEqual(Model.history(v2: .read(mine), v1: .needsSignIn), .needsSignIn)
        XCTAssertEqual(Model.history(v2: .read(mine), v1: .failed("offline")), .failed("offline"))
        XCTAssertEqual(Model.history(v2: .read(mine), v1: .unread), .unread)
        XCTAssertEqual(Model.history(v2: .read(mine), v1: .absent), .read(Model.HistoryTotals(v2: mine.totals, v1: nil)))
        XCTAssertEqual(Model.history(v2: .absent, v1: .read(legacy)), .read(Model.HistoryTotals(v2: nil, v1: legacy.totals)))
        XCTAssertEqual(Model.history(v2: .read(mine), v1: .read(legacy)), .read(Model.HistoryTotals(v2: mine.totals, v1: legacy.totals)))
    }

    /// Coins across Moments: promised before graduation, claimable, still vesting and claimed after it; none for an
    /// expired Moment, whose coins never exist.
    func testCoinsAcrossMoments() throws {
        let collecting = try Self.holding(nft: Self.nftA, state: "collecting", entitlement: "5000000000")
        let graduated = try Self.holding(nft: Self.nftB, state: "graduated", entitlement: "8000000000")
        let expired = try Self.holding(nft: Self.nftC, state: "expired", entitlement: "9000000000")
        let vesting = try JSONDecoder().decode(StellarMomentVestingV2.self, from: Data(Self.vesting(nft: Self.nftB).utf8))
        let live = StellarMyMomentsModel.Live(holdings: [collecting, graduated, expired], created: [], vesting: [Self.nftB: vesting])
        let coins = StellarMyMomentsModel.coins(live)
        XCTAssertEqual(coins.map(\.nft), [Self.nftA, Self.nftB])
        XCTAssertEqual(coins[0].pending, 5_000_000_000, "promised, not graduated yet: the holding's entitlement while vesting is unread")
        XCTAssertEqual(coins[1].claimable, 2_400_000_000)
        XCTAssertEqual(coins[1].claimed, 2_400_000_000)
        XCTAssertEqual(coins[1].vesting, 3_200_000_000, "8,000 − 4,800 vested")
        let totals = StellarMyMomentsModel.totals(coins)
        XCTAssertEqual(totals, StellarMyMomentsModel.CoinTotals(pending: 5_000_000_000, claimable: 2_400_000_000, vesting: 3_200_000_000, claimed: 2_400_000_000))
        XCTAssertEqual(StellarMyMomentsModel.vestingNFTs(holdings: [collecting, graduated, expired], created: []), [Self.nftA, Self.nftB])
    }

    /// Claim All takes the Moments with coins to claim, the most first, at most the contract's limit per transaction.
    func testClaimAllTakesAtMostTheLimit() {
        let coins = (1...25).map { StellarMyMomentsModel.Coins(nft: "C\($0)", label: "$M\($0)", claimable: BigUInt($0)) }
            + [StellarMyMomentsModel.Coins(nft: "C0", label: "$M0", pending: 7)]
        let batch = StellarMyMomentsModel.batch(coins, max: 20)
        XCTAssertEqual(batch.count, 20)
        XCTAssertEqual(batch.first?.nft, "C25")
        XCTAssertFalse(batch.contains { $0.claimable == 0 }, "nothing with nothing to claim")
        XCTAssertEqual(StellarMyMomentsModel.batch(coins, max: 0).count, 1, "never an empty batch from a bad limit")
    }

    /// A Moment the account published with a creator allocation vests for it too; a published expired one doesn't.
    func testAPublishedMomentsAllocationVests() throws {
        let published = try Self.row(nft: Self.nftA, state: "graduated", allocBps: 1000)
        let none = try Self.row(nft: Self.nftB, state: "graduated", allocBps: 0)
        let gone = try Self.row(nft: Self.nftC, state: "expired", allocBps: 1000)
        XCTAssertEqual(StellarMyMomentsModel.vestingNFTs(holdings: [], created: [published, none, gone]), [Self.nftA])
    }

    func testARetiredEditionOpensInFreighterByItsContract() throws {
        let mine = try JSONDecoder().decode(StellarMomentsMine.self, from: Data(Self.mine.utf8))
        let edition = try XCTUnwrap(StellarMyMomentsModel.freighter(mine.collected[0]))
        XCTAssertEqual(edition.contract.checksummed, Self.nftA)
        XCTAssertEqual(edition.tokenText, "7")
    }

    // MARK: - Fixtures

    static let creator = "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR"
    static let account = "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN"
    static let nftA = "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5"
    static let nftB = "CACB5AH45XMW4BHBYUUPEEZDMXGX5LBBBMSZRBS7YUUXGGQLZVM7FN7Z"
    static let nftC = "CA7D4PR6HY7D4PR6HY7D4PR6HY7D4PR6HY7D4PR6HY7D4PR6HY7D5IR2"
    static let deadline = "2026-10-22T09:00:00.000Z"
    static let deadlineDate = StellarFormat.date(deadline)!

    private static func quoted(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "null" }

    /// A v2 feed row as the API writes it (`GET /v1/moments/v2`).
    static func row(nft: String = StellarMomentsBoardTests.nftA, state: String = "collecting", deadline: String = StellarMomentsBoardTests.deadline, open: Bool = true, title: String? = "Dusk",
                    name: String = "Dusk", poster: String? = nil, progress: Double = 0.5, allocBps: Int = 1000) throws -> StellarMomentRowV2 {
        let json = """
        {"generation":2,"nft":"\(nft)","number":1,"creator":"\(creator)","uri":"https://media.test/m.json","name":"\(name)","symbol":"DUSK",
         "title":\(quoted(title)),"description":null,"place":null,"takenOn":null,"mediaUrl":\(quoted(poster)),"mediaType":"image","posterUrl":\(quoted(poster)),
         "price":"10000000","quote":"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA","quoteCode":"USDC","priceUsd":1,"threshold":"100000000",
         "totalGross":"0","reserve":"0","progress":\(progress),"minted":3,"collects":2,"collectors":2,"creatorAllocBps":\(allocBps),"platformBps":500,
         "royaltyBps":500,"deadline":"\(deadline)","state":"\(state)","open":\(open),"coin":null,"pool":null,
         "durations":{"vestPeriod":604800,"stuckExpiry":604800,"pendingBackstop":2592000,"timelock":172800,"timelockWindow":604800,"minWindow":3600,
          "maxWindow":2592000,"harvestInterval":3600},
         "publishedAt":"2026-10-15T09:41:00.000Z","completedAt":null,"graduatedAt":null,"expiredAt":null}
        """
        return try JSONDecoder().decode(StellarMomentRowV2.self, from: Data(json.utf8))
    }

    /// A v2 Moment's live state (`GET /v1/moments/:nft/status`) with the row's deadline.
    static func status(state: String) throws -> StellarMomentStatusV2 {
        let json = """
        {"generation":2,"nft":"\(nftA)","creator":"\(creator)","coin":"CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6","pool":null,
         "state":"\(state)","price":"10000000","threshold":"100000000","reserve":"0","totalGross":"0","progress":0,"collects":0,"editions":0,
         "entitlements":"0","creatorAllocBps":1000,"creatorBps":2000,"platformBps":500,"reserveBps":7500,"expiryCreatorBps":7000,"royaltyBps":500,
         "rate":{"num":"1","den":"1"},"publishedAt":"2026-10-15T09:41:00.000Z","deadline":"\(deadline)","completedAt":null,"stuckSince":null,
         "graduatedAt":null,"endedAt":null,"expiresAt":null,"expiresBy":null,"backstopAt":null,"failureExpiresAt":null,"expirable":false,
         "graduatable":false,"failure":null,"proceeds":{"creator":"0","platform":"0","treasury":"0"}}
        """
        return try JSONDecoder().decode(StellarMomentStatusV2.self, from: Data(json.utf8))
    }

    /// A retired v1 Moment (`GET /v1/moments`) with the row's deadline.
    static func retired(title: String? = "Makola", maxEditions: Int = 10, minted: Int = 3) throws -> StellarMoment {
        try JSONDecoder().decode(StellarMoment.self, from: Data(retiredJSON(title: title, maxEditions: maxEditions, minted: minted).utf8))
    }

    private static func retiredJSON(id: Int = 4, title: String? = "Makola", maxEditions: Int = 10, minted: Int = 3) -> String {
        """
        {"id":\(id),"creator":"\(creator)","uri":"https://media.test/1.json","title":\(quoted(title)),"mediaUrl":null,"price":"25000000",
         "quote":"CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC","maxEditions":\(maxEditions),"minted":\(minted),"deadline":"\(deadline)",
         "open":true,"createdAt":"2026-10-10T09:00:00.000Z","description":null,"place":null,"takenOn":null,"mediaType":"image","posterUrl":null,
         "quoteCode":"XLM","priceUsd":null,"collects":2,"collectors":2,"state":"collecting","platformBps":500,"royaltyBps":500,"publishedAt":null}
        """
    }

    /// An account's v2 Moment (`GET /v1/moments/v2/owned`).
    static func holding(nft: String, state: String, entitlement: String, editions: [Int] = [3], spent: String? = nil) throws -> StellarMomentHoldingV2 {
        try JSONDecoder().decode(StellarMomentHoldingV2.self, from: Data(try holdingJSON(nft: nft, state: state, entitlement: entitlement, editions: editions, spent: spent).utf8))
    }

    private static func holdingJSON(nft: String, state: String, entitlement: String, editions: [Int], spent: String?) throws -> String {
        let row = String(decoding: try JSONEncoder().encode(try row(nft: nft, state: state)), as: UTF8.self)
        let held = editions.map(String.init).joined(separator: ",")
        return #"{"moment":\#(row),"editions":[\#(held)],"entitlement":"\#(entitlement)","claimed":"0","spent":\#(quoted(spent))}"#
    }

    /// `GET /v1/moments/v2/mine`, as the API's fixture moments-v2-mine.json totals it: one Moment published, editions of
    /// two held.
    static func mineV2() throws -> String {
        let published = String(decoding: try JSONEncoder().encode(try row(nft: nftC, state: "graduated")), as: UTF8.self).dropLast()
        let collected = [try holdingJSON(nft: nftA, state: "collecting", entitlement: "10000000000000", editions: [3], spent: "50000000"),
                         try holdingJSON(nft: nftC, state: "graduated", entitlement: "6000000000", editions: [1, 2], spent: "300000000")]
        return """
        {"created":[\(published),"proceeds":"200000000","proceedsUsd":20,"withdrawn":"150000000"}],"collected":[\(collected.joined(separator: ","))],
         "totals":{"editions":3,"moments":2,"spentByQuote":{"USDC":"350000000"},"earnedByQuote":{"USDC":"200000000"}}}
        """
    }

    /// A graduated Moment's vesting: 8,000 coins promised, 60% vested, 2,400 claimed and 2,400 claimable.
    static func vesting(nft: String) -> String {
        """
        {"generation":2,"nft":"\(nft)","account":"\(account)","coin":"CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6","state":"graduated",
         "vests":true,"vestPeriodSecs":604800,"startsAt":"2026-10-14T11:01:00.000Z","periodsElapsed":0,
         "claimable":{"collector":"2400000000","creator":"0","total":"2400000000"},
         "collector":{"total":"8000000000","claimed":"2400000000","claimable":"2400000000","vested":"4800000000","tranches":[],"nextAt":null,"fullAt":null},
         "creator":null}
        """
    }

    /// `GET /v1/moments/mine` (the retired history).
    static let mine = """
    {"created":[\(retiredJSON(id: 2).dropLast()),"proceeds":"95000000","proceedsUsd":null}],
     "collected":[{"tokenId":7,"momentId":4,"contract":"\(nftA)","moment":\(retiredJSON(id: 4))}],
     "totals":{"editions":1,"moments":1,"spentByQuote":{"XLM":"125000000","USDC":"30000000"},"earnedByQuote":{"XLM":"95000000"}}}
    """
}
