import BigInt
import XCTest
@testable import DyorKit

/// Coins on a retired launchpad's curve are sell-only (owner decision 2026-09-28): on each of the four retired stacks a
/// curve buy is refused at the plan, whatever the pair or phase, and so is a developer buy through a retired router,
/// while a sell on the same curve still plans. The live (v2) stack's buys are unaffected. The coin page trades on the
/// curve only while it takes a sell (refund mode included). Home's token page, the Portfolio's holdings and Swap's "no
/// venue" state send the holder of any coin still on a curve, live or retired, to that page (`LaunchpadCurveRoutingTests`).
final class RetiredLaunchpadTests: XCTestCase {
    private let token = Address(literal: "0x00000000000000000000000000000000000d1100")
    private let curve = Address(literal: "0x00000000000000000000000000000000000d11c0")
    private let recipient = Address(literal: "0x000000000000000000000000000000000000beef")
    private let quoteIn = BigUInt(750_000_000)
    private var usdcPair: PairInfo { PairInfo(address: Monad.usdc, symbol: "USDC", decimals: 6, isNative: false) }

    private var retired: [LaunchpadAddresses] { LaunchpadAddresses.retiredStacks }

    override func setUp() {
        super.setUp()
        MomentsChainStub.install { _, _ in nil }
    }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func service(_ addresses: LaunchpadAddresses = V2Fixture.launchpad) -> LaunchpadService {
        LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: addresses, logsRPC: MomentsChainStub.rpc())
    }

    private func launch(on factory: Address, pair: PairInfo = .mon, phase: LaunchPhase = .bonding, completed: Bool = false, rescued: Bool = false) -> Launch {
        Launch(token: token, curve: curve, deployer: recipient, creatorFeeRecipient: recipient, pairToken: pair.address, graduationThreshold: 1_000, creatorTaxBps: 0,
               poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: true, graduationVenue: .uniswapV4, phase: phase, sweptQuote: 0, sweptTokens: 0, sweptAt: 0,
               poolId: Data(count: 32), name: "Old", symbol: "OLD", logo: "", description: "", socials: .none, pair: pair, price: 0, realQuoteReserve: 0,
               completed: completed, rescued: rescued, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0, factory: factory)
    }

    /// A launch's states as the chain leaves them: climbing, completed with its graduation stuck (the record still says
    /// NotGraduated), swept mid-migration, graduated, and rescued into refund mode.
    private static let states: [(name: String, phase: LaunchPhase, completed: Bool, rescued: Bool)] = [
        ("climbing", .bonding, false, false), ("stuck", .bonding, true, false), ("migrating", .migrating, true, false),
        ("graduated", .graduated, true, false), ("refund", .refund, true, true),
    ]

    private func sellOnlyInput(initialBuy: BigUInt) -> LaunchInput {
        LaunchInput(name: "Old", symbol: "OLD", pairToken: .zero, initialBuy: initialBuy, minTokensOut: 1, expectedEconomics: Data(repeating: 0xab, count: 32))
    }

    // MARK: Which coins

    func testEveryRetiredStackIsSellOnlyUntilItsCoinsGraduate() {
        XCTAssertEqual(retired.map(\.factory), [
            Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB"),
            Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"),
            Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"),
            Address(literal: "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea"),
        ])
        XCTAssertEqual(LaunchpadAddresses.retiredRouters, retired.map(\.router))
        for stack in retired {
            XCTAssertTrue(LaunchpadAddresses.isRetired(stack.factory))
            for phase in LaunchPhase.allCases {
                let coin = launch(on: stack.factory, phase: phase)
                XCTAssertTrue(coin.isRetiredLaunchpad)
                XCTAssertEqual(coin.isSellOnly, phase != .graduated, "\(stack.factory.short) \(phase.title): a graduated coin trades both ways")
            }
        }
        // The live stack (v2; `.zero` means the live one) and a stack the app doesn't know are not retired.
        for factory in [Address.zero, V2Fixture.launchpad.factory, Address(literal: "0x00000000000000000000000000000000000f00d0")] {
            XCTAssertFalse(LaunchpadAddresses.isRetired(factory))
            for phase in LaunchPhase.allCases {
                XCTAssertFalse(launch(on: factory, phase: phase).isRetiredLaunchpad)
                XCTAssertFalse(launch(on: factory, phase: phase).isSellOnly)
            }
        }
        XCTAssertEqual(RetiredLaunchpad.notice, "This coin's launchpad is retired: you can sell, but not buy.")
    }

    // MARK: Plans

    /// A curve buy on each retired stack, MON or ERC-20 pair, in every phase: refused before any step is built, so not even
    /// the approval is signed.
    func testABuyOnEveryRetiredCurveIsRefusedAtThePlan() async {
        let service = service()
        for stack in retired {
            for pair in [PairInfo.mon, usdcPair] {
                for phase in LaunchPhase.allCases {
                    let label = "\(stack.factory.short) \(pair.symbol) \(phase.title)"
                    do {
                        let plan = try await service.buyPlan(launch: launch(on: stack.factory, pair: pair, phase: phase), quoteIn: quoteIn, minTokensOut: 1, recipient: recipient)
                        XCTFail("\(label): a buy on a retired curve was planned: \(plan.map(\.label))")
                    } catch {
                        XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad, label)
                    }
                }
            }
        }
        XCTAssertEqual(LaunchpadError.retiredLaunchpad.errorDescription, "This coin's launchpad is retired: you can sell, but not buy. Nothing was sent.")
        XCTAssertTrue(MomentsChainStub.calls().isEmpty, "refused without asking the chain")
    }

    /// Holders can still sell into each retired curve: approve the coin for the curve, then `sell`, paid to them.
    func testASellOnEveryRetiredCurveStillPlans() async {
        let service = service()
        for stack in retired {
            for phase in [LaunchPhase.bonding, .refund] {
                let plan = await service.sellPlan(launch: launch(on: stack.factory, phase: phase), tokensIn: 5_000, minQuoteOut: 1, recipient: recipient)
                XCTAssertEqual(plan.count, 2, stack.factory.short)
                XCTAssertEqual(plan[0].kind, .approve(token: token, spender: curve, amount: 5_000))
                XCTAssertEqual(plan[1].request?.to, curve)
                XCTAssertEqual(plan[1].request?.data, LaunchpadABI.calldata(LaunchpadABI.Curve.sell, [.uint(5_000), .uint(1), .address(recipient)]))
                XCTAssertEqual(plan[1].request?.value, 0)
            }
        }
    }

    /// The live (v2) stack's curve buys are unaffected: native MON on `value`, an ERC-20 pair approved first.
    func testAV2CurveBuyStillPlans() async throws {
        let service = service()
        for factory in [Address.zero, V2Fixture.launchpad.factory] {
            let native = try await service.buyPlan(launch: launch(on: factory), quoteIn: quoteIn, minTokensOut: 1, recipient: recipient)
            XCTAssertEqual(native.count, 1)
            XCTAssertEqual(native[0].request?.to, curve)
            XCTAssertEqual(native[0].request?.data, LaunchpadABI.calldata(LaunchpadABI.Curve.buy, [.uint(quoteIn), .uint(1), .address(recipient)]))
            XCTAssertEqual(native[0].request?.value, quoteIn)
            let erc20 = try await service.buyPlan(launch: launch(on: factory, pair: usdcPair), quoteIn: quoteIn, minTokensOut: 1, recipient: recipient)
            XCTAssertEqual(erc20.map(\.kind), [.approve(token: Monad.usdc, spender: curve, amount: quoteIn), .call])
            XCTAssertEqual(erc20[1].request?.value, 0)
        }
    }

    /// A build pointed at a retired stack (a misconfigured Debug override, say) plans no developer buy through its
    /// router: the sync plan and the app's async plan refuse it, the latter before any read. A launch without one is not
    /// a buy, so it still plans here; no build is pointed at a retired stack (a Release build takes only
    /// `LaunchpadAddresses.monadMainnet`), and 0x6B1C would not refuse it on chain (owner decision 2026-09-28: its whitelist
    /// stays off). v2's developer buy still plans.
    func testADeveloperBuyThroughARetiredRouterIsRefused() async throws {
        for stack in retired {
            let service = service(stack)
            do {
                let plan = try await service.launchPlan(sellOnlyInput(initialBuy: quoteIn), launchFee: 0, from: recipient)
                XCTFail("\(stack.router.short): launchAndBuy was planned: \(plan.map(\.label))")
            } catch {
                XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad)
            }
            do {
                let plan = try await service.launchPlan(sellOnlyInput(initialBuy: quoteIn), from: recipient)
                XCTFail("\(stack.router.short): launchAndBuy was planned: \(plan.map(\.label))")
            } catch {
                XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad)
            }
            let plain = try await service.launchPlan(sellOnlyInput(initialBuy: 0), launchFee: 0, from: recipient)
            XCTAssertEqual(plain.map { $0.request?.to }, [stack.factory])
        }
        XCTAssertTrue(MomentsChainStub.calls().isEmpty, "refused before the fee, the terms or the gate were read")
        let live = try await service().launchPlan(sellOnlyInput(initialBuy: quoteIn), launchFee: 5, from: recipient)
        XCTAssertEqual(live.map { $0.request?.to }, [V2Fixture.launchpad.router])
        XCTAssertEqual(live[0].request?.value, 5 + quoteIn)
    }

    // MARK: The coin page

    /// The curve ticket shows while the curve takes a sell: climbing, or in refund mode (fee-free, and on every stack
    /// without Buy). A completed curve still waiting to graduate refuses sells (`CurveNotTrading`): it is "Graduation
    /// pending", with Retry Graduation and the keepers' note, as is nothing mid-migration or graduated. Buying is open only
    /// on a climbing curve of the live stack.
    func testTheCoinPageTradesOnTheCurveOnlyWhileItTakesSells() {
        for factory in [V2Fixture.launchpad.factory] + retired.map(\.factory) {
            let isRetired = LaunchpadAddresses.isRetired(factory)
            for state in Self.states {
                let coin = launch(on: factory, phase: state.phase, completed: state.completed, rescued: state.rescued)
                let label = "\(factory.short) \(state.name)"
                XCTAssertEqual(coin.curveSellsOpen, ["climbing", "refund"].contains(state.name), label)
                XCTAssertEqual(coin.curveBuysOpen, state.name == "climbing" && !isRetired, label)
                XCTAssertEqual(coin.awaitsGraduation, state.name == "stuck", label)
                XCTAssertEqual(coin.statusTitle, state.name == "stuck" ? "Graduation pending" : state.phase.title, label)
                // Sell-only (no buy) on a retired launchpad until it graduates; graduated, it trades both ways on Swap.
                XCTAssertEqual(coin.isSellOnly, isRetired && state.phase != .graduated, label)
            }
        }
    }

    /// The source wires those answers in: the coin page picks its ticket by `curveSellsOpen` and offers Retry Graduation
    /// only while the launch awaits it. (Which screens send a coin to this page: `LaunchpadCurveRoutingTests`.)
    func testTheScreensFollowTheCurveState() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let launchpad = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadView.swift"), encoding: .utf8)
        XCTAssertTrue(launchpad.contains("if launch.curveSellsOpen { ticketSection } else { graduatedSection }"))
        XCTAssertTrue(launchpad.contains("private var isStuck: Bool { launch.awaitsGraduation && (detail?.stuckSince ?? 0) > 0 }"))
        XCTAssertFalse(launchpad.contains("if launch.phase == .bonding { ticketSection }"))
    }
}
