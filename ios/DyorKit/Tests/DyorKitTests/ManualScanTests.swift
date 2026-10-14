import XCTest
@testable import DyorKit

/// Live scans against Monad for one wallet; runs only when DYOR_SCAN_WALLET is set (network, slow).
final class ManualScanTests: XCTestCase {
    func testWalletScans() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DYOR_SCAN_WALLET"], let wallet = Address(raw) else { throw XCTSkip("set DYOR_SCAN_WALLET") }
        let logsRPC = RPCClient(url: URL(string: "https://rpc1.monad.xyz")!)
        let rpc = RPCClient(url: URL(string: "https://rpc3.monad.xyz")!)
        let multicall = Multicall(rpc: rpc)
        let head = try await logsRPC.block(.latest).number
        let t0 = Date()
        let swaps = await SwapHistoryService(rpc: logsRPC).swaps(wallet: wallet, fromBlock: 0, toBlock: head, decimals: [:], limit: 2000)
        print("SWAPS", swaps.count, "in", Date().timeIntervalSince(t0), "s"); for s in swaps.prefix(5) { print("  ", s.soldToken.short, s.soldAmount, "->", s.boughtToken.short, s.boughtAmount, "block", s.block) }
        let launchpad = LaunchpadService(rpc: rpc, addresses: .monadMainnet)
        var launches = try await launchpad.launches(limit: 200)
        for f in LaunchpadAddresses.retiredFactories { launches += try await launchpad.launches(limit: 200, factory: f) }
        print("LAUNCHES", launches.count, launches.map(\.symbol))
        let t1 = Date()
        let history = await launchpad.walletHistory(wallet: wallet, lookbackBlocks: UInt64.max, curves: Set(launches.map(\.curve)))
        print("LAUNCH FILLS", history.fills.count, "claims", history.claims.count, "in", Date().timeIntervalSince(t1), "s")
        let moments = MomentsService(rpc: rpc, addresses: .monadMainnet)
        let t2 = Date()
        let (mh, momentsComplete) = await moments.history(account: wallet)
        print("MOMENTS collects", mh.collects.count, "claims", mh.claims.count, "publishes", mh.publishes.count, "complete", momentsComplete, "in", Date().timeIntervalSince(t2), "s")
        let t3 = Date()
        let tokens = await WalletTokenDiscovery(logsRPC: logsRPC, multicall: multicall).heldTokens(wallet: wallet, wholeHistory: true)
        print("TOKENS", tokens.map(\.symbol), "in", Date().timeIntervalSince(t3), "s")
    }
}
