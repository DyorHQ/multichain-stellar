import XCTest
@testable import DyorKit

/// The v2 addresses are unknown until the owner deploys, so each stack's lives in ONE constant
/// (`MomentsAddresses.monadMainnet`, `LaunchpadAddresses.monadMainnet`), all zero under a PENDING marker until then.
/// Three gates keep that safe without keeping DyorKit red until the deploy:
///
/// - (a) `testEachStackIsPendingOrFullyWired` always runs. A stack is either all zero (pending) or fully wired, never
///   half. Pending, the live deployment records must not be promoted yet (`143.json` is still 0x6B1C…,
///   `moments-143.json` still cohort 3, 0x0FD4…); wired, the constant must equal the promoted record. So the Swift wiring
///   and the record promotion land together, in one reviewed change.
/// - (b) `testReleaseHasV2Wired` is skipped unless `DYORHQ_RELEASE_GATE=1`, and then fails loudly unless both stacks and
///   the c4 link cohort are wired and the link base is the c4 one. The release checklist runs
///   `DYORHQ_RELEASE_GATE=1 swift test --filter V2WiringTests`.
/// - (c) The archive gate runs `scripts/dev/check-launchpad-addresses.py --release` on every archive path: the DyorHQ
///   target's install-only build phase (`ios/project.yml`, so an archive from Xcode is gated too),
///   `ios/ci_scripts/ci_post_xcodebuild.sh` and `ios/scripts/testflight.sh`. It refuses to ship while either block is
///   PENDING, while a retired Moments cohort is not final on chain, or while a live factory on chain disagrees with its
///   table and record (`RetiredCohortGateTests`), so a wrong record wired in (a) is still caught.
///
/// An always-failing test was rejected: it would keep DyorKit red until the deploy and teach everyone to ignore a red
/// run. A runtime guard alone was rejected too: the app would ship a silent "not live yet" build.
final class V2WiringTests: XCTestCase {
    enum Wiring: Equatable { case pending, wired }

    /// Cohort 3's deployment block: a v2 factory is younger.
    static let cohort3DeployBlock: UInt64 = 107_311_600
    static let cohort3Factory = Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26")
    static let relaunchFactory = Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB")

    /// All zero (pending), all set (wired), or nil for anything in between.
    static func wiring(_ m: MomentsAddresses) -> Wiring? {
        let set = [m.factory, m.collect, m.vesting, m.graduation, m.locker, m.hook, m.buyback, m.platform, m.treasury].map { !$0.isZero } + [m.deployBlock > 0]
        if set.allSatisfy({ !$0 }) { return .pending }
        return set.allSatisfy { $0 } ? .wired : nil
    }

    static func wiring(_ l: LaunchpadAddresses) -> Wiring? {
        let set = [l.factory, l.router, l.escrow, l.holderFeeSharing, l.hook].map { !$0.isZero }
        if set.allSatisfy({ !$0 }) { return .pending }
        return set.allSatisfy { $0 } ? .wired : nil
    }

    private func record(_ name: String) throws -> [String: Any] { try LaunchpadDeploymentTests.deploymentRecord(name) }

    private func address(_ record: [String: Any], _ key: String) throws -> Address {
        try XCTUnwrap(Address(try XCTUnwrap(record[key] as? String, "\(key) is missing from the record")), key)
    }

    // MARK: (a)

    func testEachStackIsPendingOrFullyWired() throws {
        let moments = MomentsAddresses.monadMainnet
        let launchpad = LaunchpadAddresses.monadMainnet
        XCTAssertEqual(moments.generation, .v2)
        XCTAssertEqual(launchpad.generation, .v2)
        XCTAssertNil(moments.retirement)
        // The infrastructure is set either way.
        XCTAssertEqual(moments.usdc, Monad.usdc)
        XCTAssertEqual(moments.permit2, Uniswap.permit2)
        XCTAssertEqual(moments.poolManager, Uniswap.poolManager)
        XCTAssertEqual(launchpad.poolManager, Uniswap.poolManager)

        switch Self.wiring(moments) {
        case nil:
            XCTFail("MomentsAddresses.monadMainnet is partly wired: set every module, platform, treasury and deployBlock, or none")
        case .pending:
            XCTAssertFalse(moments.isDeployed)
            XCTAssertFalse(MomentLink.Cohort.c4.isWired)
            // Not promoted yet: the live record is still cohort 3.
            XCTAssertEqual(try address(try record("moments-143.json"), "factory"), Self.cohort3Factory,
                           "moments-143.json names another factory while the Swift table is pending: wire MomentsAddresses.monadMainnet in the same change")
        case .wired:
            try assertMomentsWired(moments)
        }

        switch Self.wiring(launchpad) {
        case nil:
            XCTFail("LaunchpadAddresses.monadMainnet is partly wired: set all five modules, or none")
        case .pending:
            XCTAssertFalse(launchpad.isDeployed)
            XCTAssertEqual(try address(try record("143.json"), "factory"), Self.relaunchFactory,
                           "143.json names another factory while the Swift table is pending: wire LaunchpadAddresses.monadMainnet in the same change")
        case .wired:
            try assertLaunchpadWired(launchpad)
        }
    }

    private func assertMomentsWired(_ m: MomentsAddresses) throws {
        XCTAssertTrue(m.isDeployed)
        XCTAssertTrue(MomentLink.Cohort.c4.isWired)
        let modules = [m.factory, m.collect, m.vesting, m.graduation, m.locker, m.hook, m.buyback]
        XCTAssertEqual(Set(modules).count, modules.count, "the v2 Moments modules are distinct")
        let retired = Set(MomentsAddresses.retiredMainnet.flatMap { [$0.factory, $0.collect, $0.vesting, $0.graduation, $0.locker, $0.hook, $0.buyback] })
        XCTAssertTrue(retired.isDisjoint(with: modules), "a v2 Moments module is a retired cohort's")
        XCTAssertFalse([Address(literal: "0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48"), Address(literal: "0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045")].contains { [m.platform, m.treasury].contains($0) },
                       "v2 pays a retired wallet")
        XCTAssertGreaterThan(m.deployBlock, Self.cohort3DeployBlock, "deployBlock: the v2 factory's creation block, from its broadcast receipt")
        // Equal to the promoted record…
        let live = try record("moments-143.json")
        XCTAssertEqual(live["chainId"] as? Int, 143)
        for (key, value) in [("factory", m.factory), ("collect", m.collect), ("vesting", m.vesting), ("graduation", m.graduation), ("locker", m.locker), ("hook", m.hook),
                             ("buyback", m.buyback), ("platform", m.platform), ("treasury", m.treasury), ("usdc", m.usdc), ("permit2", m.permit2), ("poolManager", m.poolManager)] {
            XCTAssertEqual(try address(live, key), value, "moments-143.json \(key)")
        }
        XCTAssertEqual((live["deployBlock"] as? NSNumber)?.uint64Value, m.deployBlock, "moments-143.json deployBlock (add it by hand from the receipt)")
        // …and cohort 3's record kept as a retired one, equal to the retired table's cohort 3.
        let cohort3 = try record("moments-143-cohort3.json")
        let table = try XCTUnwrap(MomentsAddresses.retired(factory: Self.cohort3Factory))
        XCTAssertEqual(table.retirement, .replaced)
        for (key, value) in [("factory", table.factory), ("collect", table.collect), ("vesting", table.vesting), ("graduation", table.graduation), ("locker", table.locker),
                             ("hook", table.hook), ("buyback", table.buyback), ("platform", table.platform), ("treasury", table.treasury)] {
            XCTAssertEqual(try address(cohort3, key), value, "moments-143-cohort3.json \(key)")
        }
        XCTAssertEqual((cohort3["deployBlock"] as? NSNumber)?.uint64Value, table.deployBlock, "moments-143-cohort3.json deployBlock")
    }

    private func assertLaunchpadWired(_ l: LaunchpadAddresses) throws {
        XCTAssertTrue(l.isDeployed)
        let modules = [l.factory, l.router, l.escrow, l.holderFeeSharing, l.hook]
        XCTAssertEqual(Set(modules).count, modules.count, "the v2 launchpad modules are distinct")
        let retired = Set(LaunchpadAddresses.retiredStacks.flatMap { [$0.factory, $0.router, $0.escrow, $0.holderFeeSharing, $0.hook] })
        XCTAssertTrue(retired.isDisjoint(with: modules), "a v2 launchpad module is a retired stack's")
        let live = try record("143.json")
        for (key, value) in [("factory", l.factory), ("launchAndBuyRouter", l.router), ("escrow", l.escrow), ("holderFeeSharing", l.holderFeeSharing), ("hook", l.hook), ("poolManager", l.poolManager)] {
            XCTAssertEqual(try address(live, key), value, "143.json \(key)")
        }
        XCTAssertEqual(try address(try record("143-retired-0x6B1C.json"), "factory"), Self.relaunchFactory)
    }

    /// The checker itself: half a table is refused, whichever address is set alone.
    func testAPartlyWiredTableIsRefused() {
        XCTAssertEqual(Self.wiring(MomentsAddresses(generation: .v2)), .pending)
        XCTAssertEqual(Self.wiring(LaunchpadAddresses(poolManager: Uniswap.poolManager, generation: .v2)), .pending)
        XCTAssertEqual(Self.wiring(V2Fixture.moments), .wired)
        XCTAssertEqual(Self.wiring(V2Fixture.launchpad), .wired)
        let x = Address(literal: "0x00000000000000000000000000000000000000c4")
        let momentFields: [WritableKeyPath<MomentsAddresses, Address>] = [\.factory, \.collect, \.vesting, \.graduation, \.locker, \.hook, \.buyback, \.platform, \.treasury]
        for field in momentFields {
            var one = MomentsAddresses(generation: .v2)
            one[keyPath: field] = x
            XCTAssertNil(Self.wiring(one), "\(field) set alone")
            var missing = V2Fixture.moments
            missing[keyPath: field] = .zero
            XCTAssertNil(Self.wiring(missing), "\(field) missing")
        }
        var blockOnly = MomentsAddresses(generation: .v2)
        blockOnly.deployBlock = 108_900_000
        XCTAssertNil(Self.wiring(blockOnly))
        var noBlock = V2Fixture.moments
        noBlock.deployBlock = 0
        XCTAssertNil(Self.wiring(noBlock), "a wired table needs its deployBlock")
        for field in [\LaunchpadAddresses.factory, \.router, \.escrow, \.holderFeeSharing, \.hook] {
            var one = LaunchpadAddresses(poolManager: Uniswap.poolManager, generation: .v2)
            one[keyPath: field] = x
            XCTAssertNil(Self.wiring(one), "\(field) set alone")
        }
    }

    // MARK: (b)

    /// The release gate: `DYORHQ_RELEASE_GATE=1 swift test --filter V2WiringTests` before cutting a release. Fails, by
    /// design, on a branch where v2 is still pending.
    func testReleaseHasV2Wired() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DYORHQ_RELEASE_GATE"] == "1",
                          "release gate: run with DYORHQ_RELEASE_GATE=1 before a release (it fails while the v2 addresses are pending)")
        XCTAssertEqual(Self.wiring(MomentsAddresses.monadMainnet), .wired, "REFUSING A RELEASE: MomentsAddresses.monadMainnet (v2) is not wired")
        XCTAssertEqual(Self.wiring(LaunchpadAddresses.monadMainnet), .wired, "REFUSING A RELEASE: LaunchpadAddresses.monadMainnet (v2) is not wired")
        XCTAssertTrue(MomentLink.Cohort.c4.isWired, "REFUSING A RELEASE: v2 Moment links (c4) resolve to nothing")
        XCTAssertEqual(MomentsAddresses.expectedExternalBaseURI, "https://dyorhq.fun/moments/c4/")
        XCTAssertGreaterThan(MomentsAddresses.monadMainnet.deployBlock, Self.cohort3DeployBlock)
        XCTAssertEqual(Mera.SigningPolicy.Contracts.monadMainnet.momentsCohorts.first, MomentsAddresses.monadMainnet, "the passkey policy collects on v2")
    }
}
