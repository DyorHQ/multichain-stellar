import BigInt
import XCTest
@testable import DyorKit

/// The wallet's balances as the Portfolio and the Send sheet read them (`ERC20.balanceReport`): no one token can keep
/// the others from being read. MON is read on its own, the curated tokens in a read of their own, every other token in
/// bounded reads; a token that breaks its read (a return bomb) or fails inside it costs only itself, and what couldn't be
/// read is said, never taken for zero. Contract reads come from `MomentsChainStub`.
final class BalanceReportTests: XCTestCase {
    private let owner = Address(literal: "0x7777777777777777777777777777777777777777")
    private let bomb = Address(literal: "0x00000000000000000000000000000000000b0000")
    private let dead = Address(literal: "0x00000000000000000000000000000000000d0000")

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    /// `count` airdropped tokens, each holding its index in whole units.
    private func airdrops(_ count: Int) -> [Token] {
        (1...count).map { i in Token(address: Address(data: Data(count: 16) + Data([0x00, 0x0a, UInt8(i / 256), UInt8(i % 256)]))!, symbol: "A\(i)", name: "Airdrop \(i)", decimals: 18) }
    }

    private func answer(_ held: [Address: BigUInt]) -> MomentsChainStub.Answer {
        { to, data in
            guard data.prefix(4) == ABI.selector("balanceOf(address)"), let balance = held[to] else { return nil }
            return try! ABI.encode([.uint(balance)], "uint256")
        }
    }

    /// The finding's wallet: an airdropped token whose balanceOf returns a bomb makes every aggregate it is in run out of
    /// gas. MON, the curated tokens and every other token are still read; the bomb alone is left out, as failed.
    func testATokenThatBreaksItsReadCostsOnlyItself() async {
        let others = airdrops(120)
        var held: [Address: BigUInt] = [Monad.usdc: 5_000_000, bomb: 1]
        for (i, token) in others.enumerated() { held[token.address] = BigUInt(i + 1) }
        MomentsChainStub.install(answer(held), breaking: [bomb], native: [owner: 42])
        let universe = Token.core + others + [Token(address: bomb, symbol: "BOOM", name: "Bomb", decimals: 18)]
        let report = await ERC20.balanceReport(of: universe, owner: owner, rpc: MomentsChainStub.rpc(), multicall: Multicall(rpc: MomentsChainStub.rpc()))
        XCTAssertEqual(report.balances[Monad.native], 42, "MON, on its own")
        XCTAssertEqual(report.balances[Monad.usdc], 5_000_000, "the curated tokens, in their own read")
        XCTAssertEqual(report.balances[Monad.wmon], nil, "a curated token that reverts is not zero")
        for (i, token) in others.enumerated() { XCTAssertEqual(report.balances[token.address], BigUInt(i + 1), token.symbol) }
        XCTAssertNil(report.balances[bomb])
        XCTAssertEqual(report.failed, Set(Token.core.filter { !$0.isNative && $0.address != Monad.usdc }.map(\.address)).union([bomb]), "each read on its own and refused")
        XCTAssertTrue(report.unread.isEmpty)
        // No read holds more than 50 tokens, and the curated tokens are never read with a third-party contract.
        let reads = MomentsChainStub.batches().filter { $0.first?.selector == ABI.selector("balanceOf(address)").hexString }
        XCTAssertTrue(reads.allSatisfy { $0.count <= 50 })
        let curated = Set(Token.core.map(\.address))
        XCTAssertTrue(reads.allSatisfy { batch in batch.allSatisfy { curated.contains($0.to) } || batch.allSatisfy { !curated.contains($0.to) } })
    }

    /// A token that reverts inside a read that answered is read again on its own, so a token starved of gas by the one
    /// before it is read; one that reverts on its own too is failed, never zero.
    func testACallThatFailsInsideAReadIsReadAgainOnItsOwn() async {
        let token = Token(address: Address(literal: "0x00000000000000000000000000000000000a0001"), symbol: "OK", name: "Ok", decimals: 18)
        let starved = FirstTime()
        MomentsChainStub.install { to, data in
            guard data.prefix(4) == ABI.selector("balanceOf(address)"), to == token.address else { return nil }
            // Fails the first time (starved), answers when read on its own.
            return starved.take() ? nil : try! ABI.encode([.uint(9)], "uint256")
        }
        let report = await ERC20.balanceReport(ofTokens: [dead, token.address], owner: owner, multicall: Multicall(rpc: MomentsChainStub.rpc()))
        XCTAssertEqual(report.balances, [token.address: 9])
        XCTAssertEqual(report.failed, [dead])
        XCTAssertTrue(report.unread.isEmpty)
    }

    /// A read that got no answer (the node can't serve it) is unread: nothing is known, and nothing is taken for zero.
    func testAReadWithNoAnswerIsUnread() async {
        MomentsChainStub.install(answer([Monad.usdc: 1]), refusing: ["eth_call", "eth_getBalance"])
        let report = await ERC20.balanceReport(of: [Token.mon, Token.usdc] + airdrops(3), owner: owner, rpc: MomentsChainStub.rpc(), multicall: Multicall(rpc: MomentsChainStub.rpc()))
        XCTAssertTrue(report.balances.isEmpty)
        XCTAssertEqual(report.unread, Set([Monad.native, Monad.usdc] + airdrops(3).map(\.address)))
        XCTAssertTrue(report.failed.isEmpty)
    }

    /// The sources wire it in: the wallet's token list reads its balances this way, says when part of them couldn't be
    /// read, and throws only when none could be.
    func testTheWalletsTokenListReadsItsBalancesThisWay() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let source = try String(contentsOf: app.appendingPathComponent("Wallet/WalletTokens.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let report = await ERC20.balanceReport(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)"))
        XCTAssertTrue(source.contains("if report.balances.isEmpty, !report.unread.isEmpty || !report.failed.isEmpty { throw BalancesUnread() }"))
        XCTAssertTrue(source.contains("let balancesComplete = report.unread.isEmpty && report.failed.isDisjoint(with: mustRead)"))
        XCTAssertTrue(source.contains("complete: (scan?.complete ?? true) && balancesComplete)"))
        XCTAssertFalse(source.contains("ERC20.balances(of: universe"), "never one read over every token")
    }
}

/// True the first time it is taken, false after.
private final class FirstTime: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { first = false }
        return first
    }
}
