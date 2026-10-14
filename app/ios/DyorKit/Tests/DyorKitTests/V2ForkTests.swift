import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// Moments v2 against a real v2 deployment on a LOCAL anvil fork of Monad (`V2ForkCase` says how to run it), through
/// the plans DyorKit builds and `TransactionSender`, the path the app takes: the terms hash, publish, both collect paths,
/// the NFT's own link base, graduation, claims, creator withdrawals, the pool's fees, buybacks and expiry, and every v2
/// refusal decoded before anything is signed. The graduation tests use the small-threshold stack
/// (`pending-moments-small-143.json`); the rest use the c4 one.
final class V2ForkTests: V2ForkCase {
    private func input(_ name: String, price: BigUInt = 1_000_000, window: Int = 86_400) -> MomentPublishInput {
        MomentPublishInput(name: name, symbol: "FORK", mediaURI: "ipfs://bafyfork", mediaHash: Data(repeating: 0x42, count: 32), place: "Accra",
                           date: 1_790_000_000, price: price, creatorAllocBps: 1_000, collectWindow: window)
    }

    private func policy(_ fork: ForkMoments) async throws -> MomentPolicy {
        let read = try await fork.service.policy()
        return try XCTUnwrap(read)
    }

    /// Publishes through the app's plan, bound to the terms read just before (what the review screen does), and returns
    /// the new Moment.
    private func publish(_ fork: ForkMoments, _ input: MomentPublishInput, by creator: ForkWallet) async throws -> MomentDetail {
        let reviewed = try await policy(fork)
        XCTAssertTrue(reviewed.canPublish, "\(String(describing: reviewed.publishBlock))")
        let hash = try await run(try await fork.service.publishPlan(input, termsHash: reviewed.termsHash), creator)
        let resultRead = try await fork.service.publishResult(transaction: hash)
        let result = try XCTUnwrap(resultRead)
        XCTAssertEqual(result.creator, creator.address)
        let detail = try await fork.service.moment(id: result.momentId)
        return try XCTUnwrap(detail)
    }

    /// A Moment on the small-threshold stack (on the shipped deployment, which has none, the c4 stack at the owner's
    /// threshold), priced at the reserve-completing gross and collected once by `collector` through the app's collect
    /// plan: that collect is terminal and graduates the Moment in the same transaction.
    private func graduatedMoment() async throws -> (fork: ForkMoments, creator: ForkWallet, collector: ForkWallet, info: MomentInfo, quote: CollectQuote) {
        let fork = try shipped ? moments() : smallMoments()
        let terms = try await policy(fork)
        XCTAssertEqual(terms.threshold, shipped ? 771_428_571 : 10 * Self.usdcUnit, shipped ? "the owner's threshold" : "the small-threshold stack")
        let ceiling = try XCTUnwrap(MomentsMath.maxCollectPrice(threshold: terms.threshold, reserveBps: terms.reserveBps))
        let creator = try await wallet()
        let collector = try await wallet(usdc: ceiling + 1_000 * Self.usdcUnit)
        let moment = try await publish(fork, input("Fork graduate", price: ceiling), by: creator)
        let quote = try await fork.service.quote(id: moment.info.id, quantity: 1)
        XCTAssertTrue(quote.terminal, "one collect at the ceiling completes the reserve")
        try await run(await fork.service.collectWithApprovalPlan(momentId: moment.info.id, quantity: 1, gross: quote.gross, symbol: moment.info.symbol), collector)
        let infoRead = try await fork.service.info(id: moment.info.id)
        let info = try XCTUnwrap(infoRead)
        XCTAssertTrue(info.graduated)
        XCTAssertEqual(info.state, .graduated)
        XCTAssertNotNil(info.pool, "a locked Uniswap v4 pool")
        return (fork, creator, collector, info, quote)
    }

    /// A swap through the app's Uniswap route (SwapEngine) on a graduated Moment's pool.
    private func swap(_ fork: ForkMoments, _ info: MomentInfo, buy: Bool, amount: BigUInt, _ wallet: ForkWallet) async throws {
        try await run(try await swapPlan(fork, info, buy: buy, amount: amount, wallet), wallet)
    }

    private func swapPlan(_ fork: ForkMoments, _ info: MomentInfo, buy: Bool, amount: BigUInt, _ wallet: ForkWallet) async throws -> [TransactionStep] {
        let coin = Token(address: info.moment.coin, symbol: info.symbol, name: info.name, decimals: 18)
        let engine = SwapEngine(rpc: rpc, moments: fork.addresses)
        let request = SwapRequest(tokenIn: buy ? .usdc : coin, tokenOut: buy ? coin : .usdc, amountIn: amount, slippageBps: 500, account: wallet.address)
        let quoteRead = try await engine.quote(.uniswap, for: request)
        let quote = try XCTUnwrap(quoteRead, "the Moment's pool is a route")
        return try await quote.build(wallet.address)
    }

    /// Fork only: puts a raw transaction in the pool without mining it (automine off), with an explicit gas and tip.
    private func submit(_ from: Address, _ request: TransactionRequest, gas: BigUInt, tipGwei: Int) async throws -> Data {
        let gwei = BigUInt(1_000_000_000)
        let hash = try await rpc.call("eth_sendTransaction", [.object([
            "from": .string(from.hex), "to": .string(request.to.hex), "data": .string(request.data.hexString), "value": .string(request.value.hexQuantity),
            "gas": .string(gas.hexQuantity), "maxFeePerGas": .string((1_000 * gwei).hexQuantity), "maxPriorityFeePerGas": .string((BigUInt(tipGwei) * gwei).hexQuantity),
        ])])
        return try XCTUnwrap(hash.string.flatMap { Data(hex: $0) })
    }

    // MARK: Reads

    /// The v2 getters on a real deploy: the terms hash the app computes is the factory's (and the vector the unit tests
    /// pin), the link base is c4's, the guardian is named, and the constants the app assumes hold.
    func testV2TermsAndConstantsOnARealDeploy() async throws {
        let fork = try moments()
        let policy = try await policy(fork)
        XCTAssertEqual(policy.externalBaseURI, MomentsAddresses.expectedExternalBaseURI)
        XCTAssertEqual(policy.termsHash, policy.localTermsHash, "the app's keccak256(abi.encode(policy, base)) is the factory's termsHash()")
        if policy.threshold == 771_428_571, policy.platform == V2Fixture.moments.platform, policy.treasury == V2Fixture.moments.treasury {
            XCTAssertEqual(policy.termsHash, V2Fixture.termsHash, "the owner's parameters give the vector MomentsV2Tests pins")
        }
        XCTAssertEqual(policy.guardian, fork.guardian)
        XCTAssertFalse(policy.guardian?.isZero ?? true)
        XCTAssertTrue(policy.canPublish, "\(String(describing: policy.publishBlock))")
        let constants = try await Multicall(rpc: rpc).readAll([
            MomentsABI.call(fork.addresses.factory, MomentsABI.Factory.policyApplyWindow, returns: "uint256"),
            MomentsABI.call(fork.addresses.locker, MomentsABI.Locker.maxIncreaseBps, returns: "uint256"),
            MomentsABI.call(fork.addresses.buyback, MomentsABI.Buyback.maxOpenDeviationBps, returns: "uint256"),
        ])
        XCTAssertEqual(Int(constants[0][0].uint), MomentsConstants.policyApplyWindowSeconds)
        XCTAssertEqual(constants[1][0].uint, 50)
        XCTAssertEqual(constants[2][0].uint, 200)
    }

    // MARK: Publish, collect, links

    /// A publish built from the reviewed terms lands; the Moment's link is the c4 base its NFT keeps, and stays so after
    /// governance points the factory elsewhere (which turns Publish off for new Moments). A collect goes through the
    /// exact-approval plan the app uses.
    func testPublishCollectAndTheLinkBaseTheNFTKeeps() async throws {
        let fork = try moments()
        let creator = try await wallet()
        let collector = try await wallet(usdc: 5 * Self.usdcUnit)
        let reviewed = try await policy(fork)
        let detail = try await publish(fork, input("Fork sunrise"), by: creator)
        let id = detail.info.id
        XCTAssertEqual(detail.externalURL, "https://dyorhq.fun/moments/c4/\(id)")
        XCTAssertEqual(detail.info.moment.platform, reviewed.platform)
        XCTAssertEqual(detail.info.moment.treasury, reviewed.treasury)
        XCTAssertEqual(detail.info.moment.royaltyBps, reviewed.royaltyBps)
        XCTAssertEqual(detail.info.state, .collecting)

        let quote = try await fork.service.quote(id: id, quantity: 1)
        try await run(await fork.service.collectWithApprovalPlan(momentId: id, quantity: 1, gross: quote.gross, symbol: "FORK"), collector)
        let account = try await fork.service.accountView(detail.info, account: collector.address)
        XCTAssertEqual(account.nftBalance, 1)
        XCTAssertEqual(account.entitlement, quote.entitlement)
        XCTAssertEqual(account.collectAllowance, 0, "the exact approval is used up")
        // The wallets' histories decode the v2 events.
        let (collected, collectedComplete) = await fork.service.history(account: collector.address)
        XCTAssertTrue(collectedComplete, "a fork's few blocks are read whole")
        XCTAssertEqual(collected.collects.map(\.momentId), [id])
        XCTAssertEqual(collected.collects.first?.gross, quote.gross)
        let (published, publishedComplete) = await fork.service.history(account: creator.address)
        XCTAssertTrue(publishedComplete)
        XCTAssertEqual(published.publishes.map(\.momentId), [id])
        XCTAssertEqual(published.publishes.first?.coin, detail.info.moment.coin)

        // Governance moves the factory's base: the existing Moment keeps its link, and new publishes are refused here.
        let setBase = "setExternalBaseURI(string)"
        try await sendAs(fork.governance, to: fork.addresses.factory, setBase, [.string("https://dyorhq.fun/moments/elsewhere/")])
        let movedRead = try await fork.service.moment(id: id)
        XCTAssertEqual(movedRead?.externalURL, "https://dyorhq.fun/moments/c4/\(id)")
        let moved = try await policy(fork)
        XCTAssertEqual(moved.publishBlock, .unexpectedLinkBase)
        XCTAssertNotEqual(moved.termsHash, reviewed.termsHash, "the base is part of the terms")
        try await sendAs(fork.governance, to: fork.addresses.factory, setBase, [.string(MomentsAddresses.expectedExternalBaseURI)])
        let restored = try await policy(fork)
        XCTAssertTrue(restored.canPublish)
    }

    /// `collectPlan`, the Permit2 path: the collect carries a transfer signed by the fork key over the app's own Permit2
    /// digest. (The app's collect sheet uses the exact-approval plan; this keeps the Permit2 path honest on v2.)
    func testPermit2CollectSignedByTheForkKey() async throws {
        let fork = try moments()
        let creator = try await wallet()
        let collector = try await wallet(usdc: 5 * Self.usdcUnit)
        let detail = try await publish(fork, input("Fork permit"), by: creator)
        let plan = try await fork.service.collectPlan(momentId: detail.info.id, quantity: 2, price: detail.info.moment.price, signer: collector, symbol: "FORK")
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(collector.signatures, 1, "the Permit2 transfer was signed while building the plan")
        try await run(plan, collector)
        let account = try await fork.service.accountView(detail.info, account: collector.address)
        XCTAssertEqual(account.nftBalance, 2)
        XCTAssertEqual(account.usdcBalance, 5 * Self.usdcUnit - 2 * detail.info.moment.price)
    }

    // MARK: Graduation, claims, withdrawals

    /// A terminal collect graduates the Moment in the collect itself; the collector claims the 60% that vests at
    /// graduation, a second claim is refused (`NothingToClaim`) before anything is signed, and the creator withdraws the
    /// collect-time share.
    func testATerminalCollectGraduatesAndPaysOut() async throws {
        let (fork, creator, collector, info, quote) = try await graduatedMoment()
        let id = info.id

        let owed = try await fork.service.accountView(info, account: collector.address)
        XCTAssertEqual(owed.claimableCollector, owed.entitlement * 6_000 / 10_000, "60% vests at graduation")
        XCTAssertGreaterThan(owed.claimableCollector, 0)
        try await run(await fork.service.claimPlan(momentId: id, symbol: info.symbol), collector)
        let claimed = try await fork.service.accountView(info, account: collector.address)
        XCTAssertEqual(claimed.coinBalance, owed.claimableCollector)
        XCTAssertEqual(claimed.claimableCollector, 0)
        let signed = collector.signatures
        let again = await refusal(await fork.service.claimPlan(momentId: id, symbol: info.symbol), collector)
        XCTAssertEqual(again, sentence("NothingToClaim"))
        XCTAssertEqual(collector.signatures, signed, "nothing was signed")

        let proceeds = try await fork.service.accountView(info, account: creator.address)
        XCTAssertEqual(proceeds.creatorProceeds, info.ledger.creatorClaimable)
        XCTAssertEqual(proceeds.creatorProceeds, quote.creatorIn, "the creator's collect-time share (the rounding remainder included)")
        let before = try await balance(Monad.usdc, creator.address)
        try await run(await fork.service.withdrawCreatorProceedsPlan(momentId: id), creator)
        let after = try await balance(Monad.usdc, creator.address)
        XCTAssertEqual(after - before, proceeds.creatorProceeds)
        // The creator's own tranche: 20% of the allocation at graduation.
        let creatorView = try await fork.service.accountView(info, account: creator.address)
        XCTAssertEqual(creatorView.claimableCreator, info.moment.creatorAllocation * 2_000 / 10_000)
        try await run(await fork.service.claimPlan(momentId: id, symbol: info.symbol), creator)
    }

    /// Trading on a graduated Moment's pool through the app's route pays the creator's fee share and funds buybacks.
    /// The pool's own guards refuse, each in its sentence before anything is signed: a buyback simulated in the block of
    /// a >2% price move (`PriceMoved`), and a second round within the hour (`TooSoon`). A buyback that lands in the same
    /// block as such a move (automine off: both pending, so no simulation can see the swap) is reverted by the block.
    func testPoolFeesAndBuybacks() async throws {
        let (fork, creator, _, info, _) = try await graduatedMoment()
        let id = info.id
        let trader = try await wallet(usdc: 2_000 * Self.usdcUnit)
        // Half the threshold moves the pool's price well over 2%: 5 USDC on the small-threshold stack.
        let terms = try await policy(fork)
        let moveAmount = terms.threshold / 2

        // A round trip of 200 USDC: 1% of the USDC side to the hook each way, half of it for buybacks (≥ 1 USDC).
        try await swap(fork, info, buy: true, amount: 200 * Self.usdcUnit, trader)
        let coins = try await balance(info.moment.coin, trader.address)
        XCTAssertGreaterThan(coins, 0)
        try await swap(fork, info, buy: false, amount: coins, trader)
        let tradedRead = try await fork.service.info(id: id)
        let traded = try XCTUnwrap(tradedRead?.pool)
        XCTAssertGreaterThanOrEqual(traded.buybackFees, Self.usdcUnit, "a round's minimum budget")
        XCTAssertGreaterThan(traded.creatorFees, 0)

        // The creator's pool fees.
        let fees = try await fork.service.accountView(try XCTUnwrap(tradedRead), account: creator.address)
        XCTAssertEqual(fees.creatorFees, traded.creatorFees)
        let before = try await balance(Monad.usdc, creator.address)
        try await run(await fork.service.withdrawCreatorFeesPlan(momentId: id), creator)
        let after = try await balance(Monad.usdc, creator.address)
        XCTAssertEqual(after - before, traded.creatorFees)

        let keeper = try await wallet()
        // A >2% move in this block: a buyback simulated in it is refused (PriceMoved), and nothing is signed.
        try await swap(fork, info, buy: true, amount: moveAmount, trader)
        let moved = await refusal(await fork.service.buybackPlan(momentId: id, minCoinOut: 0), keeper)
        XCTAssertEqual(moved, sentence("PriceMoved"))
        XCTAssertEqual(keeper.signatures, 0)

        // The same move and a buyback in ONE block on chain: the swap first (the higher tip), then the round, both
        // pending until the block is mined. The contract's guard reverts the round; raw sends, as no app plan can see
        // a pending swap.
        let move = try await swapPlan(fork, info, buy: true, amount: moveAmount, trader)
        for step in move.dropLast() where try await sender.request(for: step, owner: trader.address) != nil { try await run([step], trader) }
        let roundPlan = await fork.service.buybackPlan(momentId: id, minCoinOut: 0)
        let round = try XCTUnwrap(roundPlan.first?.request)
        _ = try await rpc.call("evm_setAutomine", [.bool(false)])
        let swapHash = try await submit(trader.address, try XCTUnwrap(move.last?.request), gas: 2_000_000, tipGwei: 5)
        let roundHash = try await submit(keeper.address, round, gas: 3_000_000, tipGwei: 1)
        try await mine()
        _ = try await rpc.call("evm_setAutomine", [.bool(true)])
        let swapReceipt = try await rpc.waitForReceipt(swapHash)
        let roundReceipt = try await rpc.waitForReceipt(roundHash)
        XCTAssertTrue(swapReceipt.success)
        XCTAssertFalse(roundReceipt.success, "a round in the block of a >2% move reverts")
        XCTAssertEqual(roundReceipt.blockNumber, swapReceipt.blockNumber)
        do {
            _ = try await rpc.ethCall(CallRequest(from: keeper.address, to: round.to, data: round.data))
            XCTFail("the round simulated in that block must revert")
        } catch let error as RPCError {
            XCTAssertEqual(RevertReason.describe(error), sentence("PriceMoved"), "why it reverted")
        }

        // An hour on, the block opens at the moved price: the round runs.
        try await warp(3_600)
        try await run(await fork.service.buybackPlan(momentId: id, minCoinOut: 0), keeper)
        let boughtRead = try await fork.service.info(id: id)
        let bought = try XCTUnwrap(boughtRead?.pool)
        XCTAssertGreaterThan(bought.lastBuyback, 0)
        XCTAssertGreaterThan(bought.liquidity, traded.liquidity, "the round added to the locked position")

        // A second round within the hour.
        let signed = keeper.signatures
        let soon = await refusal(await fork.service.buybackPlan(momentId: id, minCoinOut: 0), keeper)
        XCTAssertEqual(soon, sentence("TooSoon"))
        XCTAssertEqual(keeper.signatures, signed)

        // "Held for later buyback rounds" is this Moment's own locker balance (`heldOf`). USDC sent to the locker
        // directly is untracked: `available` counts it for every Moment, and the next add on any Moment takes it.
        let locker = { (signature: String) in MomentsABI.call(fork.addresses.locker, signature, [.uint(id), .address(Monad.usdc)], returns: "uint256") }
        let held = try await Multicall(rpc: rpc).readAll([locker(MomentsABI.Locker.heldOf), locker(MomentsABI.Locker.available)])
        XCTAssertEqual(bought.heldForLaterRounds, held[0][0].uint)
        let stray = 25 * Self.usdcUnit
        try await fund(Monad.usdc, stray, to: fork.addresses.locker)
        let strayRead = try await fork.service.info(id: id)
        XCTAssertEqual(strayRead?.pool?.heldForLaterRounds, held[0][0].uint, "USDC sent to the locker is not this Moment's")
        let available = try await Multicall(rpc: rpc).readAll([locker(MomentsABI.Locker.available)])
        XCTAssertEqual(available[0][0].uint, held[1][0].uint + stray, "available() counts it")
    }

    /// A Moment that misses its window: expiring is refused before the deadline (`NotExpirable`), anyone's expire
    /// plan winds it down after it, and the creator withdraws their share plus 70% of the reserve.
    func testExpireAfterTheDeadline() async throws {
        let fork = try moments()
        let creator = try await wallet()
        let collector = try await wallet(usdc: 5 * Self.usdcUnit)
        let keeper = try await wallet()
        let detail = try await publish(fork, input("Fork brief", window: 3_600), by: creator)
        let id = detail.info.id
        let quote = try await fork.service.quote(id: id, quantity: 1)
        try await run(await fork.service.collectWithApprovalPlan(momentId: id, quantity: 1, gross: quote.gross, symbol: "FORK"), collector)

        let early = await refusal(await fork.service.expirePlan(momentId: id), keeper)
        XCTAssertEqual(early, sentence("NotExpirable"))
        XCTAssertEqual(keeper.signatures, 0)

        try await warp(to: detail.info.moment.deadline + 1)
        try await run(await fork.service.expirePlan(momentId: id), keeper)
        let expiredRead = try await fork.service.info(id: id)
        let expired = try XCTUnwrap(expiredRead)
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.ledger.reserve, 0)
        let share = quote.reserveIn * BigUInt(detail.info.moment.expiryCreatorBps) / 10_000
        XCTAssertEqual(expired.ledger.creatorClaimable, quote.creatorIn + share)
        let before = try await balance(Monad.usdc, creator.address)
        try await run(await fork.service.withdrawCreatorProceedsPlan(momentId: id), creator)
        let after = try await balance(Monad.usdc, creator.address)
        XCTAssertEqual(after - before, quote.creatorIn + share)
    }

    // MARK: Refusals, decoded before anything is signed

    /// MO-4: a proposal applied between the review and the publish. The publish carries the reviewed hash, so the
    /// factory refuses it (`TermsChanged`), `prepare` says so, and the wallet never signs.
    func testTermsChangedBetweenReviewAndPublishIsRefusedUnsigned() async throws {
        let fork = try moments()
        let creator = try await wallet()
        let reviewed = try await policy(fork)
        XCTAssertTrue(reviewed.canPublish)
        let next: ABIValue = .tuple([.uint(reviewed.threshold), .uint(reviewed.minPrice), .uint(reviewed.creatorBps), .uint(reviewed.platformBps), .uint(reviewed.reserveBps),
                                     .uint(reviewed.maxCreatorAllocBps), .uint(reviewed.expiryCreatorBps), .uint(reviewed.royaltyBps == 750 ? 500 : 750),
                                     .address(reviewed.platform), .address(reviewed.treasury)])
        try await sendAs(fork.governance, to: fork.addresses.factory, "proposePolicy((\(MomentsABI.policyFlat)))", [next])
        let queued = try await policy(fork)
        let pending = try XCTUnwrap(queued.pending)
        XCTAssertEqual(pending.changes(from: queued), [.royalty])
        XCTAssertEqual(pending.lapsesAt, pending.applicableAt.addingTimeInterval(TimeInterval(MomentsConstants.policyApplyWindowSeconds)))
        try await warp(48 * 3600 + 1)
        try await sendAs(creator.address, to: fork.addresses.factory, "applyPolicy()") // anyone may apply it

        let publish = try await fork.service.publishPlan(input("Fork terms"), termsHash: reviewed.termsHash)
        let why = await refusal(publish, creator)
        XCTAssertEqual(why, "The Moments terms changed after you reviewed them, so nothing was published. Review them again.")
        XCTAssertEqual(creator.signatures, 0, "nothing was signed")
        let now = try await policy(fork)
        XCTAssertNotEqual(now.termsHash, reviewed.termsHash)
        XCTAssertTrue(now.canPublish, "the new terms can be reviewed and published")
    }

    /// The guardian's pause stops publishing like governance's: the app reads it (Publish off), and a publish is refused
    /// with the paused sentence before anything is signed.
    func testGuardianPauseRefusesPublishing() async throws {
        let fork = try moments()
        let creator = try await wallet()
        let pause = "setGuardianPaused(bool)"
        try await sendAs(fork.guardian, to: fork.addresses.factory, pause, [.bool(true)])
        let paused = try await policy(fork)
        XCTAssertTrue(paused.guardianPaused)
        XCTAssertEqual(paused.publishBlock, .guardianPaused)
        let publish = try await fork.service.publishPlan(input("Fork paused"), termsHash: paused.termsHash)
        let why = await refusal(publish, creator)
        XCTAssertEqual(why, "Publishing is paused right now, so nothing was published.")
        XCTAssertEqual(creator.signatures, 0)
        try await sendAs(fork.guardian, to: fork.addresses.factory, pause, [.bool(false)])
        let open = try await policy(fork)
        XCTAssertFalse(open.guardianPaused)
    }

    /// A price above the gross that completes the reserve is refused by v2 (`PriceTooHigh`) with its sentence; the form
    /// would stop it first, so the plan here is built past the form.
    func testAPriceAboveTheCeilingIsRefused() async throws {
        let fork = try moments()
        let creator = try await wallet()
        let terms = try await policy(fork)
        let ceiling = try XCTUnwrap(MomentsMath.maxCollectPrice(threshold: terms.threshold, reserveBps: terms.reserveBps))
        let publish = try await fork.service.publishPlan(input("Fork pricey", price: ceiling + 1), termsHash: terms.termsHash)
        let why = await refusal(publish, creator)
        XCTAssertEqual(why, sentence("PriceTooHigh"))
        XCTAssertEqual(creator.signatures, 0)
        // At the ceiling itself the publish goes through.
        try await run(try await fork.service.publishPlan(input("Fork ceiling", price: ceiling), termsHash: terms.termsHash), creator)
        XCTAssertEqual(creator.signatures, 1)
    }
}
