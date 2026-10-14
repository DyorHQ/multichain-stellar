import XCTest
@testable import DyorKit

/// The Moments tab reads its list and the terms apart, side by side (`MomentsService.moments(limit:)` and `policy()`, as
/// `MomentsModel.load` does), and shows each as it lands: a policy that can't be read leaves Publish off with its reason
/// (`MomentsBoard.policyUnread`), and the Moments still show. The link base stays strict (it is hashed into
/// `termsHash()` and compared with DyorHQ's).
final class MomentsBoardTests: XCTestCase {
    private static let stack = TextMomentsChain.stack

    /// What the tab reads: the list, which throws when the Moments can't be read, and the terms, or why they couldn't be.
    private func readBoard(_ service: MomentsService) async throws -> MomentsBoard {
        async let terms = ERC20.captured { try await service.policy() }
        let list = try await service.moments(limit: 60)
        return MomentsBoard(moments: list, policy: await terms)
    }

    func testAPolicyThatCantBeReadLeavesTheFeed() async throws {
        let stack = Self.stack
        MomentsChainStub.install { to, data in
            if to == stack.addresses.factory, data.prefix(4) == ABI.selector(MomentsABI.Factory.externalBaseURI) {
                return ChainTextTests.stringReturn(Data("https://dyorhq.fun/moments/c4/".utf8) + Data([0xff]))
            }
            return stack.answer(to, data)
        }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let board = try await readBoard(service)
        XCTAssertEqual(board.moments.map(\.id), [3, 2, 1], "the Moments show")
        XCTAssertThrowsError(try board.policy.get()) { XCTAssertEqual($0 as? ABIError, .invalidUTF8, "the link base is still read strictly") }
        XCTAssertNotNil(board.policyUnread, "Publish says why it is off")
    }

    func testAReadablePolicyComesWithTheFeed() async throws {
        let stack = Self.stack
        MomentsChainStub.install { stack.answer($0, $1) }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let board = try await readBoard(service)
        XCTAssertEqual(board.moments.count, 3)
        XCTAssertEqual(try board.policy.get()?.externalBaseURI, MomentsAddresses.expectedExternalBaseURI)
        XCTAssertNil(board.policyUnread)
    }

    func testTheFeedStillThrowsWhenItsMomentsCantBeRead() async throws {
        let stack = Self.stack
        MomentsChainStub.install({ stack.answer($0, $1) }, breaking: [stack.addresses.collect])
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        do {
            let board = try await readBoard(service)
            XCTFail("the feed answered \(board.moments.map(\.id))")
        } catch {}
    }

    /// The tab wires it in: the list and the terms read side by side and each shown as it lands — the list never waits on
    /// the terms, nor the terms on the list (until build 23 one `board` read held the list until the terms answered) — a
    /// value read again as it was isn't set again, and the header says why Publish is off.
    func testTheMomentsTabLoadsItsListWithoutThePolicy() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let source = try String(contentsOf: app.appendingPathComponent("Moments/MomentsView.swift"), encoding: .utf8)
        let load = try XCTUnwrap(source.range(of: "func load(env: AppEnvironment, account: Address?) async {"))
        let body = String(source[load.upperBound...])
        let terms = try XCTUnwrap(body.range(of: "async let termsRead = Self.terms(env: env)"))
        let list = try XCTUnwrap(body.range(of: "let list = try await env.moments.moments(limit: 60)"))
        let shown = try XCTUnwrap(body.range(of: "if moments != list { moments = list }"))
        let awaited = try XCTUnwrap(body.range(of: "let terms = await termsRead"))
        XCTAssertTrue(terms.upperBound < list.lowerBound && list.upperBound < shown.lowerBound && shown.upperBound < awaited.lowerBound,
                      "the terms are asked for first, and the list is shown before they are awaited")
        XCTAssertTrue(body.contains("if policy != read { policy = read }"))
        XCTAssertTrue(body.contains("let unread = MomentsBoard(moments: [], policy: terms).policyUnread"))
        XCTAssertTrue(body.contains("if policyUnread != unread { policyUnread = unread }"))
        XCTAssertTrue(source.contains("if let unread = model.policyUnread {"))
        XCTAssertFalse(source.contains("env.moments.board("), "never one read holding the list for the terms")
        XCTAssertFalse(source.contains("try await (policyTask, listTask)"), "the list never waits on the policy")
    }
}
