import BigInt
import XCTest
@testable import DyorKit

/// A held coin still on a launchpad's bonding curve trades on that curve, from its Launch page: no Swap venue routes a
/// bonding curve, the live launchpad's (v2, the fixture here) or a retired one's. The Portfolio's holdings, Home's token
/// page and Swap's "no venue" state ask where such a coin trades (`CurveRoute`), from one aggregate over every known
/// factory's record, and open its Launch page: Buy and Sell on the live curve, Sell only on a retired one. A graduated coin
/// opens Swap. While v2 is pending nothing is asked of address 0, and a read that fails says so and leads somewhere: a coin
/// whose launch couldn't be read opens its page by reference, never the board, which doesn't list a retired launchpad's
/// sell-only coin. Contract reads are answered by `MomentsChainStub`; Kuru Flow by `SwapNetStub`.
final class LaunchpadCurveRoutingTests: XCTestCase {
    private let other = Token(address: Address(literal: "0x00000000000000000000000000000000000c0300"), symbol: "NEW", name: "New coin", decimals: 18)
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")

    override func setUp() {
        super.setUp()
        SwapNetStub.reset()
        MomentsChainStub.install { _, _ in nil }
    }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    /// The service as the app builds it once v2 is wired (the fixture), or, `pending`, with the live stack at address 0.
    private func service(pending: Bool = false) -> LaunchpadService {
        LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: pending ? LaunchpadAddresses(poolManager: Uniswap.poolManager, generation: .v2) : V2Fixture.launchpad,
                         logsRPC: MomentsChainStub.rpc())
    }

    private func engine() -> SwapEngine {
        SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session(), launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: V2Fixture.launchpad))
    }

    private func token(_ chain: CurveCoinChain) -> Token {
        Token(address: chain.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
    }

    private func request(_ tokenIn: Token, _ tokenOut: Token) -> SwapRequest {
        SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: BigUInt(10).power(18), slippageBps: 50, account: account, exactApprovals: true)
    }

    /// Every factory the live service asks, in order: the live one, then each retired one.
    private var allFactories: [Address] { CurveCoinChain.factories.map(\.factory) }

    /// A launch's states before graduation as the chain leaves them: climbing, full with its graduation stuck (the record
    /// still says NotGraduated), swept mid-migration, and rescued into refund mode.
    private static let onCurve: [(name: String, phase: LaunchPhase, completed: Bool, rescued: Bool)] = [
        ("climbing", .bonding, false, false), ("stuck", .bonding, true, false), ("migrating", .migrating, true, false), ("refund", .refund, true, true),
    ]

    // MARK: The live launchpad

    /// A coin on the live launchpad's curve, in every state before graduation, opens its Launch page, where it can be
    /// bought and sold while the curve trades: found among the holdings (each non-core coin asked of every factory, the
    /// live one in its own record layout, in one aggregate), with its launch read from that record, and the same for one
    /// coin. The Swap engine has no venue for it either way; the "no venue" state points to the same page.
    func testALiveCurveCoinOpensItsLaunchPage() async throws {
        let service = service()
        let engine = engine()
        for state in Self.onCurve {
            let chain = CurveCoinChain(stack: V2Fixture.launchpad, phase: state.phase, completed: state.completed, rescued: state.rescued)
            let coin = token(chain)
            let label = "v2 \(state.name)"
            MomentsChainStub.install(chain.answer)
            let found = try await service.curveHoldings([.mon, .usdc, coin, other, .wmon, coin])
            XCTAssertEqual(MomentsChainStub.batches().first?.map(\.to), allFactories + allFactories,
                           "\(label): the coin and the other token, each asked of every factory, the live one first, in one read")
            XCTAssertEqual(MomentsChainStub.batches().count, 2, "\(label): the records, then the launch, from those records")
            XCTAssertEqual(found.coins, [chain.coin], label)
            XCTAssertEqual(found.factories, [chain.coin: V2Fixture.launchpad.factory], label)
            let launch = try XCTUnwrap(found.launches[chain.coin], label)
            XCTAssertEqual(launch.curve, chain.curve, label)
            XCTAssertEqual(launch.factory, V2Fixture.launchpad.factory, label)
            XCTAssertEqual(launch.generation, .v2, label)
            XCTAssertEqual(launch.phase, state.phase, label)
            XCTAssertEqual(launch.symbol, "OLD", label)
            XCTAssertFalse(launch.isRetiredLaunchpad, label)
            XCTAssertFalse(launch.isSellOnly, label)

            let route = found.route(chain.coin)
            XCTAssertEqual(route, .launchPage(launch), label)
            XCTAssertTrue(route.isOnCurve, label)
            XCTAssertEqual(found.route(other.address), .swap, "\(label): a coin no launchpad has on its curve opens Swap")
            switch state.name {
            case "climbing":
                XCTAssertTrue(launch.curveBuysOpen, "\(label): the live curve takes buys")
                XCTAssertEqual(route.notice, LaunchpadCurve.tradeOnLaunchPage, label)
                XCTAssertEqual(route.rowNote, "Buy or sell on its Launch page", label)
                XCTAssertEqual(route.actionTitle("OLD"), "Trade OLD on its Launch page", label)
            case "refund":
                XCTAssertFalse(launch.curveBuysOpen, label)
                XCTAssertTrue(launch.curveSellsOpen, label)
                XCTAssertEqual(route.notice, LaunchpadCurve.refundOnLaunchPage, label)
                XCTAssertEqual(route.rowNote, "Sell on its Launch page", label)
                XCTAssertEqual(route.actionTitle("OLD"), "Sell OLD on its Launch page", label)
            default:
                XCTAssertFalse(launch.curveSellsOpen, "\(label): nothing trades until it graduates")
                XCTAssertEqual(route.notice, LaunchpadCurve.graduationPending, label)
                XCTAssertEqual(route.rowNote, "Graduation pending · Launch page", label)
                XCTAssertEqual(route.actionTitle("OLD"), "Open OLD's Launch page", label)
            }

            // Home's token page knows only the coin.
            let single = await service.curveRoute(for: coin)
            XCTAssertEqual(single, route, label)

            // Swap: no venue routes it, bought or sold, and a buy of a live coin isn't refused as a retired one's; the
            // "no venue" state points to the Launch page of the side on the curve.
            for (pay, receive) in [(Token.mon, coin), (coin, Token.usdc)] {
                SwapNetStub.reset()
                let result = await engine.quotes(for: request(pay, receive))
                XCTAssertTrue(result.quotes.isEmpty, "\(label) \(pay.symbol) → \(receive.symbol): \(result.quotes.map(\.route))")
                XCTAssertFalse(result.errors.values.contains(RetiredLaunchpad.notice), label)
                let deadEnd = await service.curveRoute(among: [receive, pay])
                XCTAssertEqual(deadEnd, CurveCoinRoute(token: coin, route: route), "\(label) \(pay.symbol) → \(receive.symbol)")
            }
        }
    }

    // MARK: Retired launchpads

    /// A coin on each retired launchpad's curve, in every state before graduation, opens its Launch page too, where it is
    /// sell-only: found in the same aggregate (each factory in its own layout, the legacy one's 16-field record included),
    /// with its launch, and what each screen says. Swap refuses to buy it, and its "no venue" state points to the page.
    func testARetiredCurveCoinOpensItsLaunchPageSellOnly() async throws {
        let service = service()
        let engine = engine()
        for stack in LaunchpadAddresses.retiredStacks {
            for state in Self.onCurve {
                let chain = CurveCoinChain(stack: stack, phase: state.phase, completed: state.completed, rescued: state.rescued)
                let coin = token(chain)
                let label = "\(stack.factory.short) \(state.name)"
                MomentsChainStub.install(chain.answer)
                let found = try await service.curveHoldings([coin, .usdc])
                XCTAssertEqual(MomentsChainStub.batches().first?.map(\.to), allFactories, "\(label): one read of every factory")
                XCTAssertEqual(found.factories, [chain.coin: stack.factory], label)
                let launch = try XCTUnwrap(found.launches[chain.coin], label)
                XCTAssertEqual(launch.factory, stack.factory, label)
                XCTAssertEqual(launch.generation, stack.generation, label)
                XCTAssertEqual(launch.phase, state.phase, label)
                XCTAssertTrue(launch.isSellOnly, label)
                XCTAssertFalse(launch.curveBuysOpen, "\(label): nobody buys on a retired curve")

                let route = found.route(chain.coin)
                XCTAssertEqual(route, .launchPage(launch), label)
                XCTAssertEqual(route.notice, RetiredLaunchpad.tokenPageNotice(launch), label)
                if ["climbing", "refund"].contains(state.name) {
                    XCTAssertEqual(route.notice, RetiredLaunchpad.sellOnLaunchPage, label)
                    XCTAssertEqual(route.rowNote, "Sell on its Launch page", label)
                    XCTAssertEqual(route.actionTitle("OLD"), "Sell OLD on its Launch page", label)
                } else {
                    XCTAssertEqual(route.notice, RetiredLaunchpad.graduationPending, label)
                    XCTAssertEqual(route.rowNote, "Graduation pending · Launch page", label)
                    XCTAssertEqual(route.actionTitle("OLD"), "Open OLD's Launch page", label)
                }
                let single = await service.curveRoute(for: coin)
                XCTAssertEqual(single, route, label)
                do {
                    let plan = try await service.buyPlan(launch: launch, quoteIn: 1_000, minTokensOut: 1, recipient: account)
                    XCTFail("\(label): a buy on its Launch page was planned: \(plan.map(\.label))")
                } catch {
                    XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad, label)
                }

                SwapNetStub.reset()
                let bought = await engine.quotes(for: request(.mon, coin))
                XCTAssertTrue(bought.quotes.isEmpty, label)
                XCTAssertEqual(bought.errors[.kuru], RetiredLaunchpad.notice, label)
                let deadEnd = await service.curveRoute(among: [coin, .mon])
                XCTAssertEqual(deadEnd, CurveCoinRoute(token: coin, route: route), label)
            }
        }
        XCTAssertEqual(RetiredLaunchpad.tokenPageNotice(nil), RetiredLaunchpad.sellOnLaunchPage)
        XCTAssertEqual(RetiredLaunchpad.sellOnLaunchPage, "This coin's launchpad is retired: you can sell it on its Launch page, but not buy.")
    }

    // MARK: Graduated coins

    /// A coin that graduated, from the live launchpad or any retired one, is an ordinary pool token: it opens Swap, with
    /// nothing said about a curve and no launch read. So does a coin no known launchpad launched.
    func testAGraduatedCoinOpensSwap() async throws {
        let service = service()
        for stack in CurveCoinChain.factories {
            let chain = CurveCoinChain(stack: stack, phase: .graduated, completed: true)
            let coin = token(chain)
            let label = stack.factory.short
            MomentsChainStub.install(chain.answer)
            let found = try await service.curveHoldings([coin, other])
            XCTAssertEqual(found, .none, label)
            XCTAssertEqual(MomentsChainStub.batches().count, 1, "\(label): the records alone; no launch is read")
            XCTAssertEqual(found.route(chain.coin), .swap, label)
            let single = await service.curveRoute(for: coin)
            XCTAssertEqual(single, .swap, label)
            XCTAssertNil(CurveRoute.swap.notice)
            XCTAssertNil(CurveRoute.swap.rowNote)
            XCTAssertNil(CurveRoute.swap.actionTitle("OLD"))
            XCTAssertFalse(CurveRoute.swap.isOnCurve)
            let deadEnd = await service.curveRoute(among: [coin, .mon])
            XCTAssertNil(deadEnd, "\(label): no side is on a curve, so Swap's venues simply have no route")
        }
    }

    // MARK: v2 pending

    /// While the live launchpad is pending (address 0), the check asks the retired factories alone: a retired coin still
    /// opens its Launch page, any other coin opens Swap, nothing is asked of address 0, and nothing traps.
    func testWhileV2IsPendingNothingIsAskedOfAddressZero() async throws {
        let service = service(pending: true)
        let stacks = await service.stacks
        XCTAssertEqual(stacks.map(\.factory), LaunchpadAddresses.retiredFactories)

        let retired = CurveCoinChain(stack: LaunchpadAddresses.retiredStacks[0], phase: .bonding)
        MomentsChainStub.install(retired.answer)
        let found = try await service.curveHoldings([token(retired), other])
        XCTAssertEqual(MomentsChainStub.batches().first?.map(\.to), LaunchpadAddresses.retiredFactories + LaunchpadAddresses.retiredFactories)
        XCTAssertEqual(found.route(retired.coin).launch?.factory, LaunchpadAddresses.retiredStacks[0].factory)
        XCTAssertEqual(found.route(other.address), .swap)
        let single = await service.curveRoute(for: other)
        XCTAssertEqual(single, .swap)
        let deadEnd = await service.curveRoute(among: [other, token(retired)])
        XCTAssertEqual(deadEnd?.token, token(retired))
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == .zero }, "an eth_call went to address 0")

        // A pending stack handed to the check itself is never asked either: no read at all.
        MomentsChainStub.install { _, _ in nil }
        let none = try await LaunchpadCurve.curveRecords([other.address], stacks: [LaunchpadAddresses(generation: .v2)], multicall: Multicall(rpc: MomentsChainStub.rpc()))
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(MomentsChainStub.calls().isEmpty)
    }

    // MARK: Failed reads

    /// A check that fails, or misses any factory's answer, can rule no coin in or out: the holdings keep what they knew
    /// (it throws), and a coin page says so and offers to check again, keeping Swap. A coin on a curve whose launch can't
    /// be read opens its Launch page by reference to the factory that recorded it, and nothing sends it to the Launch tab.
    /// MON and the app's own tokens are never read.
    func testAFailedReadSaysSoAndLeadsOn() async throws {
        let service = service()
        let live = CurveCoinChain(stack: V2Fixture.launchpad, phase: .bonding)
        let coin = token(live)

        // Nothing answers.
        do {
            let unchecked = try await service.curveHoldings([coin])
            XCTFail("a failed check returned \(unchecked)")
        } catch {}
        let single = await service.curveRoute(for: coin)
        XCTAssertEqual(single, .unchecked)
        XCTAssertEqual(single.notice, LaunchpadCurve.unchecked)
        XCTAssertTrue(LaunchpadCurve.unchecked.contains("check again"), "a way on: check again")
        XCTAssertFalse(LaunchpadCurve.unchecked.contains("Launch tab"), "the board doesn't list a retired launchpad's sell-only coin")
        XCTAssertNil(single.actionTitle("OLD"), "Swap stays offered, with Check Again beside it")
        XCTAssertFalse(single.isOnCurve)
        let deadEnd = await service.curveRoute(among: [.mon, coin])
        XCTAssertEqual(deadEnd, CurveCoinRoute(token: coin, route: .unchecked), "Swap's no-venue state says so, not a bare dead end")

        // One factory's answer missing (the live one reverts): no coin can be ruled out either.
        MomentsChainStub.install { to, data in to == V2Fixture.launchpad.factory ? nil : live.answer(to, data) }
        let partial = await service.curveRoute(for: coin)
        XCTAssertEqual(partial, .unchecked)

        // The records answer, the launch's own reads don't: its Launch page by reference, on the live launchpad and on a
        // retired one, in every state before graduation, to the factory that recorded it, with the phase its record gives.
        for stack in CurveCoinChain.factories {
            for state in Self.onCurve {
                let chain = CurveCoinChain(stack: stack, phase: state.phase, completed: state.completed, rescued: state.rescued, launchReads: false)
                let label = "\(stack.factory.short) \(state.name)"
                MomentsChainStub.install(chain.answer)
                let retired = LaunchpadAddresses.isRetired(stack.factory)
                let found = try await service.curveHoldings([token(chain)])
                XCTAssertEqual(found.coins, [chain.coin], label)
                XCTAssertEqual(found.phases, [chain.coin: state.phase], label)
                XCTAssertEqual(found.launches, [:], label)
                let route = found.route(chain.coin)
                let reference = LaunchReference(token: chain.coin, factory: stack.factory)
                XCTAssertEqual(route, .launchUnread(reference, retired: retired, phase: state.phase), label)
                XCTAssertEqual(route.reference?.factory, stack.factory, "\(label): the stack that recorded it")
                XCTAssertTrue(route.isOnCurve, "\(label): still never Swap")
                XCTAssertNil(route.launch, label)
                XCTAssertEqual(route.actionTitle("OLD"), "Open OLD's Launch page", label)
                switch state.phase {
                case .refund:
                    XCTAssertEqual(route.notice, LaunchpadCurve.refundLaunchUnread, label)
                    XCTAssertEqual(route.rowNote, "Sell it back on its Launch page", label)
                case .migrating:
                    XCTAssertEqual(route.notice, LaunchpadCurve.migratingLaunchUnread, label)
                    XCTAssertEqual(route.rowNote, "Migrating · Launch page", label)
                default:
                    XCTAssertEqual(route.notice, retired ? LaunchpadCurve.retiredLaunchUnread : LaunchpadCurve.launchUnread, label)
                    XCTAssertEqual(route.rowNote, retired ? "Sell on its Launch page" : "Trade on its Launch page", label)
                }
                for text in [route.notice, route.rowNote, route.actionTitle("OLD")] {
                    XCTAssertFalse(text?.contains("Launch tab") ?? true, "\(label): \(text ?? "nil")")
                    XCTAssertFalse(text?.contains("Refund & Migrating") ?? true, "\(label): \(text ?? "nil")")
                }
                let single = await service.curveRoute(for: token(chain))
                XCTAssertEqual(single, route, label)
            }
        }
        XCTAssertTrue(LaunchpadCurve.retiredLaunchUnread.hasPrefix(RetiredLaunchpad.sellOnLaunchPage), "the same words as a read launch's")

        // Only MON and the app's own tokens: nothing is read, and they open Swap.
        MomentsChainStub.install { _, _ in nil }
        let none = try await service.curveHoldings(Token.core + [.mon])
        XCTAssertEqual(none, .none)
        let mon = await service.curveRoute(for: .mon)
        XCTAssertEqual(mon, .swap)
        let pair = await service.curveRoute(among: [.usdc, .mon])
        XCTAssertNil(pair)
        XCTAssertTrue(MomentsChainStub.calls().isEmpty)
    }

    // MARK: By reference

    /// No route relies on the board: every coin still on a curve, on the live launchpad or a retired one, in every state
    /// before graduation, opens its page from its launch or, when that couldn't be read, by reference, which reads it from
    /// the stack that recorded it. A reference only points: a factory it names that records no such coin, or that the app
    /// doesn't serve (another factory, address 0, the live one while it is pending: never asked), is answered by whichever
    /// served stack has the coin on its curve, and no stack having it opens nothing ("Not a DyorHQ launch"). The Router
    /// and the Launch tab deliver the reference; the board is built from the coins it lists (`Launch.listsOnBoard`).
    func testEveryUnreadCurveCoinOpensItsPageByReference() async throws {
        let service = service()
        for stack in CurveCoinChain.factories {
            for state in Self.onCurve {
                let label = "\(stack.factory.short) \(state.name)"
                for reads in [true, false] {
                    let chain = CurveCoinChain(stack: stack, phase: state.phase, completed: state.completed, rescued: state.rescued, launchReads: reads)
                    MomentsChainStub.install(chain.answer)
                    let route = try await service.curveHoldings([token(chain)]).route(chain.coin)
                    XCTAssertTrue(route.isOnCurve, label)
                    XCTAssertTrue((route.launch != nil) != (route.reference != nil), "\(label): a launch or a reference, never neither: \(route)")
                    XCTAssertEqual(route.launch?.token ?? route.reference?.token, chain.coin, label)
                    XCTAssertEqual(route.launch?.factory ?? route.reference?.factory, stack.factory, label)
                }

                // The page reads the launch it names, from that stack.
                let chain = CurveCoinChain(stack: stack, phase: state.phase, completed: state.completed, rescued: state.rescued, pageReads: true)
                MomentsChainStub.install(chain.answer)
                let reference = LaunchReference(token: chain.coin, factory: stack.factory)
                let detail = try await service.launch(reference)
                let launch = try XCTUnwrap(detail?.launch, label)
                XCTAssertEqual(launch.token, chain.coin, label)
                XCTAssertEqual(launch.factory, stack.factory, label)
                XCTAssertEqual(launch.phase, state.phase, label)
                XCTAssertEqual(launch.isSellOnly, LaunchpadAddresses.isRetired(stack.factory), "\(label): sell-only on a retired launchpad")
                XCTAssertEqual(Set(MomentsChainStub.calls().map(\.to)).subtracting([stack.factory, stack.hook, chain.coin, chain.curve]), [],
                               "\(label): only that stack's factory and hook, the coin and its curve are asked")

                // A reference naming the wrong factory — another stack the app serves (the next one here), one it
                // doesn't, or address 0 — still opens the launch the coin's own factory records: the named stack (when
                // served) answers no such coin, one read asks every served stack for the coin's record, and the one that
                // has it on its curve is read. A factory the app doesn't serve is never asked. (One state per stack: the
                // record's phase plays no part.)
                let next = allFactories[(allFactories.firstIndex(of: stack.factory)! + 1) % allFactories.count]
                let wrongFactories = state.name == "climbing" ? [next, Address(literal: "0x00000000000000000000000000000000000f00d0"), .zero] : []
                for wrong in wrongFactories {
                    MomentsChainStub.install(chain.answer)
                    let resolved = try await service.launch(LaunchReference(token: chain.coin, factory: wrong))
                    XCTAssertEqual(resolved?.launch, launch, "\(label), named \(wrong.short)")
                    let asked = Set(MomentsChainStub.calls().map(\.to))
                    XCTAssertEqual(asked.subtracting(allFactories + [stack.hook, chain.coin, chain.curve]), [], "\(label), named \(wrong.short)")
                    XCTAssertTrue(asked.isSuperset(of: allFactories), "\(label), named \(wrong.short): every served stack is asked for the record")
                }

                // A factory that records no such coin, and no stack with it on its curve: nothing opens.
                MomentsChainStub.install(chain.answer)
                let unknownCoin = try await service.launch(LaunchReference(token: Address(literal: "0x00000000000000000000000000000000000c0bad"), factory: stack.factory))
                XCTAssertNil(unknownCoin, label)

                // A read that fails throws: the page says so and offers Try Again.
                MomentsChainStub.install(CurveCoinChain(stack: stack, phase: state.phase, launchReads: false).answer)
                do {
                    let read = try await service.launch(reference)
                    XCTFail("\(label): a failed read opened \(String(describing: read))")
                } catch {}
            }
        }

        // The live launchpad while it is pending, named by a reference to a coin on its curve: neither it nor address 0
        // is asked; the served (retired) stacks are, and none has the coin, so nothing opens.
        let live = CurveCoinChain(stack: V2Fixture.launchpad, phase: .bonding, pageReads: true)
        MomentsChainStub.install(live.answer)
        let pending = try await self.service(pending: true).launch(LaunchReference(token: live.coin, factory: V2Fixture.launchpad.factory))
        XCTAssertNil(pending)
        XCTAssertEqual(Set(MomentsChainStub.calls().map(\.to)), Set(LaunchpadAddresses.retiredFactories), "only the served stacks are asked for the record")

        // With no stack answering, a reference naming a factory the app doesn't serve can't be ruled out either: the read
        // throws (Try Again), and the named factory and address 0 are still never asked.
        MomentsChainStub.install { _, _ in nil }
        let stranger = Address(literal: "0x00000000000000000000000000000000000f00d0")
        for factory in [stranger, .zero] {
            do {
                let opened = try await service.launch(LaunchReference(token: live.coin, factory: factory))
                XCTFail("\(factory.short): an unread chain opened \(String(describing: opened))")
            } catch {}
        }
        XCTAssertEqual(Set(MomentsChainStub.calls().map(\.to)), Set(allFactories), "nothing was asked of a factory the app doesn't serve")

        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }

        // The Router: one helper for every screen, from its launch or by reference; the last request wins.
        let router = try String(contentsOf: app.appendingPathComponent("App/Router.swift"), encoding: .utf8)
        let helper = try XCTUnwrap(router.range(of: "func openLaunchPage(for route: CurveRoute) {"))
        let helperEnd = try XCTUnwrap(router.range(of: "\n    }\n", range: helper.upperBound..<router.endIndex))
        let body = String(router[helper.upperBound..<helperEnd.lowerBound])
        XCTAssertTrue(body.contains("switch route {"), "exhaustive: a new case is a compile error here")
        XCTAssertTrue(body.contains("case .launchPage(let launch): openLaunch(launch)"))
        XCTAssertTrue(body.contains("case .launchUnread(let reference, _, _): openLaunch(reference)"))
        XCTAssertFalse(body.contains("default"))
        XCTAssertTrue(router.contains("func openLaunch(_ launch: Launch) {\n        pendingLaunchReference = nil\n        pendingLaunch = launch\n        tab = .launch"))
        XCTAssertTrue(router.contains("func openLaunch(_ reference: LaunchReference) {\n        pendingLaunch = nil\n        pendingLaunchReference = reference\n        tab = .launch"))

        // The Launch tab pushes the loader as a page of its one typed path (a stack bound to a typed path pushes its own
        // element type and nothing else: never `navigationDestination(item:)`), delivered however the tab was built; the
        // loader reads through the service.
        let source = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct LaunchpadView: View {"))
        let end = try XCTUnwrap(source.range(of: "enum LaunchSort", range: start.upperBound..<source.endIndex))
        let board = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(source.contains("enum LaunchPage: Hashable {\n    case launch(Launch)\n    case reference(LaunchReference)\n"))
        XCTAssertTrue(source.contains("    var token: Address {\n        switch self {\n        case .launch(let launch): return launch.token\n        case .reference(let reference): return reference.token\n        }\n    }"), "a page is its coin's, however it was opened")
        XCTAssertTrue(board.contains("@State private var path: [LaunchPage] = []"))
        XCTAssertTrue(board.contains(".navigationDestination(for: LaunchPage.self) { page in\n                switch page {\n                case .launch(let launch): LaunchDetailView(launch: launch)\n                case .reference(let reference): LaunchReferenceView(reference: reference)\n                }\n            }"))
        XCTAssertFalse(board.contains("navigationDestination(item:"))
        XCTAssertFalse(board.contains("navigationDestination(isPresented:"))
        XCTAssertEqual(board.components(separatedBy: "NavigationLink(value: page(for: launch, saved: ").count - 1, 2, "each grid's cards push a page")
        XCTAssertTrue(board.contains("NavigationLink(value: page(for: launch, saved: saved))"), "a section's, saved as its coins are")
        XCTAssertTrue(board.contains("NavigationLink(value: page(for: launch, saved: boardSaved))"), "Explore's")
        // A card saved when the board was last read pushes its reference: the page reads the launch now.
        XCTAssertTrue(board.contains("saved ? .reference(LaunchReference(token: launch.token, factory: launch.factory)) : .launch(launch)"))
        XCTAssertTrue(board.contains("private var boardSaved: Bool { model.savedAt != nil }"))
        XCTAssertFalse(board.contains("NavigationLink(value: launch)"))
        XCTAssertTrue(board.contains(".onChange(of: router.pendingLaunch) { _, launch in\n                guard let launch else { return }\n                open(.launch(launch))\n                router.pendingLaunch = nil"))
        XCTAssertTrue(board.contains(".onChange(of: router.pendingLaunchReference) { _, reference in\n                guard let reference else { return }\n                open(.reference(reference))\n                router.pendingLaunchReference = nil"))
        XCTAssertTrue(board.contains("if let launch = router.pendingLaunch { path = [.launch(launch)]; router.pendingLaunch = nil }"), "delivered on appear too")
        XCTAssertTrue(board.contains("if let reference = router.pendingLaunchReference { path = [.reference(reference)]; router.pendingLaunchReference = nil }"), "delivered on appear too")
        XCTAssertTrue(board.contains("private func open(_ page: LaunchPage) {\n        if path.last?.token != page.token { path.append(page) }\n    }"),
                      "pushed once per coin: Home's copy of a launch, or a reference to it, never stacks a second page over the coin's")
        XCTAssertFalse(board.contains("path.last != page"))
        // An account that takes over in place (Session.adopt, watch) doesn't rebuild the tabs: the previous account's
        // pages go with it.
        XCTAssertTrue(board.contains(".onChange(of: session.address) { _, _ in path = [] }"))
        let loader = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchReferenceView.swift"), encoding: .utf8)
        XCTAssertTrue(loader.contains("try await env.launchpad.launch(reference)"))
        XCTAssertTrue(loader.contains("LaunchDetailView(launch: launch)"))
        XCTAssertTrue(loader.contains("\"Not a DyorHQ launch\""))
        XCTAssertTrue(loader.contains("Button(\"Try Again\")"))
        XCTAssertTrue(loader.contains("Link(\"View on Monadscan\", destination: Monad.explorerToken(reference.token))"))
        XCTAssertTrue(loader.contains(".task(id: reference)"))

        // The board: every public section is taken once from `matching`, which holds only the coins it lists.
        XCTAssertTrue(board.contains("private var matching: [Launch] { searched(model.launches.filter(\\.listsOnBoard)) }"))
        for section in LaunchBoardSection.allCases {
            XCTAssertEqual(board.components(separatedBy: "matching.filter { $0.phase.boardSection == .\(section) }").count - 1, 1, "\(section): listed once, searched too")
        }
        XCTAssertFalse(board.contains("matching.filter { $0.phase =="), "no section picks its phases by hand")
        XCTAssertEqual(board.components(separatedBy: "model.launches").count - 1, 2, "only the listed coins and the first load")
        XCTAssertTrue(board.contains("if graduated.isEmpty, climbing.isEmpty, refundAndMigrating.isEmpty, sellOnly.isEmpty, !firstLoad {"))
        XCTAssertTrue(board.contains("if !refundAndMigrating.isEmpty {\n                        section(title: \"Refund & Migrating\", count: refundAndMigrating.count,"))
        XCTAssertTrue(board.contains("coins: refundAndMigrating, saved: boardSaved)"))
        XCTAssertEqual(Set(LaunchPhase.allCases.map(\.boardSection)), Set(LaunchBoardSection.allCases), "every section lists some phase")
    }

    // MARK: The screens

    /// The sources wire those answers in. The Portfolio checks before listing and sends a coin on a curve to its Launch
    /// page (by reference when unread) ahead of its one Swap row; Home's token page does the same for its coin, with Check
    /// Again when the check failed; Home's launch holdings open each launch's own page, and list a created coin at a zero
    /// balance only while the board lists it; My Launchpad lists the coins launched the same way but reads creator fees
    /// for every one; Swap's "no venue" state asks and points to the Launch page.
    func testTheScreensSendACurveCoinToItsLaunchPage() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let toLaunch = "router.openLaunchPage(for: route)"

        let assets = try String(contentsOf: app.appendingPathComponent("Portfolio/AssetsModel.swift"), encoding: .utf8)
        // The coins on a curve come from the read that values the list (`HeldLaunches.curve`): the launchpads are asked once.
        XCTAssertTrue(assets.contains("found = result.curve"))
        let checked = try XCTUnwrap(assets.range(of: "if let found { curve = found }"))
        let listed = try XCTUnwrap(assets.range(of: "tokens = ranked\n"))
        XCTAssertLessThan(checked.lowerBound, listed.lowerBound, "known before the token list shows")
        let curveRow = try XCTUnwrap(assets.range(of: "} else if route.isOnCurve {"))
        let swapRow = try XCTUnwrap(assets.range(of: "Button { router.openSwap(tokenIn: asset.token,"))
        XCTAssertLessThan(curveRow.lowerBound, swapRow.lowerBound, "a coin on a curve is caught before the Swap row")
        let branch = String(assets[curveRow.upperBound..<swapRow.lowerBound])
        XCTAssertTrue(branch.contains(toLaunch))
        XCTAssertTrue(branch.contains("tokenRow(asset, note: route.rowNote"))
        XCTAssertFalse(branch.contains("openSwap"))
        XCTAssertEqual(assets.components(separatedBy: "router.openSwap(").count - 1, 1, "one Swap row, for the other coins")

        let home = try String(contentsOf: app.appendingPathComponent("Home/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("let route = await env.launchpad.curveRoute(for: row.token)"))
        XCTAssertTrue(home.contains("} else if let route = curveRoute, route.isOnCurve, let title = route.actionTitle(row.token.symbol) {"))
        XCTAssertTrue(home.contains(toLaunch))
        XCTAssertTrue(home.contains("if curveRoute == .unchecked {"))
        XCTAssertTrue(home.contains("let notice = curveRoute?.notice { Paragraph(notice) }"))
        XCTAssertFalse(home.contains("buyRefusal"), "the page asks where the coin trades, not whether a retired one may be bought")
        XCTAssertFalse(home.contains("router.openSwap(tokenIn: row.token,"), "no Swap that sells the page's coin: none routes a curve")
        let launchTab = try XCTUnwrap(home.range(of: "case .launchpad:"))
        let momentsTab = try XCTUnwrap(home.range(of: "case .moments:", range: launchTab.upperBound..<home.endIndex))
        let launchHoldings = String(home[launchTab.upperBound..<momentsTab.lowerBound])
        XCTAssertTrue(launchHoldings.contains("Button { openLaunch(holding.launch) }"), "each launch holding opens its own Launch page")
        // One saved when the wallet was last read opens by reference: the page reads the launch now.
        XCTAssertTrue(home.contains("if model.reads.isSaved(.launch) {\n            router.openLaunch(LaunchReference(token: launch.token, factory: launch.factory))\n        } else {\n            router.openLaunch(launch)"))
        XCTAssertFalse(launchHoldings.contains("openSwap"))
        // Held coins always; a created one at zero only while the board lists it (not a retired launchpad's sell-only coin).
        XCTAssertTrue(home.contains("guard balance > 0 || (created && launch.listsOnBoard) else { return nil }"))
        XCTAssertFalse(home.contains("guard balance > 0 || created else"))
        XCTAssertFalse(home.contains("openLaunchTab"), "Home's token page never sends a coin to the board")
        XCTAssertFalse(assets.contains("openLaunchTab"), "nor the Portfolio")

        // My Launchpad: Coins You Launched and its count list what the board lists; the creator-fee escrows are read for
        // every coin created and every pair asset, so a hidden retired coin's fees (aBIL in 0xad3d's escrow) are still read.
        let profile = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadProfileView.swift"), encoding: .utf8)
        XCTAssertTrue(profile.contains("var launched: [Created] { created.filter(\\.launch.listsOnBoard) }"))
        XCTAssertTrue(profile.contains("stat(\"Launched\", model.launchesRead ? \"\\(model.launched.count)\" : model.launchesUnread ? \"—\" : \"0\", reading: !model.launchesRead && !model.launchesUnread)"),
                      "the count of what the board lists, a placeholder until the launches are read")
        XCTAssertTrue(profile.contains("ForEach(model.launched) { item in"))
        XCTAssertFalse(profile.contains("model.created"), "the view shows only what the board lists")
        XCTAssertTrue(profile.contains("let createdPairs = launches.filter { $0.deployer == address }.map(\\.pairToken)\n        async let escrowRead = env.launchpad.escrowReads(account: address, extraPairTokens: createdPairs)"),
                      "the escrow pairs come from every coin created, unfiltered")
        XCTAssertTrue(Token.launchpadPairAssets.contains(Token.abil.address), "and every escrow reads aBIL, a pair asset, whatever was created")

        let swap = try String(contentsOf: app.appendingPathComponent("Swap/SwapView.swift"), encoding: .utf8)
        // The "no venue" answer shows as soon as the venues answer; the curve check follows it and never holds it back,
        // and its answer is kept only while it answers what is on screen.
        let quoteLoop = try XCTUnwrap(swap.range(of: "func quote(env: AppEnvironment, account: Address?"))
        let loopEnd = try XCTUnwrap(swap.range(of: "struct SlippageSheet", range: quoteLoop.upperBound..<swap.endIndex))
        let loop = String(swap[quoteLoop.upperBound..<loopEnd.lowerBound])
        let published = try XCTUnwrap(loop.range(of: "resultKey = key\n"))
        let errorShown = try XCTUnwrap(loop.range(of: "error = outcome.quotes.isEmpty ?"))
        let curveChecked = try XCTUnwrap(loop.range(of: "let onCurve = await env.launchpad.curveRoute(among: [request.tokenOut, request.tokenIn])"))
        XCTAssertLessThan(published.lowerBound, curveChecked.lowerBound, "the venues' answer is shown before the curve check")
        XCTAssertLessThan(errorShown.lowerBound, curveChecked.lowerBound, "\"No venue\" is shown before the curve check")
        XCTAssertTrue(loop.contains("if key == quoteKey, resultKey == key { curve = onCurve; curveKey = key }"))
        XCTAssertTrue(swap.contains("var currentCurve: CurveCoinRoute? { resultKey == quoteKey && curveKey == quoteKey ? curve : nil }"))
        let section = try XCTUnwrap(swap.range(of: "@ViewBuilder private var curveSection: some View {"))
        let quotes = try XCTUnwrap(swap.range(of: "@ViewBuilder private var quotesSection: some View {"))
        let curveSection = String(swap[section.upperBound..<quotes.lowerBound])
        XCTAssertTrue(curveSection.contains("Button(title, systemImage: \"arrow.up.right.circle\") { router.openLaunchPage(for: curve.route) }"))
        XCTAssertTrue(curveSection.contains("Button(\"Check Again\""))
        // Only when the check failed: the board, where a retired coin's holder finds it under Your Sell-Only Coins.
        XCTAssertEqual(curveSection.components(separatedBy: "router.openLaunchTab()").count - 1, 1)
        XCTAssertTrue(curveSection.contains("Button(\"Open the Launch Tab\", systemImage: \"flame\") { router.openLaunchTab() }"))
        let listed2 = try XCTUnwrap(swap.range(of: "curveSection\n                quotesSection"), "shown with the quotes, right under the action")
        XCTAssertLessThan(listed2.lowerBound, section.lowerBound)
    }
}

/// One coin launched on one stack (the live v2 fixture or a retired one), in one state, answered from memory: every known
/// factory's `getLaunchedToken` (the coin's record from its own stack, and an empty record in its own layout from every
/// other), then, unless `launchReads` is off, the reads its launch is built from: the coin's name, symbol, token info and
/// supply, and its curve's price, reserve, launch time and `completed` / `rescued` flags; with `pageReads`, also what its
/// page reads beyond that (`LaunchpadService.launch(token:factory:)`): the curve's terms and reserves, its stack's
/// `stuckSince` and pool key, and its hook's pending fees. Anything else reverts (no live price: `getReserves`).
struct CurveCoinChain: Sendable {
    /// The factories a live service asks, in order: the live fixture, then each retired stack.
    static let factories = [V2Fixture.launchpad] + LaunchpadAddresses.retiredStacks

    let stack: LaunchpadAddresses
    let phase: LaunchPhase
    var completed = false
    var rescued = false
    var launchReads = true
    /// On: the page's reads answer too (off, `getReserves` reverts, so the coin has no live price).
    var pageReads = false
    let coin = Address(literal: "0x00000000000000000000000000000000000c02d0")
    let curve = Address(literal: "0x00000000000000000000000000000000000c02c0")

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        typealias T = LaunchpadABI.Token
        typealias C = LaunchpadABI.Curve
        if is_(LaunchpadABI.Factory.getLaunchedToken), let known = Self.factories.first(where: { $0.factory == to }) {
            let legacy = known.generation.legacyRecord
            let ours = to == stack.factory && args.address(0) == coin
            return encode([RetiredCoinChain.record(token: ours ? coin : .zero, curve: ours ? curve : .zero, phase: ours ? phase : .bonding,
                                                   venue: legacy ? .monday : .uniswapV4, exists: ours, legacy: legacy)],
                          LaunchpadABI.launchedTokenReturns(legacy: legacy))
        }
        guard launchReads else { return nil }
        if pageReads, to == stack.factory {
            if is_(LaunchpadABI.Factory.stuckSince) { return encode([.uint(0)], "uint256") }
            if is_(LaunchpadABI.Factory.poolKeyOf) { return encode([.tuple([.address(.zero), .address(coin), .uint(0), .int(60), .address(stack.hook)])], LaunchpadABI.poolKeyTuple) }
        }
        if pageReads, to == stack.hook, is_(LaunchpadABI.Hook.pendingFees) || is_(LaunchpadABI.Hook.pendingCreatorTax) || is_(LaunchpadABI.Hook.pendingProtocolFees) {
            return encode([.uint(0)], "uint256")
        }
        if to == coin {
            if is_(T.name) { return encode([.string("Old coin")], "string") }
            if is_(T.symbol) { return encode([.string("OLD")], "string") }
            if is_(T.totalSupply) { return encode([.uint(BigUInt(10).power(27))], "uint256") }
            if is_(T.getTokenInfo) { return encode([.address(coin), .string(""), .string(""), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,\(LaunchpadABI.socialsTuple)") }
        }
        if to == curve {
            if is_(C.price) || is_(C.realQuoteReserve) { return encode([.uint(1_000)], "uint256") }
            if is_(C.completed) { return encode([.bool(completed)], "bool") }
            if is_(C.rescued) { return encode([.bool(rescued)], "bool") }
            if is_(C.launchedAt) { return encode([.uint(1_789_000_000)], "uint64") }
            // Read with the launch, for its decimal price (`Launch.pairPrice`), and again by its page.
            if is_(C.getReserves) { return encode([.uint(1_000), .uint(BigUInt(10).power(27))], "uint256,uint256") }
            guard pageReads else { return nil }
            if is_(C.sellableTokens) || is_(C.phantomQuote) || is_(C.reservedTokens) { return encode([.uint(1_000)], "uint256") }
            if is_(C.swept) { return encode([.bool(phase == .migrating)], "bool") }
            if is_(C.feeBps) { return encode([.uint(100)], "uint16") }
            if is_(C.snipeTaxSchedule) { return encode([.array([])], "uint16[]") }
        }
        return nil
    }
}
