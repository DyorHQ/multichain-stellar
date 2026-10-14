import BigInt
import XCTest
@testable import DyorKit

/// The DyorHQ coin registry: which addresses are DyorHQ coins — every launchpad's and every cohort's, live or retired —
/// read only from the factories' own records; what a failed read means (unknown, never "not DyorHQ"); reading only
/// what's new; and keeping it in a file, not UserDefaults. Contract reads come from `MomentsChainStub` (`DyorCoinChain`).
final class DyorCoinRegistryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "dyor-coins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MomentsChainStub.install { _, _ in nil }
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: DyorCoinStore { DyorCoinStore(url: folder.appending(path: DyorCoinStore.fileName())) }

    private func registry(_ chain: DyorCoinChain, store: DyorCoinStore? = nil) -> DyorCoinRegistry {
        chain.install()
        return DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
    }

    private func launch(_ token: String, _ symbol: String, deployer: Address = DyorCoinChain.creator) -> DyorCoinChain.LaunchCoin {
        let address = Address(literal: token)
        return DyorCoinChain.LaunchCoin(token: address, name: symbol + " Coin", symbol: symbol, logo: DyorCoinChain.media(deployer, "\(symbol).jpg"), deployer: deployer,
                                        curve: Address(data: Data(address.data.reversed()))!)
    }

    private func moment(_ coin: String, _ symbol: String) -> DyorCoinChain.MomentCoin {
        let address = Address(literal: coin)
        return DyorCoinChain.MomentCoin(coin: address, nft: Address(data: Data(address.data.reversed()))!, creator: DyorCoinChain.creator, name: symbol, symbol: symbol,
                                        mediaURI: "ipfs://bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe", mediaHash: Data(repeating: 0xab, count: 32))
    }

    // MARK: Mainnet

    /// The chain as it is today: the 7 launches of the four retired launchpads (none on v2 or 0x6B1C yet) and the 6
    /// Moments of cohorts 1–3 (none on c4 yet), each as its factory recorded it, read in three Multicall3 reads.
    func testTheMainnetCoinsAreReadInThreeReads() async throws {
        let registry = registry(.mainnet)
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let coins = await registry.all
        XCTAssertEqual(coins.count, 13)
        XCTAssertEqual(MomentsChainStub.batches().count, 3, "counts, then lists, then every new coin's details")

        let qt = try XCTUnwrap(coins[DyorCoinChain.qt])
        XCTAssertEqual(qt.origin, .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), "read in the 16-field layout")
        XCTAssertEqual([qt.symbol, qt.name], ["QT", "Quet"])
        XCTAssertEqual(qt.creator, DyorCoinChain.owner)
        XCTAssertEqual(qt.logo, DyorCoinChain.media(DyorCoinChain.owner, "0136f3f3-24cf-45e5-b4d8-1f68423c36cf.jpg"))
        XCTAssertEqual(qt.pair, .zero, "MON")
        XCTAssertTrue(qt.isLaunch && qt.retired)
        XCTAssertEqual(coins[Address(literal: "0xCD83D45F985BB42b7d6ABB1f2cC12860B4610c3D")]?.pair, DyorCoinChain.aBIL, "JUST trades against aBIL")
        XCTAssertEqual(coins[Address(literal: "0xA4D9b2697254292ad30e06Ce968a7e18De6fF884")]?.origin, .launch(factory: DyorCoinChain.audit, generation: .v1, retired: true))
        XCTAssertEqual(coins[Address(literal: "0x74b215C1788A90aAF45A33f83584C1a04ba402b8")]?.origin, .launch(factory: DyorCoinChain.preAudit, generation: .preAudit, retired: true))
        XCTAssertEqual(Set(coins.values.filter(\.isLaunch).map(\.symbol)), ["QT", "JUST", "BB", "BP", "GMGM", "BPP", "LP"])

        // Every Moment coin the retired cohorts minted, each under its (factory, id).
        for (coin, key) in MomentsAddresses.retiredMainnetCoins {
            let entry = try XCTUnwrap(coins[coin], "\(coin) is a DyorHQ Moment")
            XCTAssertEqual(entry.momentKey, key)
            XCTAssertTrue(entry.retired)
            XCTAssertEqual(entry.pair, Monad.usdc)
        }
        let nature = try XCTUnwrap(coins[Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")])
        XCTAssertEqual([nature.symbol, nature.name], ["NAT", "Nature"])
        XCTAssertTrue(nature.mediaIsVideo, "Nature is a video: its picture is the poster")
        XCTAssertEqual(nature.logo, "ipfs://bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe")
        XCTAssertEqual(nature.mediaHash, Data(hex: "0x46a0fa05ecc0fd0f47856df1d8a6fbd69145d1d9df6da9927301719b4a06a6c5"))
        let diva = try XCTUnwrap(coins[Address(literal: "0xd6c17E083b53fa1c46b71120D6959303Ae4B8e1F")])
        XCTAssertTrue(diva.mediaIsVideo)
        XCTAssertEqual(diva.creator, DyorCoinChain.creator)
        XCTAssertFalse(try XCTUnwrap(coins[Address(literal: "0xDc1bC41b7C197DE19f17C7832bec3Bb748D92297")]).mediaIsVideo)
        let proof = await registry.prove([DyorCoinChain.james])
        XCTAssertEqual(proof[DyorCoinChain.james], .notDyor, "JAMES, a nad.fun coin, is none of these")
    }

    // MARK: Every factory

    /// A coin on each of the five launchpads — the live v2 one and the four retired ones, 0xad3d's in its 16-field layout —
    /// and each of the four cohorts is proven a DyorHQ coin, retired everywhere but on the live launchpad and cohort.
    func testACoinOnEachLaunchpadAndEachCohortIsProven() async throws {
        var chain = DyorCoinChain()
        let live = LaunchpadAddresses.monadMainnet.factory
        let tokens = [
            live: "0x0000000000000000000000000000000000c0a001", DyorCoinChain.relaunch: "0x0000000000000000000000000000000000c0a002",
            DyorCoinChain.audit: "0x0000000000000000000000000000000000c0a003", DyorCoinChain.preAudit: "0x0000000000000000000000000000000000c0a004",
            DyorCoinChain.legacy: "0x0000000000000000000000000000000000c0a005",
        ]
        for (factory, token) in tokens { chain.launches[factory] = [launch(token, "L\(token.suffix(1))")] }
        let c4 = MomentsAddresses.monadMainnet.factory
        let coins = [c4: "0x0000000000000000000000000000000000c0b004", DyorCoinChain.c3: "0x0000000000000000000000000000000000c0b003",
                     DyorCoinChain.c2: "0x0000000000000000000000000000000000c0b002", DyorCoinChain.c1: "0x0000000000000000000000000000000000c0b001"]
        for (factory, coin) in coins { chain.moments[factory] = [moment(coin, "M\(coin.suffix(1))")] }
        let registry = registry(chain)
        let asked = tokens.values.map { Address(literal: $0) } + coins.values.map { Address(literal: $0) }
        let proof = await registry.prove(asked)
        for (factory, token) in tokens {
            guard case .dyor(let coin)? = proof[Address(literal: token)] else { return XCTFail("\(token) on \(factory) is a DyorHQ launch") }
            let stack = try XCTUnwrap(DyorCoinChain.stacks.first { $0.factory == factory })
            XCTAssertEqual(coin.origin, .launch(factory: factory, generation: stack.generation, retired: factory != live))
        }
        for (factory, token) in coins {
            guard case .dyor(let coin)? = proof[Address(literal: token)] else { return XCTFail("\(token) on \(factory) is a DyorHQ Moment") }
            XCTAssertEqual(coin.origin, .moment(factory: factory, id: 1, retired: factory != c4))
            XCTAssertEqual(coin.pair, Monad.usdc)
        }
        XCTAssertEqual(MomentsChainStub.batches().count, 5,
                       "the counts; every factory's record; then, at once, the launches' records and text and the Moments; then the Moments' text")
        let known = await registry.all
        XCTAssertEqual(known.count, 9, "a coin proven is kept")
    }

    /// 0x6B1C was retired in the app only (owner decision 2026-09-28): builds before 16 can still launch there, and such a
    /// coin is a DyorHQ launch like any other — on a retired launchpad.
    func testACoinLaunchedOnTheRetired0x6B1CIsADyorHQLaunchOnARetiredLaunchpad() async throws {
        var chain = DyorCoinChain.mainnet
        let late = launch("0x0000000000000000000000000000000000006b1c", "LATE")
        chain.launches[DyorCoinChain.relaunch] = [late]
        let registry = registry(chain)
        await registry.refresh()
        let found = await registry.coin(late.token)
        let coin = try XCTUnwrap(found)
        XCTAssertEqual(coin.origin, .launch(factory: DyorCoinChain.relaunch, generation: .v1, retired: true))
        XCTAssertEqual(coin.creator, late.deployer)
    }

    // MARK: Only the factories say

    /// A factory record that names another token proves nothing about the one asked: not when a factory lists it — it
    /// stays out, and that factory's list is read from there again next time, as when a node behind the chain answers —
    /// and not when it is asked about directly. Nor does a Moment id whose Moment is another coin's.
    func testARecordNamingAnotherTokenIsRefused() async throws {
        var chain = DyorCoinChain()
        var listed = launch("0x0000000000000000000000000000000000000b0b", "BOB")
        listed.recordToken = DyorCoinChain.qt
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [listed]
        var other = moment("0x0000000000000000000000000000000000000c0c", "CC")
        other.momentCoin = Address(literal: "0x0000000000000000000000000000000000000d0d")
        chain.moments[DyorCoinChain.c2] = [other]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertFalse(complete, "neither list was read past its coin")
        let coins = await registry.all
        XCTAssertTrue(coins.isEmpty)
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[LaunchpadAddresses.monadMainnet.factory], 0)
        XCTAssertEqual(checkpoints[DyorCoinChain.c2], 0)
        let proof = await registry.prove([listed.token, other.coin])
        XCTAssertEqual(proof[listed.token], .notDyor)
        XCTAssertEqual(proof[other.coin], .notDyor)
        // Pure half: the record must exist, name this very token and a curve.
        let stack = LaunchpadAddresses.monadMainnet
        let answers: [Result<[ABIValue], Error>] = [.success([.tuple(DyorCoinChain.record(listed, legacy: false))]), .success([.string("Bob")]), .success([.string("BOB")]),
                                                    .success([.address(.zero), .string(""), .string(""), .tuple(Array(repeating: .string(""), count: 5))])]
        XCTAssertNil(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: answers))
        listed.recordToken = nil
        var named = answers
        named[0] = .success([.tuple(DyorCoinChain.record(listed, legacy: false))])
        XCTAssertNotNil(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: named))
        var noRecord = named
        noRecord[0] = .failure(RPCError(code: 3, message: "reverted"))
        XCTAssertNil(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: noRecord), "no record, no coin")
    }

    // MARK: Creator text never holds a list back (F1)

    /// A launch named with bytes that aren't text (ff fe fd fc) on the live launchpad, then two ordinary ones; a Moment on
    /// cohort 4 whose name and symbol aren't text, then an ordinary one; and a launch whose own calls revert however
    /// they are read. One refresh reads every list to its count: each poisoned coin is a DyorHQ coin with its text as
    /// read (U+FFFD) or stood in (`ChainText.unreadable`), badged with a warning, and the coins after it are listed. So
    /// is it after a restart from the file.
    func testTextThatIsntTextNeverHoldsAFactorysListBack() async throws {
        var chain = DyorCoinChain.mainnet
        let v2 = LaunchpadAddresses.monadMainnet.factory
        let c4 = MomentsAddresses.monadMainnet.factory
        let poisoned = launch("0x0000000000000000000000000000000000000f11", "BAD")
        let mute = launch("0x0000000000000000000000000000000000000f12", "MUTE")
        let later = [launch("0x0000000000000000000000000000000000000f13", "SEA"), launch("0x0000000000000000000000000000000000000f14", "SUN")]
        chain.launches[v2] = [poisoned, mute] + later
        let poisonedMoment = moment("0x0000000000000000000000000000000000000f21", "BADM")
        let laterMoment = moment("0x0000000000000000000000000000000000000f22", "SEAM")
        chain.moments[c4] = [poisonedMoment, laterMoment]
        chain.rawText = [poisoned.token: DyorCoinChain.rawString([0xff, 0xfe, 0xfd, 0xfc]), poisonedMoment.coin: DyorCoinChain.rawString([0x41, 0xff, 0xfe, 0xfd, 0xfc, 0x5a])]
        chain.textReverts = [mute.token]
        let registry = registry(chain, store: store)
        let complete = await registry.refresh()
        XCTAssertTrue(complete, "every list read to its count")
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[v2], 4)
        XCTAssertEqual(checkpoints[c4], 2)
        let coins = await registry.all
        XCTAssertEqual(coins.count, 19)
        XCTAssertEqual(Set(later.map { coins[$0.token]?.symbol }), ["SEA", "SUN"], "the launches after the poisoned ones are listed")
        XCTAssertEqual(coins[laterMoment.coin]?.symbol, "SEAM", "and the Moment after the poisoned one")
        let bad = try XCTUnwrap(coins[poisoned.token])
        XCTAssertEqual([bad.name, bad.symbol], ["\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}", "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"], "each byte that isn't text is one U+FFFD")
        let badMoment = try XCTUnwrap(coins[poisonedMoment.coin])
        XCTAssertEqual(badMoment.name, "A\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}Z")
        let muted = try XCTUnwrap(coins[mute.token])
        XCTAssertEqual([muted.name, muted.symbol, muted.logo], [ChainText.unreadable, ChainText.unreadable, ""])
        for coin in [bad, badMoment, muted] {
            let badge = TokenBadge.of(coin.token, coin: coin, receivedUnasked: false)
            XCTAssertTrue(badge.isWarning, "\(coin.address): \(badge)")
            let membership = await registry.membership(coin.address)
            XCTAssertEqual(membership, .dyor(coin))
        }
        XCTAssertEqual(TokenBadge.of(coins[later[0].token]!.token, coin: coins[later[0].token], receivedUnasked: false), .dyorLaunch)

        MomentsChainStub.install { chain.answer($0, $1) }
        let reopened = DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
        let kept = await reopened.all
        XCTAssertEqual(kept, coins, "kept in the file as read")
        let again = await reopened.refresh()
        XCTAssertTrue(again)
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "nothing left to read: the counts alone")
    }

    /// Only a factory's own answer may hold its list back: a coin whose record can't be read stops that factory's list
    /// there (it is read again next time), while every other factory's list is read on.
    func testAFactoryRecordThatCantBeReadHoldsBackOnlyItsOwnList() async throws {
        var chain = DyorCoinChain.mainnet
        let v2 = LaunchpadAddresses.monadMainnet.factory
        let stuck = launch("0x0000000000000000000000000000000000000f31", "STUCK")
        let behind = launch("0x0000000000000000000000000000000000000f32", "BEHIND")
        let elsewhere = launch("0x0000000000000000000000000000000000000f33", "ELSE")
        chain.launches[v2] = [stuck, behind]
        chain.launches[DyorCoinChain.relaunch] = [elsewhere]
        chain.brokenRecords = [stuck.token]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertFalse(complete)
        var checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[v2], 0, "held at the coin whose record couldn't be read")
        XCTAssertEqual(checkpoints[DyorCoinChain.relaunch], 1)
        var coins = await registry.all
        XCTAssertEqual(coins.count, 14, "every other factory's coins")
        XCTAssertNil(coins[behind.token])

        chain.brokenRecords = []
        chain.install()
        let healed = await registry.refresh()
        XCTAssertTrue(healed)
        checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[v2], 2)
        coins = await registry.all
        XCTAssertEqual(coins[behind.token]?.symbol, "BEHIND")
    }

    /// 300 coins whose text is as long as a launch stores, then an ordinary one: read 20 coins a read
    /// (`Multicall.textChunk`), every read stays under the node's answer cap, and the ordinary coin is admitted in the
    /// first refresh in 18 requests (the counts, the lists, 16 reads of coins). Even 300 coins that make any read they
    /// are in fail — which no launch's text can do (a transaction stores far less than one read answers) — cost two
    /// requests each, all in the first refresh, and the ordinary coin with them.
    func testHeavyCoinsDontHoldBackTheOthersNorCostARequestEach() async throws {
        let v2 = LaunchpadAddresses.monadMainnet.factory
        let long = String(repeating: "L", count: 20_000)
        func coin(_ i: Int, _ symbol: String) -> DyorCoinChain.LaunchCoin {
            var coin = launch(String(format: "0x00000000000000000000000000000000%08x", 0xa0000 + i), symbol)
            coin.name = long
            coin.logo = "ipfs://" + long
            return coin
        }
        let heavy = (1...300).map { coin($0, "H\($0)") }
        let normal = launch("0x000000000000000000000000000000000000f401", "NORMAL")
        var chain = DyorCoinChain()
        chain.launches[v2] = heavy + [normal]
        MomentsChainStub.install({ chain.answer($0, $1) }, responseCap: 4_100_000)
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc())
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        var admitted = await registry.coin(normal.token)
        XCTAssertEqual(admitted?.symbol, "NORMAL")
        XCTAssertEqual(MomentsChainStub.batches().count, 18, "counts, lists, then 301 coins 20 a read")
        let cut = await registry.coin(heavy[0].token)
        XCTAssertEqual(cut?.name.count, DyorCoin.maxStoredName.characters, "kept cut")
        XCTAssertEqual(cut?.logo, "", "a picture link over 2,048 bytes is dropped")

        chain.breaking = Set(heavy.map(\.token))
        chain.install()
        let bombed = DyorCoinRegistry(rpc: MomentsChainStub.rpc())
        let bombedComplete = await bombed.refresh()
        XCTAssertTrue(bombedComplete)
        admitted = await bombed.coin(normal.token)
        XCTAssertEqual(admitted?.symbol, "NORMAL", "in the first refresh")
        let requests = MomentsChainStub.batches().count
        XCTAssertEqual(requests, 2 + 16 + 300 + 300, "counts, lists, 16 reads (15 fail), each bomb on its own, then its record alone")
        print("DyorCoinRegistry heavy coins: 301 coins of long text in 18 requests; 300 read-breaking coins and 1 normal in \(requests)")
        let bombs = await bombed.all
        XCTAssertEqual(bombs.count, 301)
    }

    /// A token that claims a DyorHQ factory (`factory()`), DyorHQ's name, symbol and bucket is none of DyorHQ's: no factory
    /// names it, and nothing is ever asked of the token itself.
    func testATokenClaimingAFactoryIsNotADyorHQCoin() async throws {
        let impostor = Address(literal: "0x000000000000000000000000000000000000beef")
        var chain = DyorCoinChain.mainnet
        chain.impostors = [impostor]
        let registry = registry(chain)
        let proof = await registry.prove([impostor])
        XCTAssertEqual(proof[impostor], .notDyor)
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == impostor }, "membership never comes from the token")
        let coin = await registry.coin(impostor)
        XCTAssertNil(coin)
    }

    /// A factory that doesn't answer leaves a coin unknown — shown as today — never "not DyorHQ", and it is asked again
    /// next time; a coin one factory does name is DyorHQ's whatever another failed to say. The enumeration keeps what it
    /// read and reads the rest once the factory answers.
    func testAFailedReadIsUnknownAndIsAskedAgain() async throws {
        let unseen = Address(literal: "0x0000000000000000000000000000000000000abc")
        var chain = DyorCoinChain.mainnet
        chain.silent = [DyorCoinChain.c2]
        let registry = registry(chain)
        var proof = await registry.prove([unseen, DyorCoinChain.qt])
        XCTAssertEqual(proof[unseen], .unknown)
        guard case .dyor(let qt)? = proof[DyorCoinChain.qt] else { return XCTFail("QT's own factory named it") }
        XCTAssertEqual(qt.symbol, "QT")
        var membership = await registry.membership(unseen)
        XCTAssertEqual(membership, .unknown, "no negative is kept from an incomplete read")

        let complete = await registry.refresh()
        XCTAssertFalse(complete, "cohort 2 didn't answer")
        var coins = await registry.all
        XCTAssertEqual(coins.count, 11, "all but cohort 2's two")

        chain.silent = []
        chain.install()
        proof = await registry.prove([unseen])
        XCTAssertEqual(proof[unseen], .notDyor, "asked again, and every factory answered")
        membership = await registry.membership(unseen)
        XCTAssertEqual(membership, .notDyor)
        let healed = await registry.refresh()
        XCTAssertTrue(healed)
        coins = await registry.all
        XCTAssertEqual(coins.count, 13)
    }

    /// A node behind the chain answers a coin its factory already lists with an empty record, and the coin itself as an
    /// account with no code: the coin stays out and its factory's list is read from it again next time, never passed over.
    func testACoinANodeHasNotReachedIsReadAgainNextTime() async throws {
        var chain = DyorCoinChain.mainnet
        let fresh = launch("0x0000000000000000000000000000000000000f10", "NEW")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [fresh]
        chain.lagging = [fresh.token]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertFalse(complete)
        var coins = await registry.all
        XCTAssertEqual(coins.count, 13, "every other coin is read")
        XCTAssertNil(coins[fresh.token])
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[LaunchpadAddresses.monadMainnet.factory], 0, "not passed over")

        chain.lagging = []
        chain.install()
        let caughtUp = await registry.refresh()
        XCTAssertTrue(caughtUp)
        coins = await registry.all
        XCTAssertEqual(coins[fresh.token]?.symbol, "NEW")
    }

    /// Anyone launching for 5 MON can make a coin's strings cost more gas than a read has. The coins listed after it —
    /// whose calls it starved in the shared read — are read again on their own and admitted, and so is it: its factory
    /// names it, so it is a DyorHQ coin whose text couldn't be read (`ChainText.unreadable`), badged with a warning. Its
    /// factory's list moves past it, and nothing is read again at the next refresh.
    func testACoinWhoseCallsBurnTheReadsGasIsAdmittedWithAWarning() async throws {
        var chain = DyorCoinChain.mainnet
        let bomb = launch("0x0000000000000000000000000000000000000b0a", "BOMB")
        let after = launch("0x0000000000000000000000000000000000000b0b", "AFTER")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [bomb, after]
        chain.starving = [bomb.token]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let coins = await registry.all
        XCTAssertEqual(coins[after.token]?.symbol, "AFTER")
        XCTAssertEqual(coins.count, 15)
        let admitted = try XCTUnwrap(coins[bomb.token], "its factory names it")
        XCTAssertEqual([admitted.symbol, admitted.name, admitted.logo], [ChainText.unreadable, ChainText.unreadable, ""])
        XCTAssertEqual(TokenBadge.of(admitted.token, coin: admitted, receivedUnasked: false), .unverified, "never plainly \"DyorHQ Launch\"")
        XCTAssertEqual(MomentsChainStub.batches().count, 18, "counts, lists, every coin, then each of the 15 coins from the bomb on (it starved them) on its own")
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[LaunchpadAddresses.monadMainnet.factory], 2, "past it")

        chain.install()
        await registry.refresh()
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "the next refresh: the counts alone")
    }

    /// A coin that makes the node refuse any read it is in (out of gas) doesn't take the others down: they are read
    /// again, and it is admitted with its text unread. The same holds for a held coin being proven.
    func testAReadRefusedAsAWholeIsReadAgainCoinByCoin() async throws {
        var chain = DyorCoinChain.mainnet
        let bomb = launch("0x0000000000000000000000000000000000000b1a", "BOMB")
        chain.launches[DyorCoinChain.relaunch] = [bomb]
        chain.breaking = [bomb.token]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let coins = await registry.all
        XCTAssertEqual(coins.count, 14)
        XCTAssertEqual(coins[bomb.token]?.symbol, ChainText.unreadable)

        let fresh = self.registry(chain)
        let proof = await fresh.prove([bomb.token, DyorCoinChain.qt])
        guard case .dyor(let proven)? = proof[bomb.token] else { return XCTFail("its factory names it") }
        XCTAssertEqual(proven.name, ChainText.unreadable)
        guard case .dyor(let qt)? = proof[DyorCoinChain.qt] else { return XCTFail("QT is read though the bomb shared its read") }
        XCTAssertEqual(qt.symbol, "QT")
    }

    /// A coin is its factory's record's: once that names it, its text is as read — bytes that aren't text as U+FFFD, a
    /// call that failed as `ChainText.unreadable`, a picture that couldn't be read as none — and only a record that is
    /// missing, empty or names another coin admits nothing.
    func testACoinsTextIsAsReadAndOnlyItsRecordDecides() throws {
        let stack = LaunchpadAddresses.monadMainnet
        let listed = launch("0x0000000000000000000000000000000000000b0c", "TXT")
        let record: Result<[ABIValue], Error> = .success([.tuple(DyorCoinChain.record(listed, legacy: false))])
        let reverted: Result<[ABIValue], Error> = .failure(RPCError(code: -32000, message: "Call reverted", data: "0x"))
        let info: Result<[ABIValue], Error> = .success([.address(.zero), .string("ipfs://x"), .string(""), .tuple(Array(repeating: .string(""), count: 5))])
        let lossy = try XCTUnwrap(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false,
                                                              answers: [record, .success([.string("A\u{FFFD}B")]), .success([.string("\u{FFFD}")]), info]))
        XCTAssertEqual([lossy.name, lossy.symbol, lossy.logo], ["A\u{FFFD}B", "\u{FFFD}", "ipfs://x"])
        let unread = try XCTUnwrap(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: [record, reverted, reverted, reverted]))
        XCTAssertEqual([unread.name, unread.symbol, unread.logo], [ChainText.unreadable, ChainText.unreadable, ""])
        XCTAssertFalse(SymbolSafety.isDisplaySafe(unread), "a stand-in is never display-safe")
        let empty: Result<[ABIValue], Error> = .success([.tuple(DyorCoinChain.record(nil, legacy: false))])
        for bad in [reverted, empty] {
            XCTAssertNil(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: [bad, reverted, reverted, reverted]))
        }

        let cohort = MomentsAddresses.monadMainnet
        let moment = Moment(id: 3, creator: DyorCoinChain.creator, platform: .zero, treasury: .zero, coin: Address(literal: "0x0000000000000000000000000000000000000e0c"),
                            nft: Address(literal: "0x0000000000000000000000000000000000000e0d"), price: 1, threshold: 1, rateNum: 1, rateDen: 1, creatorBps: 0, platformBps: 0,
                            reserveBps: 0, creatorAllocBps: 0, expiryCreatorBps: 0, royaltyBps: 0, publishedAt: 0, deadline: 0, factory: cohort.factory)
        let unreadMoment = try XCTUnwrap(DyorCoinRegistry.momentCoin(moment, cohort: cohort, retired: false, answers: [.success([.uint(3)]), reverted, reverted, reverted]))
        XCTAssertEqual([unreadMoment.name, unreadMoment.symbol, unreadMoment.logo], [ChainText.unreadable, ChainText.unreadable, ""])
        XCTAssertNil(unreadMoment.mediaHash)
        XCTAssertNil(DyorCoinRegistry.momentCoin(moment, cohort: cohort, retired: false, answers: [.success([.uint(4)]), reverted, reverted, reverted]), "another Moment's id")
        XCTAssertNil(DyorCoinRegistry.momentCoin(moment, cohort: cohort, retired: false, answers: [reverted, reverted, reverted, reverted]))
    }

    /// Answers the pure half gets: a missing one leaves the candidate incomplete; an empty record or a zero id is an
    /// answer.
    func testClaimsNeedEveryFactorysAnswer() {
        let stacks = Array(DyorCoinChain.stacks.prefix(2))
        let cohorts = Array(DyorCoinChain.cohortTable.prefix(1))
        let empty: Result<[ABIValue], Error> = .success([.tuple(DyorCoinChain.record(nil, legacy: false))])
        let zero: Result<[ABIValue], Error> = .success([.uint(0)])
        let candidate = Address(literal: "0x0000000000000000000000000000000000000abc")
        XCTAssertTrue(DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, empty, zero]).complete)
        let missing = DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, .failure(RPCError(code: 3, message: "reverted")), zero])
        XCTAssertFalse(missing.complete)
        XCTAssertNil(missing.launch)
        XCTAssertFalse(DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, empty]).complete, "an answer short")
        let claimed = DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, empty, .success([.uint(7)])])
        XCTAssertEqual(claimed.moments.map(\.1), [7])
    }

    /// After a complete refresh every factory's list is known, so a new session proving a wallet full of airdropped
    /// tokens asks the factories' counts and nothing else: 1,000 addresses no factory made, JAMES and QT cost one read.
    /// A coin launched since is asked of the one factory whose count moved past what was read, and nothing else.
    func testAProofAfterACompleteRefreshAsksOnlyTheCounts() async throws {
        var chain = DyorCoinChain.mainnet
        let first = registry(chain, store: store)
        let complete = await first.refresh()
        XCTAssertTrue(complete)
        let spam = (1...1_000).map { Address(literal: String(format: "0x00000000000000000000000000000000%08x", 0x5a000000 + $0)) }
        chain.install()
        let session = DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
        let proof = await session.prove(spam + [DyorCoinChain.james, DyorCoinChain.qt])
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "the counts alone")
        XCTAssertEqual(MomentsChainStub.batches().first?.count, DyorCoinChain.stacks.count + DyorCoinChain.cohortTable.count)
        XCTAssertEqual(Set(spam.map { proof[$0] }), [.notDyor])
        XCTAssertEqual(proof[DyorCoinChain.james], .notDyor)
        guard case .dyor? = proof[DyorCoinChain.qt] else { return XCTFail("QT is known from the file") }

        let fresh = launch("0x0000000000000000000000000000000000000f40", "LATE")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [fresh]
        chain.install()
        let other = Address(literal: "0x0000000000000000000000000000000000000f41")
        let late = await session.prove([fresh.token, other])
        guard case .dyor(let coin)? = late[fresh.token] else { return XCTFail("a coin launched since is proven") }
        XCTAssertEqual(coin.symbol, "LATE")
        XCTAssertEqual(late[other], .notDyor)
        let batches = MomentsChainStub.batches()
        XCTAssertEqual(Set(batches[1].map(\.to)), [LaunchpadAddresses.monadMainnet.factory], "only the launchpad whose count moved is asked")
    }

    /// Before any list is read, a proof of many addresses asks every factory with coins about each, in reads of at most
    /// 200 calls sent a few at a time; every answer lands with its own address.
    func testAProofBeforeAnyRefreshAsksEveryFactoryWithCoins() async throws {
        let registry = registry(.mainnet)
        let spam = (1...100).map { Address(literal: String(format: "0x00000000000000000000000000000000%08x", 0x5b000000 + $0)) }
        let proof = await registry.prove(spam + [DyorCoinChain.qt])
        guard case .dyor(let qt)? = proof[DyorCoinChain.qt] else { return XCTFail("QT is proven among 100 others") }
        XCTAssertEqual(qt.symbol, "QT")
        XCTAssertEqual(Set(spam.map { proof[$0] }), [.notDyor])
        let batches = MomentsChainStub.batches()
        XCTAssertEqual(batches.first?.count, DyorCoinChain.stacks.count + DyorCoinChain.cohortTable.count, "the counts first")
        XCTAssertEqual(batches.dropFirst().filter { $0.count == 200 }.count, 3, "then 101 addresses asked of the 6 factories with coins: 606 calls, 200 a read")
        XCTAssertTrue(batches.allSatisfy { $0.count <= 200 })
        let asked = Set(batches.dropFirst().flatMap { $0 }.map(\.to))
        XCTAssertFalse(asked.contains(LaunchpadAddresses.monadMainnet.factory), "v2 has no launches yet: nothing to ask it")
        XCTAssertFalse(asked.contains(MomentsAddresses.monadMainnet.factory), "nor cohort 4")
    }

    /// MON and the curated tokens are never DyorHQ coins, and never asked.
    func testMONAndTheCuratedTokensAreNeverAsked() async {
        let registry = registry(.mainnet)
        let proof = await registry.prove([.zero, Monad.usdc, Monad.wmon])
        XCTAssertEqual(Set(proof.values), [.notDyor])
        XCTAssertTrue(MomentsChainStub.batches().isEmpty)
    }

    // MARK: Reading only what's new

    /// A second refresh reads each factory's count, then only the launches and Moments added since.
    func testARefreshReadsOnlyWhatIsNew() async throws {
        var chain = DyorCoinChain.mainnet
        let registry = registry(chain)
        await registry.refresh()
        let fresh = launch("0x0000000000000000000000000000000000000f00", "NEW")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [fresh]
        var late = moment("0x0000000000000000000000000000000000000f01", "LATE")
        late.creator = DyorCoinChain.owner
        chain.moments[DyorCoinChain.c3]?.append(late)
        chain.install()
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let batches = MomentsChainStub.batches()
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].count, DyorCoinChain.stacks.count + DyorCoinChain.cohortTable.count, "one count per factory")
        let lists = batches[1]
        XCTAssertEqual(lists.map(\.to), [LaunchpadAddresses.monadMainnet.factory, DyorCoinChain.c3], "v2's new launch, cohort 3's Moment #2 — nothing else")
        XCTAssertEqual(Set(batches[2].map(\.to)), [fresh.token, LaunchpadAddresses.monadMainnet.factory, late.coin, late.nft, DyorCoinChain.c3])
        let coins = await registry.all
        XCTAssertEqual(coins.count, 15)
        XCTAssertEqual(coins[late.coin]?.momentKey, MomentKey(factory: DyorCoinChain.c3, id: 2), "a Moment published on cohort 3 after its pin is read like any other")
        let own = await registry.coins(createdBy: DyorCoinChain.owner).map(\.symbol)
        XCTAssertEqual(Set(own), ["QT", "JUST", "NAT", "LATE"])

        chain.install()
        await registry.refresh()
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "nothing new: the counts alone")
    }

    /// A factory whose count stays below what was read (a fork restarted under the same file) for `lowerCountGrace` is
    /// read again from the start, and read on from there.
    func testACountBelowTheCheckpointIsReadAgainFromThere() async throws {
        let v2 = LaunchpadAddresses.monadMainnet.factory
        try store.save(DyorCoinStore.Snapshot(coins: [], checkpoints: [DyorCoinStore.Checkpoint(factory: v2, count: 5)]))
        var chain = DyorCoinChain()
        let first = launch("0x0000000000000000000000000000000000000f02", "ONE")
        chain.launches[v2] = [first]
        let registry = registry(chain, store: store)
        let start = Date()
        await registry.refresh(now: start)
        chain.install()
        await registry.refresh(now: start.addingTimeInterval(DyorCoinRegistry.lowerCountGrace))
        chain.launches[v2]?.append(launch("0x0000000000000000000000000000000000000f03", "TWO"))
        chain.install()
        await registry.refresh(now: start.addingTimeInterval(DyorCoinRegistry.lowerCountGrace + 1))
        let coins = await registry.all
        XCTAssertEqual(Set(coins.values.map(\.symbol)), ["ONE", "TWO"])
    }

    // MARK: Keeping it

    /// What was read is kept in the file and read back at the next start — before any read, which then asks only the
    /// counts. The file holds chain facts only, stays out of backups, and comes back byte for byte.
    func testTheRegistryIsKeptInItsFileAcrossStarts() async throws {
        let first = registry(.mainnet, store: store)
        await first.refresh()
        let read = await first.all

        MomentsChainStub.install { _, _ in nil }
        let next = DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
        let kept = await next.all
        XCTAssertEqual(kept, read)
        let qt = await next.coin(DyorCoinChain.qt)
        XCTAssertEqual(qt?.symbol, "QT")
        DyorCoinChain.mainnet.install()
        await next.refresh()
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "every factory's list was read before")

        XCTAssertEqual(store.url.lastPathComponent, "dyor-coins-143.json")
        XCTAssertEqual(DyorCoinStore.fileName(fork: true), "dyor-coins-143-fork.json")
        let values = try store.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.version, DyorCoinStore.Snapshot.currentVersion)
        XCTAssertEqual(snapshot.coins.count, 13)
        XCTAssertEqual(Set(snapshot.checkpoints.map(\.factory)), Set(DyorCoinChain.stacks.map(\.factory) + DyorCoinChain.cohortTable.map(\.factory)))
        XCTAssertEqual(snapshot.checkpoints.first { $0.factory == DyorCoinChain.legacy }?.count, 4)
        let bytes = try Data(contentsOf: store.url)
        try store.save(try JSONDecoder().decode(DyorCoinStore.Snapshot.self, from: bytes))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes, "the same set always writes the same bytes")
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"launch\"") && text.contains("\"generation\":\"legacy\"") && text.contains("\"kind\":\"moment\""))
    }

    /// A file from another build is read against this build's tables: a coin of a factory it doesn't read is dropped, and a
    /// stack or cohort retired since then reads as retired. A damaged file, or one of another version, is ignored.
    func testAKeptFileIsReadAgainstThisBuildsTables() throws {
        let v2 = LaunchpadAddresses.monadMainnet
        let stranger = Address(literal: "0x00000000000000000000000000000000f0f0f0f0")
        let coins = [
            DyorCoin(address: DyorCoinChain.qt, origin: .launch(factory: DyorCoinChain.legacy, generation: .v2, retired: false), symbol: "QT", name: "Quet", creator: DyorCoinChain.owner, logo: "", pair: .zero),
            DyorCoin(address: stranger, origin: .launch(factory: stranger, generation: .v2, retired: false), symbol: "X", name: "X", creator: stranger, logo: "", pair: .zero),
            DyorCoin(address: Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF"), origin: .moment(factory: DyorCoinChain.c3, id: 1, retired: false), symbol: "NAT", name: "Nature",
                     creator: DyorCoinChain.owner, logo: "", mediaHash: Data(count: 32), mediaIsVideo: true, pair: Monad.usdc),
        ]
        let snapshot = DyorCoinStore.Snapshot(coins: coins, checkpoints: [.init(factory: stranger, count: 3), .init(factory: v2.factory, count: 2)])
        let kept = DyorCoinRegistry.restored(snapshot, launchpads: DyorCoinChain.stacks, cohorts: DyorCoinChain.cohortTable,
                                             liveLaunchpad: v2.factory, liveCohort: MomentsAddresses.monadMainnet.factory)
        XCTAssertEqual(Set(kept.coins.keys), [DyorCoinChain.qt, coins[2].address])
        XCTAssertEqual(kept.coins[DyorCoinChain.qt]?.origin, .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true))
        XCTAssertEqual(kept.coins[coins[2].address]?.retired, true)
        XCTAssertEqual(kept.checkpoints, [v2.factory: 2])

        try Data("not json".utf8).write(to: store.url)
        XCTAssertNil(store.load())
        var other = snapshot
        other.version = 99
        try JSONEncoder().encode(other).write(to: store.url)
        XCTAssertNil(store.load())
        store.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        store.erase()
    }

    /// Account deletion: everything forgotten and the file deleted; a read already under way writes nothing back.
    func testEraseForgetsEverythingAndDeletesTheFile() async throws {
        let registry = registry(.mainnet, store: store)
        await registry.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        await registry.erase()
        let coins = await registry.all
        XCTAssertTrue(coins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        await registry.refresh()
        let again = await registry.all
        XCTAssertEqual(again.count, 13, "read again from the start")
    }

    // MARK: Ingest

    /// Launches and Moments another screen read are only a hint: each coin not known yet is proven from its factory's
    /// own record, so a hand-built `Launch` or `MomentInfo` — a fake token under a real factory, a real token under a fake
    /// one, the value's own name — admits nothing, and a coin already known isn't asked again.
    func testIngestProvesWhatItIsGivenAndAdmitsNothingElse() async throws {
        var chain = DyorCoinChain()
        let v2 = LaunchpadAddresses.monadMainnet.factory
        let real = launch("0x0000000000000000000000000000000000000d01", "REAL")
        chain.launches[v2] = [real]
        let sea = moment("0x0000000000000000000000000000000000000e01", "SEA")
        chain.moments[DyorCoinChain.c2] = [sea]
        let registry = registry(chain)
        func launchValue(_ token: Address, factory: Address) -> Launch {
            Launch(token: token, curve: Address(literal: "0x00000000000000000000000000000000000c02c0"), deployer: DyorCoinChain.owner, creatorFeeRecipient: DyorCoinChain.owner,
                   pairToken: Monad.usdc, graduationThreshold: 1, creatorTaxBps: 0, poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false, graduationVenue: .uniswapV4,
                   phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: Data(count: 32), name: "Doge", symbol: "狗狗",
                   logo: "https://tracker.example/d.jpg", description: "", socials: .none, pair: .mon, price: 0, realQuoteReserve: 0,
                   completed: false, rescued: false, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0, factory: factory)
        }
        let fake = Address(literal: "0x0000000000000000000000000000000000000d02")
        let stranger = Address(literal: "0x0000000000000000000000000000000000000d03")
        await registry.ingest([launchValue(real.token, factory: .zero), launchValue(fake, factory: v2), launchValue(fake, factory: DyorCoinChain.audit),
                               launchValue(stranger, factory: stranger), launchValue(Monad.usdc, factory: .zero)])
        let first = await registry.all
        XCTAssertEqual(Set(first.keys), [real.token], "only the coin a factory's record names")
        let admitted = try XCTUnwrap(first[real.token])
        XCTAssertEqual([admitted.symbol, admitted.name, admitted.logo], [real.symbol, real.name, real.logo], "as the chain has it, not as the value said")
        XCTAssertEqual(admitted.origin, .launch(factory: v2, generation: .v2, retired: false))
        let unasked = await registry.membership(stranger)
        XCTAssertEqual(unasked, .unknown, "a launch of a factory the registry doesn't read is never proven")
        let asked = await registry.membership(fake)
        XCTAssertEqual(asked, .notDyor, "a fake token under a real factory: every factory answered for it")

        MomentsChainStub.install { chain.answer($0, $1) }
        await registry.ingest([launchValue(real.token, factory: .zero)])
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "a coin already known isn't asked again")

        let provenance = MomentProvenance(mediaURI: "https://tracker.example/sea.jpg", mediaHash: Data(repeating: 1, count: 32), place: "", date: 0, animationURI: "")
        func info(_ coin: Address, id: BigUInt, factory: Address) -> MomentInfo {
            let moment = Moment(id: id, creator: DyorCoinChain.owner, platform: .zero, treasury: .zero, coin: coin, nft: coin, price: 1, threshold: 1, rateNum: 1, rateDen: 1,
                                creatorBps: 0, platformBps: 0, reserveBps: 0, creatorAllocBps: 0, expiryCreatorBps: 0, royaltyBps: 0, publishedAt: 0, deadline: 0, factory: factory)
            return MomentInfo(moment: moment, name: "Fake Sea", symbol: "FSEA", provenance: provenance,
                              ledger: MomentLedger(state: .collecting, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 0, creatorClaimable: 0, platformClaimable: 0,
                                                   treasuryClaimable: 0, totalGross: 0, collects: 0),
                              editions: 0, closed: false, entitlements: 0, graduated: false, progressBps: 0, pool: nil)
        }
        let fakeMoment = Address(literal: "0x0000000000000000000000000000000000000e02")
        await registry.ingest([info(sea.coin, id: 9, factory: DyorCoinChain.c2), info(fakeMoment, id: 1, factory: DyorCoinChain.c2), info(stranger, id: 1, factory: stranger)])
        let second = await registry.all
        let seaCoin = try XCTUnwrap(second[sea.coin])
        XCTAssertEqual(seaCoin.origin, .moment(factory: DyorCoinChain.c2, id: 1, retired: true), "the cohort's own id, not the value's")
        XCTAssertEqual([seaCoin.symbol, seaCoin.logo], [sea.symbol, sea.mediaURI])
        XCTAssertEqual(seaCoin.creator, sea.creator)
        XCTAssertNil(second[fakeMoment])
        XCTAssertNil(second[stranger])
    }

    /// A screen model following the registry gets the list at once, then again when a coin arrives.
    func testUpdatesFollowEveryChange() async throws {
        let registry = registry(.mainnet)
        let stream = await registry.updates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 0)
        await registry.refresh()
        let second = await iterator.next()
        XCTAssertEqual(second?.count, 13)
    }

    // MARK: Live (read-only; DYOR_LIVE_COINS=1)

    /// Monad mainnet, read-only, through rpc1 with a User-Agent, one Multicall3 read after another: every coin recorded in
    /// `DyorCoinChain.mainnet` is in the registry exactly as the fixture has it (a launch or Moment added since only adds
    /// to the list), every factory's list is read to its count, QT is proven by point proof too, and JAMES and an address
    /// no factory made are not DyorHQ's. Prints the counts per launchpad and cohort.
    func testLiveMainnetHoldsEveryRecordedCoin() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_COINS"] == "1" else { throw XCTSkip("set DYOR_LIVE_COINS=1") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "DyorHQ-build17-C2-readonly/1.0"]
        let rpc = RPCClient(url: URL(string: "https://rpc1.monad.xyz")!, session: URLSession(configuration: configuration))
        let registry = DyorCoinRegistry(rpc: rpc, store: store)
        let complete = await registry.refresh()
        let coins = await registry.all
        let checkpoints = await registry.checkpoints
        XCTAssertTrue(complete, "Monad RPC incomplete: \(coins.count) coins read")
        let names: [Address: String] = [LaunchpadAddresses.monadMainnet.factory: "launchpad v2 0x3B1f (live)", DyorCoinChain.relaunch: "launchpad 0x6B1C (retired, open)",
                                        DyorCoinChain.audit: "launchpad 0x10F3 (retired)", DyorCoinChain.preAudit: "launchpad 0x2F02 (retired)",
                                        DyorCoinChain.legacy: "launchpad 0xad3d (retired, legacy)", MomentsAddresses.monadMainnet.factory: "Moments c4 0x95eb (live)",
                                        DyorCoinChain.c3: "Moments c3 0x0FD4 (retired, open)", DyorCoinChain.c2: "Moments c2 0xc12B (retired)", DyorCoinChain.c1: "Moments c1 0x6469 (retired)"]
        for factory in DyorCoinChain.stacks.map(\.factory) + DyorCoinChain.cohortTable.map(\.factory) {
            let found = coins.values.filter { $0.factory == factory }.sorted { $0.symbol < $1.symbol }
            print("DYOR_LIVE \(names[factory] ?? factory.hex): count \(checkpoints[factory] ?? 0), registry \(found.count): \(found.map(\.symbol).joined(separator: ", "))")
            XCTAssertEqual(found.count, checkpoints[factory] ?? 0, "every coin \(names[factory] ?? factory.hex) lists is a DyorHQ coin")
        }
        let chain = DyorCoinChain.mainnet
        for (factory, launches) in chain.launches {
            for expected in launches {
                let coin = try XCTUnwrap(coins[expected.token], expected.symbol)
                XCTAssertEqual(coin.factory, factory)
                XCTAssertEqual([coin.symbol, coin.name, coin.logo], [expected.symbol, expected.name, expected.logo])
                XCTAssertEqual(coin.creator, expected.deployer)
                XCTAssertEqual(coin.pair, expected.pair)
                XCTAssertTrue(coin.retired)
            }
        }
        for (factory, moments) in chain.moments {
            for (index, expected) in moments.enumerated() {
                let coin = try XCTUnwrap(coins[expected.coin], expected.symbol)
                XCTAssertEqual(coin.origin, .moment(factory: factory, id: BigUInt(index + 1), retired: true))
                XCTAssertEqual([coin.symbol, coin.name, coin.logo], [expected.symbol, expected.name, expected.mediaURI])
                XCTAssertEqual(coin.creator, expected.creator)
                XCTAssertEqual(coin.mediaHash, expected.mediaHash)
                XCTAssertEqual(coin.mediaIsVideo, !expected.animationURI.isEmpty)
            }
        }
        let proving = DyorCoinRegistry(rpc: rpc)
        let nobody = Address(literal: "0x000000000000000000000000000000000000dEaD")
        let proof = await proving.prove([nobody, DyorCoinChain.james, DyorCoinChain.qt, Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")])
        XCTAssertEqual(proof[nobody], .notDyor)
        XCTAssertEqual(proof[DyorCoinChain.james], .notDyor, "JAMES is a nad.fun coin")
        XCTAssertEqual(proof[DyorCoinChain.qt], coins[DyorCoinChain.qt].map(DyorCoinRegistry.Membership.dyor))
        guard case .dyor(let nature)? = proof[Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")] else { return XCTFail("Nature, cohort 3's Moment, by point proof") }
        XCTAssertEqual(nature.momentKey, MomentKey(factory: DyorCoinChain.c3, id: 1))
        print("DYOR_LIVE total \(coins.count) coins; point proof: QT \(proof[DyorCoinChain.qt].map { "\($0)" } ?? "?"), JAMES \(proof[DyorCoinChain.james].map { "\($0)" } ?? "?"), 0x…dEaD \(proof[nobody].map { "\($0)" } ?? "?")")
    }

    /// Nothing is kept in UserDefaults: a key there with an earlier-install prefix turns App Lock off on a new install
    /// (`AppSettings.appLockDefault`, rule R4).
    func testTheRegistryKeepsNothingInUserDefaults() throws {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit
        folder.append(path: "Sources/DyorKit/Services/DyorCoins")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "DyorCoinStore.swift" })
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for use in ["UserDefaults.standard", "UserDefaults(", "@AppStorage", "NSUbiquitousKeyValueStore"] {
                XCTAssertFalse(source.contains(use), "\(file.lastPathComponent) uses \(use)")
            }
        }
    }
}
