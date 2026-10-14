import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The launchpad v2 against a real v2 deployment on a LOCAL anvil fork of Monad (`V2ForkCase` says how to run it), through
/// the plans DyorKit builds and `TransactionSender`, the path the app takes: the wiring and gate reads, launches on all
/// four pairs, curve trades against the quotes' floors, holder rewards, a Uniswap v4 graduation and a swap through the
/// v2 hook, the sweep, a stuck Monday launch whose fallback only the keepers send, and a retired launchpad's coin, which
/// sells and is never bought. The owner is impersonated on the fork only, and the Monday executor's code is swapped out
/// on the fork only to make one graduation fail.
final class LaunchpadV2ForkTests: V2ForkCase {
    private func info(_ fork: ForkLaunchpad, _ wallet: Address) async throws -> ProtocolInfo {
        let read = try await fork.service.protocolInfo(extraPairTokens: Token.launchpadPairAssets, account: wallet)
        return try XCTUnwrap(read)
    }

    private func input(_ symbol: String, pair: Address = .zero, venue: GraduationVenue = .uniswapV4, sharing: Bool = true) -> LaunchInput {
        LaunchInput(name: "Fork \(symbol)", symbol: symbol, description: "v2 fork rehearsal", creatorTaxBps: 100, holderFeeSharing: sharing, graduationVenue: venue, pairToken: pair)
    }

    /// A wallet with enough fork MON to complete a MON curve (~150,000 MON).
    private func richWallet(usdc: BigUInt = 0, ausd: BigUInt = 0, abil: BigUInt = 0) async throws -> ForkWallet {
        try await wallet(mon: 1_000_000 * Self.mon, usdc: usdc, ausd: ausd, abil: abil)
    }

    /// Launches through the app's plan, bound to the terms the screen would show, and returns the new coin.
    private func launch(_ fork: ForkLaunchpad, _ input: LaunchInput, _ wallet: ForkWallet) async throws -> Launch {
        let terms = try await info(fork, wallet.address)
        let shown = try XCTUnwrap(terms.pairs.first { $0.pair.address == input.pairToken }?.economicsHash)
        let plan = try await fork.service.launchPlan(input, from: wallet.address, expectedLaunchFee: terms.launchFee, expectedEconomics: shown)
        let hash = try await run(plan, wallet)
        let resultRead = try await fork.service.launchResult(transaction: hash)
        let result = try XCTUnwrap(resultRead)
        XCTAssertEqual(result.deployer, wallet.address)
        let detail = try await fork.service.launch(token: result.token)
        return try XCTUnwrap(detail).launch
    }

    /// Buys what is left of the curve, which completes it and starts the graduation.
    private func completeCurve(_ fork: ForkLaunchpad, _ launch: Launch, _ wallet: ForkWallet) async throws {
        let rest = launch.graduationThreshold > launch.realQuoteReserve ? launch.graduationThreshold - launch.realQuoteReserve : 0
        let quoteIn = rest * 11 / 10 + Self.mon // fees and tax on top; the curve refunds what it doesn't take
        try await run(try await fork.service.buyPlan(launch: launch, quoteIn: quoteIn, minTokensOut: 0, recipient: wallet.address), wallet)
    }

    // MARK: Reads

    /// The new getters on a real v2 factory: sealed modules equal to the record's, the wallet allowed, the constants the
    /// copy relies on, and aBIL Monday-only.
    func testTheWiringAndTheNewGettersOnARealV2Factory() async throws {
        let fork = try launchpad()
        let wallet = try await wallet()
        let terms = try await info(fork, wallet.address)
        XCTAssertEqual(terms.modulesSealed, true)
        XCTAssertEqual(terms.moduleMismatches, [])
        XCTAssertEqual(terms.accountCanLaunch, true)
        XCTAssertNil(terms.launchBlocker)
        XCTAssertTrue(terms.configEnabled, "launch config 0")
        XCTAssertFalse(terms.whitelistEnabled)
        XCTAssertEqual(terms.launchFee, 5 * Self.mon)
        XCTAssertEqual(terms.protocolFeeShareBps, 5_000)
        XCTAssertEqual(Set(terms.pairs.filter(\.approved).map(\.pair.address)), Set([Address.zero] + Token.launchpadPairAssets), "MON, USDC, AUSD and aBIL")
        XCTAssertEqual(terms.pairs.filter(\.mondayOnly).map(\.pair.address), [Token.abil.address])
        let constants = try await Multicall(rpc: rpc).readAll([
            LaunchpadABI.call(fork.addresses.factory, LaunchpadABI.Factory.mondayRetryGas, returns: "uint256"),
            LaunchpadABI.call(fork.addresses.factory, LaunchpadABI.Factory.mondayOnlyFallbackDelay, returns: "uint256"),
        ])
        XCTAssertEqual(constants[0][0].uint, 20_000_000)
        XCTAssertEqual(constants[1][0].uint, 86_400)

        // A build baked with another hook refuses to offer Launch on this factory.
        var other = fork.addresses
        other.hook = Address(literal: "0x00000000000000000000000000000000000bad00")
        let mismatched = try await LaunchpadService(rpc: rpc, addresses: other, logsRPC: rpc).protocolInfo(account: wallet.address)
        XCTAssertEqual(mismatched?.launchBlocker, .modulesChanged(["hook"]))
    }

    // MARK: Launch and trade on every pair

    /// A launch on each approved pair, through the app's plans: MON and USDC each with and without a developer buy (on
    /// USDC: approve the router, then `launchAndBuy`), AUSD, and aBIL, which the create screen forces to Monday Trade.
    /// Each new coin's route is its Launch page, where its curve trades both ways. On each the app buys and sells on the
    /// curve against its quotes' 99% floors (so ERC-20 transfers of AUSD and aBIL go through the curve without
    /// `UnsupportedQuoteToken`), and one block later claims the holder rewards those trades queued.
    func testEveryPairLaunchesTradesAndPaysHolders() async throws {
        let fork = try launchpad()
        let wallet = try await richWallet(usdc: 100 * Self.usdcUnit, ausd: 100 * Self.usdcUnit, abil: 2 * Self.mon)
        let terms = try await info(fork, wallet.address)
        let start = try await latest().number
        let cases: [(symbol: String, pair: Address, developerBuy: BigUInt, buy: BigUInt)] = [
            ("FMON", .zero, 0, 50 * Self.mon),
            ("FMONB", .zero, 10 * Self.mon, 50 * Self.mon),
            ("FUSD", Monad.usdc, 10 * Self.usdcUnit, 20 * Self.usdcUnit),
            ("FUSDN", Monad.usdc, 0, 20 * Self.usdcUnit),
            ("FAUSD", Monad.ausd, 0, 20 * Self.usdcUnit),
            ("FRWA", Token.abil.address, 0, Self.mon / 2),
        ]
        var launches: [Launch] = []
        for c in cases {
            let economics = try XCTUnwrap(terms.pairs.first { $0.pair.address == c.pair }, c.symbol)
            XCTAssertTrue(economics.approved, c.symbol)
            // The create screen forces Monday Trade for a Monday-only pair (the factory's PairRequiresMonday).
            var input = input(c.symbol, pair: c.pair, venue: economics.mondayOnly ? .monday : .uniswapV4)
            input.initialBuy = c.developerBuy
            let plan = try await fork.service.launchPlan(input, from: wallet.address, expectedLaunchFee: terms.launchFee, expectedEconomics: economics.economicsHash)
            XCTAssertEqual(plan.count, c.developerBuy > 0 && !c.pair.isZero ? 2 : 1, "\(c.symbol): the router's approval, then the launch")
            let hash = try await run(plan, wallet)
            let resultRead = try await fork.service.launchResult(transaction: hash)
            let result = try XCTUnwrap(resultRead, c.symbol)
            let detailRead = try await fork.service.launch(token: result.token)
            let launch = try XCTUnwrap(detailRead, c.symbol).launch
            XCTAssertEqual(launch.pairToken, c.pair, c.symbol)
            XCTAssertEqual(launch.generation, .v2, c.symbol)
            XCTAssertEqual(launch.factory, fork.addresses.factory, c.symbol)
            XCTAssertEqual(launch.graduationVenue, c.pair == Token.abil.address ? .monday : .uniswapV4, c.symbol)
            launches.append(launch)
            let launched = try await balance(launch.token, wallet.address)
            XCTAssertEqual(launched > 0, c.developerBuy > 0, "\(c.symbol): the developer buy lands in the deployer's wallet")

            // Home's token page and the Portfolio open its Launch page, where it buys and sells; Swap refuses nothing.
            let coin = Token(address: launch.token, symbol: launch.symbol, name: launch.name, decimals: 18, isLaunchpad: true)
            let route = await fork.service.curveRoute(for: coin)
            XCTAssertEqual(route.launch?.token, launch.token, c.symbol)
            XCTAssertEqual(route.launch?.curveBuysOpen, true, c.symbol)
            XCTAssertEqual(route.notice, LaunchpadCurve.tradeOnLaunchPage, c.symbol)
            XCTAssertEqual(route.actionTitle(c.symbol), "Trade \(c.symbol) on its Launch page")
            let swapRefusal = await SwapEngine(rpc: rpc, launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: fork.addresses)).buyRefusal(coin)
            XCTAssertNil(swapRefusal, c.symbol)

            // Buy against the quote's floor.
            let buyQuote = try await fork.service.quoteBuy(curve: launch.curve, quoteIn: c.buy, recipient: wallet.address)
            let floor = buyQuote.tokensOut * 99 / 100
            try await run(try await fork.service.buyPlan(launch: launch, quoteIn: c.buy, minTokensOut: floor, recipient: wallet.address), wallet)
            let bought = try await balance(launch.token, wallet.address) - launched
            XCTAssertGreaterThanOrEqual(bought, floor, c.symbol)

            // Sell half against the quote's floor.
            let sellQuote = try await fork.service.quoteSell(curve: launch.curve, tokensIn: bought / 2)
            let pairBefore = try await balance(c.pair, wallet.address)
            try await run(await fork.service.sellPlan(launch: launch, tokensIn: bought / 2, minQuoteOut: sellQuote.quoteOut * 99 / 100, recipient: wallet.address), wallet)
            let pairAfter = try await balance(c.pair, wallet.address)
            if !c.pair.isZero { XCTAssertGreaterThanOrEqual(pairAfter - pairBefore, sellQuote.quoteOut * 99 / 100, c.symbol) }
            let left = try await balance(launch.token, wallet.address)
            XCTAssertEqual(left, launched + bought - bought / 2, c.symbol)

            // One block later the queued rewards are the holder's to claim.
            try await mine()
            let view = try await fork.service.accountView(launch, account: wallet.address)
            XCTAssertGreaterThan(view.pendingRewards, 0, c.symbol)
            try await run(await fork.service.claimRewardsPlan(launch: launch, view: view), wallet)
            let claimed = try await fork.service.accountView(launch, account: wallet.address)
            XCTAssertEqual(claimed.pendingRewards, 0, c.symbol)
        }
        let after = try await info(fork, wallet.address)
        XCTAssertEqual(after.launchCount, terms.launchCount + cases.count)

        // The wallet's history decodes the v2 events: the wallet's fills and its claims.
        let lookback = try await latest().number - start + 1
        let history = await fork.service.walletHistory(wallet: wallet.address, lookbackBlocks: lookback, curves: Set(launches.map(\.curve)))
        XCTAssertEqual(history.fills.filter(\.isBuy).count, cases.count)
        XCTAssertEqual(history.fills.filter { !$0.isBuy }.count, cases.count)
        XCTAssertEqual(history.claims.count, cases.count, "one holder-reward claim per launch")
    }

    // MARK: Launch gate and refusals

    /// The owner closes launching two ways; each shows the right reason, the plan is refused before anything is signed,
    /// and a launch sent anyway is refused by `prepare` with the factory's own error, decoded. New economics from the
    /// owner make the terms the screen showed stale: the plan refuses them, and a launch bound to them anyway is refused
    /// with `LaunchEconomicsMismatch` in the launch screen's words.
    func testTheLaunchGateFollowsTheOwnersSwitches() async throws {
        let fork = try launchpad()
        let wallet = try await wallet()
        let factory = fork.addresses.factory
        let open = try await info(fork, wallet.address)
        let mon = try XCTUnwrap(open.pairs.first { $0.pair.isNative })
        // What a build that skipped the gate would send: the sync plan, with the terms the screen showed.
        func raw(_ symbol: String, economics: Data? = nil) async throws -> [TransactionStep] {
            var bound = input(symbol)
            bound.expectedEconomics = economics ?? mon.economicsHash ?? Data()
            return try await fork.service.launchPlan(bound, launchFee: open.launchFee, from: wallet.address)
        }

        try await sendAs(fork.owner, to: factory, "setWhitelistEnabled(bool)", [.bool(true)])
        let whitelisted = try await info(fork, wallet.address)
        XCTAssertEqual(whitelisted.launchBlocker, .notAllowed)
        do {
            _ = try await fork.service.launchPlan(input("GATE"), from: wallet.address, expectedLaunchFee: open.launchFee, expectedEconomics: mon.economicsHash)
            XCTFail("the plan must refuse a launch the factory would refuse")
        } catch {
            XCTAssertEqual(error as? LaunchpadError, .launchBlocked(.notAllowed))
        }
        let notWhitelisted = await refusal(try await raw("GATE"), wallet)
        XCTAssertEqual(notWhitelisted, sentence("NotWhitelisted"))
        try await sendAs(fork.owner, to: factory, "setWhitelistEnabled(bool)", [.bool(false)])

        try await sendAs(fork.owner, to: factory, "setLaunchConfigEnabled(uint256,bool)", [.uint(0), .bool(false)])
        let closed = try await info(fork, wallet.address)
        XCTAssertEqual(closed.launchBlocker, .configDisabled)
        let disabled = await refusal(try await raw("SHUT"), wallet)
        XCTAssertEqual(disabled, sentence("LaunchConfigDisabled"))
        try await sendAs(fork.owner, to: factory, "setLaunchConfigEnabled(uint256,bool)", [.uint(0), .bool(true)])

        // The owner re-prices MON launches after the screen loaded.
        try await sendAs(fork.owner, to: factory, "setPairEconomics(address,uint256,uint256,uint8,bool)",
                         [.address(.zero), .uint(mon.phantomQuote * 2), .uint(mon.graduationThreshold * 2), .uint(18), .bool(true)])
        let repriced = try await info(fork, wallet.address)
        XCTAssertNotEqual(repriced.pairs.first { $0.pair.isNative }?.economicsHash, mon.economicsHash)
        do {
            _ = try await fork.service.launchPlan(input("STALE"), from: wallet.address, expectedLaunchFee: open.launchFee, expectedEconomics: mon.economicsHash)
            XCTFail("the plan must refuse terms the screen no longer shows")
        } catch {
            XCTAssertEqual(error as? LaunchpadError, .termsChanged)
        }
        let mismatch = await refusal(try await raw("STALE"), wallet)
        XCTAssertEqual(mismatch, sentence("LaunchEconomicsMismatch"))
        XCTAssertEqual(mismatch, LaunchpadError.termsChanged.errorDescription)
        XCTAssertEqual(wallet.signatures, 0, "nothing was signed")
        XCTAssertNil(repriced.launchBlocker)
    }

    // MARK: Graduation and hook fees

    /// A fee-sharing MON launch graduates on Uniswap v4 in its completing buy; the app's swap engine routes a swap
    /// through the v2 hook, which pays the holders' cut to fee sharing in the swap (HolderFeesForwarded, queued for the
    /// next block) and keeps DyorHQ's in pendingProtocolFees, which the coin page counts. The sweep plan then pays it to
    /// the treasury's escrow.
    func testAV4SwapOnAFeeSharingLaunchPaysHoldersInTheSwap() async throws {
        let fork = try launchpad()
        let wallet = try await richWallet()
        let launched = try await launch(fork, input("SHARE"), wallet)
        XCTAssertEqual(launched.generation, .v2)
        try await completeCurve(fork, launched, wallet)
        let graduatedRead = try await fork.service.launch(token: launched.token)
        let graduated = try XCTUnwrap(graduatedRead)
        XCTAssertEqual(graduated.launch.phase, .graduated)
        XCTAssertEqual(graduated.launch.graduationVenue, .uniswapV4)
        XCTAssertEqual(graduated.stuckSince, 0)

        let engine = SwapEngine(rpc: rpc, launchpadFactories: [fork.addresses.factory])
        let coin = Token(address: launched.token, symbol: launched.symbol, name: launched.name, decimals: 18, isLaunchpad: true)
        let quoteRead = try await engine.quote(.uniswap, for: SwapRequest(tokenIn: .mon, tokenOut: coin, amountIn: 100 * Self.mon, slippageBps: 500, account: wallet.address))
        let quote = try XCTUnwrap(quoteRead, "the graduated pool is a v4 route")
        XCTAssertTrue(quote.route.hasPrefix("v4"), quote.route)
        let hash = try await run(try await quote.build(wallet.address), wallet)
        let logsRead = try await rpc.transactionLogs(hash)
        let logs = try XCTUnwrap(logsRead)
        XCTAssertTrue(logs.contains { $0.address == fork.addresses.hook && $0.topics.first == LaunchpadABI.Events.holderFeesForwardedTopic }, "HolderFeesForwarded in the swap")
        let received = try await balance(launched.token, wallet.address)
        XCTAssertGreaterThan(received, 0)

        let afterRead = try await fork.service.launch(token: launched.token)
        let after = try XCTUnwrap(afterRead)
        XCTAssertEqual(after.hookPendingFees, 0, "the holders' cut left in the swap")
        XCTAssertGreaterThan(after.hookPendingProtocolFees, 0)
        XCTAssertGreaterThan(after.queuedRewards, 0)
        XCTAssertEqual(after.hookFeesAwaitingSweep, after.hookPendingTax + after.hookPendingProtocolFees)

        // The sweep: what waited in the hook goes out through the escrow, which pays the treasury directly.
        let treasuryBefore = try await balance(.zero, fork.treasury)
        try await run(await fork.service.sweepPoolFeesPlan(launch: after.launch), wallet)
        let sweptRead = try await fork.service.launch(token: launched.token)
        let swept = try XCTUnwrap(sweptRead)
        XCTAssertEqual(swept.hookFeesAwaitingSweep, 0)
        let treasuryAfter = try await balance(.zero, fork.treasury)
        XCTAssertGreaterThanOrEqual(treasuryAfter - treasuryBefore, after.hookPendingProtocolFees)
    }

    // MARK: Graduation fallback

    /// The fallback rule's reads on a real factory: an aBIL launch is Monday-only from launch, a stuck MON Monday launch is
    /// not, so its fallback is open at once. The app plans no fallback (the keepers send it with ~29.9M gas); one built
    /// by hand is refused by `prepare` on the network-fee cap (or, on a fork whose block gas limit is under 22,062,500, by
    /// the factory's gas floor), the passkey policy refuses it whatever the sheet says, and an `eth_call` of it at 15M gas
    /// decodes to `InsufficientGasForGraduation`. Retry Graduation finishes on Monday once the venue works again.
    func testAStuckMondayLaunchOnARealV2Factory() async throws {
        let fork = try launchpad()
        let wallet = try await richWallet()
        typealias F = LaunchpadABI.Factory
        let abil = try await launch(fork, input("RWA", pair: Token.abil.address, venue: .monday, sharing: false), wallet)
        XCTAssertEqual(abil.graduationVenue, .monday)
        let snapshot = try await Multicall(rpc: rpc).readAll([
            LaunchpadABI.call(fork.addresses.factory, F.launchMondayOnly, [.address(abil.token)], returns: "bool"),
            LaunchpadABI.call(fork.addresses.factory, F.v4FallbackAllowed, [.address(abil.token)], returns: "bool"),
        ])
        XCTAssertTrue(snapshot[0][0].bool, "launchMondayOnly: the launch-time snapshot")
        XCTAssertFalse(snapshot[1][0].bool)
        // A v4 venue for aBIL is refused by the factory, in its sentence.
        var v4 = input("RWA4", pair: Token.abil.address, sharing: false)
        let abilTerms = try await info(fork, wallet.address)
        v4.expectedEconomics = try XCTUnwrap(abilTerms.pairs.first { $0.pair.address == Token.abil.address }?.economicsHash)
        let venue = await refusal(try await fork.service.launchPlan(v4, launchFee: abilTerms.launchFee, from: wallet.address), wallet)
        XCTAssertEqual(venue, sentence("PairRequiresMonday"))

        // A MON launch on Monday Trade whose graduation fails: the Monday executor is broken on the fork only.
        let monday = try await launch(fork, input("STUCK", venue: .monday, sharing: false), wallet)
        let code = try await rpc.call("eth_getCode", [.string(fork.mondayExecutor.hex), .string("latest")])
        _ = try await rpc.call("anvil_setCode", [.string(fork.mondayExecutor.hex), .string("0xfe")])
        try await completeCurve(fork, monday, wallet)
        let stuckRead = try await fork.service.launch(token: monday.token)
        let stuck = try XCTUnwrap(stuckRead)
        XCTAssertEqual(stuck.launch.phase, .bonding)
        XCTAssertTrue(stuck.launch.completed)
        XCTAssertGreaterThan(stuck.stuckSince, 0)
        // The coin page shows it as pending graduation (Retry Graduation, the keepers' note), not a curve ticket.
        XCTAssertTrue(stuck.launch.awaitsGraduation)
        XCTAssertFalse(stuck.launch.curveSellsOpen)
        XCTAssertFalse(stuck.launch.curveBuysOpen)
        XCTAssertEqual(stuck.fallbackRule, GraduationFallbackRule(mondayOnly: false, allowed: false, delay: 86_400))
        XCTAssertEqual(stuck.v4FallbackOpensAt, stuck.stuckSince, "not Monday-only: open as soon as it is stuck")
        XCTAssertTrue(stuck.launch.keepersTakeGraduateFallback)
        do {
            _ = try await fork.service.graduateFallbackPlan(launch: stuck.launch)
            XCTFail("the app never plans graduateFallback")
        } catch {
            XCTAssertEqual(error as? LaunchpadError, .graduateFallbackByKeepers)
        }

        // A fallback built by hand anyway.
        let data = LaunchpadABI.calldata(F.graduateFallback, [.address(monday.token)])
        let fallback = TransactionStep.call(TransactionRequest(to: fork.addresses.factory, data: data), label: "Fallback")
        let why = await refusal([fallback], wallet)
        let head = try await rpc.call("eth_getBlockByNumber", [.string("latest"), .bool(false)])
        let blockGas = try XCTUnwrap(head["gasLimit"].string.flatMap { BigUInt(hexQuantity: $0) })
        if blockGas < 22_062_500 {
            XCTAssertEqual(why, sentence("InsufficientGasForGraduation"))
        } else {
            // The simulation passes with the block's gas; the estimate is over the factory's 22,062,500 floor, so the
            // gas limit is over the 15M cap.
            let estimate = try await rpc.estimateGas(CallRequest(from: wallet.address, to: fork.addresses.factory, data: data))
            XCTAssertGreaterThanOrEqual(estimate, 22_062_500)
            let gasLimit = TransactionSender.gasLimit(estimate: estimate)
            let fees = try await sender.feeQuote()
            XCTAssertEqual(NetworkFeeLimits.violation(gasLimit: gasLimit, maxFeePerGas: fees.maxFee, maxPriorityFeePerGas: fees.tip, baseFee: fees.baseFee, chainId: Monad.chainId), .gasLimit)
            XCTAssertEqual(why, NetworkFeeLimits.refusal(.gasLimit, gasLimit: gasLimit, maxFeePerGas: fees.maxFee, chainId: Monad.chainId))
            // A passkey account refuses it on the same bound, whatever the sheet declared or a Face ID approved.
            let prepared = PreparedTransaction(from: wallet.address, to: fork.addresses.factory, data: data, value: 0, nonce: 0, gasLimit: gasLimit,
                                               maxFeePerGas: fees.maxFee, maxPriorityFeePerGas: fees.tip, chainId: Monad.chainId)
            for intent in [Mera.Intent.ask, .alwaysAsks(.unlisted), .momentsClaim] {
                XCTAssertEqual(Mera.SigningPolicy.refusal(.init(prepared), intent: intent, account: wallet.address), .networkFee)
            }
        }
        // What the factory itself answers at the cap: its gas floor, in the app's words.
        do {
            _ = try await rpc.call("eth_call", [.object(["from": .string(wallet.address.hex), "to": .string(fork.addresses.factory.hex), "data": .string(data.hexString),
                                                          "gas": .string(BigUInt(15_000_000).hexQuantity)]), .string("latest")])
            XCTFail("graduateFallback at 15M gas must revert")
        } catch let error as RPCError {
            XCTAssertEqual(RevertReason.describe(error), sentence("InsufficientGasForGraduation"))
        }
        XCTAssertEqual(wallet.signatures, 3, "two launches and one curve buy signed; no fallback")

        // Retry Graduation: plain graduate, gas estimated, on the creator's venue once it works again.
        _ = try await rpc.call("anvil_setCode", [.string(fork.mondayExecutor.hex), code])
        try await run(await fork.service.graduatePlan(launch: stuck.launch), wallet)
        let doneRead = try await fork.service.launch(token: monday.token)
        let done = try XCTUnwrap(doneRead)
        XCTAssertEqual(done.launch.phase, .graduated)
        XCTAssertEqual(done.launch.graduationVenue, .monday)
        XCTAssertEqual(done.stuckSince, 0)
    }

    // MARK: Retired launchpads

    /// A MON coin still on a retired launchpad's curve, as mainnet has it (the newest `allLaunches` lists): the app builds
    /// no buy of it, not even through Swap, a passkey account refuses a curve buy built by hand on what the chain says of
    /// the curve, and its route is its Launch page, where it sells through the app's plan. The coins sold come from a raw
    /// curve buy on the fork only: on chain the retired curves still take buys, and only the app refuses them.
    func testARetiredLaunchpadsCurveCoinSellsButIsNeverBought() async throws {
        let fork = try launchpad()
        let wallet = try await wallet()
        let all = try await fork.service.allLaunches()
        guard let retired = all.first(where: { $0.isSellOnly && $0.curveSellsOpen && $0.pair.isNative }) else {
            throw XCTSkip("no MON coin on a retired launchpad's curve takes sells on this fork")
        }
        XCTAssertTrue(LaunchpadAddresses.isRetired(retired.factory))
        XCTAssertNotEqual(retired.factory, fork.addresses.factory)
        XCTAssertFalse(retired.curveBuysOpen)
        XCTAssertFalse(retired.listsOnBoard, "the public board never lists it")
        do {
            _ = try await fork.service.buyPlan(launch: retired, quoteIn: Self.mon, minTokensOut: 0, recipient: wallet.address)
            XCTFail("the app builds no buy on a retired launchpad's curve")
        } catch {
            XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad)
        }

        // Swap shows no venue's quote for buying it: the round ends refused under every venue (and never asks Kuru Flow,
        // `SwapRetiredLaunchpadTests`).
        let coin = Token(address: retired.token, symbol: retired.symbol, name: retired.name, decimals: 18, isLaunchpad: true)
        let engine = SwapEngine(rpc: rpc, launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: fork.addresses))
        let refusal = await engine.buyRefusal(coin)
        XCTAssertEqual(refusal, .retiredLaunchpad(retired.token))
        let quotes = await engine.quotes(for: SwapRequest(tokenIn: .mon, tokenOut: coin, amountIn: Self.mon, slippageBps: 100, account: wallet.address))
        XCTAssertTrue(quotes.quotes.isEmpty)
        XCTAssertEqual(Set(quotes.errors.values), [SwapMath.describe(SwapError.retiredLaunchpad(retired.token))])

        // Its route: the Launch page, to sell.
        let route = await fork.service.curveRoute(for: coin)
        XCTAssertEqual(route.launch?.token, retired.token)
        XCTAssertEqual(route.notice, RetiredLaunchpad.sellOnLaunchPage)
        XCTAssertEqual(route.actionTitle(retired.symbol), "Sell \(retired.symbol) on its Launch page")

        // A curve buy built by hand: a passkey account refuses it, whatever the sheet declared.
        let data = LaunchpadABI.calldata(LaunchpadABI.Curve.buy, [.uint(Self.mon), .uint(0), .address(wallet.address)])
        let buy = TransactionStep.call(TransactionRequest(to: retired.curve, data: data, value: Self.mon), label: "Buy (test only)")
        let call = try XCTUnwrap(Mera.SigningPolicy.Call(step: buy, from: wallet.address))
        let curves = await fork.service.retiredCurves(among: Mera.SigningPolicy.curveCandidates([call]))
        XCTAssertEqual(curves, .known([retired.curve: retired.token]))
        XCTAssertEqual(Mera.SigningPolicy.refusal(call, intent: .ask, account: wallet.address, retiredCurves: curves), .retiredLaunchpad)

        // The sell, through the app's plan against its quote's floor.
        try await sendAs(wallet.address, to: retired.curve, data: data, value: Self.mon)
        let held = try await balance(retired.token, wallet.address)
        XCTAssertGreaterThan(held, 0)
        let quote = try await fork.service.quoteSell(curve: retired.curve, tokensIn: held)
        XCTAssertGreaterThan(quote.quoteOut, 0)
        try await run(await fork.service.sellPlan(launch: retired, tokensIn: held, minQuoteOut: quote.quoteOut * 99 / 100, recipient: wallet.address), wallet)
        let left = try await balance(retired.token, wallet.address)
        XCTAssertEqual(left, 0)
    }

    /// The Launch tab on mainnet as it stands (owner decision 2026-09-29): a retired launchpad's coin lists only once it
    /// graduated; LP's one holder (0x2AF8…) finds it under "Your Sell-Only Coins" and sells all of it on its retired curve
    /// through the app's plan (impersonated on the fork only); a new v2 launch lists in Explore, so its empty card goes.
    func testTheBoardListsWhatTradesAndAHolderStillSellsTheRest() async throws {
        let fork = try launchpad()
        let all = try await fork.service.allLaunches(limit: 60)
        let listed = all.filter(\.listsOnBoard)
        XCTAssertTrue(listed.filter(\.isRetiredLaunchpad).allSatisfy { $0.phase == .graduated }, "\(listed.map(\.symbol))")
        XCTAssertTrue(all.filter(\.isSellOnly).allSatisfy { !$0.listsOnBoard })

        let holder = Address(literal: "0x2AF85656F1B17Ce935DE335A4Ce95A4eFa807af5")
        let lpToken = Address(literal: "0xA4D9b2697254292ad30e06Ce968a7e18De6fF884")
        guard let lp = all.first(where: { $0.token == lpToken }), lp.isSellOnly, lp.curveSellsOpen else { throw XCTSkip("LP isn't a sell-only coin taking sells on this fork") }
        let sellOnly = all.filter { !$0.listsOnBoard }
        let tokens = sellOnly.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        let balances = try await ERC20.balances(of: tokens, owner: holder, rpc: rpc, multicall: Multicall(rpc: rpc))
        let section = try XCTUnwrap(LaunchBoard.heldSellOnly(sellOnly, balances: balances))
        XCTAssertTrue(section.contains { $0.token == lpToken }, "\(section.map(\.symbol))")
        let held = try XCTUnwrap(balances[lpToken])
        guard held > 0 else { throw XCTSkip("0x2AF8… no longer holds LP") }
        let nobody = try await ERC20.balances(of: tokens, owner: Address(literal: "0x00000000000000000000000000000000000b0a2d"), rpc: rpc, multicall: Multicall(rpc: rpc))
        XCTAssertEqual(LaunchBoard.heldSellOnly(sellOnly, balances: nobody), [], "no section for a wallet holding none")

        // Its page, as Home and the Portfolio open it: the sell through the app's plan against its quote's floor.
        let quote = try await fork.service.quoteSell(curve: lp.curve, tokensIn: held)
        XCTAssertGreaterThan(quote.quoteOut, 0)
        let plan = await fork.service.sellPlan(launch: lp, tokensIn: held, minQuoteOut: quote.quoteOut * 99 / 100, recipient: holder)
        XCTAssertEqual(plan.count, 2)
        for step in plan {
            let request = try XCTUnwrap(try step.request(), step.label)
            try await sendAs(holder, to: request.to, data: request.data, value: request.value)
        }
        let left = try await balance(lpToken, holder)
        XCTAssertEqual(left, 0)
        let mon = try await balance(.zero, holder)
        XCTAssertGreaterThan(mon, 1_000 * Self.mon, "paid in MON (the impersonated sender starts each call at 1,000 MON)")

        // A v2 launch lists in Explore, on the curve.
        let wallet = try await wallet()
        let launched = try await launch(fork, input("BRD"), wallet)
        let board = try await fork.service.allLaunches(limit: 60).filter(\.listsOnBoard)
        let shown = try XCTUnwrap(board.first { $0.token == launched.token })
        XCTAssertEqual(shown.phase.boardSection, .climbing)
        XCTAssertFalse(shown.isRetiredLaunchpad)
    }
}
