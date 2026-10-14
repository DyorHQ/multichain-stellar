import XCTest
@testable import DyorKit

/// The launchpad addresses baked into DyorKit must be the ones the contracts repo records for Monad mainnet, so a
/// redeploy can never leave the app on a retired (pre-audit) factory without this test saying so. While the v2 stack is
/// pending (`LaunchpadAddresses.monadMainnet` all zero) the live record `143.json` is still the relaunch stack 0x6B1C…,
/// now the newest retired one; once the v2 record is promoted, 0x6B1C… moves to `143-retired-0x6B1C.json`.
final class LaunchpadDeploymentTests: XCTestCase {
    /// A deployment record from `contracts/deployments/`, or a skip when this checkout has no contracts.
    static func deploymentRecord(_ name: String) throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios → repo root
        url.appendPathComponent("contracts/deployments/\(name)")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("contracts/deployments/\(name) is not in this checkout") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertStack(_ stack: LaunchpadAddresses, matches name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try Self.deploymentRecord(name)
        func address(_ key: String) throws -> Address { try XCTUnwrap(Address(try XCTUnwrap(record[key] as? String, key)), key) }
        XCTAssertEqual(record["chainId"] as? Int, 143, name, file: file, line: line)
        XCTAssertEqual(stack.factory, try address("factory"), name, file: file, line: line)
        XCTAssertEqual(stack.router, try address("launchAndBuyRouter"), name, file: file, line: line)
        XCTAssertEqual(stack.escrow, try address("escrow"), name, file: file, line: line)
        XCTAssertEqual(stack.holderFeeSharing, try address("holderFeeSharing"), name, file: file, line: line)
        XCTAssertEqual(stack.hook, try address("hook"), name, file: file, line: line)
        XCTAssertEqual(stack.poolManager, try address("poolManager"), name, file: file, line: line)
    }

    /// The v2 stack against the live record, once it is wired (`V2WiringTests` keeps the pending table honest).
    func testMainnetAddressesMatchDeploymentRecord() throws {
        let baked = LaunchpadAddresses.monadMainnet
        guard baked.isDeployed else { throw XCTSkip("the v2 launchpad is pending: LaunchpadAddresses.monadMainnet is not wired yet") }
        try assertStack(baked, matches: "143.json")
        XCTAssertEqual(baked.poolManager, Uniswap.poolManager)
        XCTAssertEqual(baked.generation, .v2)
    }

    /// The relaunch stack 0x6B1C…: the live record while v2 is pending, its retired record after the promotion.
    func testRelaunchStackMatchesItsRecord() throws {
        let relaunch = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first)
        XCTAssertEqual(relaunch.factory, Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB"))
        try assertStack(relaunch, matches: LaunchpadAddresses.monadMainnet.isDeployed ? "143-retired-0x6B1C.json" : "143.json")
    }

    func testMainnetIsNotTheRetiredFactory() {
        // The pre-audit deployment (2026-09-12) carried a live holder-reward drain; nothing may point at it again.
        XCTAssertNotEqual(LaunchpadAddresses.monadMainnet.factory, Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"))
        // Nor at any other retired factory: new launches always go to the live one.
        XCTAssertFalse(LaunchpadAddresses.retiredFactories.contains(LaunchpadAddresses.monadMainnet.factory))
        XCTAssertNil(LaunchpadAddresses.retiredStack(for: LaunchpadAddresses.monadMainnet.factory))
    }

    func testAuditFixStackMatchesItsRecord() throws {
        let stack = try XCTUnwrap(LaunchpadAddresses.retiredStack(for: Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7")))
        try assertStack(stack, matches: "143-retired-0x10F3.json")
    }

    /// Each stack's generation, pinned: it decides the record layout, the `queuedRewards` read, the fallback and the
    /// v2-only getters, so a stack in the wrong generation reads garbage or fails whole multicalls.
    func testRetiredStackGenerations() {
        let stacks = LaunchpadAddresses.retiredStacks
        XCTAssertEqual(stacks.map(\.factory), [
            Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB"),
            Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"),
            Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"),
            Address(literal: "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea"),
        ])
        XCTAssertEqual(stacks.map(\.generation), [.v1, .v1, .preAudit, .legacy])
        XCTAssertEqual(LaunchpadAddresses.monadMainnet.generation, .v2)
        XCTAssertTrue(stacks.allSatisfy { $0.poolManager == Uniswap.poolManager })
        XCTAssertEqual(LaunchpadAddresses.monadMainnet.poolManager, Uniswap.poolManager)
        // No stack, live or retired, shares a module with another (the pending v2 table's zero placeholders aside).
        let modules = ([LaunchpadAddresses.monadMainnet] + stacks).flatMap { [$0.factory, $0.router, $0.escrow, $0.holderFeeSharing, $0.hook] }.filter { !$0.isZero }
        XCTAssertEqual(Set(modules).count, modules.count)
        XCTAssertEqual(modules.count, LaunchpadAddresses.monadMainnet.isDeployed ? 25 : 20)
    }

    /// What each generation reads and sends.
    func testGenerationCapabilities() {
        typealias G = LaunchpadAddresses.Generation
        XCTAssertEqual(G.allCases, [.legacy, .preAudit, .v1, .v2])
        XCTAssertEqual(G.allCases.map(\.legacyRecord), [true, false, false, false])
        XCTAssertEqual(G.allCases.map(\.hasQueuedRewards), [false, false, true, true])
        XCTAssertEqual(G.allCases.map(\.hasGraduateFallback), [false, false, true, true], "the keepers send it where it exists; the app never does")
        XCTAssertEqual(G.allCases.map(\.hasV2Getters), [false, false, false, true])
        XCTAssertEqual(LaunchpadAddresses().generation, .v1, "an unknown factory is read as v1: no v2-only getter is sent to it")
    }

    /// The swap routes through graduated launchpad pools: the retired stacks with the 17-field record while v2 is
    /// pending (0x6B1C, 0x10F3, 0x2F02; the legacy 0xad3d graduates on Monday Trade only), the live one first once wired.
    func testSwapRoutesKeepTheRetiredFactoriesWhileV2IsPending() {
        let retired = [
            Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB"),
            Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"),
            Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"),
        ]
        XCTAssertEqual(LaunchpadAddresses.swapRouteFactories(live: .none), retired)
        XCTAssertEqual(LaunchpadAddresses.swapRouteFactories(live: LaunchpadAddresses(poolManager: Uniswap.poolManager, generation: .v2)), retired)
        XCTAssertEqual(LaunchpadAddresses.swapRouteFactories(live: V2Fixture.launchpad), [V2Fixture.launchpad.factory] + retired)
        XCTAssertEqual(LaunchpadAddresses.swapRouteFactories(live: LaunchpadAddresses.monadMainnet),
                       LaunchpadAddresses.monadMainnet.isDeployed ? [LaunchpadAddresses.monadMainnet.factory] + retired : retired)
        // A build pointed at a retired stack as live lists it once.
        let relaunch = LaunchpadAddresses.retiredStacks[0]
        XCTAssertEqual(LaunchpadAddresses.swapRouteFactories(live: relaunch), retired)
    }

    /// A launch knows its stack's generation: the stack's when read, else a retired stack's, else the live table's.
    func testLaunchCarriesItsGeneration() {
        func launch(_ factory: Address, _ generation: LaunchpadAddresses.Generation? = nil) -> Launch {
            Launch(token: .zero, curve: .zero, deployer: .zero, creatorFeeRecipient: .zero, pairToken: .zero, graduationThreshold: 0, creatorTaxBps: 0, poolFeeBps: 0,
                   tickSpacing: 60, holderFeeSharing: false, graduationVenue: .monday, phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: Data(count: 32),
                   name: "", symbol: "", logo: "", description: "", socials: .none, pair: .mon, price: 0, realQuoteReserve: 0, completed: false, rescued: false,
                   launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0, factory: factory, generation: generation)
        }
        XCTAssertEqual(LaunchpadAddresses.retiredStacks.map { launch($0.factory).generation }, [.v1, .v1, .preAudit, .legacy])
        XCTAssertEqual(launch(.zero).generation, .v2)
        XCTAssertEqual(launch(V2Fixture.launchpad.factory).generation, .v2)
        XCTAssertEqual(launch(V2Fixture.launchpad.factory, .v1).generation, .v1, "the stack it was read from wins")
    }

    /// A pending v2 stack serves the retired stacks alone: nothing is read from, or planned against, address 0.
    func testAPendingLiveStackLeavesOnlyTheRetiredOnes() async {
        let service = LaunchpadService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: .none)
        let stacks = await service.stacks
        XCTAssertEqual(stacks.map(\.factory), LaunchpadAddresses.retiredFactories)
        XCTAssertFalse(stacks.contains { $0.factory.isZero })
        let retired = await service.retiredStacks
        XCTAssertEqual(retired, LaunchpadAddresses.retiredStacks)
        let wired = LaunchpadService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: V2Fixture.launchpad)
        let wiredStacks = await wired.stacks
        XCTAssertEqual(wiredStacks.map(\.factory), [V2Fixture.launchpad.factory] + LaunchpadAddresses.retiredFactories)
    }
}
