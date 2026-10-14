import BigInt
import XCTest
@testable import DyorKit

/// A read that fails as a whole — the node refuses `eth_call`, or a contract every item needs makes the call fail — is
/// an error, never an empty or shorter list: the Launch board, the board with every launchpad, the Moments feed, the
/// wallet's Moments and its launch holdings each throw (the per-item reads never turn such a failure into "none").
final class WholeReadFailureTests: XCTestCase {
    private func throwsError<T>(_ label: String, _ body: () async throws -> T) async {
        do {
            let value = try await body()
            XCTFail("\(label) answered \(String(describing: value)) instead of throwing")
        } catch {}
    }

    private static let wallet = [HonestyLaunchpad.alpha, HonestyLaunchpad.beta].map { Token(address: $0, symbol: "?", name: "?", decimals: 18) }

    func testANodeThatRefusesCallsFailsEveryList() async {
        let chain = HonestyLaunchpad()
        let moments = TextMomentsChain(failing: .text)
        MomentsChainStub.install({ to, data in chain.answer(to, data) ?? moments.answer(to, data) }, refusing: ["eth_call"])
        let launchpad = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: TextMomentsChain.stack.addresses)
        await throwsError("launches()") { try await launchpad.launches().map(\.token) }
        await throwsError("allLaunches()") { try await launchpad.allLaunches().map(\.token) }
        await throwsError("heldLaunches") { try await launchpad.heldLaunches(Self.wallet).launches.keys.map { $0 } }
        await throwsError("moments()") { try await service.moments().map(\.id) }
        await throwsError("infos(ids:)") { try await service.infos(ids: [1, 2]).map(\.id) }
    }

    func testALaunchpadWhoseFactoryBreaksEveryCallFailsItsLists() async {
        let chain = HonestyLaunchpad()
        MomentsChainStub.install({ chain.answer($0, $1) }, breaking: [HonestyLaunchpad.live.factory])
        let launchpad = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        await throwsError("launches()") { try await launchpad.launches().map(\.token) }
        await throwsError("allLaunches()") { try await launchpad.allLaunches().map(\.token) }
        await throwsError("heldLaunches") { try await launchpad.heldLaunches(Self.wallet).launches.keys.map { $0 } }
    }

    func testCurvesThatBreakEveryCallFailTheBoard() async {
        let chain = HonestyLaunchpad()
        MomentsChainStub.install({ chain.answer($0, $1) }, breaking: [HonestyLaunchpad.curve(HonestyLaunchpad.alpha), HonestyLaunchpad.curve(HonestyLaunchpad.beta)])
        let launchpad = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        await throwsError("launches()") { try await launchpad.launches().map(\.token) }
        await throwsError("allLaunches()") { try await launchpad.allLaunches().map(\.token) }
    }

    func testAMomentsCohortWhoseLedgerBreaksEveryCallFailsItsLists() async {
        let moments = TextMomentsChain(failing: .text)
        MomentsChainStub.install({ moments.answer($0, $1) }, breaking: [TextMomentsChain.stack.addresses.collect])
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: TextMomentsChain.stack.addresses)
        await throwsError("moments()") { try await service.moments().map(\.id) }
        await throwsError("infos(ids:)") { try await service.infos(ids: [1, 2]).map(\.id) }
        await throwsError("info(id: 1)") { try await service.info(id: 1).map(\.id) }
    }

    func testAMomentsFactoryThatBreaksEveryCallFailsItsLists() async {
        let moments = TextMomentsChain(failing: .text)
        MomentsChainStub.install({ moments.answer($0, $1) }, breaking: [TextMomentsChain.stack.addresses.factory])
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: TextMomentsChain.stack.addresses)
        await throwsError("moments()") { try await service.moments().map(\.id) }
        await throwsError("infos(ids:)") { try await service.infos(ids: [1, 2]).map(\.id) }
    }
}
