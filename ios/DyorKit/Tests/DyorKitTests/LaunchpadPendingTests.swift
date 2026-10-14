import BigInt
import XCTest
@testable import DyorKit

/// The launchpad while the live (v2) stack is pending: every read the board, a coin's page, My Launchpad and the
/// portfolio make goes to the retired stacks alone, answered from memory (`MomentsChainStub`), and nothing is ever
/// asked of address 0.
final class LaunchpadPendingTests: XCTestCase {
    private let wallet = Address(literal: "0x000000000000000000000000000000000000b0b0")

    private var auditFix: LaunchpadAddresses { LaunchpadAddresses.retiredStack(for: Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"))! }
    private var legacy: LaunchpadAddresses { LaunchpadAddresses.retiredStacks.last! }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func pendingService() -> LaunchpadService {
        LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: LaunchpadAddresses.monadMainnet.isDeployed ? LaunchpadAddresses(poolManager: Uniswap.poolManager, generation: .v2) : .monadMainnet,
                         logsRPC: MomentsChainStub.rpc())
    }

    /// No eth_call target and no log filter is address 0, and nothing is asked of the pending table.
    private func assertNothingAskedOfAddressZero(file: StaticString = #filePath, line: UInt = #line) {
        let targets = MomentsChainStub.calls().map(\.to)
        XCTAssertFalse(targets.isEmpty, file: file, line: line)
        XCTAssertFalse(targets.contains(.zero), "an eth_call went to address 0", file: file, line: line)
        XCTAssertFalse(MomentsChainStub.logQueries().contains { $0.address == .zero }, "a log filter named address 0", file: file, line: line)
    }

    func testRetiredLaunchesListWhileTheLiveStackIsPending() async throws {
        let chain = FakeLaunchpadChain(auditFix: auditFix, legacy: legacy, wallet: wallet)
        MomentsChainStub.install(chain.answer, logs: chain.logs)
        let service = pendingService()
        let deployed = await service.isDeployed
        XCTAssertFalse(deployed)

        // The board: the retired stacks' launches, newest stack first, each with its stack's generation.
        let launches = try await service.allLaunches(limit: 60)
        XCTAssertEqual(launches.map(\.token), [chain.climbing, chain.graduated])
        XCTAssertEqual(launches.map(\.factory), [auditFix.factory, legacy.factory])
        XCTAssertEqual(launches.map(\.generation), [.v1, .legacy])
        XCTAssertEqual(launches.map(\.name), ["Climbing", "Graduated"])
        XCTAssertEqual(launches[1].graduationVenue, .monday, "the legacy record has no venue: Monday Trade")
        XCTAssertTrue(launches.allSatisfy(\.isRetiredLaunchpad))

        // A coin's page reads its own stack, `queuedRewards` included on a v1 sharing contract.
        let detail = try await service.launch(token: chain.climbing, factory: auditFix.factory)
        XCTAssertEqual(detail?.launch.token, chain.climbing)
        XCTAssertEqual(detail?.queuedRewards, 7)
        let orphan = try await service.launch(token: chain.climbing)
        XCTAssertNil(orphan, "no factory given means the live one, which is pending")

        // The passkey policy's curve check finds the curve on the retired factory that recorded it.
        let curve = await service.knownCurve(token: chain.climbing)
        XCTAssertEqual(curve, chain.climbingCurve)

        // Escrow balances of a retired stack.
        let escrow = try await service.escrowBalances(account: wallet, pairTokens: [], escrow: auditFix.escrow)
        XCTAssertEqual(escrow.native, 42)

        assertNothingAskedOfAddressZero()
    }

    func testRetiredWalletHistoryWhileTheLiveStackIsPending() async throws {
        let chain = FakeLaunchpadChain(auditFix: auditFix, legacy: legacy, wallet: wallet)
        MomentsChainStub.install(chain.answer, logs: chain.logs)
        let service = pendingService()

        // The wallet's history: its curve fills and the retired escrow's claim.
        let history = await service.walletHistory(wallet: wallet, lookbackBlocks: 1_000, curves: [chain.climbingCurve])
        XCTAssertEqual(history.fills.map(\.curve), [chain.climbingCurve])
        XCTAssertEqual(history.claims.map(\.amount), [5])
        let escrows = Set(MomentsChainStub.logQueries().compactMap(\.address))
        XCTAssertTrue(escrows.isSuperset(of: LaunchpadAddresses.retiredStacks.map(\.escrow)), "every retired escrow is scanned for the wallet's claims")

        // Logs only (the feed's launch reads went with it): no filter names address 0.
        XCTAssertTrue(MomentsChainStub.calls().isEmpty)
        XCTAssertFalse(MomentsChainStub.logQueries().isEmpty)
        XCTAssertFalse(MomentsChainStub.logQueries().contains { $0.address == .zero }, "a log filter named address 0")
    }

    /// Reads that need the live stack answer nothing, without asking the chain anything.
    func testLiveOnlyReadsAskNothingWhilePending() async throws {
        MomentsChainStub.install { _, _ in nil }
        let service = pendingService()
        let info = try await service.protocolInfo(extraPairTokens: Token.launchpadPairAssets)
        XCTAssertNil(info)
        let live = try await service.launches()
        XCTAssertEqual(live, [])
        let allowed = try await service.canLaunch(account: wallet)
        XCTAssertFalse(allowed)
        let result = try await service.launchResult(transaction: Data(repeating: 0xaa, count: 32))
        XCTAssertNil(result, "no live factory: no TokenLaunched is taken for a launch")
        XCTAssertTrue(MomentsChainStub.calls().isEmpty)
        XCTAssertTrue(MomentsChainStub.logQueries().isEmpty)
    }

    /// `launchResult` reads only the live factory's `TokenLaunched`: a lookalike event from another emitter in the same
    /// transaction is never taken for the launch.
    func testLaunchResultReadsOnlyTheLiveFactory() async throws {
        let hash = Data(repeating: 0xab, count: 32)
        let data = try ABI.encode([.address(.zero), .uint(0), .uint(1)], "address,uint256,uint256")
        func launched(by emitter: Address, token: Address) -> Log {
            Log(address: emitter, topics: [LaunchpadABI.Events.launchedTopic, token.data.leftPadded(to: 32), token.data.leftPadded(to: 32), wallet.data.leftPadded(to: 32)],
                data: data, blockNumber: 900, transactionHash: hash, logIndex: 0)
        }
        let fake = Address(literal: "0x00000000000000000000000000000000000fa4e0")
        let real = Address(literal: "0x0000000000000000000000000000000000000c01")
        MomentsChainStub.install({ _, _ in nil }, receipts: [hash: [launched(by: fake, token: fake), launched(by: V2Fixture.launchpad.factory, token: real)]])
        let wired = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.launchpad, logsRPC: MomentsChainStub.rpc())
        let result = try await wired.launchResult(transaction: hash)
        XCTAssertEqual(result?.token, real)
        MomentsChainStub.install({ _, _ in nil }, receipts: [hash: [launched(by: fake, token: fake)]])
        let none = try await wired.launchResult(transaction: hash)
        XCTAssertNil(none)
    }
}

/// Two retired launches answered from memory: a bonding MON launch with holder fee sharing on 0x10F3 (v1) and a
/// graduated Monday launch on the legacy 0xad3d (16-field record). Every other factory has none; any getter not listed
/// here reverts, as it would on a contract without it.
struct FakeLaunchpadChain: Sendable {
    let auditFix: LaunchpadAddresses
    let legacy: LaunchpadAddresses
    let wallet: Address

    let climbing = Address(literal: "0x00000000000000000000000000000000000c1100")
    let climbingCurve = Address(literal: "0x00000000000000000000000000000000000c11c0")
    let graduated = Address(literal: "0x00000000000000000000000000000000000c2100")
    let graduatedCurve = Address(literal: "0x00000000000000000000000000000000000c21c0")
    let mondayPool = Address(literal: "0x00000000000000000000000000000000000c21a0")
    static let stranger = Address(literal: "0x00000000000000000000000000000000005a4e00")
    let deployer = Address(literal: "0x00000000000000000000000000000000000de900")

    private func record(_ token: Address, legacyLayout: Bool) -> Data {
        let known = token == climbing ? (auditFix.factory, climbingCurve, false) : token == graduated ? (legacy.factory, graduatedCurve, true) : nil
        let exists = known != nil
        let curve = known?.1 ?? .zero
        let graduatedPhase = known?.2 ?? false
        var fields: [ABIValue] = [.address(exists ? token : .zero), .address(curve), .address(exists ? deployer : .zero), .address(exists ? deployer : .zero), .address(.zero),
                                  .uint(exists ? BigUInt(10).power(21) : 0), .uint(100), .uint(100), .int(60), .bool(token == climbing),
                                  .uint(0), .uint(graduatedPhase ? 2 : 0), .uint(0), .uint(0), .uint(0),
                                  .bytes(graduatedPhase ? mondayPool.data.leftPadded(to: 32) : Data(count: 32)), .bool(exists)]
        if legacyLayout { fields.remove(at: 10) }
        return try! ABI.encode([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: legacyLayout))
    }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let arg = data.count >= 36 ? Address(data: data[data.startIndex + 16 ..< data.startIndex + 36]) : nil
        typealias F = LaunchpadABI.Factory
        typealias C = LaunchpadABI.Curve
        typealias T = LaunchpadABI.Token
        if let stack = LaunchpadAddresses.retiredStack(for: to) {
            let own: Address? = to == auditFix.factory ? climbing : to == legacy.factory ? graduated : nil
            if is_(F.launchCount) { return encode([.uint(own == nil ? 0 : 1)], "uint256") }
            if is_(F.getLaunches) { return encode([.array(own.map { [.address($0)] } ?? [])], "address[]") }
            if is_(F.getLaunchedToken), let arg { return record(arg == own ? arg : .zero, legacyLayout: stack.generation.legacyRecord) }
            if is_(F.stuckSince) { return encode([.uint(0)], "uint256") }
            if is_(F.poolKeyOf) { return encode([.tuple([.address(.zero), .address(own ?? .zero), .uint(0), .int(60), .address(stack.hook)])], LaunchpadABI.poolKeyTuple) }
            return nil
        }
        if to == auditFix.escrow, is_(LaunchpadABI.Escrow.balanceOf) { return encode([.uint(42)], "uint256") }
        if to == auditFix.holderFeeSharing, is_(LaunchpadABI.Sharing.queuedRewards) { return encode([.uint(7), .uint(901)], "uint256,uint256") }
        for (token, curve, name) in [(climbing, climbingCurve, "Climbing"), (graduated, graduatedCurve, "Graduated")] {
            if to == token {
                if is_(T.name) { return encode([.string(name)], "string") }
                if is_(T.symbol) { return encode([.string(String(name.prefix(4)).uppercased())], "string") }
                if is_(T.totalSupply) { return encode([.uint(BigUInt(10).power(27))], "uint256") }
                if is_(T.getTokenInfo) { return encode([.address(deployer), .string(""), .string(""), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,\(LaunchpadABI.socialsTuple)") }
            }
            if to == curve {
                if is_(C.price) || is_(C.realQuoteReserve) || is_(C.sellableTokens) || is_(C.phantomQuote) || is_(C.reservedTokens) { return encode([.uint(1_000)], "uint256") }
                if is_(C.completed) || is_(C.rescued) || is_(C.swept) { return encode([.bool(token == graduated && is_(C.completed))], "bool") }
                if is_(C.launchedAt) { return encode([.uint(1_789_000_000)], "uint64") }
                if is_(C.feeBps) { return encode([.uint(100)], "uint16") }
                if is_(C.snipeTaxSchedule) { return encode([.array([.uint(5_000), .uint(2_500)])], "uint16[]") }
                if is_(C.getReserves) { return encode([.uint(1), .uint(2)], "uint256,uint256") }
            }
        }
        return nil
    }

    private func word(_ address: Address) -> Data { address.data.leftPadded(to: 32) }
    private func hash(_ n: UInt8) -> Data { Data(repeating: n, count: 32) }

    /// The feed's and the wallet's events, plus a launch by an unknown factory and a trade on an unknown curve.
    var logs: [Log] {
        let launchedData = try! ABI.encode([.address(.zero), .uint(0), .uint(BigUInt(10).power(21))], "address,uint256,uint256")
        let fill = try! ABI.encode([.uint(100), .uint(5_000), .uint(1), .uint(0)], "uint256,uint256,uint256,uint256")
        return [
            Log(address: auditFix.factory, topics: [LaunchpadABI.Events.launchedTopic, word(climbing), word(climbingCurve), word(deployer)], data: launchedData, blockNumber: 700, transactionHash: hash(1), logIndex: 0),
            Log(address: Self.stranger, topics: [LaunchpadABI.Events.launchedTopic, word(Self.stranger), word(Self.stranger), word(deployer)], data: launchedData, blockNumber: 701, transactionHash: hash(2), logIndex: 0),
            Log(address: legacy.factory, topics: [LaunchpadABI.Events.graduatedTopic, word(graduated), hash(9)], data: try! ABI.encode([.uint(1)], "uint128"), blockNumber: 710, transactionHash: hash(3), logIndex: 0),
            Log(address: climbingCurve, topics: [LaunchpadABI.Events.buyTopic, word(wallet), word(wallet)], data: fill, blockNumber: 720, transactionHash: hash(4), logIndex: 0),
            Log(address: Self.stranger, topics: [LaunchpadABI.Events.buyTopic, word(wallet), word(wallet)], data: fill, blockNumber: 721, transactionHash: hash(5), logIndex: 0),
            Log(address: auditFix.escrow, topics: [LaunchpadABI.Events.escrowClaimedTopic, word(wallet)], data: try! ABI.encode([.uint(5)], "uint256"), blockNumber: 730, transactionHash: hash(6), logIndex: 0),
        ]
    }
}
