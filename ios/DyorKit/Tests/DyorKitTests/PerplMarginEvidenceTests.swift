import XCTest
@testable import DyorKit

/// Add Margin over Perpl's trading connection (p4 spec A.4.3, R.1.6, R.1.7): what the chain, or a growth reported without the
/// request's id, may say of one request. A fill moves the collateral too, and so does every other margin request: only an
/// unambiguous change is this request's, and one deposit is never credited to two requests.
final class PerplMarginEvidenceTests: XCTestCase {
    private let lotDecimals = 5

    private func position(size: Double = 0.002, margin: Double, side: PositionSide = .long, perpId: Int = 1) -> PerpPosition {
        PerpPosition(perpId: perpId, symbol: "BTC", side: side, size: size, entry: 80_000, mark: 80_000, margin: margin, unrealized: 0, premium: 0,
                     leverage: 5, liquidation: nil, notional: size * 80_000)
    }

    /// The position's collateral grown by the amount, its size as it was: added. Grown by the amount with the size doubled (a
    /// fill brought its own collateral): not this request's, and the chain can't tell it any more.
    func testTheChainCreditsOnlyAnUnmovedPositionGrownByTheAmount() {
        let before = position(margin: 32)
        XCTAssertTrue(PerplMarginEvidence.chainShows([position(margin: 64)], before: before, amount: 32, lotDecimals: lotDecimals))
        XCTAssertTrue(PerplMarginEvidence.chainShows([position(margin: 64.009)], before: before, amount: 32, lotDecimals: lotDecimals), "to the cent")

        // Margin +32 with the size doubled must not read as added.
        let doubled = [position(size: 0.004, margin: 64)]
        XCTAssertFalse(PerplMarginEvidence.chainShows(doubled, before: before, amount: 32, lotDecimals: lotDecimals))
        XCTAssertTrue(PerplMarginEvidence.sizeMoved(in: doubled, before: before, lotDecimals: lotDecimals))
        // One lot more is a fill too.
        XCTAssertFalse(PerplMarginEvidence.chainShows([position(size: 0.00201, margin: 64)], before: before, amount: 32, lotDecimals: lotDecimals))
        // At least the amount is not enough: two deposits, or a fill's collateral, are not this one.
        XCTAssertFalse(PerplMarginEvidence.chainShows([position(margin: 96)], before: before, amount: 32, lotDecimals: lotDecimals))
        XCTAssertFalse(PerplMarginEvidence.chainShows([position(margin: 63.9)], before: before, amount: 32, lotDecimals: lotDecimals))
        // Another side, another market, or no position: nothing.
        XCTAssertFalse(PerplMarginEvidence.chainShows([position(margin: 64, side: .short)], before: before, amount: 32, lotDecimals: lotDecimals))
        XCTAssertTrue(PerplMarginEvidence.sizeMoved(in: [position(margin: 64, side: .short)], before: before, lotDecimals: lotDecimals))
        XCTAssertFalse(PerplMarginEvidence.chainShows([position(margin: 64, perpId: 2)], before: before, amount: 32, lotDecimals: lotDecimals))
        XCTAssertFalse(PerplMarginEvidence.chainShows([], before: before, amount: 32, lotDecimals: lotDecimals))
        XCTAssertFalse(PerplMarginEvidence.sizeMoved(in: [], before: before, lotDecimals: lotDecimals), "a read without the market says nothing")
        XCTAssertFalse(PerplMarginEvidence.sizeMoved(in: [position(margin: 40)], before: before, lotDecimals: lotDecimals))
    }

    /// Another margin request on the market makes the evidence ambiguous while it is being sent, waited for or re-checked, and
    /// once its result came in after this request's "before" was read; one decided well before it does not; nor does one on
    /// another market, or this request itself.
    func testAnotherMarginRequestMakesItAmbiguous() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let mine = UUID(), other = UUID()
        func ambiguous(_ request: PerplMarginEvidence.Request, since: Date?) -> Bool {
            PerplMarginEvidence.otherMargin(than: mine, on: 1, since: since, among: [mine: .init(marketId: 1, startedAt: t0), other: request])
        }
        XCTAssertFalse(PerplMarginEvidence.otherMargin(than: mine, on: 1, since: t0, among: [mine: .init(marketId: 1, startedAt: t0)]), "itself")
        XCTAssertTrue(ambiguous(.init(marketId: 1, startedAt: t0.addingTimeInterval(-600)), since: t0), "an earlier one still open")
        XCTAssertTrue(ambiguous(.init(marketId: 1, startedAt: t0.addingTimeInterval(30)), since: t0), "a later one in flight")
        XCTAssertTrue(ambiguous(.init(marketId: 1, startedAt: t0.addingTimeInterval(30), settledAt: t0.addingTimeInterval(40)), since: t0), "a later one, added")
        XCTAssertTrue(ambiguous(.init(marketId: 1, startedAt: t0.addingTimeInterval(-60), settledAt: t0.addingTimeInterval(-2)), since: t0),
                      "decided as the chain may still trail it")
        XCTAssertFalse(ambiguous(.init(marketId: 1, startedAt: t0.addingTimeInterval(-600), settledAt: t0.addingTimeInterval(-60)), since: t0),
                       "decided well before this one's before")
        XCTAssertTrue(ambiguous(.init(marketId: 1, startedAt: t0.addingTimeInterval(-600), settledAt: t0.addingTimeInterval(-60)), since: nil),
                      "a before read at an unknown time")
        XCTAssertFalse(ambiguous(.init(marketId: 2, startedAt: t0), since: t0), "another market")
    }

    /// A pending request followed by a second add of the same amount: the second is credited by its own report, the first stays
    /// not confirmed — the deposit is counted once — whichever read comes first; with no report of either, neither is credited
    /// from a chain that shows one deposit.
    func testOneDepositIsNeverCountedTwice() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let first = UUID(), second = UUID()
        let before = position(margin: 32)
        let chain = [position(margin: 64)] // one deposit of 32 landed
        var requests: [UUID: PerplMarginEvidence.Request] = [
            first: .init(marketId: 1, startedAt: t0),                          // written at t0, not confirmed: re-checked
            second: .init(marketId: 1, startedAt: t0.addingTimeInterval(60)),  // the same amount, a minute later
        ]
        /// What the app credits from the chain: the position shows it, and no other request could have moved it.
        func chainCredits(_ id: UUID, beforeAt: Date) -> Bool {
            PerplMarginEvidence.chainShows(chain, before: before, amount: 32, lotDecimals: lotDecimals)
                && !PerplMarginEvidence.otherMargin(than: id, on: 1, since: beforeAt, among: requests)
        }
        // Neither has a report of its own: the one deposit the chain shows is credited to neither.
        XCTAssertFalse(chainCredits(first, beforeAt: t0))
        XCTAssertFalse(chainCredits(second, beforeAt: t0.addingTimeInterval(60)))

        // The second's own report says it was added (counted once, here); its result can't change any more.
        var counted = 1
        requests[second]?.settledAt = t0.addingTimeInterval(65)
        // The first, re-checked against the chain on a later read: the second's deposit is in it, so it stays not confirmed.
        if chainCredits(first, beforeAt: t0) { counted += 1 }
        XCTAssertEqual(counted, 1, "the deposit is counted once")
        // A new request while the first is still open: ambiguous. Once the first was given up on well before a request's
        // "before", it no longer makes that one ambiguous.
        XCTAssertFalse(chainCredits(UUID(), beforeAt: t0.addingTimeInterval(600)), "the first is still open")
        requests[first]?.settledAt = t0.addingTimeInterval(3600)
        let third = UUID()
        requests[third] = .init(marketId: 1, startedAt: t0.addingTimeInterval(4000))
        XCTAssertTrue(chainCredits(third, beforeAt: t0.addingTimeInterval(4000)))
    }
}
