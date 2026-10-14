import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The retired cohorts next to a real v2 deployment on a LOCAL anvil fork of Monad (`V2ForkCase` says how to run it):
/// cohort 3 (0x0FD4…, "Nature") read and served claim-only by `RetiredMoments` as it stands on mainnet, and the share
/// links across c1–c3 and c4: a fork v2 cohort (a Debug fork rehearsal, `MomentLink.Cohort.rehearse`) or the shipped one.
final class CohortsV2ForkTests: V2ForkCase {
    static let cohort3 = MomentsAddresses.retiredMainnet[0]
    static let natureCoin = Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")
    /// Nature's collect window ends at 2026-09-29 04:46:57 UTC.
    static let natureDeadline = 1_790_657_217

    /// Cohort 3 as the app sees it: Nature read from mainnet state, and the only plans a retired cohort builds (claim and
    /// the creator's two withdrawals, to cohort 3's own contracts). Once its window has passed anyone may expire it (the
    /// app never does; here a raw request from a fresh key), and the creator's withdrawal through the retired plan pays
    /// the collect-time share plus 70% of the reserve: 72,500 USDC units for the state read on 2026-09-28.
    func testCohort3IsClaimOnlyAndPaysNaturesCreatorAfterExpiry() async throws {
        let c3 = Self.cohort3
        XCTAssertEqual(c3.factory, MomentLink.Cohort.c3.factory)
        XCTAssertEqual(c3.retirement, .replaced)
        XCTAssertEqual(c3.platform, V2Fixture.moments.platform, "cohort 3 pays the current fees wallet")
        XCTAssertEqual(c3.treasury, V2Fixture.moments.treasury, "and the current treasury")
        let retired = RetiredMoments(rpc: rpc, addresses: c3)
        let listed = try await retired.moments()
        XCTAssertEqual(listed.map(\.name), ["Nature"], "one Moment, pinned (MomentLink.Cohort.c3.finalMomentCount)")
        let nature = try XCTUnwrap(listed.first)
        XCTAssertEqual(nature.key, MomentKey(factory: c3.factory, id: 1))
        XCTAssertEqual(nature.moment.coin, Self.natureCoin)
        XCTAssertEqual(MomentsAddresses.retiredMainnetCoins[Self.natureCoin], nature.key)
        XCTAssertFalse(SwapEngine.isTradable(Token(address: Self.natureCoin, symbol: nature.symbol, name: nature.name, decimals: 18)))
        XCTAssertEqual(nature.moment.platform, c3.platform)
        XCTAssertEqual(nature.moment.treasury, c3.treasury)
        XCTAssertEqual(nature.moment.deadline, Self.natureDeadline)
        let creator = nature.moment.creator
        XCTAssertTrue(creator.hex.lowercased().hasPrefix("0x90f3"), creator.hex)

        // Claim-only: three one-call plans, no value, each to cohort 3's own contract.
        XCTAssertEqual(RetiredMomentAction.allCases, [.claim, .withdrawCreatorProceeds, .withdrawCreatorFees])
        let targets: [RetiredMomentAction: (Address, String)] = [
            .claim: (c3.vesting, MomentsABI.Vesting.claim), .withdrawCreatorProceeds: (c3.collect, MomentsABI.Collect.withdrawCreator),
            .withdrawCreatorFees: (c3.hook, MomentsABI.Hook.withdrawCreator),
        ]
        for action in RetiredMomentAction.allCases {
            let plan = retired.plan(action, momentId: 1, symbol: nature.symbol)
            XCTAssertEqual(plan.count, 1, "\(action)")
            let request = try XCTUnwrap(plan.first?.request, "\(action)")
            XCTAssertEqual(request.to, targets[action]?.0, "\(action)")
            XCTAssertEqual(request.data, MomentsABI.calldata(targets[action]!.1, [.uint(1)]), "\(action)")
            XCTAssertEqual(request.value, 0)
        }

        // Before the deadline nobody can expire it.
        let keeper = try await wallet()
        let expire = TransactionStep.call(TransactionRequest(to: c3.collect, data: MomentsABI.calldata(MomentsABI.Collect.expire, [.uint(1)])), label: "Expire Nature (test only)")
        let now = try await latest().timestamp
        if now < Self.natureDeadline {
            let early = await refusal([expire], keeper)
            XCTAssertEqual(early, sentence("NotExpirable"))
        }
        let openRead = try await retired.info(id: 1)
        let open = try XCTUnwrap(openRead)
        guard open.state == .collecting else { throw XCTSkip("Nature is \(open.state.title) on this fork; the expiry below needs it still collecting") }
        let expected = open.ledger.creatorClaimable + open.ledger.reserve * BigUInt(open.moment.expiryCreatorBps) / 10_000

        try await warp(to: max(now, Self.natureDeadline) + 1)
        try await run([expire], keeper)
        let expiredRead = try await retired.info(id: 1)
        let expired = try XCTUnwrap(expiredRead)
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.ledger.creatorClaimable, expected)
        let positions = try await retired.positions(account: creator).positions
        XCTAssertEqual(positions.map(\.key), [nature.key])
        XCTAssertEqual(positions.first?.creatorProceeds, expected)

        // The creator (impersonated on the fork only) withdraws through the app's retired plan.
        let withdraw = try XCTUnwrap(retired.plan(.withdrawCreatorProceeds, momentId: 1, symbol: nature.symbol).first?.request)
        let before = try await balance(Monad.usdc, creator)
        try await sendAs(creator, to: withdraw.to, data: withdraw.data)
        let paid = try await balance(Monad.usdc, creator) - before
        XCTAssertEqual(paid, expected)
        if open.ledger.reserve == 75_000, open.ledger.creatorClaimable == 20_000 {
            XCTAssertEqual(paid, 72_500, "20,000 creator share + 70% of the 75,000 reserve")
        }
        let settled = try await retired.positions(account: creator).positions
        XCTAssertEqual(settled.first?.creatorWithdrawable ?? 0, 0, "nothing left to withdraw")
    }

    /// Links across every cohort with a fork v2 deployment as c4 (a Debug fork rehearsal), or the shipped c4 itself:
    /// every existing name keeps its Moment (read from mainnet state through the fork), a c4 Moment named "Nature" is
    /// `nature-2` (while c4 has no other), the c4 id form is the NFT's own `external_url` and parses back to it, and the
    /// bare id form stays cohort 3's.
    func testLinksNameTheRetiredMomentsAndTheForkCohort() async throws {
        let fork = try moments()
        // The shipped deployment is c4 as it is; a fork deploy is c4 only in a rehearsal.
        if !shipped { MomentLink.Cohort.rehearse(liveFactory: fork.addresses.factory) }
        defer { if !shipped { MomentLink.Cohort.rehearse(liveFactory: nil) } }
        XCTAssertEqual(MomentLink.Cohort.c4.factory, fork.addresses.factory)

        let creator = try await wallet()
        let reviewedRead = try await fork.service.policy()
        let reviewed = try XCTUnwrap(reviewedRead)
        let input = MomentPublishInput(name: "Nature", symbol: "NATURE", mediaURI: "ipfs://bafyfork", mediaHash: Data(repeating: 0x42, count: 32), place: "Accra",
                                       date: 1_790_000_000, price: 1_000_000, creatorAllocBps: 1_000, collectWindow: 86_400)
        let hash = try await run(try await fork.service.publishPlan(input, termsHash: reviewed.termsHash), creator)
        let resultRead = try await fork.service.publishResult(transaction: hash)
        let result = try XCTUnwrap(resultRead)
        let key = MomentKey(factory: fork.addresses.factory, id: result.momentId)

        let directory = MomentDirectory(rpc: rpc)
        for (cohort, id, _, slug) in MomentDirectoryTests.pinned {
            let found = try await directory.key(for: slug)
            XCTAssertEqual(found, MomentKey(factory: cohort.factory, id: BigUInt(id)), slug)
        }
        let nature = try await directory.key(for: "nature")
        XCTAssertEqual(nature, MomentKey(factory: MomentLink.Cohort.c3.factory, id: 1), "nature stays cohort 3's #1")
        let second = try await directory.key(for: "nature-2")
        XCTAssertEqual(second, key)
        let shared = try await directory.link(for: key)
        XCTAssertEqual(shared?.url.absoluteString, "https://dyorhq.fun/moments/nature-2")

        let detailRead = try await fork.service.moment(id: result.momentId)
        let detail = try XCTUnwrap(detailRead)
        XCTAssertEqual(detail.externalURL, "https://dyorhq.fun/moments/c4/\(result.momentId)")
        let byId = URL(string: detail.externalURL).flatMap(MomentLink.init(url:))
        XCTAssertEqual(byId?.target, .key(key))
        XCTAssertEqual(MomentLink(key: key)?.url.absoluteString, detail.externalURL)
        XCTAssertEqual(URL(string: "https://dyorhq.fun/moments/1").flatMap(MomentLink.init(url:))?.target, .key(MomentKey(factory: MomentLink.Cohort.c3.factory, id: 1)))
        XCTAssertEqual(URL(string: "https://dyorhq.fun/moments/nature").flatMap(MomentLink.init(url:))?.target, .name("nature"))
    }
}
