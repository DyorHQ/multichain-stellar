import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The passkey (Mera) session's scope on the exact plans the app builds against a real v2 Moments deployment on a LOCAL
/// anvil fork of Monad (`V2ForkCase` says how to run it), with the contracts table the app builds from its configured
/// cohort (`Contracts(moments:)`). The launchpad's `graduateFallback`, which a passkey account refuses on any stack (v2's on
/// the network-fee bound first), is checked on a real stuck launch in `LaunchpadV2ForkTests.testAStuckMondayLaunchOnARealV2Factory`.
final class MeraV2ForkTests: V2ForkCase {
    typealias Policy = Mera.SigningPolicy

    private func review(_ steps: [TransactionStep], _ intent: Mera.Intent, as account: Address, contracts: Policy.Contracts) -> Policy.Verdict {
        let calls = steps.compactMap { Policy.Call(step: $0, from: account) }
        XCTAssertEqual(calls.count, steps.count, "every step previews")
        let context = Policy.Context(account: account, expiresAt: Date().addingTimeInterval(15 * 60), contracts: contracts)
        return Policy.review(calls, intent: intent, context: context, caps: Mera.SpendingCaps())
    }

    /// Collecting, claiming and a creator's withdrawals sign without asking; publishing always asks (launching or
    /// creating, whatever the sheet declares); a collect above what the sheet shows asks; the retired cohorts' claims and
    /// withdrawals stay prompt-free and their collects are on no list. The shipped table, pending, trusts nothing of the
    /// fork's; wired to this deployment (`DYOR_V2_FORK_RECORDS=shipped`), it trusts the same plans.
    func testThePasskeyScopeOnPlansBuiltAgainstTheFork() async throws {
        let fork = try moments()
        let contracts = Policy.Contracts(moments: fork.addresses)
        XCTAssertEqual(contracts.momentsCohorts, [fork.addresses] + MomentsAddresses.retiredMainnet, "v2, then cohorts 3, 2, 1")
        let creator = try await wallet()
        let collector = try await wallet(usdc: 5 * Self.usdcUnit)

        // Publish.
        let termsRead = try await fork.service.policy()
        let terms = try XCTUnwrap(termsRead)
        let input = MomentPublishInput(name: "Fork passkey", symbol: "PASS", mediaURI: "ipfs://bafyfork", mediaHash: Data(repeating: 0x42, count: 32), place: "Accra",
                                       date: 1_790_000_000, price: 1_000_000, creatorAllocBps: 1_000, collectWindow: 86_400)
        let publish = try await fork.service.publishPlan(input, termsHash: terms.termsHash)
        XCTAssertEqual(review(publish, .alwaysAsks(.launch), as: creator.address, contracts: contracts), .ask(.alwaysAsks(.launch)))
        let collectShown = Mera.Intent.momentsCollect(pay: .init(token: fork.addresses.usdc, amount: 1_000_000), usd: 1)
        XCTAssertEqual(review(publish, collectShown, as: creator.address, contracts: contracts), .ask(.notAllowlisted))
        let hash = try await run(publish, creator)
        let resultRead = try await fork.service.publishResult(transaction: hash)
        let id = try XCTUnwrap(resultRead).momentId

        // Collect: the exact approval of the collect contract, then collect.
        let quote = try await fork.service.quote(id: id, quantity: 1)
        let collect = await fork.service.collectWithApprovalPlan(momentId: id, quantity: 1, gross: quote.gross, symbol: "PASS")
        let intent = Mera.Intent.momentsCollect(pay: .init(token: fork.addresses.usdc, amount: quote.gross), usd: MomentsMath.usdc(quote.gross))
        XCTAssertEqual(review(collect, intent, as: collector.address, contracts: contracts), .allowed)
        let more = await fork.service.collectWithApprovalPlan(momentId: id, quantity: 2, gross: quote.gross * 2, symbol: "PASS")
        XCTAssertEqual(review(more, intent, as: collector.address, contracts: contracts), .ask(.approval(.amount)), "more than the sheet shows")
        // The prepared transaction, fee included, is within the bounds the passkey signer checks again before signing.
        let approveRead = try await sender.request(for: collect[0], owner: collector.address)
        let approve = try XCTUnwrap(approveRead)
        let prepared = try await sender.prepare(approve, from: collector)
        XCTAssertNil(Policy.refusal(.init(prepared), intent: intent, account: collector.address))
        try await run(collect, collector)
        let collectedRead = try await fork.service.info(id: id)
        let view = try await fork.service.accountView(try XCTUnwrap(collectedRead), account: collector.address)
        XCTAssertEqual(view.nftBalance, 1)

        // Claims and the creator's withdrawals, on v2 and on every retired cohort.
        let claim = await fork.service.claimPlan(momentId: id, symbol: "PASS")
        let proceeds = await fork.service.withdrawCreatorProceedsPlan(momentId: id)
        let fees = await fork.service.withdrawCreatorFeesPlan(momentId: id)
        let platform = await fork.service.withdrawPlatformProceedsPlan(momentId: id)
        XCTAssertEqual(review(claim, .momentsClaim, as: collector.address, contracts: contracts), .allowed)
        XCTAssertEqual(review(proceeds, .momentsWithdraw, as: creator.address, contracts: contracts), .allowed)
        XCTAssertEqual(review(fees, .momentsWithdraw, as: creator.address, contracts: contracts), .allowed)
        for cohort in MomentsAddresses.retiredMainnet {
            let retired = RetiredMoments(rpc: rpc, addresses: cohort)
            XCTAssertEqual(review(retired.plan(.claim, momentId: 1, symbol: "PAST"), .momentsClaim, as: collector.address, contracts: contracts), .allowed)
            XCTAssertEqual(review(retired.plan(.withdrawCreatorProceeds, momentId: 1, symbol: "PAST"), .momentsWithdraw, as: creator.address, contracts: contracts), .allowed)
            XCTAssertEqual(review(retired.plan(.withdrawCreatorFees, momentId: 1, symbol: "PAST"), .momentsWithdraw, as: creator.address, contracts: contracts), .allowed)
            // A retired cohort's collect (which no app plan builds) is on no list.
            let past = TransactionStep.call(TransactionRequest(to: cohort.collect, data: MomentsABI.calldata(MomentsABI.Collect.collect, [.uint(1), .uint(1)])), label: "Collect")
            XCTAssertEqual(review([past], intent, as: collector.address, contracts: contracts), .ask(.notAllowlisted))
        }
        // The platform's withdrawal is not a creator's: it asks.
        XCTAssertEqual(review(platform, .momentsWithdraw, as: creator.address, contracts: contracts), .ask(.notAllowlisted))

        // The shipped table while v2 is pending trusts none of the fork's contracts; once it is this deployment, the
        // same plans sign without asking.
        if !MomentsAddresses.monadMainnet.isDeployed {
            XCTAssertEqual(review(collect, intent, as: collector.address, contracts: .monadMainnet), .ask(.approval(.spender)))
            XCTAssertEqual(review(claim, .momentsClaim, as: collector.address, contracts: .monadMainnet), .ask(.notAllowlisted))
        } else if fork.addresses == MomentsAddresses.monadMainnet {
            XCTAssertEqual(review(collect, intent, as: collector.address, contracts: .monadMainnet), .allowed)
            XCTAssertEqual(review(claim, .momentsClaim, as: collector.address, contracts: .monadMainnet), .allowed)
            XCTAssertEqual(review(proceeds, .momentsWithdraw, as: creator.address, contracts: .monadMainnet), .allowed)
        }
    }
}
