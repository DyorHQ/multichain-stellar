import BigInt
import XCTest
@testable import DyorKit

/// A sale into native MON leaves no Transfer log for the MON, so swap history read it as "0 MON" and Portfolio counted the
/// sale as a loss of everything sold. Its MON is the wallet's balance change across the sale's block plus the gas it paid,
/// when the sale is the wallet's only transaction in that block; otherwise it stays unknown, shown without an amount and
/// left out of P&L.
final class SwapHistoryNativeTests: XCTestCase {
    /// A Monday Trade sale on mainnet (0x1dddc64e…, block 110,814,305): the router unwrapped exactly what the balance says.
    func testTheBalanceChangePlusGasIsTheMONReceived() {
        let received = SwapHistoryService.nativeReceived(balanceBefore: BigUInt("22937531073325807685"), balanceAfter: BigUInt("33178486999835627006"),
                                                         gasFee: BigUInt(342_452) * BigUInt(102_000_000_000),
                                                         noncesBefore: 47, noncesAfter: 48)
        XCTAssertEqual(received, BigUInt("10275886030509819321"), "the WMON its router unwrapped for the wallet, to the wei")
    }

    /// Anything else the wallet sent in that block moved its balance too, so the change says nothing about the sale.
    func testAnotherTransactionInTheBlockLeavesItUnknown() {
        XCTAssertNil(SwapHistoryService.nativeReceived(balanceBefore: 100, balanceAfter: 300, gasFee: 10, noncesBefore: 5, noncesAfter: 7))
        XCTAssertNil(SwapHistoryService.nativeReceived(balanceBefore: 100, balanceAfter: 300, gasFee: 10, noncesBefore: 5, noncesAfter: 5))
        XCTAssertNil(SwapHistoryService.nativeReceived(balanceBefore: 300, balanceAfter: 100, gasFee: 10, noncesBefore: 5, noncesAfter: 6), "nothing came in")
        XCTAssertEqual(SwapHistoryService.nativeReceived(balanceBefore: 100, balanceAfter: 300, gasFee: 10, noncesBefore: 5, noncesAfter: 6), 210)
    }

    /// Unknown is not zero: a sale into MON with no amount read is marked so, and only that one.
    func testUnknownMONIsMarked() {
        func record(_ bought: Address, _ amount: BigUInt) -> SwapRecord {
            SwapRecord(hash: Data(repeating: 1, count: 32), block: 1, time: Date(), soldToken: Monad.usdc, soldAmount: 1_000_000,
                       boughtToken: bought, boughtAmount: amount)
        }
        XCTAssertTrue(record(Monad.native, 0).boughtNativeUnknown)
        XCTAssertFalse(record(Monad.native, 5).boughtNativeUnknown)
        XCTAssertFalse(record(Monad.wmon, 0).boughtNativeUnknown)
    }

    /// The app shows an unknown amount as the token alone ("12.82 AUSD → MON") and keeps it out of P&L, which says it is
    /// incomplete; the scan reads the MON of the newest sales in one batch.
    func testTheAppNeverShowsZeroMON() throws {
        let swap = Self.squeezed(try DocsLinksTests.appSource("Swap/SwapView.swift"))
        XCTAssertTrue(swap.contains("let bought = swap.boughtNativeUnknown ? (tokens[swap.boughtToken]?.symbol ?? Token.mon.symbol) : leg(swap.boughtToken, swap.boughtAmount)"))
        let portfolio = Self.squeezed(try DocsLinksTests.appSource("Portfolio/PortfolioModel.swift"))
        XCTAssertTrue(portfolio.contains("if swap.boughtNativeUnknown { stats.pnlComplete = false; continue }"))
        XCTAssertTrue(portfolio.contains("if !swap.boughtNativeUnknown, let price = prices[swap.boughtToken]"))
        XCTAssertEqual(SwapHistoryService.nativeReadLimit, 50)
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
