import BigInt
import XCTest
@testable import DyorKit

/// A retired cohort is read by its pinned Moments (`MomentLink.Cohort.finalMomentCount`, the coins in
/// `MomentsAddresses.retiredMainnetCoins`): cohort 3's publishing isn't paused on chain, and however many Moments are
/// published there after the pin, none of them can push a pinned Moment off the list and hide what its holders are owed.
/// After the pin it reads as many Moments as build 16 read of the whole cohort (200), and when more were published it
/// says so: a holder's own Moments among those left out are found from their history, and the positions say they may
/// be incomplete.
final class RetiredMomentsPinTests: XCTestCase {
    private static let cohort3 = MomentsAddresses.retiredMainnet.first { $0.factory == MomentLink.Cohort.c3.factory }!
    private static let holder = Address(literal: "0x00000000000000000000000000000000000c0113")

    /// "Nature" (#1, pinned) and `later` Moments published after it; the holder holds an edition of Moment `held`, and
    /// `collected` lists the Moments whose `Collected` log names the holder. History is read from block 0 (the stub's
    /// chain is 1,000 blocks long), through the stub.
    private func install(later: Int, held: Int = 1, collected: [Int] = []) -> (stack: FakeMomentsStack, cohort: RetiredMoments) {
        var addresses = Self.cohort3
        addresses.deployBlock = 0
        let stack = FakeMomentsStack(addresses: addresses, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "",
                                     names: ["Nature"] + (0..<later).map { "Later \($0)" })
        let logs = collected.map { id in
            Log(address: addresses.collect, topics: [MomentsABI.Events.collectedTopic, BigUInt(id).word, Self.holder.data.leftPadded(to: 32)],
                data: try! ABI.encode([.uint(1_000_000), .uint(1), .uint(1), .uint(0), .uint(750_000), .uint(200_000), .uint(50_000), .uint(0)],
                                      "uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256"),
                blockNumber: 500, transactionHash: Data(repeating: UInt8(id), count: 32), logIndex: 0)
        }
        MomentsChainStub.install({ to, data in
            let selector = data.prefix(4)
            func is_(_ s: String) -> Bool { selector == StubSelector.of(s) }
            let args = ABIWords(data.dropFirst(4))
            if to == stack.addresses.vesting, is_(MomentsABI.Vesting.entitlement) || is_(MomentsABI.Vesting.claimed) || is_(MomentsABI.Vesting.creatorClaimed) {
                return try! ABI.encode([.uint(0)], "uint256")
            }
            if to == stack.addresses.vesting, is_(MomentsABI.Vesting.claimable) { return try! ABI.encode([.uint(0), .uint(0)], "uint256,uint256") }
            if is_(MomentsABI.NFT.balanceOf) || is_(MomentsABI.Coin.balanceOf) {
                return try! ABI.encode([.uint(to == stack.nft(held) && args.address(0) == Self.holder ? 1 : 0)], "uint256")
            }
            if to == stack.addresses.hook { return try! ABI.encode([.uint(0)], "uint256") }
            return stack.answer(to, data)
        }, logs: logs)
        let rpc = MomentsChainStub.rpc()
        return (stack, RetiredMoments(rpc: rpc, addresses: addresses, logsRPC: rpc))
    }

    func testAPinnedMomentIsReadHoweverManyArePublishedAfterIt() async throws {
        let (stack, cohort) = install(later: 250)
        let moments = try await cohort.moments()
        XCTAssertTrue(moments.contains { $0.id == 1 && $0.name == "Nature" }, "the pinned Moment is read")
        let read = try await cohort.positions(account: Self.holder)
        XCTAssertEqual(read.positions.map(\.key), [MomentKey(factory: stack.addresses.factory, id: 1)], "its holder's edition is listed")
    }

    func testMomentsAfterThePinAreStillReadWhenFew() async throws {
        let (_, cohort) = install(later: 2)
        let list = try await cohort.list()
        XCTAssertEqual(list.moments.map(\.id), [3, 2, 1], "newest first, the pinned Moment included")
        XCTAssertFalse(list.cut)
    }

    /// 150 Moments after the pin are all read (the 100 H1 read at first left out 2…51), nothing is cut, and the
    /// positions of a holder of #2 are complete without any history scan.
    func testUpTo200MomentsAfterThePinAreAllRead() async throws {
        let (stack, cohort) = install(later: 150, held: 2)
        let list = try await cohort.list()
        XCTAssertEqual(list.moments.map(\.id), (1...151).reversed().map { BigUInt($0) }, "every Moment, newest first")
        XCTAssertFalse(list.cut)
        let read = try await cohort.positions(account: Self.holder)
        XCTAssertEqual(read.positions.map(\.key), [MomentKey(factory: stack.addresses.factory, id: 2)])
        XCTAssertTrue(read.complete)
        XCTAssertEqual(MomentsChainStub.logQueries(), [], "a list that wasn't cut scans no history")
    }

    /// 250 Moments after the pin: the newest 200 and the pinned one are read, #2…#51 are not, and the list says so. A
    /// holder who collected #2 still finds it (read by id from their history), and the positions say they may be
    /// incomplete: a Moment received by transfer is in no history.
    func testACutListFindsTheHoldersOwnMomentsAndSaysItMayBeIncomplete() async throws {
        let (stack, cohort) = install(later: 250, held: 2, collected: [2])
        let list = try await cohort.list()
        XCTAssertTrue(list.cut)
        XCTAssertEqual(list.moments.map(\.id), (52...251).reversed().map { BigUInt($0) } + [1])
        let read = try await cohort.positions(account: Self.holder)
        XCTAssertEqual(read.positions.map(\.key), [MomentKey(factory: stack.addresses.factory, id: 2)], "the holder's own Moment, read by id")
        XCTAssertEqual(read.positions.first?.info.name, "Later 0")
        XCTAssertFalse(read.complete)
        XCTAssertFalse(MomentsChainStub.logQueries().isEmpty, "the history was scanned")
    }

    /// A cut list completed from the wallet's Moments history the app's history store already holds (every cohort, read in
    /// full) scans nothing of its own: the holder's #2 is found by id from it, and the positions still say they may be
    /// incomplete (a Moment received by transfer is in no history).
    func testACutListUsesTheHistoryStoresMomentsHistoryWithNoScan() async throws {
        let (stack, cohort) = install(later: 250, held: 2)
        let collected = Log(address: stack.addresses.collect, topics: [MomentsABI.Events.collectedTopic, BigUInt(2).word, Self.holder.data.leftPadded(to: 32)],
                            data: try ABI.encode([.uint(1_000_000), .uint(1), .uint(1), .uint(0), .uint(750_000), .uint(200_000), .uint(50_000), .uint(0)],
                                                 "uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256"),
                            blockNumber: 500, transactionHash: Data(repeating: 2, count: 32), logIndex: 0)
        let known = MomentsService.history(collected: [collected], claimed: [], withdrawn: [], feesWithdrawn: [], published: [], anchor: MomentsChainStub.head,
                                           secondsPerBlock: 0.3, factory: stack.addresses.factory)
        let read = try await cohort.positions(account: Self.holder, history: known)
        XCTAssertEqual(read.positions.map(\.key), [MomentKey(factory: stack.addresses.factory, id: 2)], "the holder's own Moment, read by id")
        XCTAssertFalse(read.complete)
        XCTAssertEqual(MomentsChainStub.logQueries(), [], "no scan of its own")
    }

    /// The cohort's own history scan reads newest first and says whether it read the whole window.
    func testTheCohortsOwnHistorySaysItWasReadWhole() async {
        let (_, cohort) = install(later: 0, collected: [1])
        let (history, complete) = await cohort.history(account: Self.holder)
        XCTAssertEqual(history.collects.map(\.momentId), [1])
        XCTAssertTrue(complete)
    }

    /// A holder of a left-out Moment it only received by transfer isn't in any history: it can't be found, and the
    /// positions say they may be incomplete rather than that there is nothing.
    func testACutListWithoutHistorySaysItMayBeIncomplete() async throws {
        let (_, cohort) = install(later: 250, held: 2)
        let read = try await cohort.positions(account: Self.holder)
        XCTAssertEqual(read.positions, [])
        XCTAssertFalse(read.complete)
    }

    /// Moments a caller already read (the wallet's coins, by id) are taken as they are: no history scan.
    func testACallersOwnMomentsScanNoHistory() async throws {
        let (stack, cohort) = install(later: 250, held: 2, collected: [2])
        let own = try await cohort.infos(ids: [2])
        let read = try await cohort.positions(account: Self.holder, moments: own)
        XCTAssertEqual(read.positions.map(\.key), [MomentKey(factory: stack.addresses.factory, id: 2)])
        XCTAssertTrue(read.complete)
        XCTAssertEqual(MomentsChainStub.logQueries(), [])
    }

    /// Whatever the counts, the ids read are a superset of build 16's (the newest 200 of the cohort), and the list is cut
    /// exactly when more than 200 Moments were published after the pin.
    func testTheIdsReadAlwaysIncludeBuild16s() {
        for pinned in 0...4 {
            for total in pinned...(pinned + 420) {
                let read = MomentsService.retiredIds(total: total, pinned: pinned, later: RetiredMoments.laterLimit)
                let ids = Set(read.ids)
                XCTAssertEqual(ids.count, read.ids.count, "no id twice")
                let build16 = total >= 1 ? Set(max(1, total - 199)...total) : []
                XCTAssertTrue(build16.isSubset(of: ids), "pin \(pinned), total \(total)")
                XCTAssertTrue(Set(stride(from: pinned, through: 1, by: -1)).isSubset(of: ids), "every pinned id")
                XCTAssertEqual(read.cut, total - pinned > RetiredMoments.laterLimit, "pin \(pinned), total \(total)")
                XCTAssertEqual(read.ids, read.ids.sorted(by: >), "newest first")
            }
        }
        XCTAssertEqual(RetiredMoments.laterLimit, 200)
    }
}
