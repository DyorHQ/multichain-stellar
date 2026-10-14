import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The launch list and the Moments lists every screen shares (`ChainCache`): one read for the screens that ask within its
/// time, each taking its own newest, every factory's count in one aggregate, and what never changes of a settled launch or
/// Moment kept on the device (`ChainStore`) so a refresh reads only what moves, exactly as a full read shows it.
final class SharedChainReadsTests: XCTestCase {
    private static let launchedAt = 1_789_000_000 // `HonestyLaunchpad`'s curves
    private static let settled: @Sendable () -> Date = { Date(timeIntervalSince1970: TimeInterval(launchedAt + 3_600)) }

    private func selector(_ signature: String) -> String { ABI.selector(signature).hexString }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "shared-reads-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func install(_ chain: HonestyLaunchpad) {
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
    }

    private var chain: HonestyLaunchpad {
        var chain = HonestyLaunchpad()
        chain.retiredCoin = HonestyLaunchpad.old
        return chain
    }

    // MARK: The launch list

    /// The screens' lists come from one read: the same launches a read of each screen's own would list, every count in one
    /// aggregate, and nothing read again within its time, until an invalidation.
    func testTheScreensShareOneLaunchListing() async throws {
        install(chain)
        let plain = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        let full = await plain.launchListing(limit: 200)
        let newest = await plain.launchListing(limit: 1)
        XCTAssertTrue(full.complete)

        let cache = ChainCache()
        let shared = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: cache)
        install(chain)
        let board = await shared.launchListing(limit: 60)
        XCTAssertEqual(board.launches, full.launches, "exactly the launches a full read lists")
        XCTAssertEqual(board.factories, full.factories)
        let counts = MomentsChainStub.batches().filter { $0.contains { $0.selector == selector(LaunchpadABI.Factory.launchCount) } }
        let factories = await shared.stacks.count
        XCTAssertEqual(counts.count, 1, "every factory's count in one aggregate")
        XCTAssertEqual(counts.first?.count, factories)

        install(chain)
        let home = await shared.launchListing(limit: 30)
        let one = await shared.launchListing(limit: 1)
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "the other screens share it")
        XCTAssertEqual(home.launches, full.launches)
        XCTAssertEqual(one.launches, newest.launches, "each screen takes its own newest, per factory")
        XCTAssertEqual(one.launches.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.old])

        cache.invalidate()
        let pulled = await shared.launchListing(limit: 30)
        XCTAssertFalse(MomentsChainStub.batches().isEmpty, "a pull or a settled transaction reads again")
        XCTAssertEqual(pulled.launches, full.launches)
    }

    /// A launchpad that couldn't be read is named, as without the shared read, and the list isn't kept: Retry reads again.
    func testAListingThatCouldntBeReadInFullIsNotKept() async throws {
        var failing = chain
        failing.liveFails = true
        install(failing)
        let shared = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache())
        let failed = await shared.launchListing(limit: 60)
        XCTAssertEqual(Array(failed.unread.keys), [HonestyLaunchpad.live.factory])
        XCTAssertEqual(failed.launches.map(\.token), [HonestyLaunchpad.old], "the other launchpads still read")
        install(chain)
        let retried = await shared.launchListing(limit: 60)
        XCTAssertTrue(retried.complete, "read again, not kept")
        XCTAssertEqual(retried.launches.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha, HonestyLaunchpad.old])
    }

    /// A launchpad whose calls fail as a whole (out of gas) can't take the others' counts down: the counts are asked again
    /// one by one.
    func testOneLaunchpadCantTakeTheOthersCountsDown() async throws {
        let retired = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first)
        let chain = chain
        MomentsChainStub.install({ [chain] in chain.answer($0, $1) }, breaking: [retired.factory])
        let shared = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache())
        let listing = await shared.launchListing(limit: 60)
        XCTAssertEqual(Array(listing.unread.keys), [retired.factory])
        XCTAssertEqual(listing.launches.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha])
    }

    /// The guards against a node behind, on the read every screen of the app goes through (the shared one): a listed coin
    /// with no record, or a page shorter than the count, leaves that launchpad unread — named, none of its launches listed,
    /// for every screen's limit (read again with its own, `launchListing`), with launches kept on the device or not —
    /// never a shorter list. Without the shared reads, the same.
    func testASharedListingReadOnANodeBehindIsUnreadNeverShorter() async throws {
        var missing = chain
        missing.recorded = [HonestyLaunchpad.alpha]
        var short = chain
        short.shortPage = true
        for (name, behind) in [("a coin with no record", missing), ("a short page", short)] {
            for store in [nil, ChainStore(directory: folder())] {
                for limit in [LaunchpadService.listingLimit, 60, 30, 1] {
                    install(behind)
                    let shared = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: store, now: Self.settled)
                    let listing = await shared.launchListing(limit: limit)
                    let context = "\(name), limit \(limit), kept \(store != nil)"
                    XCTAssertEqual(listing.unread[HonestyLaunchpad.live.factory] as? ChainListUnread, ChainListUnread(.launch), context)
                    XCTAssertFalse(listing.launches.contains { $0.factory == HonestyLaunchpad.live.factory }, "none of its launches: \(context)")
                    XCTAssertEqual(listing.launches.map(\.token), [HonestyLaunchpad.old], "the other launchpads still read: \(context)")
                }
            }
            install(behind)
            let plain = await LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live).launchListing(limit: 60)
            XCTAssertEqual(plain.unread[HonestyLaunchpad.live.factory] as? ChainListUnread, ChainListUnread(.launch), "\(name), without the shared reads")
        }
    }

    /// A launchpad the shared read (its newest 200) couldn't read is read again with a screen's own limit: a screen listing
    /// fewer lists them when they can be read, exactly as a read of its limit does, never unread for want of the
    /// Portfolio's 200; and screens asking for the same limit share that read too.
    func testAScreenListingFewerIsReadWithItsOwnLimit() async throws {
        var behind = chain
        behind.recorded = [HonestyLaunchpad.beta] // Alpha, the older, has no record on this node
        install(behind)
        let plain = await LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live).launchListing(limit: 1)
        XCTAssertTrue(plain.complete)

        let shared = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache())
        install(behind)
        let board = await shared.launchListing(limit: 60)
        XCTAssertEqual(Array(board.unread.keys), [HonestyLaunchpad.live.factory], "the board's 60 include Alpha")
        install(behind)
        let newest = await shared.launchListing(limit: 1)
        XCTAssertTrue(newest.complete, "the newest one reads")
        XCTAssertEqual(newest.launches, plain.launches, "exactly what a read of its limit lists")
        XCTAssertEqual(newest.launches.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.old])
        let pages = { MomentsChainStub.calls().filter { $0.to == HonestyLaunchpad.live.factory && $0.selector == self.selector(LaunchpadABI.Factory.getLaunches) }.count }
        XCTAssertEqual(pages(), 2, "the shared read, then the screen's own")
        install(behind)
        let again = await shared.launchListing(limit: 1)
        XCTAssertEqual(again.launches, newest.launches)
        XCTAssertEqual(pages(), 1, "the shared read again (it wasn't whole, so it isn't kept); the screen's own is shared for its time")
    }

    /// A settled launch whose creator wrote more than the device keeps (`ChainSettled.maxKeptText`) isn't kept: it is read
    /// in full every time, and the others are kept.
    func testALaunchWithLongTextIsNotKept() async throws {
        let folder = folder()
        var long = chain
        long.longText = HonestyLaunchpad.beta
        install(long)
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: Self.settled)
        let read = await service.launchListing(limit: 60)
        XCTAssertTrue(read.complete)
        let kept = try XCTUnwrap(ChainStore(directory: folder).load(LaunchStaticsFile.self, from: LaunchpadService.staticsFile))
        XCTAssertEqual(Set(kept.launches.map(\.token)), [HonestyLaunchpad.alpha, HonestyLaunchpad.old])
        let relaunched = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: Self.settled)
        install(long)
        let again = await relaunched.launchListing(limit: 60)
        XCTAssertEqual(again.launches, read.launches)
        XCTAssertEqual(MomentsChainStub.calls().filter { $0.selector == selector(LaunchpadABI.Token.getTokenInfo) }.map(\.to), [HonestyLaunchpad.beta], "read in full again")
    }

    /// A fork keeps nothing of a settled launch or Moment (`ChainStore.keepsFacts`), in memory either: a fork restarted
    /// while the app runs can record something else at the same index or id, so each is read in full every time.
    func testAForkKeepsNoSettledLaunchOrMoment() async throws {
        let fork = ChainStore(directory: nil)
        XCTAssertFalse(fork.keepsFacts)
        XCTAssertTrue(ChainStore(directory: folder()).keepsFacts)
        let cache = ChainCache()
        install(chain)
        let launchpad = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: cache, store: fork, now: Self.settled)
        let first = await launchpad.launchListing(limit: 60)
        XCTAssertTrue(first.complete)
        cache.invalidate()
        install(chain)
        let again = await launchpad.launchListing(limit: 60)
        XCTAssertEqual(again.launches, first.launches)
        let asked = Set(MomentsChainStub.calls().map(\.selector))
        XCTAssertTrue(asked.contains(selector(LaunchpadABI.Factory.getLaunches)), "the page is read again")
        XCTAssertTrue(asked.contains(selector(LaunchpadABI.Token.name)), "and the text")

        installMoments()
        let moments = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses, store: fork, now: Self.momentsSettled)
        let read = try await moments.moments(limit: 60)
        installMoments()
        let reread = try await moments.moments(limit: 60)
        XCTAssertEqual(reread, read)
        let momentsAsked = Set(MomentsChainStub.calls().map(\.selector))
        XCTAssertTrue(momentsAsked.contains(selector(MomentsABI.Factory.getMoment)), "the records are read again")
        XCTAssertTrue(momentsAsked.contains(selector(MomentsABI.Coin.name)), "and the text")
        installMoments()
        let info = try await moments.info(id: 2)
        XCTAssertEqual(info, read.first { $0.id == 2 })
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.selector == selector(MomentsABI.Factory.getMoment) }, "a link reads the record too")
    }

    // MARK: Kept on the device

    /// A settled launch's token, text, supply and launch time are kept: a relaunch reads only its record and its curve's
    /// values, in one aggregate per launchpad after the counts, and lists exactly what a full read lists.
    func testASettledLaunchIsReadOnlyForWhatMoves() async throws {
        let folder = folder()
        install(chain)
        let first = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: Self.settled)
        let read = await first.launchListing(limit: 60)
        XCTAssertTrue(read.complete)

        let relaunched = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: Self.settled)
        install(chain)
        let again = await relaunched.launchListing(limit: 60)
        XCTAssertEqual(again.launches, read.launches, "read as a full read shows it")
        let asked = Set(MomentsChainStub.calls().map(\.selector))
        for fixed in [LaunchpadABI.Token.name, LaunchpadABI.Token.symbol, LaunchpadABI.Token.getTokenInfo, LaunchpadABI.Token.totalSupply,
                      LaunchpadABI.Curve.launchedAt, LaunchpadABI.Factory.getLaunches] {
            XCTAssertFalse(asked.contains(selector(fixed)), "\(fixed) is kept")
        }
        for moving in [LaunchpadABI.Factory.getLaunchedToken, LaunchpadABI.Curve.price, LaunchpadABI.Curve.realQuoteReserve, LaunchpadABI.Curve.completed,
                       LaunchpadABI.Curve.rescued, LaunchpadABI.Curve.getReserves] {
            XCTAssertTrue(asked.contains(selector(moving)), "\(moving) is read every time")
        }
        XCTAssertEqual(MomentsChainStub.batches().count, 3, "the counts, then each launchpad with launches in one read: no page, no record, no text")
    }

    /// A launch made in the last few minutes is read in full every time: none of it is kept until it settled.
    func testAYoungLaunchIsReadInFull() async throws {
        let folder = folder()
        let young: @Sendable () -> Date = { Date(timeIntervalSince1970: TimeInterval(Self.launchedAt + 60)) }
        install(chain)
        let first = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: young)
        _ = await first.launchListing(limit: 60)
        XCTAssertNil(ChainStore(directory: folder).load(LaunchStaticsFile.self, from: LaunchpadService.staticsFile))
        let relaunched = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: young)
        install(chain)
        _ = await relaunched.launchListing(limit: 60)
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.selector == selector(LaunchpadABI.Token.name) })
    }

    /// Text that couldn't be read (shown with stand-ins) is never kept: that launch's text is read again next time, and the
    /// others' isn't.
    func testTextThatCouldntBeReadIsNotKept() async throws {
        let folder = folder()
        var unreadable = chain
        unreadable.textFails = true
        install(unreadable)
        let first = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: Self.settled)
        let read = await first.launchListing(limit: 60)
        XCTAssertEqual(read.launches.first { $0.token == HonestyLaunchpad.beta }?.name, ChainText.unreadable)
        let relaunched = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: ChainCache(), store: ChainStore(directory: folder), now: Self.settled)
        install(chain)
        let again = await relaunched.launchListing(limit: 60)
        XCTAssertEqual(MomentsChainStub.calls().filter { $0.selector == selector(LaunchpadABI.Token.name) }.map(\.to), [HonestyLaunchpad.beta])
        XCTAssertEqual(again.launches.first { $0.token == HonestyLaunchpad.beta }?.name, "Beta", "read whole this time")
        XCTAssertEqual(again.launches.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha, HonestyLaunchpad.old])
    }

    /// A kept launch whose record no longer names it (a file that isn't this chain's) is an error with Retry, never a
    /// launch shown from what was kept: every launch kept of that launchpad is forgotten, and the next read is a full one.
    func testAKeptLaunchTheChainNoLongerRecordsIsForgotten() async throws {
        let folder = folder()
        install(chain)
        let store = ChainStore(directory: folder)
        let cache = ChainCache()
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: cache, store: store, now: Self.settled)
        _ = await service.launchListing(limit: 60)
        var kept = try XCTUnwrap(store.load(LaunchStaticsFile.self, from: LaunchpadService.staticsFile))
        XCTAssertEqual(Set(kept.launches.map(\.token)), [HonestyLaunchpad.alpha, HonestyLaunchpad.beta, HonestyLaunchpad.old])

        var gone = chain
        gone.recorded = [HonestyLaunchpad.beta]
        install(gone)
        cache.invalidate()
        let failed = await service.launchListing(limit: 60)
        XCTAssertEqual(Array(failed.unread.keys), [HonestyLaunchpad.live.factory])
        kept = try XCTUnwrap(store.load(LaunchStaticsFile.self, from: LaunchpadService.staticsFile))
        XCTAssertEqual(kept.launches.map(\.token), [HonestyLaunchpad.old], "the live launchpad's are forgotten")

        install(chain)
        let read = await service.launchListing(limit: 60)
        XCTAssertTrue(read.complete)
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.selector == selector(LaunchpadABI.Factory.getLaunches) }, "read in full")
    }

    /// An erase of this device's data removes the file and what memory held: the next read is a full one.
    func testAnEraseForgetsWhatWasKept() async throws {
        let folder = folder()
        install(chain)
        let store = ChainStore(directory: folder)
        let cache = ChainCache()
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live, cache: cache, store: store, now: Self.settled)
        _ = await service.launchListing(limit: 60)
        store.erase()
        cache.invalidate()
        XCTAssertNil(store.load(LaunchStaticsFile.self, from: LaunchpadService.staticsFile))
        install(chain)
        _ = await service.launchListing(limit: 60)
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.selector == selector(LaunchpadABI.Token.name) }, "the text is read again")
    }

    // MARK: Moments

    private static let stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                                nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Plain", "Fresh", "Third"])
    /// A day after `FakeMomentsStack`'s Moments were published.
    private static let momentsSettled: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_570_817 + 86_400) }

    private func installMoments() {
        let stack = Self.stack
        MomentsChainStub.install { stack.answer($0, $1) }
    }

    func testTheScreensShareOneMomentsList() async throws {
        installMoments()
        let plain = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses)
        let full = try await plain.moments(limit: 200)
        let newest = try await plain.moments(limit: 2)
        let cache = ChainCache()
        let shared = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses, cache: cache)
        let board = try await shared.moments(limit: 60)
        XCTAssertEqual(board, full)
        installMoments()
        let home = try await shared.moments(limit: 2)
        let holdings = try await shared.moments(limit: 200)
        XCTAssertEqual(home, newest, "each screen takes its own newest")
        XCTAssertEqual(holdings, full)
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.selector == selector(MomentsABI.Factory.momentCount) }, "the list is shared, not read again")
        cache.invalidate()
        _ = try await shared.moments(limit: 60)
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.selector == selector(MomentsABI.Factory.momentCount) })
    }

    /// A settled Moment's record, name, symbol and provenance are kept: a relaunch reads only its state, and every reader
    /// (the list, a link, several ids) shows it as a full read does.
    func testASettledMomentIsReadOnlyForItsState() async throws {
        let folder = folder()
        installMoments()
        let first = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses, store: ChainStore(directory: folder), now: Self.momentsSettled)
        let read = try await first.moments(limit: 60)
        let info = try await first.info(id: 2)
        let infos = try await first.infos(ids: [1, 3])

        let relaunched = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses, store: ChainStore(directory: folder), now: Self.momentsSettled)
        installMoments()
        let again = try await relaunched.moments(limit: 60)
        XCTAssertEqual(again, read)
        let asked = Set(MomentsChainStub.calls().map(\.selector))
        for fixed in [MomentsABI.Factory.getMoment, MomentsABI.Coin.name, MomentsABI.Coin.symbol, MomentsABI.NFT.provenance] {
            XCTAssertFalse(asked.contains(selector(fixed)), "\(fixed) is kept")
        }
        for moving in [MomentsABI.Factory.momentCount, MomentsABI.Collect.ledger, MomentsABI.NFT.totalMinted, MomentsABI.NFT.closed,
                       MomentsABI.Vesting.totalEntitlement, MomentsABI.Graduation.isGraduated] {
            XCTAssertTrue(asked.contains(selector(moving)), "\(moving) is read every time")
        }
        let infoAgain = try await relaunched.info(id: 2)
        let infosAgain = try await relaunched.infos(ids: [1, 3])
        XCTAssertEqual(infoAgain, info)
        XCTAssertEqual(infosAgain, infos)
    }

    /// A kept Moment whose state can't be read fails the read, as a full read does — the list, a link, several ids —
    /// never a Moment shown from what was kept: its state is the protocol's, read every time.
    func testAKeptMomentWhoseStateCantBeReadIsAnError() async throws {
        let folder = folder()
        installMoments()
        let first = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses, store: ChainStore(directory: folder), now: Self.momentsSettled)
        _ = try await first.moments(limit: 60)
        let stack = Self.stack
        MomentsChainStub.install({ stack.answer($0, $1) }, breaking: [stack.addresses.collect])
        let relaunched = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses, store: ChainStore(directory: folder), now: Self.momentsSettled)
        for (what, read) in [("the list", { _ = try await relaunched.moments(limit: 60) }),
                             ("a link", { _ = try await relaunched.info(id: 2) }),
                             ("several ids", { _ = try await relaunched.infos(ids: [1, 3]) })] as [(String, () async throws -> Void)] {
            do {
                try await read()
                XCTFail("\(what) answered from what was kept")
            } catch {
                XCTAssertEqual(error as? ChainListUnread, ChainListUnread(.moment), what)
            }
        }
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.selector == selector(MomentsABI.Factory.getMoment) }, "the records are kept: only the state failed")
    }

    /// A Moment published in the last few minutes, and one whose text couldn't be read, are read in full every time.
    func testAYoungMomentOrUnreadTextIsNotKept() async throws {
        let folder = folder()
        let stack = Self.stack
        MomentsChainStub.install { to, data in
            if to == stack.coin(2) { return Data() }
            return stack.answer(to, data)
        }
        let first = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses, store: ChainStore(directory: folder), now: Self.momentsSettled)
        let read = try await first.moments(limit: 60)
        XCTAssertEqual(read.first { $0.id == 2 }?.name, ChainText.unreadable)
        let kept = try XCTUnwrap(ChainStore(directory: folder).load(MomentStaticsFile.self, from: "moments-\(stack.addresses.factory.hex.lowercased()).json"))
        XCTAssertEqual(Set(kept.moments.compactMap(\.momentId)), [1, 3], "Moment 2's name couldn't be read: not kept")

        let young = FileManager.default.temporaryDirectory.appending(path: "shared-reads-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: young) }
        installMoments()
        let fresh = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses, store: ChainStore(directory: young),
                                   now: { Date(timeIntervalSince1970: 1_790_570_817 + 60) })
        _ = try await fresh.moments(limit: 60)
        XCTAssertNil(ChainStore(directory: young).load(MomentStaticsFile.self, from: "moments-\(stack.addresses.factory.hex.lowercased()).json"))
    }

    /// A retired cohort's Moments are frozen: read once, kept on the device, and the Portfolio, My Holdings and Past
    /// Cohorts share its list.
    func testARetiredCohortIsReadOnceAndShared() async throws {
        let folder = folder()
        let c2 = try XCTUnwrap(MomentsAddresses.retiredMainnet.first { $0.factory == MomentLink.Cohort.c2.factory })
        let two = FakeMomentsStack(addresses: c2, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "", names: ["Two A", "Two B"])
        MomentsChainStub.install { two.answer($0, $1) }
        let plain = RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: c2)
        let full = try await plain.list()
        let cache = ChainCache()
        let cohort = RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: c2, cache: cache, store: ChainStore(directory: folder))
        let read = try await cohort.list()
        XCTAssertEqual(read.moments, full.moments)
        XCTAssertEqual(read.cut, full.cut)
        MomentsChainStub.install { two.answer($0, $1) }
        let shared = await RetiredMoments.moments(of: [cohort])
        XCTAssertEqual(shared.moments, full.moments)
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "shared within its time")

        let relaunched = RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: c2, cache: ChainCache(), store: ChainStore(directory: folder))
        let again = try await relaunched.list()
        XCTAssertEqual(again.moments, full.moments)
        let asked = Set(MomentsChainStub.calls().map(\.selector))
        XCTAssertFalse(asked.contains(selector(MomentsABI.Factory.getMoment)), "the records are read once")
        XCTAssertFalse(asked.contains(selector(MomentsABI.Coin.name)))
        XCTAssertTrue(asked.contains(selector(MomentsABI.Collect.ledger)), "the state is read every time")
    }
}
