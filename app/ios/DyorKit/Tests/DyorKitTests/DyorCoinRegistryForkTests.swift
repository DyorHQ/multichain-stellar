import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The DyorHQ coin registry on a LOCAL anvil fork of Monad whose live v2 launchpad (`LaunchpadAddresses.monadMainnet`)
/// and cohort 4 (`MomentsAddresses.monadMainnet`) hold a launch and a Moment whose name and symbol aren't text (bytes
/// such as ff fe fd fc), with ordinary ones listed after them: build 17's review launched exactly that on the real v2
/// launchpad and stalled the registry's reading of it for good. The repository's seed scripts put such a launch and
/// Moment there, each followed by another (the Moment after it has a name longer than the form allows: a long name alone
/// is no warning); then make one ordinary launch and one ordinary Moment after them, in the app or with `cast` and a key
/// derived from a label (never anvil's own keys: they carry EIP-7702 code on Monad):
///
///   anvil --fork-url https://rpc3.monad.xyz --no-rate-limit --disable-code-size-limit --port 8751
///   node scripts/dev/seed-fork.mjs --text 8751 && node scripts/dev/seed-moments-fork.mjs --text 8751
///   (one ordinary launch on 0x3B1f…, one ordinary Moment on 0x95eb…)
///   cd ios/DyorKit && DYOR_COINS_FORK_RPC=http://127.0.0.1:8751 swift test --filter DyorCoinRegistryForkTests
///
/// Skipped only without `DYOR_COINS_FORK_RPC`, or when it isn't a local RPC of chain 143; a fork without a poisoned
/// launch and Moment, each with an ordinary one after it, fails. What the lists must hold is read from the fork itself.
/// Reads only.
final class DyorCoinRegistryForkTests: XCTestCase {
    private var rpc: RPCClient!
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        guard let text = ProcessInfo.processInfo.environment["DYOR_COINS_FORK_RPC"], let url = URL(string: text) else {
            throw XCTSkip("set DYOR_COINS_FORK_RPC (a local fork of Monad whose v2 launchpad and cohort 4 hold coins whose text isn't UTF-8)")
        }
        let rpc = RPCClient(url: url)
        guard rpc.isLocal else { throw XCTSkip("DYOR_COINS_FORK_RPC must be a local fork (127.0.0.1 or localhost), never a public RPC") }
        let chain = try await rpc.call("eth_chainId")
        guard chain.string.flatMap({ BigUInt(hexQuantity: $0) }) == 143 else { throw XCTSkip("DYOR_COINS_FORK_RPC is not a fork of Monad mainnet (chain 143)") }
        self.rpc = rpc
        folder = FileManager.default.temporaryDirectory.appending(path: "dyor-coins-fork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A list's coins with their name and symbol as raw bytes, `Multicall.textChunk` coins a read.
    private func rawText(_ coins: [Address], multicall: Multicall) async throws -> [(name: Data, symbol: Data)] {
        var out: [(Data, Data)] = []
        for start in stride(from: 0, to: coins.count, by: Multicall.textChunk) {
            let chunk = coins[start ..< min(start + Multicall.textChunk, coins.count)]
            let answers = try await multicall.readAll(try chunk.flatMap { [try ContractCall(to: $0, "name()", returns: "bytes"), try ContractCall(to: $0, "symbol()", returns: "bytes")] })
            for i in stride(from: 0, to: answers.count, by: 2) { out.append((answers[i][0].bytes, answers[i + 1][0].bytes)) }
        }
        return out
    }

    private static func isText(_ raw: Data) -> Bool { String(data: raw, encoding: .utf8) != nil }

    func testCreatorTextThatIsntTextNeverStallsTheRegistry() async throws {
        let multicall = Multicall(rpc: rpc)
        let launchpad = LaunchpadAddresses.monadMainnet.factory
        let cohort = MomentsAddresses.monadMainnet.factory
        let launchCount = Int(try await multicall.readAll([try ContractCall(to: launchpad, "launchCount()", returns: "uint256")])[0][0].uint)
        let momentCount = Int(try await multicall.readAll([try ContractCall(to: cohort, "momentCount()", returns: "uint256")])[0][0].uint)
        let tokens = launchCount == 0 ? [] : try await multicall.readAll([try ContractCall(to: launchpad, "getLaunches(uint256,uint256)", [.uint(0), .uint(BigUInt(launchCount))], returns: "address[]")])[0][0]
            .elements.map(\.address)
        let moments = momentCount == 0 ? [] : try await multicall.readAll((1...momentCount).map { try ContractCall(to: cohort, "getMoment(uint256)", [.uint(BigUInt($0))], returns: MomentsABI.momentTuple) })
            .enumerated().map { MomentsABI.moment(id: BigUInt($0.offset + 1), $0.element[0], factory: cohort).coin }
        let launchText = try await rawText(tokens, multicall: multicall)
        let momentText = try await rawText(moments, multicall: multicall)
        func poisoned(_ text: [(name: Data, symbol: Data)]) -> [Int] { text.indices.filter { !Self.isText(text[$0].name) || !Self.isText(text[$0].symbol) } }
        let badLaunches = poisoned(launchText)
        let badMoments = poisoned(momentText)
        guard let firstBadLaunch = badLaunches.first, let firstBadMoment = badMoments.first, firstBadLaunch < tokens.count - 1, firstBadMoment < moments.count - 1 else {
            return XCTFail("the fork's v2 launchpad holds \(tokens.count) launches (\(badLaunches.count) whose text isn't UTF-8) and cohort 4 \(moments.count) Moments (\(badMoments.count)): seed a poisoned launch and Moment, each with more after it (see the file's header)")
        }

        let store = DyorCoinStore(url: folder.appending(path: DyorCoinStore.fileName(fork: true)))
        let registry = DyorCoinRegistry(rpc: rpc, store: store)
        let started = Date()
        let complete = await registry.refresh()
        let seconds = Date().timeIntervalSince(started)
        XCTAssertTrue(complete, "one refresh reads every list to its count")
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[launchpad], launchCount, "the v2 launchpad read to its count")
        XCTAssertEqual(checkpoints[cohort], momentCount, "cohort 4 read to its count")
        let coins = await registry.all
        for (index, token) in tokens.enumerated() {
            let membership = await registry.membership(token)
            guard case .dyor(let coin) = membership else { XCTFail("launch \(index) \(token) is a DyorHQ coin: \(membership)"); continue }
            let badge = TokenBadge.of(coin.token, coin: coin, receivedUnasked: false)
            if badLaunches.contains(index) {
                XCTAssertTrue(badge.isWarning, "launch \(index) \(token): its text isn't text, so a warning, never \"DyorHQ Launch\": \(badge)")
                XCTAssertTrue(coin.name.contains("\u{FFFD}") || coin.symbol.contains("\u{FFFD}"))
            }
        }
        for (index, coin) in moments.enumerated() {
            let membership = await registry.membership(coin)
            guard case .dyor(let entry) = membership else { XCTFail("Moment \(index + 1) \(coin) is a DyorHQ coin: \(membership)"); continue }
            if badMoments.contains(index) {
                XCTAssertTrue(TokenBadge.of(entry.token, coin: entry, receivedUnasked: false).isWarning, "Moment \(index + 1)")
            }
        }
        let laterLaunches = tokens[(firstBadLaunch + 1)...].compactMap { coins[$0] }
        let laterMoments = moments[(firstBadMoment + 1)...].compactMap { coins[$0] }
        XCTAssertEqual(laterLaunches.count, tokens.count - firstBadLaunch - 1, "every launch after the poisoned one is listed")
        XCTAssertEqual(laterMoments.count, moments.count - firstBadMoment - 1, "every Moment after the poisoned one is listed")
        XCTAssertTrue(laterLaunches.contains { TokenBadge.of($0.token, coin: $0, receivedUnasked: false) == .dyorLaunch }, "an ordinary launch after it: DyorHQ Launch")
        XCTAssertTrue(laterMoments.contains { TokenBadge.of($0.token, coin: $0, receivedUnasked: false) == .dyorMoment }, "an ordinary Moment after it: DyorHQ Moment")
        XCTAssertGreaterThanOrEqual(coins.count, 13 + launchCount + momentCount, "and the retired factories' 13")
        print("DyorCoinRegistryForkTests: \(coins.count) coins in \(String(format: "%.2f", seconds)) s; v2 \(launchCount) launches (poisoned \(badLaunches)), c4 \(momentCount) Moments (poisoned \(badMoments.map { $0 + 1 }))")
        for coin in (tokens + moments).compactMap({ coins[$0] }) {
            print("DyorCoinRegistryForkTests \(coin.address.short) \(coin.isMoment ? "Moment" : "launch"): \(coin.symbol.debugDescription) / \(String(coin.name.prefix(24)).debugDescription) -> \(TokenBadge.of(coin.token, coin: coin, receivedUnasked: false).title ?? "none")")
        }

        // After a restart, from the file: nothing held back, nothing to read but the counts.
        let reopened = DyorCoinRegistry(rpc: rpc, store: store)
        let kept = await reopened.all
        XCTAssertEqual(kept, coins)
        let again = await reopened.refresh()
        XCTAssertTrue(again)
    }
}
