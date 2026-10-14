import XCTest
@testable import DyorKit

/// Guards the bug that stalled the Bridge at "Confirming your deposit…": Aurora's `/status` returns
/// origin/destinationChainTxHashes as arrays of `{hash, explorerUrl}` OBJECTS, which an earlier `[String]` model
/// failed to decode the moment the deposit tx was recorded, so the poll never saw SUCCESS.
final class AuroraIntentsTests: XCTestCase {
    private func decode(_ json: String) throws -> AuroraSwapState {
        try JSONDecoder().decode(AuroraSwapState.self, from: Data(json.utf8))
    }

    func testSuccessStatusWithPopulatedTxObjectsDecodes() throws {
        let json = """
        {"correlationId":"abc","status":"SUCCESS","updatedAt":"2026-09-19T07:00:00Z",
         "swapDetails":{"amountOutFormatted":"0.097","amountOutUsd":"0.097",
           "originChainTxHashes":[{"hash":"0xabc","explorerUrl":"https://monadscan.com/tx/0xabc"}],
           "destinationChainTxHashes":[{"hash":"0xdef","explorerUrl":"https://basescan.org/tx/0xdef"}],
           "refundedAmountFormatted":"0","refundReason":null}}
        """
        let state = try decode(json)
        XCTAssertEqual(state.status, .success)
        XCTAssertEqual(state.swapDetails?.amountOutFormatted, "0.097")
        XCTAssertEqual(state.swapDetails?.originChainTxHashes?.first?.hash, "0xabc")
        XCTAssertEqual(state.swapDetails?.destinationChainTxHashes?.first?.explorerUrl, "https://basescan.org/tx/0xdef")
    }

    func testPendingStatusWithEmptyArraysDecodes() throws {
        let json = """
        {"status":"PENDING_DEPOSIT","updatedAt":"2026-09-19T07:00:00Z",
         "swapDetails":{"amountOutFormatted":null,"originChainTxHashes":[],"destinationChainTxHashes":[],
           "refundedAmountFormatted":"0","refundReason":null}}
        """
        XCTAssertEqual(try decode(json).status, .pendingDeposit)
    }

    func testMinimalStatusOnlyVariantDecodes() throws {
        XCTAssertEqual(try decode(#"{"status":"PROCESSING"}"#).status, .processing)
    }

    /// The lenient decoder must still yield `status` even if `swapDetails` is a shape we don't model (future drift),
    /// so settlement tracking can never stall on a swapDetails decode error again.
    func testStatusSurvivesUnexpectedSwapDetailsShape() throws {
        let json = #"{"status":"SUCCESS","swapDetails":{"originChainTxHashes":"not-an-array","weird":123}}"#
        let state = try decode(json)
        XCTAssertEqual(state.status, .success)
        XCTAssertNil(state.swapDetails)
    }
}
