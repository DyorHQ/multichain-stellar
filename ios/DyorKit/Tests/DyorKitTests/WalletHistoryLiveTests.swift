import BigInt
import XCTest
@testable import DyorKit

/// Live: a wallet's history read through the router and the store on Monad's public endpoints; runs only when
/// DYOR_SCAN_WALLET is set (network, slow). Prints each scan's progress, the requests spent, and what was built.
final class WalletHistoryLiveTests: XCTestCase {
    func testTheWalletsHistoryIsReadWithinItsBudget() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DYOR_SCAN_WALLET"], let wallet = Address(raw) else { throw XCTSkip("set DYOR_SCAN_WALLET") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-live-\(wallet.hex.suffix(6))")
        let router = LogsRouter(endpoints: LogsEndpoints.monadMainnet)
        let logs = RPCClient(logsRouter: router)
        let store = HistoryStore(router: router, directory: directory)
        let clock = BlockClock(rpc: RPCClient(urls: Monad.publicRPCs))
        let service = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: logs, clock: clock), clock: clock,
                                           stacks: { [LaunchpadAddresses.monadMainnet] + LaunchpadAddresses.retiredStacks }, cohorts: [MomentsAddresses.monadMainnet] + MomentsAddresses.retiredMainnet)
        let cachedBefore = await service.cached(wallet: wallet, curves: [], decimals: [:])
        print("CACHED before: swaps \(cachedBefore.swaps.count) progress \(cachedBefore.progress)")
        for round in 1...3 {
            let t0 = Date()
            let snapshot = await service.refresh(wallet: wallet, budget: LogsBudget(requests: 60, seconds: 25), curves: [], decimals: [:])
            print("ROUND \(round) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: progress \(String(format: "%.3f", snapshot.progress)) complete \(snapshot.complete) filling \(snapshot.filling) unreachable \(snapshot.unreachable)")
            for id in WalletHistoryScans.ids {
                let s = snapshot.status(id)
                print("  \(id): complete \(s.complete) progress \(String(format: "%.3f", s.progress)) reached \(s.reachedChain)")
            }
            for swap in snapshot.swaps.prefix(8) { print("  swap \(swap.block) sold \(swap.soldToken.short) \(swap.soldAmount) bought \(swap.boughtToken.short) \(swap.boughtAmount) unknown \(swap.boughtNativeUnknown)") }
            print("  swaps \(snapshot.swaps.count) fills \(snapshot.launch.fills.count) payments \(snapshot.launch.payments.count) claims \(snapshot.launch.claims.count) collects \(snapshot.moments.collects.count) publishes \(snapshot.moments.publishes.count) withdrawals \(snapshot.moments.withdrawals.count) transfersIn \(snapshot.transfersIn.count)")
            for id in WalletHistoryScans.ids { let e = await store.cached(await service.scans(wallet: wallet).first { $0.id == id }!, wallet: wallet); print("  \(id): covered \(e.covered.count) ranges \(e.covered.prefix(4).map { "\($0.lowerBound)-\($0.upperBound)" }) logs \(e.logs.count) head \(e.head ?? 0) floor \(e.floor ?? 0)") }
            for (host, stats) in await router.stats().sorted(by: { $0.key < $1.key }) { print("  \(host): \(stats)") }
            if snapshot.complete { break }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
