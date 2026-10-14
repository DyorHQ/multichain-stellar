import BigInt
import XCTest
@testable import DyorKit

/// The app never sends `graduateFallback`, on any stack (owner decision 2026-09-28): DyorHQ's keepers finish a stuck
/// Monday graduation with the gas it needs. The plan builder refuses it for a launch of every generation, whatever its
/// venue or state, no screen of the app offers it, and a passkey account refuses it whatever the sheet declared or a
/// Face ID approved. The plain Retry Graduation (`graduatePlan`) stays, on every stack.
final class KeeperFallbackTests: XCTestCase {
    private let token = Address(literal: "0x00000000000000000000000000000000000d1100")
    private let curve = Address(literal: "0x00000000000000000000000000000000000d11c0")
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")

    /// The live (v2) stack (a fixture while the mainnet table is pending), then the four retired ones: one of each
    /// generation, and both v1 stacks.
    private var stacks: [LaunchpadAddresses] { [V2Fixture.launchpad] + LaunchpadAddresses.retiredStacks }

    private func launch(on factory: Address, venue: GraduationVenue, phase: LaunchPhase = .bonding, completed: Bool = true) -> Launch {
        Launch(token: token, curve: curve, deployer: account, creatorFeeRecipient: account, pairToken: .zero, graduationThreshold: 1_000, creatorTaxBps: 0, poolFeeBps: 100,
               tickSpacing: 60, holderFeeSharing: false, graduationVenue: venue, phase: phase, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: Data(count: 32),
               name: "Stuck", symbol: "STK", logo: "", description: "", socials: .none, pair: .mon, price: 0, realQuoteReserve: 1_000, completed: completed,
               rescued: false, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 10_000, factory: factory)
    }

    func testGraduateFallbackIsRefusedOnEveryGeneration() async {
        let service = LaunchpadService(rpc: RPCClient(url: Monad.defaultRPC), addresses: V2Fixture.launchpad)
        XCTAssertEqual(Set(stacks.map(\.generation)), Set(LaunchpadAddresses.Generation.allCases), "every generation is covered")
        for stack in stacks {
            for venue in GraduationVenue.allCases {
                for (phase, completed) in [(LaunchPhase.bonding, true), (.bonding, false), (.migrating, true), (.graduated, true), (.refund, true)] {
                    let stuck = launch(on: stack.factory, venue: venue, phase: phase, completed: completed)
                    let label = "\(stack.factory.short) \(stack.generation) \(venue.title) \(phase.title)"
                    do {
                        let plan = try await service.graduateFallbackPlan(launch: stuck)
                        XCTFail("\(label): the app planned graduateFallback: \(plan.map(\.label))")
                    } catch {
                        XCTAssertEqual(error as? LaunchpadError, .graduateFallbackByKeepers, label)
                    }
                }
            }
            // Retry Graduation stays: the plain `graduate`, to the launch's own factory.
            let graduate = await service.graduatePlan(launch: launch(on: stack.factory, venue: .monday))
            XCTAssertEqual(graduate.map { $0.request?.to }, [stack.factory])
            XCTAssertEqual(graduate.first?.request?.data, LaunchpadABI.calldata(LaunchpadABI.Factory.graduate, [.address(token)]))
        }
        let message = LaunchpadError.graduateFallbackByKeepers.errorDescription ?? ""
        XCTAssertTrue(message.hasPrefix("DyorHQ's keepers will finish this graduation"), message)
        XCTAssertTrue(message.hasSuffix("Nothing was sent."), message)
    }

    /// Where the fallback exists (v1 and v2), a stuck Monday launch is the keepers' to finish; a Uniswap v4 launch has no
    /// fallback, and the pre-audit stacks have none at all.
    func testTheKeepersTakeEveryStuckMondayFallback() {
        for stack in stacks {
            let monday = launch(on: stack.factory, venue: .monday)
            XCTAssertEqual(monday.keepersTakeGraduateFallback, stack.generation >= .v1, "\(stack.factory.short) \(stack.generation)")
            XCTAssertFalse(launch(on: stack.factory, venue: .uniswapV4).keepersTakeGraduateFallback)
        }
        XCTAssertTrue(launch(on: .zero, venue: .monday).keepersTakeGraduateFallback, "the live (v2) stack")
    }

    /// A `graduateFallback` built by hand anyway, to any stack's factory at an ordinary gas limit: a passkey account
    /// refuses it before any prompt, under every intent. Over the fee bound it is still the fee that is named first.
    func testAPasskeyAccountRefusesGraduateFallbackOnEveryStack() {
        let gwei = BigUInt(10).power(9)
        let data = LaunchpadABI.calldata(LaunchpadABI.Factory.graduateFallback, [.address(token)])
        func prepared(_ to: Address, gasLimit: BigUInt) -> Mera.SigningPolicy.Call {
            Mera.SigningPolicy.Call(PreparedTransaction(from: account, to: to, data: data, value: 0, nonce: 1, gasLimit: gasLimit,
                                                         maxFeePerGas: 110 * gwei, maxPriorityFeePerGas: 2 * gwei, chainId: Monad.chainId))
        }
        let intents: [Mera.Intent] = [.ask, .alwaysAsks(.unlisted), .alwaysAsks(.launch), .momentsClaim,
                                      .launchpadSell(token: token, amount: 1, usd: 1)]
        for stack in stacks {
            for intent in intents {
                XCTAssertEqual(Mera.SigningPolicy.refusal(prepared(stack.factory, gasLimit: 1_000_000), intent: intent, account: account), .graduateFallback, stack.factory.short)
                // A preview of the step (no fee yet) is refused the same way, so the sheet's button never enables.
                XCTAssertEqual(Mera.SigningPolicy.refusal(.init(from: account, to: stack.factory, data: data), intent: intent, account: account), .graduateFallback)
            }
            XCTAssertEqual(Mera.SigningPolicy.refusal(prepared(stack.factory, gasLimit: 22_100_000), intent: .ask, account: account), .networkFee)
        }
        XCTAssertEqual(Mera.SigningPolicy.Reason.graduateFallback.summary, "a graduation fallback, which only DyorHQ’s keepers send")
        // The plain graduate is not refused (it is on no list, so it asks like any unlisted call).
        let graduate = Mera.SigningPolicy.Call(from: account, to: V2Fixture.launchpad.factory, data: LaunchpadABI.calldata(LaunchpadABI.Factory.graduate, [.address(token)]))
        XCTAssertNil(Mera.SigningPolicy.refusal(graduate, intent: .ask, account: account))
    }

    /// No screen offers it: no source file of the app plans `graduateFallback`, encodes it or shows its old button.
    func testNoScreenOffersTheFallback() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = (FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the app's sources were found")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "LaunchpadView.swift" })
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["graduateFallbackPlan", "graduateFallback(address)", "Graduate on Uniswap v4", "appSendsGraduateFallback"] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) mentions \(banned)")
            }
        }
    }
}
