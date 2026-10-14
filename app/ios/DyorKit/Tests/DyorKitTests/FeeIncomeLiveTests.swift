import BigInt
import XCTest
@testable import DyorKit

/// Live reads against Monad for one wallet's fee income and Moments earnings; runs only when DYOR_SCAN_WALLET is set
/// (network, slow). Prints what My Launchpad's Fees and My Moments' Proceeds would show.
final class FeeIncomeLiveTests: XCTestCase {
    func testFeeIncomeAndMomentsEarnings() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DYOR_SCAN_WALLET"], let wallet = Address(raw) else { throw XCTSkip("set DYOR_SCAN_WALLET") }
        // The app's endpoints: reads on the default RPC, logs on rpc1.
        let logsRPC = RPCClient(url: LaunchpadService.defaultLogsRPC)
        let rpc = RPCClient(url: Monad.defaultRPC)
        let launchpad = LaunchpadService(rpc: rpc, addresses: .monadMainnet, logsRPC: logsRPC)
        let t0 = Date()
        let income = await launchpad.feeIncome(wallet: wallet)
        print("FEES complete", income.complete, "in", Date().timeIntervalSince(t0), "s")
        for (token, amount) in income.paid { print("  paid", token.short, amount) }
        for (token, amount) in income.claimed { print("  claimed", token.short, amount) }
        for (coin, amount) in income.rewardsClaimed { print("  rewards", coin.short, amount) }
        XCTAssertTrue(income.complete)

        let t1 = Date()
        var earnings = try await MomentsService(rpc: rpc, addresses: .monadMainnet, logsRPC: logsRPC).creatorEarnings(account: wallet)
        for addresses in MomentsAddresses.retiredMainnet {
            earnings = earnings + (try await RetiredMoments(rpc: rpc, addresses: addresses, logsRPC: logsRPC).creatorEarnings(account: wallet))
        }
        print("MOMENTS complete", earnings.complete, "in", Date().timeIntervalSince(t1), "s")
        for m in earnings.moments {
            print("  ", m.key, "collects", m.fromCollectors, "fees", m.tradingFees, "claimed", m.claimed, "unclaimed", m.unclaimed)
        }
        print("  totals: from collectors", earnings.fromCollectors, "trading fees", earnings.tradingFees, "claimed", earnings.claimed, "unclaimed", earnings.unclaimed)
        XCTAssertTrue(earnings.complete)
        XCTAssertEqual(earnings.fromCollectors + earnings.tradingFees, earnings.claimed + earnings.unclaimed)
    }
}
