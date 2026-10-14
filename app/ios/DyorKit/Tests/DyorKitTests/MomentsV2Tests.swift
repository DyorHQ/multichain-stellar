import BigInt
import XCTest
@testable import DyorKit

/// Moments v2 in the app: the terms hash a publish carries (pinned against `cast`), when publishing is allowed at all
/// (`MomentPolicy.canPublish`), the publish plan's binding to the reviewed terms, and the generation gate that keeps every
/// v2-only getter away from the v1 cohorts (a reverted sub-call fails a whole Multicall3 read).
final class MomentsV2Tests: XCTestCase {
    private let input = MomentPublishInput(name: "Nature", symbol: "NATURE", mediaURI: "ipfs://bafy", mediaHash: Data(repeating: 0x11, count: 32), place: "Accra",
                                           date: 1_790_000_000, price: 1_000_000, creatorAllocBps: 1_000, collectWindow: 86_400)

    // MARK: Terms hash (cast abi-encode | cast keccak)

    func testTermsHashMatchesTheFactory() {
        // cast keccak $(cast abi-encode "f((uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,address,address),string)" \
        //   "(771428571,100000,2000,500,7500,1000,7000,500,0x15ED3bb488231213b141A2f78b62358D52235Cd7,0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371)" \
        //   "https://dyorhq.fun/moments/c4/")
        let policy = V2Fixture.policy(termsHash: nil)
        XCTAssertEqual(MomentsABI.termsHash(policy: policy, base: "https://dyorhq.fun/moments/c4/").hexString, "0x3d9ff80b17a4f23544485081f1d595532c4f1d7932b3deea682e0b1e1fb2fa03")
        XCTAssertEqual(policy.localTermsHash, V2Fixture.termsHash)
        // Every hashed term moves it: the policy's fields and the link base.
        XCTAssertNotEqual(V2Fixture.policy(royaltyBps: 501).localTermsHash, V2Fixture.termsHash)
        XCTAssertNotEqual(V2Fixture.policy(platform: Address(literal: "0x00000000000000000000000000000000000000aa")).localTermsHash, V2Fixture.termsHash)
        XCTAssertNotEqual(V2Fixture.policy(base: "https://dyorhq.fun/moments/").localTermsHash, V2Fixture.termsHash)
        // The pauses and the guardian are not terms: they don't move it.
        XCTAssertEqual(V2Fixture.policy(publishingPaused: true, guardianPaused: true).localTermsHash, V2Fixture.termsHash)
    }

    func testTheExpectedLinkBaseIsTheC4Cohort() {
        XCTAssertEqual(MomentsAddresses.expectedExternalBaseURI, "https://dyorhq.fun/moments/c4/")
        // The NFTs' external_url (base + id) is a c4 link.
        let link = URL(string: MomentsAddresses.expectedExternalBaseURI + "7").flatMap(MomentLink.init(url:))
        if MomentLink.Cohort.c4.isWired {
            XCTAssertEqual(link?.target, .key(MomentKey(factory: MomentsAddresses.monadMainnet.factory, id: 7)))
        } else {
            XCTAssertNil(link, "no c4 link resolves while v2 is pending")
        }
    }

    // MARK: canPublish

    func testCanPublishOnlyWithEveryCheckPassing() {
        XCTAssertTrue(V2Fixture.policy().canPublish)
        XCTAssertNil(V2Fixture.policy().publishBlock)
        XCTAssertEqual(V2Fixture.policy(publishingPaused: true).publishBlock, .publishingPaused)
        XCTAssertEqual(V2Fixture.policy(guardianPaused: true).publishBlock, .guardianPaused, "the guardian's pause counts like governance's")
        XCTAssertEqual(V2Fixture.policy(publishingPaused: true, guardianPaused: true).publishBlock, .publishingPaused)
        XCTAssertEqual(V2Fixture.policy(termsHash: nil).publishBlock, .unverifiedTerms, "a v1 factory has no terms hash")
        for flagged in [V2Fixture.policy(publishingPaused: true), V2Fixture.policy(guardianPaused: true), V2Fixture.policy(termsHash: nil)] {
            XCTAssertFalse(flagged.canPublish)
            XCTAssertFalse(flagged.publishBlock?.message.isEmpty ?? true)
        }
    }

    func testCanPublishRefusesAnyOtherLinkBase() {
        for base in ["https://dyorhq.fun/moments/", "https://dyorhq.fun/moments/c4", "https://evil.example/moments/c4/", "http://dyorhq.fun/moments/c4/",
                     "https://DYORHQ.FUN/moments/c4/", "https://dyorhq.fun/moments/c4/ ", "https://dyorhq.fun/moments/c5/", ""] {
            // Even with the on-chain hash matching those terms: the base itself is wrong.
            let policy = V2Fixture.policy(base: base, termsHash: V2Fixture.policy(base: base).localTermsHash)
            XCTAssertEqual(policy.publishBlock, .unexpectedLinkBase, base)
            XCTAssertFalse(policy.canPublish, base)
        }
    }

    func testCanPublishRefusesAHashThatIsNotTheTermsRead() {
        // The hash read on chain must be the hash of the terms read with it; anything else binds terms nobody saw.
        let stale = V2Fixture.policy(royaltyBps: 750, termsHash: V2Fixture.termsHash)
        XCTAssertEqual(stale.publishBlock, .unverifiedTerms)
        XCTAssertFalse(V2Fixture.policy(termsHash: Data(repeating: 0xab, count: 32)).canPublish)
        XCTAssertFalse(V2Fixture.policy(termsHash: Data(count: 32)).canPublish)
    }

    // MARK: Publish plan

    func testPublishPlanCarriesTheReviewedHashAndNothingElse() async throws {
        let service = MomentsService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: V2Fixture.moments)
        let reviewed = V2Fixture.policy()
        let steps = try await service.publishPlan(input, termsHash: reviewed.termsHash)
        XCTAssertEqual(steps.count, 1)
        let request = try XCTUnwrap(steps.first?.request)
        XCTAssertEqual(steps.first?.kind, .call)
        XCTAssertEqual(request.to, V2Fixture.moments.factory)
        XCTAssertEqual(request.value, 0)
        XCTAssertEqual(request.data.prefix(4).hexString, "0xa270dccc")
        let args = try ABI.decode(request.data.dropFirst(4), "\(MomentsABI.publishParams),bytes32")
        XCTAssertEqual(args[1].bytes, reviewed.termsHash, "the hash of the reviewed terms")
        XCTAssertEqual(args[0][0].string, "Nature")
        XCTAssertEqual(args[0][3].uint, 1_000_000)

        // The terms move after the review (the model refreshes the policy under an open sheet): the plan built from the
        // snapshot still carries the snapshot's hash, never the new one.
        let refreshed = V2Fixture.policy(royaltyBps: 750, termsHash: V2Fixture.policy(royaltyBps: 750).localTermsHash)
        XCTAssertNotEqual(refreshed.termsHash, reviewed.termsHash)
        let again = try await service.publishPlan(input, termsHash: reviewed.termsHash)
        let againArgs = try ABI.decode(try XCTUnwrap(again.first?.request).data.dropFirst(4), "\(MomentsABI.publishParams),bytes32")
        XCTAssertEqual(againArgs[1].bytes, reviewed.termsHash)
        // Everything but the random CREATE2 salt is the same calldata.
        XCTAssertEqual(Array(againArgs[0].elements.dropLast()), Array(args[0].elements.dropLast()))
    }

    func testPublishPlanRefusesWithoutAReviewedHash() async {
        let service = MomentsService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: V2Fixture.moments)
        for hash in [nil, Data(count: 31), Data()] as [Data?] {
            do {
                _ = try await service.publishPlan(input, termsHash: hash)
                XCTFail("a publish was built without the reviewed terms hash")
            } catch {
                XCTAssertEqual(error as? MomentsService.MomentsError, .termsNotReviewed)
            }
        }
        // Nothing publishes on a v1 cohort or on a pending v2 table.
        for addresses in [MomentsAddresses.retiredMainnet[0], MomentsAddresses(generation: .v2)] {
            let other = MomentsService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: addresses)
            do {
                _ = try await other.publishPlan(input, termsHash: V2Fixture.termsHash)
                XCTFail("a publish was built for \(addresses.factory.hex)")
            } catch {
                XCTAssertEqual(error as? MomentsService.MomentsError, .notDeployed)
            }
        }
        // The shipped v2 table publishes on its own factory.
        let live = MomentsService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: .monadMainnet)
        let steps = try? await live.publishPlan(input, termsHash: V2Fixture.termsHash)
        XCTAssertEqual(steps?.first?.request?.to, MomentsAddresses.monadMainnet.factory)
    }

    // MARK: Generations (stubbed chain)

    private static let v2Only: Set<String> = [
        MomentsABI.Factory.termsHash, MomentsABI.Factory.guardian, MomentsABI.Factory.guardianPaused, MomentsABI.Factory.policyApplyWindow,
        MomentsABI.Locker.available, MomentsABI.Locker.heldOf, MomentsABI.Locker.maxIncreaseBps, MomentsABI.Buyback.maxOpenDeviationBps,
        MomentsABI.Hook.blockOpenSqrtPrice,
    ].reduce(into: []) { $0.insert(ABI.selector($1).hexString) }

    func testEveryRetiredCohortIsV1AndTheLiveOneV2() {
        XCTAssertEqual(MomentsAddresses.retiredMainnet.map(\.generation), [.v1, .v1, .v1])
        XCTAssertEqual(MomentsAddresses.monadMainnet.generation, .v2)
        XCTAssertEqual(LaunchpadAddresses.retiredStacks.map(\.generation), [.v1, .v1, .preAudit, .legacy])
        XCTAssertEqual(LaunchpadAddresses.monadMainnet.generation, .v2)
    }

    /// Cohort 3 (v1) through the service the retired client shares: its policy and Moment #1 are read without one v2
    /// getter, and the link comes from the factory, as its NFTs read it.
    func testAV1StackIsNeverAskedAV2Getter() async throws {
        let cohort3 = MomentsAddresses.retiredMainnet[0]
        let stack = FakeMomentsStack(addresses: cohort3, policy: V2Fixture.policy(termsHash: nil), factoryBase: "https://dyorhq.fun/moments/", nftBase: "https://never.example/")
        MomentsChainStub.install { stack.answer($0, $1) }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: cohort3)
        let policyRead = try await service.policy()
        let policy = try XCTUnwrap(policyRead)
        XCTAssertNil(policy.termsHash)
        XCTAssertNil(policy.guardian)
        XCTAssertFalse(policy.guardianPaused)
        XCTAssertEqual(policy.publishBlock, .unexpectedLinkBase, "cohort 3's bare base is not the v2 one")
        let detailRead = try await service.moment(id: 1)
        let detail = try XCTUnwrap(detailRead)
        XCTAssertEqual(detail.externalURL, "https://dyorhq.fun/moments/1")
        XCTAssertEqual(detail.info.name, "Nature")
        let retired = RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: cohort3)
        let moments = try await retired.moments()
        XCTAssertEqual(moments.map(\.key), [MomentKey(factory: cohort3.factory, id: 1)])

        let calls = MomentsChainStub.calls()
        XCTAssertFalse(calls.isEmpty)
        XCTAssertEqual(calls.filter { Self.v2Only.contains($0.selector) }, [], "a v2 getter was sent to a v1 cohort")
        let baseReads = calls.filter { $0.selector == ABI.selector(MomentsABI.NFT.externalBaseURI).hexString }
        XCTAssertFalse(baseReads.isEmpty)
        XCTAssertTrue(baseReads.allSatisfy { $0.to == cohort3.factory }, "a v1 NFT has no externalBaseURI of its own")
    }

    /// A v2 stack: the terms, the link base and the hash that binds them come from one aggregate (one block), and a
    /// Moment's link is the base its NFT kept, whatever the factory's base became since.
    func testAV2StackReadsItsTermsAtOneBlockAndTheNFTsOwnLinkBase() async throws {
        let stack = FakeMomentsStack(addresses: V2Fixture.moments, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                     nftBase: MomentsAddresses.expectedExternalBaseURI)
        MomentsChainStub.install { stack.answer($0, $1) }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.moments)
        let policyRead = try await service.policy()
        let policy = try XCTUnwrap(policyRead)
        XCTAssertEqual(policy.termsHash, V2Fixture.termsHash)
        XCTAssertEqual(policy.guardian, V2Fixture.policy().guardian)
        XCTAssertTrue(policy.canPublish)
        let batch = try XCTUnwrap(MomentsChainStub.batches().first)
        let selectors = Set(batch.map(\.selector))
        for signature in [MomentsABI.Factory.policy, MomentsABI.Factory.externalBaseURI, MomentsABI.Factory.pendingPolicy, MomentsABI.Factory.pendingPolicyAt,
                          MomentsABI.Factory.termsHash, MomentsABI.Factory.guardian, MomentsABI.Factory.guardianPaused] {
            XCTAssertTrue(selectors.contains(ABI.selector(signature).hexString), "\(signature) is not in the policy's aggregate")
        }

        // Governance later points the factory elsewhere: an existing Moment keeps the base its NFT stored at publish.
        var changed = stack
        changed.factoryBase = "https://evil.example/"
        let moved = changed
        MomentsChainStub.install { moved.answer($0, $1) }
        let detailRead = try await service.moment(id: 1)
        let detail = try XCTUnwrap(detailRead)
        XCTAssertEqual(detail.externalURL, "https://dyorhq.fun/moments/c4/1")
        XCTAssertTrue(MomentsChainStub.calls().contains(MomentsChainStub.Call(to: stack.nft(1), selector: ABI.selector(MomentsABI.NFT.externalBaseURI).hexString)))
        // …while new terms under the moved base can't be published (and no longer hash to what was reviewed).
        let nowRead = try await service.policy()
        let now = try XCTUnwrap(nowRead)
        XCTAssertEqual(now.publishBlock, .unexpectedLinkBase)
    }

    /// A graduated v2 Moment's "Held for later buyback rounds" is its own locker balance, `heldOf(id, USDC)`. The
    /// locker's `available` adds its untracked USDC (anything sent to it directly), which every Moment shares and the
    /// next add on any Moment takes: shown as each Moment's own, it would overstate every page.
    func testHeldForLaterRoundsIsTheMomentsOwnLockerBalance() async throws {
        let v2 = V2Fixture.moments
        let stack = FakeMomentsStack(addresses: v2, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                     nftBase: MomentsAddresses.expectedExternalBaseURI)
        let held = BigUInt(7_250_000)
        let untracked = BigUInt(500_000_000)
        let key: [ABIValue] = [.address(v2.usdc), .address(stack.coin(1)), .uint(5_000), .int(60), .address(v2.hook)]
        let record = try ABI.encode([.tuple([.tuple(key), .uint(BigUInt(1) << 96), .uint(1_000), .uint(771_000_000), .uint(1), .uint(0), .uint(0), .uint(1_790_600_000)])],
                                    MomentsABI.recordTuple)
        MomentsChainStub.install { to, data in
            func is_(_ signature: String) -> Bool { data.prefix(4) == ABI.selector(signature) }
            switch to {
            case v2.graduation:
                if is_(MomentsABI.Graduation.isGraduated) { return BigUInt(1).word }
                if is_(MomentsABI.Graduation.record) { return record }
            case v2.locker:
                if is_(MomentsABI.Locker.liquidityOf) { return BigUInt(1_000).word }
                if is_(MomentsABI.Locker.heldOf) { return held.word }
                if is_(MomentsABI.Locker.available) { return (held + untracked).word }
            case v2.hook, v2.buyback:
                return BigUInt(0).word
            case v2.poolManager:
                return nil // no live price: the pool falls back to its opening price
            default:
                break
            }
            return stack.answer(to, data)
        }
        let read = try await MomentsService(rpc: MomentsChainStub.rpc(), addresses: v2).info(id: 1)
        let pool = try XCTUnwrap(read?.pool, "a graduated Moment has its pool read")
        XCTAssertEqual(pool.heldForLaterRounds, held)
        let calls = MomentsChainStub.calls()
        XCTAssertTrue(calls.contains(MomentsChainStub.Call(to: v2.locker, selector: ABI.selector(MomentsABI.Locker.heldOf).hexString)))
        XCTAssertFalse(calls.contains { $0.selector == ABI.selector(MomentsABI.Locker.available).hexString }, "available() mixes in the locker's shared untracked USDC")
    }

    // MARK: Pending proposals (v2 lapse)

    func testAV2ProposalLapsesAfterTheApplyWindow() async throws {
        let stack = FakeMomentsStack(addresses: V2Fixture.moments, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                     nftBase: MomentsAddresses.expectedExternalBaseURI)
        let at = 1_800_000_000
        MomentsChainStub.install { to, data in
            if to == V2Fixture.moments.factory, data.prefix(4) == ABI.selector(MomentsABI.Factory.pendingPolicyAt) { return BigUInt(at).word }
            return stack.answer(to, data)
        }
        let v2Read = try await MomentsService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.moments).policy()?.pending
        let v2 = try XCTUnwrap(v2Read)
        XCTAssertEqual(v2.applicableAt.timeIntervalSince1970, TimeInterval(at))
        XCTAssertEqual(v2.lapsesAt?.timeIntervalSince1970, TimeInterval(at + 7 * 86_400))

        var retired = stack
        retired.addresses = MomentsAddresses.retiredMainnet[0]
        let v1Stack = retired
        MomentsChainStub.install { to, data in
            if to == v1Stack.addresses.factory, data.prefix(4) == ABI.selector(MomentsABI.Factory.pendingPolicyAt) { return BigUInt(at).word }
            return v1Stack.answer(to, data)
        }
        let v1Read = try await MomentsService(rpc: MomentsChainStub.rpc(), addresses: MomentsAddresses.retiredMainnet[0]).policy()?.pending
        let v1 = try XCTUnwrap(v1Read)
        XCTAssertNil(v1.lapsesAt, "a v1 proposal never lapses")
    }

    // MARK: The Moment page

    /// Cohort 4's threshold is 771.428571 USDC, which the page printed in full ("US$771.428571", "Still needed
    /// US$760.178571"). The reserve, the threshold and what is still needed are rounded to the cent
    /// (`MomentsFormat.usdcCents`); what a collect pays, and a queued change of the threshold, stay exact
    /// (`MomentsFormat.usdc`).
    func testTheReserveRowsRoundToTheCentAndACollectStaysExact() throws {
        XCTAssertEqual(V2Fixture.policy(termsHash: nil).threshold, 771_428_571)
        let detail = try DocsLinksTests.appSource("Moments/MomentDetailView.swift")
        XCTAssertTrue(detail.contains(#"LabeledContent("Reserve", value: tr("\(MomentsFormat.usdcCents(info.ledger.reserve)) of \(MomentsFormat.usdcCents(m.threshold))"))"#))
        XCTAssertTrue(detail.contains(#"LabeledContent("Still needed", value: tr("\(MomentsFormat.usdcCents(info.reserveRemaining)) · about"#))
        for unrounded in ["MomentsFormat.usdc(m.threshold)", "MomentsFormat.usdc(info.reserveRemaining)", "MomentsFormat.usdc(info.ledger.reserve)"] {
            XCTAssertFalse(detail.contains(unrounded), unrounded)
        }
        XCTAssertTrue(detail.contains(#"LabeledContent("You pay") { Text(MomentsFormat.usdc(quote.gross))"#))
        XCTAssertTrue(detail.contains(#"DetailRow("You pay", MomentsFormat.usdc(quote?.gross ?? m.price * BigUInt(quantity)))"#))
        let create = try DocsLinksTests.appSource("Moments/CreateMomentView.swift")
        XCTAssertEqual(create.components(separatedBy: "MomentsFormat.usdcCents(policy.threshold)").count - 1, 3, "Graduates at, twice, and the pricing footer")
        XCTAssertTrue(create.contains(#"case .threshold: return "\(MomentsFormat.usdc(now.threshold)) → \(MomentsFormat.usdc(next.threshold))""#))
    }
}
