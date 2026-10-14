import BigInt
import XCTest
@testable import DyorKit

/// The Moments screens made fast without showing less (speed work, build 23): a board of settled Moments is one read; a
/// Moment's page reads each part once, side by side; its edition holders are never a failed read shown as none, nor a
/// count cut at 400; its coin's holders are counted once and then only what is new; the proceeds take what the Moments
/// hold from the lists already read; the terms are shared; and a countdown is drawn again only when its text changes.
final class MomentsSpeedTests: XCTestCase {
    private static let stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                                nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Plain", "Fresh", "Third"])
    /// A day after `FakeMomentsStack`'s Moments were published: each one settled (`ChainSettled`).
    private static let settled: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_570_817 + 86_400) }
    /// The creator of every `FakeMomentsStack` Moment.
    private static let creator = Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")

    private func selector(_ signature: String) -> String { ABI.selector(signature).hexString }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moments-speed-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func install(_ stack: FakeMomentsStack = MomentsSpeedTests.stack) {
        MomentsChainStub.install { stack.answer($0, $1) }
    }

    /// A service whose device kept every settled Moment of `stack` (`MomentStatics`): a relaunch over `folder`.
    private func relaunched(over folder: URL, _ stack: FakeMomentsStack = MomentsSpeedTests.stack) async throws -> (MomentsService, [MomentInfo]) {
        install(stack)
        let first = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses, store: ChainStore(directory: folder), now: Self.settled)
        let read = try await first.moments(limit: 60)
        return (MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses, store: ChainStore(directory: folder), now: Self.settled), read)
    }

    // MARK: The board

    /// The count and the state of every Moment the device keeps go in one aggregate: a board of settled Moments is one
    /// read, not three in a row, the first time after a relaunch and every poll after it, and shows what a full read does.
    func testABoardOfSettledMomentsIsOneRead() async throws {
        let (service, read) = try await relaunched(over: folder())
        for _ in 0 ..< 2 {
            install()
            let again = try await service.moments(limit: 60)
            XCTAssertEqual(again, read)
            let batches = MomentsChainStub.batches()
            XCTAssertEqual(batches.count, 1, "one aggregate")
            XCTAssertEqual(batches.first?.first?.selector, selector(MomentsABI.Factory.momentCount))
            XCTAssertEqual(batches.first?.count, 1 + 3 * MomentsService.stateCallCount, "the count and each Moment's state")
        }
    }

    /// A Moment published since the last count is read in full (its record and text), and the kept Moments' state, read
    /// with the count, isn't read again.
    func testAMomentPastTheLastCountIsReadInFull() async throws {
        let (service, _) = try await relaunched(over: folder())
        var grown = Self.stack
        grown.names = ["Plain", "Fresh", "Third", "Fourth"]
        install(grown)
        let list = try await service.moments(limit: 60)
        let ledgers = MomentsChainStub.calls().filter { $0.selector == selector(MomentsABI.Collect.ledger) }.count
        install(grown)
        let full = try await MomentsService(rpc: MomentsChainStub.rpc(), addresses: grown.addresses).moments(limit: 60)
        XCTAssertEqual(list, full)
        XCTAssertEqual(list.map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(ledgers, 4, "three with the count, the new one with its record")
    }

    /// A count below the last one (a node a block behind) is the count: the Moments past it are never shown from the
    /// state read with it.
    func testACountBelowTheLastIsTheCount() async throws {
        let (service, _) = try await relaunched(over: folder())
        var behind = Self.stack
        behind.momentCount = 2
        install(behind)
        let list = try await service.moments(limit: 60)
        XCTAssertEqual(list.map(\.id), [2, 1])
        install(behind)
        let full = try await MomentsService(rpc: MomentsChainStub.rpc(), addresses: behind.addresses).moments(limit: 60)
        XCTAssertEqual(list, full)
        let past = try await service.info(id: 3)
        XCTAssertNil(past, "a kept Moment past the count is no Moment")
    }

    /// An aggregate the node refuses as a whole (its answer too large) is read again as the count alone, and the Moments'
    /// state as before: the list is the same.
    func testARefusedAggregateFallsBackToTheCountAlone() async throws {
        let folder = folder()
        let (service, read) = try await relaunched(over: folder)
        let stack = Self.stack
        // The answer the folded aggregate would get, and a cap one byte under it: every smaller read still answers.
        var calls = [MomentsABI.call(stack.addresses.factory, MomentsABI.Factory.momentCount, returns: "uint256")]
        for id in [3, 2, 1] {
            calls += [
                MomentsABI.call(stack.addresses.collect, MomentsABI.Collect.ledger, [.uint(BigUInt(id))], returns: MomentsABI.ledgerTuple),
                MomentsABI.call(stack.nft(id), MomentsABI.NFT.totalMinted, returns: "uint256"),
                MomentsABI.call(stack.nft(id), MomentsABI.NFT.closed, returns: "bool"),
                MomentsABI.call(stack.addresses.vesting, MomentsABI.Vesting.totalEntitlement, [.uint(BigUInt(id))], returns: "uint256"),
                MomentsABI.call(stack.addresses.graduation, MomentsABI.Graduation.isGraduated, [.uint(BigUInt(id))], returns: "bool"),
            ]
        }
        let answers: [ABIValue] = calls.map { call in
            let returned = stack.answer(call.to, call.data)
            return .tuple([.bool(returned != nil), .bytes(returned ?? Data())])
        }
        let size = try ABI.encode([.array(answers)], "(bool,bytes)[]").count
        MomentsChainStub.install({ stack.answer($0, $1) }, responseCap: size - 1)
        let again = try await service.moments(limit: 60)
        XCTAssertEqual(again, read)
        XCTAssertEqual(MomentsChainStub.batches().count, 3, "refused, then the count, then the state")
    }

    /// A kept Moment's page reads it in one aggregate with the count: no record, no text.
    func testAKeptMomentIsOneRead() async throws {
        let (service, read) = try await relaunched(over: folder())
        install()
        let info = try await service.info(id: 2)
        XCTAssertEqual(info, read.first { $0.id == 2 })
        XCTAssertEqual(MomentsChainStub.batches().count, 1)
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.selector == selector(MomentsABI.Factory.getMoment) })
    }

    /// The terms are read once a minute for every reader (`ChainCache.TTL.terms`), and again after a pull or a settled
    /// transaction (`invalidate`); a failed read is never kept.
    func testTheTermsAreShared() async throws {
        install()
        let cache = ChainCache()
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses, cache: cache)
        let first = try await service.policy()
        install()
        let second = try await service.policy()
        XCTAssertEqual(first, second)
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "shared within its time")
        cache.invalidate()
        _ = try await service.policy()
        XCTAssertFalse(MomentsChainStub.batches().isEmpty, "read again after an invalidation")
        XCTAssertEqual(ChainCache.TTL.terms, 60)

        let stack = Self.stack
        MomentsChainStub.install({ stack.answer($0, $1) }, breaking: [stack.addresses.factory])
        cache.invalidate()
        do {
            _ = try await service.policy()
            XCTFail("the terms answered")
        } catch {}
        install()
        let recovered = try await service.policy()
        XCTAssertEqual(recovered, first, "a failure isn't kept: the next read goes to the chain")
    }

    // MARK: A Moment's page

    /// The page's supply is read on its own, beside the Moment: one aggregate of the three extras, from the Moment the
    /// page was given; `moment(id:)` no longer reads the count and the record twice; another cohort's Moment is refused.
    func testTheSupplyIsOneReadBesideTheMoment() async throws {
        install()
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses)
        let whole = try await service.moment(id: 1)
        let detail = try XCTUnwrap(whole)
        XCTAssertEqual(MomentsChainStub.calls().filter { $0.selector == selector(MomentsABI.Factory.momentCount) }.count, 1)
        XCTAssertEqual(MomentsChainStub.calls().filter { $0.selector == selector(MomentsABI.Factory.getMoment) }.count, 1)
        install()
        let extras = try await service.detail(for: detail.info)
        XCTAssertEqual(extras, detail)
        XCTAssertEqual(MomentsChainStub.batches().map { Set($0.map(\.selector)) },
                       [[selector(MomentsABI.Collect.supplyCheck), selector(MomentsABI.Coin.totalSupply), selector(MomentsABI.NFT.externalBaseURI)]])

        let c3 = MomentsAddresses.retiredMainnet[0]
        let three = FakeMomentsStack(addresses: c3, policy: V2Fixture.policy(termsHash: nil), factoryBase: "https://dyorhq.fun/moments/", nftBase: "")
        install(three)
        let otherRead = try await RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: c3).info(id: 1)
        let other = try XCTUnwrap(otherRead)
        do {
            _ = try await service.detail(for: other)
            XCTFail("another cohort's Moment was read under this one's id")
        } catch {
            XCTAssertEqual(error as? MomentsService.MomentsError, .unknownMoment)
        }
    }

    /// The account's stake is one aggregate — its edition ids included — and its MON balance beside it. The ids are used
    /// only when it holds an edition: one that does and whose ids can't be read throws; one that doesn't gets none.
    func testTheStakeIsOneRead() async throws {
        let stack = Self.stack
        let account = Address(literal: "0x00000000000000000000000000000000000a11ce")
        func answer(editions: Int, ids: [BigUInt]?) -> MomentsChainStub.Answer {
            { to, data in
                let sel = data.prefix(4)
                func is_(_ signature: String) -> Bool { sel == StubSelector.of(signature) }
                if to == stack.nft(1), is_(MomentsABI.NFT.tokensOfOwner) { return ids.map { try! ABI.encode([.array($0.map { .uint($0) })], "uint256[]") } }
                if to == stack.nft(1), is_(MomentsABI.NFT.balanceOf) { return try! ABI.encode([.uint(BigUInt(editions))], "uint256") }
                if is_("balanceOf(address)") || is_("allowance(address,address)") { return try! ABI.encode([.uint(5_000_000)], "uint256") }
                if to == stack.addresses.vesting, is_(MomentsABI.Vesting.claimable) { return try! ABI.encode([.uint(0), .uint(0)], "uint256,uint256") }
                if to == stack.addresses.vesting, is_(MomentsABI.Vesting.entitlement) || is_(MomentsABI.Vesting.claimed) { return try! ABI.encode([.uint(0)], "uint256") }
                if to == stack.addresses.hook, is_(MomentsABI.Hook.creatorAccrued) || is_(MomentsABI.Hook.platformAccrued) { return try! ABI.encode([.uint(0)], "uint256") }
                return stack.answer(to, data)
            }
        }
        MomentsChainStub.install(answer(editions: 2, ids: [7, 9]), native: [account: 10])
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let infoRead = try await service.info(id: 1)
        let info = try XCTUnwrap(infoRead)
        MomentsChainStub.install(answer(editions: 2, ids: [7, 9]), native: [account: 10])
        let view = try await service.accountView(info, account: account)
        XCTAssertEqual(view.nftIds, [7, 9])
        XCTAssertEqual(view.nftBalance, 2)
        XCTAssertEqual(view.monBalance, 10)
        XCTAssertEqual(view.usdcBalance, 5_000_000)
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "one aggregate")

        MomentsChainStub.install(answer(editions: 2, ids: nil), native: [account: 10])
        do {
            _ = try await service.accountView(info, account: account)
            XCTFail("an edition held whose ids couldn't be read")
        } catch {}
        MomentsChainStub.install(answer(editions: 0, ids: nil), native: [account: 10])
        let none = try await service.accountView(info, account: account)
        XCTAssertEqual(none.nftIds, [])
    }

    /// The edition holders: every edition's owner, 400 to a read, a wallet counted once, the largest named (of equal counts
    /// the lowest address); one owner that can't be read fails the read, never "0".
    func testTheEditionHoldersCountEveryEdition() async throws {
        let stack = Self.stack
        let wallets = [Address(literal: "0x00000000000000000000000000000000000000b2"), Address(literal: "0x00000000000000000000000000000000000000a1"),
                       Address(literal: "0x00000000000000000000000000000000000000c3")]
        func answer(failing: Int?) -> MomentsChainStub.Answer {
            { to, data in
                guard to == stack.nft(1), data.prefix(4) == StubSelector.of(MomentsABI.NFT.ownerOf) else { return stack.answer(to, data) }
                let id = Int(BigUInt(data.dropFirst(4).prefix(32)))
                if id == failing { return nil }
                // Editions 1…300 to the first wallet, the rest shared by the other two.
                let owner = id <= 300 ? wallets[0] : wallets[1 + id % 2]
                return try! ABI.encode([.address(owner)], "address")
            }
        }
        MomentsChainStub.install(answer(failing: nil))
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let holders = try await service.editionHolders(nft: stack.nft(1), editions: 450)
        XCTAssertEqual(holders.holders, 3)
        XCTAssertEqual(holders.topHolder, wallets[0])
        XCTAssertEqual(holders.topCount, 300)
        XCTAssertTrue(holders.complete)
        XCTAssertEqual(MomentsChainStub.batches().map(\.count).sorted(), [50, 400], "400 to a read")
        XCTAssertGreaterThan(MomentsService.maxEditionsRead, 400, "no longer cut at the 400th")

        MomentsChainStub.install(answer(failing: 420))
        do {
            _ = try await service.editionHolders(nft: stack.nft(1), editions: 450)
            XCTFail("a failed read was counted")
        } catch {
            XCTAssertEqual(error as? ChainListUnread, ChainListUnread(.thisMoment))
        }
        let empty = try await service.editionHolders(nft: stack.nft(1), editions: 0)
        XCTAssertEqual(empty, MomentEditionHolders(owners: [], complete: true))

        // Past the most it reads, its first editions are counted and the count says it is a part, never the whole.
        MomentsChainStub.install(answer(failing: nil))
        let capped = try await service.editionHolders(nft: stack.nft(1), editions: MomentsService.maxEditionsRead + 1)
        XCTAssertFalse(capped.complete)
        XCTAssertEqual(capped.holders, 3)
        let asked = MomentsChainStub.calls().filter { $0.to == stack.nft(1) && $0.selector == selector(MomentsABI.NFT.ownerOf) }
        XCTAssertEqual(asked.count, MomentsService.maxEditionsRead, "exactly the first \(MomentsService.maxEditionsRead)")

        let tie = MomentEditionHolders(owners: [wallets[2], wallets[0], wallets[0], wallets[2], wallets[1]], complete: false)
        XCTAssertEqual(tie.topHolder, wallets[0], "of equal counts, the lowest address")
        XCTAssertEqual(tie.topCount, 2)
        XCTAssertFalse(tie.complete)
    }

    // MARK: A coin's holders, counted once

    private static let coin = Address(literal: "0x5555555555555555555555555555555555555555")
    private static let wallets = (0 ..< 6).map { Address(data: Data(repeating: 0, count: 19) + Data([UInt8(0xa0 + $0)]))! }

    private static func transfer(_ from: Address, _ to: Address, _ coins: Int, at block: UInt64, index: Int = 0) -> Log {
        Log(address: coin, topics: [MomentsABI.Events.transferTopic, from.data.leftPadded(to: 32), to.data.leftPadded(to: 32)],
            data: (BigUInt(coins) * BigUInt(10).power(18)).serialize().leftPadded(to: 32), blockNumber: block,
            transactionHash: Data([UInt8(block & 0xff), UInt8(block >> 8), UInt8(index)]).leftPadded(to: 32), logIndex: index)
    }

    /// Mints, pool seeding and trades spread over blocks 10…990.
    private static let history: [Log] = {
        let pool = MomentsAddresses.monadMainnet.poolManager
        var logs = [transfer(.zero, pool, 600, at: 10)]
        for (i, wallet) in wallets.enumerated() { logs.append(transfer(.zero, wallet, 50 + i * 10, at: UInt64(20 + i * 50))) }
        for step in 0 ..< 12 {
            let from = wallets[step % wallets.count], to = wallets[(step * 5 + 1) % wallets.count]
            logs.append(transfer(from, to, 3 + step, at: UInt64(400 + step * 49), index: 1))
        }
        logs.append(transfer(pool, wallets[2], 25, at: 950, index: 2))
        logs.append(transfer(wallets[0], pool, 7, at: 990, index: 3))
        return logs
    }()

    private func read(_ from: UInt64, _ to: UInt64, readFrom: UInt64? = nil, complete: Bool = true) -> NewestLogs {
        let floor = readFrom ?? from
        return NewestLogs(logs: Self.history.filter { $0.blockNumber >= floor && $0.blockNumber <= to }, readFrom: floor, complete: complete)
    }

    private func whole(through head: UInt64) -> MomentHolderStats {
        MomentsService.holderStats(transfers: Self.history.filter { $0.blockNumber <= head }, addresses: .monadMainnet, scannedTo: head)
    }

    /// Counted in two openings — the first reading the whole window, the second only the blocks since — the statistics are
    /// those of one read of everything; the newest blocks are shown and never kept.
    func testACountReadAgainReadsOnlyWhatIsNew() throws {
        let asOf = Date(timeIntervalSince1970: 1_000)
        let first = try XCTUnwrap(MomentHolderTally.round(saved: nil, coin: Self.coin, floor: 0, head: 600, start: 0, settled: 500, settledAt: asOf, newer: read(0, 600)))
        XCTAssertEqual(first.stats(addresses: .monadMainnet), whole(through: 600))
        let kept = try XCTUnwrap(first.kept)
        XCTAssertEqual([kept.from, kept.to], [0, 500], "the newest blocks aren't kept")
        XCTAssertEqual(kept.balances, MomentsService.netTransfers(Self.history.filter { $0.blockNumber <= 500 }))
        XCTAssertTrue(kept.complete)

        let second = try XCTUnwrap(MomentHolderTally.round(saved: kept, coin: Self.coin, floor: 0, head: 1_000, start: 501, settled: 900, settledAt: asOf, newer: read(501, 1_000)))
        XCTAssertEqual(second.stats(addresses: .monadMainnet), whole(through: 1_000))
        XCTAssertEqual(second.kept?.to, 900)
        XCTAssertTrue(second.complete)

        // Nothing new settled since (the head moved less than the blocks never kept): what was kept stays as it was.
        let third = try XCTUnwrap(MomentHolderTally.round(saved: second.kept, coin: Self.coin, floor: 0, head: 1_000, start: 901, settled: 900, settledAt: asOf,
                                                          newer: read(901, 1_000)))
        XCTAssertEqual(third.kept, second.kept)
        XCTAssertEqual(third.stats(addresses: .monadMainnet), whole(through: 1_000))
    }

    /// A first read that stops short is a minimum, kept as the newest run; the next opening reads the blocks since, then
    /// the blocks below the run, newest first, until the count reaches the publish — the statistics then those of one read
    /// of everything. A read below the run that stops short again reaches down as far as it read.
    func testAShortCountGrowsDownToThePublish() throws {
        let asOf = Date(timeIntervalSince1970: 1_000)
        let short = try XCTUnwrap(MomentHolderTally.round(saved: nil, coin: Self.coin, floor: 0, head: 1_000, start: 0, settled: 900, settledAt: asOf,
                                                          newer: read(0, 1_000, readFrom: 700, complete: false)))
        XCTAssertFalse(short.complete)
        XCTAssertFalse(short.stats(addresses: .monadMainnet).complete)
        XCTAssertLessThanOrEqual(short.stats(addresses: .monadMainnet).holders, whole(through: 1_000).holders, "a minimum")
        XCTAssertEqual([short.kept?.from, short.kept?.to], [700, 900])

        var next = try XCTUnwrap(MomentHolderTally.round(saved: short.kept, coin: Self.coin, floor: 0, head: 1_000, start: 901, settled: 900, settledAt: asOf,
                                                         newer: read(901, 1_000)))
        XCTAssertTrue(next.newerComplete)
        next.extend(read(0, 699, readFrom: 300, complete: false))
        XCTAssertEqual(next.kept?.from, 300)
        XCTAssertFalse(next.complete)
        next.extend(read(0, 299))
        XCTAssertEqual(next.kept?.from, 0)
        XCTAssertTrue(next.complete)
        XCTAssertEqual(next.stats(addresses: .monadMainnet), whole(through: 1_000))
    }

    /// A read of the blocks since that stops short starts again from the head: what was kept, cut off from it by blocks
    /// unread, is dropped, never added across the gap. One that can't read the head is no statistics at all.
    func testAGapStartsTheCountAgainFromTheHead() throws {
        let asOf = Date(timeIntervalSince1970: 1_000)
        let kept = try XCTUnwrap(MomentHolderTally.round(saved: nil, coin: Self.coin, floor: 0, head: 600, start: 0, settled: 500, settledAt: asOf, newer: read(0, 600))?.kept)
        let gap = try XCTUnwrap(MomentHolderTally.round(saved: kept, coin: Self.coin, floor: 0, head: 1_000, start: 501, settled: 900, settledAt: asOf,
                                                        newer: read(501, 1_000, readFrom: 800, complete: false)))
        XCTAssertEqual([gap.kept?.from, gap.kept?.to], [800, 900])
        XCTAssertEqual(gap.kept?.balances, MomentsService.netTransfers(Self.history.filter { (800 ... 900).contains($0.blockNumber) }))
        XCTAssertFalse(gap.complete)
        var stays = gap
        stays.extend(read(0, 799))
        XCTAssertEqual(stays, gap, "nothing older is added to a read that stopped short")
        XCTAssertNil(MomentHolderTally.round(saved: kept, coin: Self.coin, floor: 0, head: 1_000, start: 501, settled: 900, settledAt: asOf,
                                             newer: NewestLogs(logs: [], readFrom: nil, complete: false)))
        // A later read's window never narrows the kept one's.
        let wider = try XCTUnwrap(MomentHolderTally.round(saved: kept, coin: Self.coin, floor: 300, head: 1_000, start: 501, settled: 900, settledAt: asOf,
                                                          newer: read(501, 1_000)))
        XCTAssertEqual(wider.floor, 0)
    }

    /// The holders' read is a screen's, given no head, so an endpoint that clamps may answer its newest ranges short, from
    /// a node hundreds of blocks behind, with no error (`LogsEndpoint.clamps`). Nothing within `LogsEndpoints.headLag` of
    /// the head is kept: what such a node left out shows short once, is never kept as blocks with no transfers, and the
    /// next opening counts it — the figures then those of one read of everything. With 100 blocks held back, as merged, the
    /// transfers of blocks 402–900 were lost for good.
    func testAClampedAnswerNeverReachesTheKeptCount() throws {
        XCTAssertGreaterThanOrEqual(MomentHolderTally.settleBlocks, LogsEndpoints.headLag)
        XCTAssertEqual(MomentHolderTally.settled(head: 1_000), 400)
        XCTAssertEqual(MomentHolderTally.settled(head: 600), 0, "near the chain's first blocks")
        let asOf = Date(timeIntervalSince1970: 1_000)
        let head: UInt64 = 1_000
        let settled = MomentHolderTally.settled(head: head)
        // Answered by a node `headLag - 1` blocks behind: nothing past block 401, no error, the read said to be whole.
        let nodeHead = head - LogsEndpoints.headLag + 1
        XCTAssertTrue(Self.history.contains { $0.blockNumber > nodeHead && $0.blockNumber <= head - 100 }, "transfers the node left out")
        let clamped = NewestLogs(logs: Self.history.filter { $0.blockNumber <= nodeHead }, readFrom: 0, complete: true)
        let first = try XCTUnwrap(MomentHolderTally.round(saved: nil, coin: Self.coin, floor: 0, head: head, start: 0, settled: settled, settledAt: asOf,
                                                          newer: clamped))
        let kept = try XCTUnwrap(first.kept)
        XCTAssertEqual([kept.from, kept.to], [0, settled])
        XCTAssertEqual(kept.balances, MomentsService.netTransfers(Self.history.filter { $0.blockNumber <= settled }), "only blocks the node had")

        let next = try XCTUnwrap(MomentHolderTally.round(saved: kept, coin: Self.coin, floor: 0, head: head, start: settled + 1, settled: settled, settledAt: asOf,
                                                         newer: read(settled + 1, head)))
        XCTAssertEqual(next.stats(addresses: .monadMainnet), whole(through: head))
        XCTAssertEqual(next.kept, kept)
    }

    /// The kept count on disk: every wallet, a net that went below zero included, read back exactly; a file of another
    /// version or coin, blocks out of order, or any entry that can't be read back is not used at all.
    func testTheKeptCountReadsBackExactlyOrNotAtAll() throws {
        let balances: [Address: BigInt] = [Self.wallets[0]: BigInt(-5) * BigInt(10).power(18), Self.wallets[1]: BigInt(123_456_789), Self.wallets[2]: BigInt(1) << 200]
        let tally = MomentHolderTally(coin: Self.coin, floor: 40, from: 100, to: 900, balances: balances, asOf: Date(timeIntervalSince1970: 1_790_000_000))
        let data = try JSONEncoder().encode(MomentHolderTallyFile(tally))
        let file = try JSONDecoder().decode(MomentHolderTallyFile.self, from: data)
        XCTAssertEqual(file.tally(coin: Self.coin), tally)
        XCTAssertNil(file.tally(coin: Self.wallets[3]), "another coin's")
        XCTAssertFalse(tally.complete)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func decoded(_ change: (inout [String: Any]) -> Void) throws -> MomentHolderTally? {
            var copy = json
            change(&copy)
            return try JSONDecoder().decode(MomentHolderTallyFile.self, from: JSONSerialization.data(withJSONObject: copy)).tally(coin: Self.coin)
        }
        XCTAssertNil(try decoded { $0["version"] = 2 })
        XCTAssertNil(try decoded { $0["from"] = 901 })
        XCTAssertNil(try decoded { $0["balances"] = [Self.wallets[0].hex: "12x"] })
        XCTAssertNil(try decoded { $0["balances"] = ["0x12": "1"] })
        json["balances"] = [:] as [String: String]
        XCTAssertEqual(try decoded { _ in }?.balances, [:])
    }

    /// Over the chain: the first opening reads the window's every range; the next reads only the blocks since what it kept
    /// (one range here), with the same statistics; the count it kept shows at once, said to be what was kept; an erase
    /// forgets it.
    func testTheSecondOpeningReadsOnlyTheNewBlocks() async throws {
        var addresses = MomentsAddresses.monadMainnet
        addresses.deployBlock = 0
        let store = ChainStore(directory: folder())
        MomentsChainStub.install({ _, _ in nil }, logs: Self.history)
        let rpc = MomentsChainStub.rpc()
        let service = MomentsService(rpc: rpc, addresses: addresses, logsRPC: rpc, clock: BlockClock(rpc: rpc, measured: 0.3), store: store)
        let published = MomentsChainStub.head.timestamp - 3_600
        let firstRead = await service.holderStats(coin: Self.coin, publishedAt: published)
        let first = try XCTUnwrap(firstRead)
        XCTAssertEqual(first, whole(through: MomentsChainStub.head.number))
        let ranges = MomentsChainStub.logQueries().count
        XCTAssertGreaterThan(ranges, 1)

        let savedRead = await service.savedHolderStats(coin: Self.coin)
        let saved = try XCTUnwrap(savedRead)
        XCTAssertEqual(saved.stats.scannedTo, MomentHolderTally.settled(head: MomentsChainStub.head.number))
        XCTAssertEqual(saved.stats.scannedTo, MomentsChainStub.head.number - LogsEndpoints.headLag)
        XCTAssertTrue(saved.stats.complete)

        MomentsChainStub.install({ _, _ in nil }, logs: Self.history)
        let secondRead = await service.holderStats(coin: Self.coin, publishedAt: published)
        XCTAssertEqual(secondRead, first)
        // Only the blocks since what was kept: the newest `settleBlocks`, in the stub endpoint's 100-block ranges.
        XCTAssertEqual(MomentsChainStub.logQueries().count, Int(MomentHolderTally.settleBlocks / 100), "only the blocks since what was kept")
        XCTAssertLessThan(MomentsChainStub.logQueries().count, ranges)

        store.erase()
        let erased = await service.savedHolderStats(coin: Self.coin)
        XCTAssertNil(erased)
    }

    // MARK: Proceeds

    /// What a Moment holds for its creator comes from the list already read (its ledger, its pool once graduated): no read
    /// of its own; a Moment the list doesn't hold is read, and the proceeds are the same either way — the pool fees of a
    /// graduated one (`MomentPool.creatorFees`, the hook's `creatorAccrued`) included.
    func testTheProceedsTakeTheListsAlreadyRead() async throws {
        let stack = Self.stack
        let a = stack.addresses
        let answer: MomentsChainStub.Answer = { to, data in
            let selector = data.prefix(4)
            func is_(_ signature: String) -> Bool { selector == StubSelector.of(signature) }
            func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
            let id = data.count >= 36 ? Int(clamping: BigUInt(data.dropFirst(4).prefix(32))) : 0
            if to == a.collect, is_(MomentsABI.Collect.ledger) {
                return encode([.tuple([.uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .uint(40_000), .uint(0), .uint(0), .uint(0), .uint(0)])], MomentsABI.ledgerTuple)
            }
            // Moment 2 graduated: its pool, and the fees its hook holds for the creator.
            if to == a.graduation, is_(MomentsABI.Graduation.isGraduated) { return encode([.bool(id == 2)], "bool") }
            if to == a.graduation, is_(MomentsABI.Graduation.record) {
                let key: ABIValue = .tuple([.address(a.usdc), .address(stack.coin(id)), .uint(10_000), .int(200), .address(a.hook)])
                return encode([.tuple([key, .uint(BigUInt(2).power(96)), .uint(1_000), .uint(0), .uint(0), .uint(0), .uint(0), .uint(1_790_600_000)])], MomentsABI.recordTuple)
            }
            if to == a.hook, is_(MomentsABI.Hook.creatorAccrued) { return encode([.uint(id == 2 ? 12_345 : 0)], "uint256") }
            if to == a.hook, is_(MomentsABI.Hook.platformAccrued) || is_(MomentsABI.Hook.buybackAccrued) { return encode([.uint(0)], "uint256") }
            if to == a.locker, is_(MomentsABI.Locker.liquidityOf) { return encode([.uint(1_000)], "uint128") }
            if to == a.locker, is_(MomentsABI.Locker.heldOf) { return encode([.uint(0)], "uint256") }
            if to == a.buyback, is_(MomentsABI.Buyback.carry) || is_(MomentsABI.Buyback.minInterval) || is_(MomentsABI.Buyback.minAmount) { return encode([.uint(0)], "uint256") }
            if to == a.buyback, is_(MomentsABI.Buyback.lastRun) { return encode([.uint(0)], "uint64") }
            if to == a.poolManager { return nil } // no live price: the opening one
            return stack.answer(to, data)
        }
        MomentsChainStub.install(answer)
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let list = try await service.moments(limit: 60)
        let data = try ABI.encode([.address(.zero), .address(.zero), .uint(100_000), .uint(500), .uint(1), .uint(1), .uint(0)], "address,address,uint256,uint16,uint256,uint256,uint64")
        let published = [Log(address: stack.addresses.factory, topics: [MomentsABI.Events.publishedTopic, BigUInt(2).serialize().leftPadded(to: 32), Self.creator.data.leftPadded(to: 32)],
                             data: data, blockNumber: 109_000_000, transactionHash: Data(repeating: 0x0b, count: 32), logIndex: 0)]

        MomentsChainStub.install(answer)
        let fromList = try await service.creatorEarnings(account: Self.creator, published: published, withdrawn: [], feesWithdrawn: [], complete: true, known: list)
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "nothing read: the list holds it")
        XCTAssertEqual(fromList.moments.map(\.key), [MomentKey(factory: stack.addresses.factory, id: 2)])
        XCTAssertEqual(list.first { $0.id == 2 }?.pool?.creatorFees, 12_345, "graduated, with its pool")
        XCTAssertEqual(fromList.moments.first?.proceedsUnclaimed, 40_000)
        XCTAssertEqual(fromList.moments.first?.feesUnclaimed, 12_345, "the pool's fees, from the list")

        let read = try await service.creatorEarnings(account: Self.creator, published: published, withdrawn: [], feesWithdrawn: [], complete: true, known: list.filter { $0.id != 2 })
        XCTAssertFalse(MomentsChainStub.batches().isEmpty, "read: the list doesn't hold it")
        XCTAssertEqual(read, fromList)

        let held = MomentsService.creatorHeld(ids: [1, 2], known: list, factory: Address(literal: "0x0000000000000000000000000000000000000c03"))
        XCTAssertTrue(held.isEmpty, "another cohort's Moments of the same ids hold nothing for this one")
    }

    // MARK: Time on screen

    /// The countdown reads differently exactly at the instants `nextChange` names, and at no other: checked second by
    /// second over three days before a deadline.
    func testTheCountdownChangesOnlyWhereItSays() {
        let deadline = 1_790_000_000
        var now = deadline - 3 * 86_400 - 17
        while now < deadline {
            let next = MomentCountdown.nextChange(after: now, deadline: deadline)
            let change = try? XCTUnwrap(next)
            guard let change else { return XCTFail("open at \(now) but no next change") }
            XCTAssertGreaterThan(change, now)
            let shown = MomentCountdown.shownMinutes(secondsLeft: deadline - now)
            // Every second up to the next change reads as now; the change reads differently.
            if change - now <= 120 {
                for t in now + 1 ..< change { XCTAssertEqual(MomentCountdown.shownMinutes(secondsLeft: deadline - t), shown, "\(t)") }
            } else {
                XCTAssertEqual(MomentCountdown.shownMinutes(secondsLeft: deadline - (change - 1)), shown)
            }
            XCTAssertNotEqual(MomentCountdown.shownMinutes(secondsLeft: deadline - change), shown, "\(change)")
            now = change
        }
        XCTAssertEqual(now, deadline, "the last change is the deadline")
        XCTAssertNil(MomentCountdown.nextChange(after: deadline, deadline: deadline))
        XCTAssertEqual(MomentCountdown.shownMinutes(secondsLeft: 59), 1, "under a minute still reads one")
        XCTAssertEqual(MomentCountdown.shownMinutes(secondsLeft: 0), 0)
        XCTAssertEqual(MomentCountdown.nextChange(after: deadline - 125, deadline: deadline), deadline - 119)
    }

    /// A page's time-bound values change at the deadline, the vesting cliffs and the buyback coming due, and nowhere
    /// between; the board's when a Moment stops collecting.
    func testThePagesTimesChangeAtTheirInstants() async throws {
        install()
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: Self.stack.addresses)
        let list = try await service.moments(limit: 60)
        let info = try XCTUnwrap(list.first)
        let deadline = info.moment.deadline
        XCTAssertEqual(MomentPageTimes(info, at: deadline - 1_000), MomentPageTimes(info, at: deadline - 1))
        XCTAssertNotEqual(MomentPageTimes(info, at: deadline - 1), MomentPageTimes(info, at: deadline))
        XCTAssertTrue(MomentPageTimes(info, at: deadline - 1).collecting)
        XCTAssertFalse(MomentPageTimes(info, at: deadline).collecting)
        XCTAssertTrue(MomentPageTimes(info, at: deadline).expirable)
        XCTAssertEqual(MomentPageTimes(info, at: deadline), MomentPageTimes(info, at: deadline + 86_400))

        XCTAssertNotEqual(MomentBoardTimes(moments: list, policy: nil, at: deadline - 1), MomentBoardTimes(moments: list, policy: nil, at: deadline))
        XCTAssertEqual(MomentBoardTimes(moments: list, policy: nil, at: deadline), MomentBoardTimes(moments: list, policy: nil, at: deadline + 600))

        // A graduated Moment's vesting moves at each 30-day cliff.
        let graduatedAt = deadline - 86_400
        let pool = MomentPool(key: PoolKey(currency0: .zero, currency1: .zero, fee: 0, tickSpacing: 60, hooks: .zero), poolId: Data(), usdcIs0: true, sqrtPriceX96: 1,
                              openingSqrtPriceX96: 1, liquidity: 0, seedLiquidity: 0, reserveSeed: 0, poolCoins: 0, graduatedAt: graduatedAt, usdcPerCoin: 0,
                              creatorFees: 0, platformFees: 0, buybackFees: 0, buybackCarry: 0, lastBuyback: graduatedAt, buybackInterval: 3_600, buybackMin: 0)
        let graduated = MomentInfo(moment: info.moment, name: info.name, symbol: info.symbol, provenance: info.provenance, ledger: info.ledger, editions: info.editions,
                                   closed: true, entitlements: info.entitlements, graduated: true, progressBps: 10_000, pool: pool)
        let month = MomentsConstants.monthSeconds
        XCTAssertEqual(MomentPageTimes(graduated, at: graduatedAt + month - 1).collectorVestedBps, 6_000)
        XCTAssertEqual(MomentPageTimes(graduated, at: graduatedAt + month).collectorVestedBps, 8_000)
        XCTAssertNotEqual(MomentPageTimes(graduated, at: graduatedAt + 2 * month - 1), MomentPageTimes(graduated, at: graduatedAt + 2 * month))
        XCTAssertFalse(MomentPageTimes(graduated, at: graduatedAt + 3_599).buybackReady)
        XCTAssertTrue(MomentPageTimes(graduated, at: graduatedAt + 3_600).buybackReady)
    }
}

/// The Moments screens wired for speed, read from the app's sources: the board polls only while on screen and never
/// again at once on return, shows the list and the terms as each lands and sets nothing a poll read again as it was;
/// a Moment's page reads its parts side by side and shows each as it lands; My Moments reads each cohort's list once for
/// its positions and proceeds, and its proceeds once on opening; the screens are drawn again only when what they show of
/// the time changes; a Moment saved when last read opens by its link.
final class MomentsSpeedScreenPinTests: XCTestCase {
    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func source(_ path: String) throws -> String { squeezed(try DocsLinksTests.appSource(path)) }

    func testTheBoardPollsOnlyOnScreenAndDrawsOnlyWhatChanged() throws {
        let board = try Self.source("Moments/MomentsView.swift")
        XCTAssertTrue(board.contains(".task(id: \"\\(session.address?.hex ?? \"\")-\\(scenePhase == .active)\") { guard scenePhase == .active else { return } "
                                     + "await model.poll(env: env, account: session.address) }"), "only while on screen with the app in front")
        XCTAssertTrue(board.contains("if let lastRead, lastReadFor == account { let wait = .seconds(Self.pollInterval) - (ContinuousClock.now - lastRead) "
                                     + "if wait > .zero { try? await Task.sleep(for: wait) } }"), "back on screen, it waits out the rest of its 20 s")
        // On the monotonic clock: a device clock set back never makes the wait longer than the 20 s.
        XCTAssertTrue(board.contains("@ObservationIgnored private var lastRead: ContinuousClock.Instant?"))
        XCTAssertTrue(board.contains("lastRead = .now lastReadFor = account"))
        XCTAssertFalse(board.contains("timeIntervalSince(lastRead)"))
        XCTAssertTrue(board.contains("static let pollInterval: TimeInterval = 20"))
        XCTAssertTrue(board.contains("if moments != list { moments = list }"))
        XCTAssertTrue(board.contains(".task { await clock.run(showing: { MomentBoardTimes(moments: model.moments, policy: model.policy, at: $0) }) }"))
        XCTAssertTrue(board.contains("case .collecting: return model.moments.filter { $0.isCollecting(at: clock.now) }"))
        XCTAssertTrue(board.contains(".sheet(isPresented: $showPortfolio) { MomentsPortfolioView { info in showPortfolio = false; path.append(info) } }"))
    }

    func testTheClockMovesOnlyWhenTheScreenWouldChange() throws {
        let ui = try Self.source("Moments/MomentsUI.swift")
        XCTAssertTrue(ui.contains("func run<Face: Equatable>(showing face: @escaping @MainActor (Int) -> Face) async { while !Task.isCancelled { "
                                  + "let time = Int(Date().timeIntervalSince1970) if time != now, face(time) != face(now) { now = time } try? await Task.sleep(for: .seconds(1)) } }"))
        XCTAssertTrue(ui.contains("if info.state == .collecting { TimelineView(CountdownSchedule(deadline: info.moment.deadline)) { context in "
                                  + "MomentStateLabel(info: info, now: Int(context.date.timeIntervalSince1970), onMedia: onMedia) }"), "a countdown draws itself alone")
        XCTAssertTrue(ui.contains("next = MomentCountdown.nextChange(after: Int(current.timeIntervalSince1970), deadline: deadline)"))
        XCTAssertTrue(ui.contains("struct MomentCard: View { let info: MomentInfo var body: some View {"), "a card has no clock of its own")
        // Every screen's clock says what it shows of the time; no badge or card is handed one.
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() }
        app.appendPathComponent("DyorHQ")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("clock.run()"), file.lastPathComponent)
            XCTAssertFalse(text.contains("MomentStateBadge(info: info, now:"), file.lastPathComponent)
            XCTAssertFalse(text.contains("MomentCard(info: info, now:"), file.lastPathComponent)
        }
        for path in ["Moments/MomentDetailView.swift", "Moments/RetiredMomentDetailView.swift"] {
            XCTAssertTrue(try Self.source(path).contains(".task { await clock.run(showing: { MomentPageTimes(info, at: $0) }) }"), path)
        }
    }

    func testAMomentsPageShowsEachPartAsItLands() throws {
        let page = try Self.source("Moments/MomentDetailView.swift")
        XCTAssertTrue(page.contains("async let moment: Void = loadMoment() async let supply: Void = loadSupply() async let stake: Void = loadAccount() "
                                    + "_ = await (moment, supply, stake) if !Task.isCancelled { loaded = true }"))
        XCTAssertTrue(page.contains("let read = try await env.moments.detail(for: info)"), "the supply beside the Moment, never after a second read of it")
        XCTAssertTrue(page.contains("let read = try await env.moments.accountView(info, account: address)"))
        XCTAssertTrue(page.contains("async let editions: Void = loadEditionHolders() if info.graduated { await loadHolderStats() } await editions"))
        XCTAssertTrue(page.contains("ToolbarItem(placement: .topBarTrailing) { MomentShareButton(info: info, ready: loaded) }"))
        XCTAssertFalse(page.contains("env.moments.moment(id:"))
        XCTAssertFalse(page.contains("try await (detailTask, holdersTask, accountTask)"), "no part waits for the slowest")
        let retired = try Self.source("Moments/RetiredMomentDetailView.swift")
        XCTAssertTrue(retired.contains("async let moment: Void = loadMoment() async let stake: Void = loadAccount() _ = await (moment, stake)"))
        XCTAssertTrue(retired.contains("ToolbarItem(placement: .topBarTrailing) { MomentShareButton(info: info, ready: loaded) }"))
        XCTAssertTrue(retired.contains("Button(\"Retry\") { reloads += 1 }"))
        let share = try Self.source("Moments/MomentLinkView.swift")
        XCTAssertTrue(share.contains("guard ready else { return } named = try? await env.momentDirectory.link(for: info.key)"), "the name after the page's reads")
    }

    func testMyMomentsReadsEachListOnce() throws {
        let mine = try Self.source("Moments/MomentsPortfolioView.swift")
        XCTAssertTrue(mine.contains(".task { await loadPositions() }"))
        XCTAssertTrue(mine.contains(".task(id: env.history.snapshot.status(WalletHistoryScans.momentsId)) { await loadEarnings() }"),
                      "the proceeds once on opening, then with the Moments scan")
        XCTAssertFalse(mine.contains(".task(id: env.history.version)"))
        XCTAssertTrue(mine.contains("portfolio = try await env.moments.portfolio(account: address, moments: try await env.moments.moments(limit: MomentsService.listingLimit))"),
                      "every Moment the screens check, never the board's 60 or its saved copy")
        XCTAssertFalse(mine.contains("let moments: [MomentInfo]"))
        XCTAssertTrue(mine.contains("complete: liveLogs.complete, known: liveList)"))
        XCTAssertTrue(mine.contains("async let listRead = cohort.moments()"))
        XCTAssertTrue(mine.contains("complete: logs.complete, known: list)"))
    }

    func testAMomentSavedWhenLastReadOpensByItsLink() throws {
        let home = try Self.source("Home/HomeView.swift")
        XCTAssertTrue(home.contains("if model.reads.isSaved(.moments), let link = MomentLink(key: moment.key) { router.openMoment(link) } else { router.openMoment(moment) }"))
        XCTAssertTrue(home.contains("Button { openMoment(row.moment) }"))
        XCTAssertFalse(home.contains("Button { router.openMoment(row.moment) }"))
        XCTAssertTrue(try Self.source("App/Router.swift").contains("func openMoment(_ link: MomentLink) { pendingMomentLink = link tab = .moments }"))
    }
}
