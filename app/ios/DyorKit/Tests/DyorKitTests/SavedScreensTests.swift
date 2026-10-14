import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// What the money screens last showed is kept per wallet (`SavedScreens`) and painted at once, said to be saved, while the
/// screen reads everything again: never another wallet's, never one over a day old or dated ahead of the clock, never one
/// another build wrote, gone with an erase of this device's data — which no save read before it outlives — and nothing at
/// all on a fork. Then the app's wiring: every screen restores only its own wallet's file, saves only what it read in full
/// with the erase count from when its read began, labels what it shows from a save, and Home publishes each part as its
/// read lands.
final class SavedScreensTests: XCTestCase {
    private static let walletA = Address(literal: "0x00000000000000000000000000000000000000a1")
    private static let walletB = Address(literal: "0x00000000000000000000000000000000000000b2")
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "saved-screens-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func store(_ folder: URL?, build: String = "1.0-23", now: Date = SavedScreensTests.now) -> SavedScreens {
        SavedScreens(directory: folder, build: build, now: { now })
    }

    // MARK: The store

    func testAScreenSavedForAWalletOpensForThatWalletOnly() throws {
        let folder = directory()
        let saved = store(folder)
        saved.save(["one"], .home, wallet: Self.walletA, savedAt: Self.now.addingTimeInterval(-60), epoch: saved.epoch)
        saved.waitForSaves()
        let read = try XCTUnwrap(saved.load([String].self, .home, wallet: Self.walletA))
        XCTAssertEqual(read.value, ["one"])
        XCTAssertEqual(read.savedAt, Self.now.addingTimeInterval(-60), "said when it was read, not when it was opened")
        XCTAssertNil(saved.load([String].self, .home, wallet: Self.walletB), "never another wallet's")
        XCTAssertNil(saved.load([String].self, .home, wallet: nil), "nor a signed-out screen's")
        XCTAssertNil(saved.load([String].self, .portfolio, wallet: Self.walletA), "nor another screen's")
        XCTAssertEqual(store(folder).load([String].self, .home, wallet: Self.walletA)?.value, ["one"], "between launches")
        let file = folder.appending(path: SavedScreens.fileName(.home, wallet: Self.walletA))
        XCTAssertEqual(file.lastPathComponent, "home-\(Self.walletA.hex.lowercased()).json")
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertNil(saved.load([Int].self, .home, wallet: Self.walletA), "a file that isn't the shape asked for is none")
    }

    /// A file that names another wallet than its own name, as one copied over another's would, is never shown.
    func testAFileNamingAnotherWalletIsNeverShown() throws {
        let folder = directory()
        let saved = store(folder)
        saved.save(["b's"], .home, wallet: Self.walletB, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        try FileManager.default.moveItem(at: folder.appending(path: SavedScreens.fileName(.home, wallet: Self.walletB)),
                                         to: folder.appending(path: SavedScreens.fileName(.home, wallet: Self.walletA)))
        XCTAssertNil(saved.load([String].self, .home, wallet: Self.walletA))
    }

    func testOnlyTheBuildThatSavedAScreenShowsIt() {
        let folder = directory()
        let saved = store(folder, build: "1.0-22")
        saved.save(["old"], .launchBoard, wallet: nil, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        XCTAssertEqual(saved.load([String].self, .launchBoard, wallet: nil)?.value, ["old"])
        XCTAssertNil(store(folder, build: "1.0-23").load([String].self, .launchBoard, wallet: nil), "an update reads it all again")
    }

    /// A day-old screen is no starting point, and one dated ahead of the clock is never said to be newer than now.
    func testAScreenOverADayOldOrFromTheFutureIsNotShown() throws {
        XCTAssertTrue(SavedScreens.isShowable(savedAt: Self.now.addingTimeInterval(-SavedScreens.maxAge + 1), now: Self.now))
        XCTAssertFalse(SavedScreens.isShowable(savedAt: Self.now.addingTimeInterval(-SavedScreens.maxAge), now: Self.now))
        XCTAssertTrue(SavedScreens.isShowable(savedAt: Self.now.addingTimeInterval(SavedScreens.maxSkew), now: Self.now))
        XCTAssertFalse(SavedScreens.isShowable(savedAt: Self.now.addingTimeInterval(SavedScreens.maxSkew + 1), now: Self.now))

        let folder = directory()
        let saved = store(folder)
        saved.save([1], .portfolio, wallet: Self.walletA, savedAt: Self.now.addingTimeInterval(-25 * 3600), epoch: saved.epoch)
        saved.save([2], .momentsBoard, wallet: Self.walletA, savedAt: Self.now.addingTimeInterval(-23 * 3600), epoch: saved.epoch)
        saved.save([3], .myLaunchpad, wallet: Self.walletA, savedAt: Self.now.addingTimeInterval(120), epoch: saved.epoch)
        saved.save([4], .launchBoard, wallet: Self.walletA, savedAt: Self.now.addingTimeInterval(3600), epoch: saved.epoch)
        saved.waitForSaves()
        XCTAssertNil(saved.load([Int].self, .portfolio, wallet: Self.walletA), "25 hours old")
        XCTAssertEqual(saved.load([Int].self, .momentsBoard, wallet: Self.walletA)?.value, [2], "23 hours old")
        let skewed = try XCTUnwrap(saved.load([Int].self, .myLaunchpad, wallet: Self.walletA))
        XCTAssertEqual(skewed.savedAt, Self.now, "a clock set back a little: dated now, never in the future")
        XCTAssertNil(saved.load([Int].self, .launchBoard, wallet: Self.walletA), "an hour ahead of the clock")
    }

    /// An erase removes every screen of every wallet, and a save asked for by a read that began before it never lands.
    func testAnEraseRemovesEveryScreenAndNoEarlierReadIsSavedAfterIt() {
        let folder = directory()
        let saved = store(folder)
        saved.save(["a"], .home, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.save(["b"], .home, wallet: Self.walletB, savedAt: Self.now, epoch: saved.epoch)
        saved.save(["board"], .momentsBoard, wallet: nil, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        let readBefore = saved.epoch
        saved.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(saved.load([String].self, .home, wallet: Self.walletA))
        XCTAssertNil(saved.load([String].self, .home, wallet: Self.walletB))
        XCTAssertNil(saved.load([String].self, .momentsBoard, wallet: nil))
        saved.save(["late"], .home, wallet: Self.walletA, savedAt: Self.now, epoch: readBefore)
        saved.waitForSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "read before the erase: never written after it")
        saved.save(["new"], .home, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        XCTAssertEqual(saved.load([String].self, .home, wallet: Self.walletA)?.value, ["new"])
    }

    /// One screen's file removed (`remove`: the Portfolio's figures once the history they were built from is dropped) is
    /// gone for that screen and wallet only, and a save asked for before the removal — still waiting to be written — never
    /// lands after it; one asked for after it is written as any other.
    func testARemovedScreenIsGoneAndNoSaveAskedBeforeItLandsAfterIt() {
        let folder = directory()
        let saved = store(folder)
        saved.save(["a"], .portfolio, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.save(["b"], .portfolio, wallet: Self.walletB, savedAt: Self.now, epoch: saved.epoch)
        saved.save(["home"], .home, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        // Asked for before the removal, written after it unless dropped: the saves are held until the removal is done.
        let gate = DispatchSemaphore(value: 0)
        saved.holdSaves(until: gate)
        saved.save(["late"], .portfolio, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.remove(.portfolio, wallet: Self.walletA)
        XCTAssertNil(saved.load([String].self, .portfolio, wallet: Self.walletA), "gone at once")
        gate.signal()
        saved.waitForSaves()
        XCTAssertNil(saved.load([String].self, .portfolio, wallet: Self.walletA), "a save asked for before the removal never lands after it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: SavedScreens.fileName(.portfolio, wallet: Self.walletA)).path))
        XCTAssertEqual(saved.load([String].self, .portfolio, wallet: Self.walletB)?.value, ["b"], "another wallet's stays")
        XCTAssertEqual(saved.load([String].self, .home, wallet: Self.walletA)?.value, ["home"], "another screen's stays")
        saved.save(["new"], .portfolio, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        XCTAssertEqual(saved.load([String].self, .portfolio, wallet: Self.walletA)?.value, ["new"], "asked for after it: written")
        store(nil).remove(.portfolio, wallet: Self.walletA)
    }

    /// Saves land in the order asked: a newer one is never overwritten by an older one.
    func testSavesLandInTheOrderAsked() {
        let folder = directory()
        let saved = store(folder)
        for value in 0..<20 { saved.save([value], .home, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch) }
        saved.waitForSaves()
        XCTAssertEqual(saved.load([Int].self, .home, wallet: Self.walletA)?.value, [19])
    }

    /// A screen too big to keep isn't saved, and the older file goes with it: the screen never opens on something older
    /// than its last read.
    func testAScreenTooBigToSaveRemovesTheOlderOne() {
        let folder = directory()
        let saved = store(folder)
        saved.save(["small"], .launchBoard, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        XCTAssertNotNil(saved.load([String].self, .launchBoard, wallet: Self.walletA))
        saved.save([String(repeating: "a", count: SavedScreens.maxBytes)], .launchBoard, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        XCTAssertNil(saved.load([String].self, .launchBoard, wallet: Self.walletA))
    }

    func testAForkSavesNothing() {
        let saved = store(nil)
        saved.save(["one"], .home, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        XCTAssertNil(saved.load([String].self, .home, wallet: Self.walletA))
        saved.erase()
        XCTAssertEqual(saved.epoch, 1)
    }

    // MARK: What the screens save

    private static func launch(pairPrice: Double?) -> Launch {
        Launch(token: Address(literal: "0x00000000000000000000000000000000000c0e01"), curve: Address(literal: "0x00000000000000000000000000000000000c0e02"),
               deployer: walletA, creatorFeeRecipient: walletA, pairToken: Monad.usdc, graduationThreshold: BigUInt("12000000000"), creatorTaxBps: 100,
               poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: true, graduationVenue: .monday, phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0,
               poolId: Data(repeating: 7, count: 32), name: "\u{2068}שלום\u{2069}", symbol: "SHLM", logo: "https://example.com/l.png", description: "Line one\nLine two",
               socials: Socials(twitter: "x", website: "https://example.com"), pair: PairInfo(address: Monad.usdc, symbol: "USDC", decimals: 6, isNative: false),
               price: BigUInt("123456789012345678901234567890"), realQuoteReserve: 5_000_000, completed: false, rescued: false, launchedAt: 1_799_000_000,
               supply: BigUInt("1000000000000000000000000000"), marketCap: 1, progressBps: 4_200, factory: LaunchpadAddresses.monadMainnet.factory,
               generation: .v2, pairPrice: pairPrice)
    }

    private static func moment(pool: Bool) -> MomentInfo {
        let record = Moment(id: 3, creator: walletA, platform: walletB, treasury: walletB, coin: Address(literal: "0x00000000000000000000000000000000000c0e03"),
                            nft: Address(literal: "0x00000000000000000000000000000000000c0e04"), price: 1_000_000, threshold: 100_000_000, rateNum: 7, rateDen: 3,
                            creatorBps: 2_000, platformBps: 500, reserveBps: 7_500, creatorAllocBps: 600, expiryCreatorBps: 0, royaltyBps: 500,
                            publishedAt: 1_799_000_000, deadline: 1_801_000_000, factory: MomentsAddresses.retiredMainnet[0].factory)
        let key = PoolKey(currency0: Monad.usdc, currency1: record.coin, fee: 10_000, tickSpacing: 200, hooks: walletB)
        return MomentInfo(moment: record, name: "Sea", symbol: "SEA",
                          provenance: MomentProvenance(mediaURI: "ipfs://bafy", mediaHash: Data(repeating: 9, count: 32), place: "Lisbon", date: 1_798_000_000, animationURI: ""),
                          ledger: MomentLedger(state: pool ? .graduated : .collecting, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 75_000_000,
                                               creatorClaimable: 1, platformClaimable: 2, treasuryClaimable: 3, totalGross: 100_000_000, collects: 12),
                          editions: 12, closed: false, entitlements: BigUInt("4200000000000000000000"), graduated: pool, progressBps: 7_500,
                          pool: pool ? MomentPool(key: key, poolId: Data(repeating: 1, count: 32), usdcIs0: true, sqrtPriceX96: BigUInt("79228162514264337593543950336"),
                                                  openingSqrtPriceX96: BigUInt("79228162514264337593543950336"), liquidity: 5, seedLiquidity: 4, reserveSeed: 3,
                                                  poolCoins: 2, graduatedAt: 1_799_500_000, usdcPerCoin: 0.0123, creatorFees: 1, platformFees: 1, buybackFees: 0,
                                                  buybackCarry: 0, lastBuyback: 0, buybackInterval: 3_600, buybackMin: 1, heldForLaterRounds: nil, livePriceRead: false) : nil)
    }

    private struct ScreenTypes: Codable, Equatable {
        let launches: [Launch]
        let moments: [MomentInfo]
        let rows: [MomentPortfolioRow]
        let prices: [PriceInfo]
        let held: LaunchHoldings
        let escrows: [LaunchpadEscrowRead]
        let reads: [HomeReadState.Part: Date]
    }

    /// Every value a screen saves comes back exactly as it was shown: a launch's text as it was made safe to show (the
    /// isolate around right-to-left text kept), its generation and its price (or none), a Moment's record, media hash and
    /// pool, a holding's balances and the block they were read at, an escrow's balances.
    func testWhatTheScreensSaveComesBackExactly() throws {
        let folder = directory()
        let saved = store(folder)
        let coin = Self.launch(pairPrice: nil).token
        let value = ScreenTypes(
            launches: [Self.launch(pairPrice: 0.000_012_3), Self.launch(pairPrice: nil)],
            moments: [Self.moment(pool: true), Self.moment(pool: false)],
            rows: [MomentPortfolioRow(moment: Self.moment(pool: true), entitlement: 10, claimed: 1, claimableCollector: 2, claimableCreator: 3, nftBalance: 4,
                                      coinBalance: BigUInt("99999999999999999999999"), isCreator: true)],
            prices: [PriceInfo(usd: 0.98, change24h: nil, source: "DyorHQ curve", pairChange: 1.5, pairSymbol: "MON", isNew: true)],
            held: LaunchHoldings(balances: [coin: BigUInt("1120000000000000000000000")], rewards: [coin: 7], balancesUnread: [], rewardsUnread: [coin], block: 111_714_154),
            escrows: [LaunchpadEscrowRead(escrow: Self.walletB, factory: LaunchpadAddresses.monadMainnet.factory, retired: false,
                                          balances: EscrowBalances(native: 5, tokens: [Monad.usdc: 6]), kept: false),
                      LaunchpadEscrowRead(escrow: Self.walletA, factory: .zero, retired: true, balances: nil)],
            reads: [.spot: Self.now, .perps: Self.now.addingTimeInterval(-60)])
        saved.save(value, .myLaunchpad, wallet: Self.walletA, savedAt: Self.now, epoch: saved.epoch)
        saved.waitForSaves()
        let read = try XCTUnwrap(saved.load(ScreenTypes.self, .myLaunchpad, wallet: Self.walletA)).value
        XCTAssertEqual(read, value)
        XCTAssertNil(read.launches[1].pairPrice, "a coin without a price read stays unpriced")
        XCTAssertEqual(read.launches[0].generation, .v2)
        XCTAssertEqual(read.launches[0].name, "\u{2068}שלום\u{2069}", "its text as it was shown")
        XCTAssertEqual(read.moments[0].provenance.mediaHash, Data(repeating: 9, count: 32), "the hash its media is checked against")
        XCTAssertEqual(read.moments[0].pool?.livePriceRead, false)
    }

    // MARK: Home's parts

    /// A part saved when last read shows its figures, said to be saved, until a read of it answers; a part with nothing
    /// saved stays unread. Spot's figure still waits for the Launch and Moments tabs to have figures, read or saved.
    func testASavedPartShowsUntilItsReadAnswers() {
        var state = HomeReadState()
        state.showSaved([.spot, .launch, .perps])
        XCTAssertTrue(state.isSaved(.spot))
        XCTAssertTrue(state.hasFigures(.spot))
        XCTAssertFalse(state.isRead(.spot), "saved is not read")
        XCTAssertEqual(state.status(.spot), .reading)
        XCTAssertTrue(state.showsValue(of: .perps))
        XCTAssertTrue(state.showsValue(of: .launch))
        XCTAssertFalse(state.showsValue(of: .moments), "nothing saved: unread")
        XCTAssertFalse(state.showsValue(of: .spot), "Spot waits for Moments")
        XCTAssertEqual(HomeReadState.Part.allCases.filter(state.isSaved), [.spot, .perps, .launch])
        state.record(.moments, answered: true)
        XCTAssertTrue(state.showsValue(of: .spot))
        state.record(.spot, answered: true)
        state.record(.launch, answered: true)
        XCTAssertFalse(state.isSaved(.spot), "read now")
        XCTAssertTrue(state.isSaved(.perps))
        state.record(.perps, answered: true)
        XCTAssertEqual(HomeReadState.Part.allCases.filter(state.isSaved), [], "every part read in this session")
        XCTAssertTrue(HomeReadState.Part.allCases.allSatisfy(state.showsValue(of:)))
    }

    /// A saved part whose read fails keeps its saved figures, still said to be saved, and is failed too (its tab says so,
    /// with Retry); a part already read is never shown as saved again.
    func testASavedPartWhoseReadFailsKeepsItsFiguresAndSaysSo() {
        var state = HomeReadState()
        state.record(.moments, answered: true)
        state.showSaved([.moments, .spot])
        XCTAssertFalse(state.isSaved(.moments), "read in this session: never shown as saved")
        state.record(.spot, answered: false)
        XCTAssertTrue(state.isSaved(.spot))
        XCTAssertTrue(state.hasFigures(.spot))
        XCTAssertEqual(state.status(.spot), .failed)
        XCTAssertEqual(state.failed, [.spot])
        state.record(.spot, answered: true)
        XCTAssertFalse(state.isSaved(.spot))
        XCTAssertEqual(state.failed, [])
        XCTAssertNotEqual(state, HomeReadState())
    }

    // MARK: The app's wiring

    /// An erase of this device's data removes every saved screen of every wallet, and Delete Account and Forget This
    /// Device both erase through it.
    func testAnEraseOfThisDeviceRemovesEverySavedScreen() throws {
        let session = try DocsLinksTests.appSource("Wallet/Session.swift")
        let erase = try XCTUnwrap(session.range(of: "func eraseLocalData() async {"))
        let body = String(session[erase.upperBound...].prefix(6_000))
        XCTAssertTrue(body.contains("savedScreens?.erase()"))
        let signedOut = try XCTUnwrap(body.range(of: "state = .signedOut"))
        XCTAssertLessThan(try XCTUnwrap(body.range(of: "savedScreens?.erase()")).upperBound, signedOut.lowerBound)
        let env = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        XCTAssertTrue(env.contains("session.savedScreens = savedScreens"))
        XCTAssertTrue(env.contains("savedScreens = isFork ? SavedScreens(directory: nil, build: build) : SavedScreens.applicationSupport(build: build)"), "a fork saves none")
        let deletion = try DocsLinksTests.appSource("Profile/AccountDeletion.swift")
        XCTAssertEqual(deletion.components(separatedBy: "await session.eraseLocalData()").count - 1, 2, "Delete Account and Forget This Device")
    }

    /// Each screen restores only the file of the wallet it reads for, and saves with the erase count from when its read
    /// began, so nothing read for an erased account is saved after the erase.
    func testEveryScreenRestoresItsOwnWalletAndSavesWithTheEpochItsReadBeganAt() throws {
        let screens: [(file: String, restore: String, epoch: String, save: String)] = [
            ("Home/HomeView.swift", "env.savedScreens.load(Saved.self, .home, wallet: address)", "let epoch = env.savedScreens.epoch",
             "env.savedScreens.save(saved, .home, wallet: address, savedAt: newest, epoch: epoch)"),
            ("Portfolio/PortfolioModel.swift", "env.savedScreens.load(SavedFigures.self, .portfolio, wallet: address)", "loadEpoch = env.savedScreens.epoch",
             "savedScreens.save(figures, .portfolio, wallet: address, savedAt: newest, epoch: loadEpoch)"),
            ("Launchpad/LaunchpadView.swift", "env.savedScreens.load(Saved.self, .launchBoard, wallet: account)", "let epoch = env.savedScreens.epoch",
             "env.savedScreens.save(Saved(launches: launches, pairUSD: pairUSD, heldSellOnly: heldSellOnly), .launchBoard, wallet: account, savedAt: readAt, epoch: epoch)"),
            ("Moments/MomentsView.swift", "env.savedScreens.load(Saved.self, .momentsBoard, wallet: account)", "let epoch = env.savedScreens.epoch",
             "env.savedScreens.save(Saved(moments: list), .momentsBoard, wallet: account, savedAt: readAt, epoch: epoch)"),
            ("Launchpad/LaunchpadProfileView.swift", "env.savedScreens.load(Saved.self, .myLaunchpad, wallet: address)", "let epoch = env.savedScreens.epoch",
             "env.savedScreens.save(saved, .myLaunchpad, wallet: address, savedAt: began, epoch: epoch)"),
        ]
        for screen in screens {
            let source = try DocsLinksTests.appSource(screen.file)
            XCTAssertEqual(source.components(separatedBy: "env.savedScreens.load(").count - 1, 1, screen.file)
            XCTAssertTrue(source.contains(screen.restore), screen.file)
            XCTAssertTrue(source.contains(screen.save), screen.file)
            // The erase count is taken before the reads begin, never when the save is asked for.
            let epoch = try XCTUnwrap(source.range(of: screen.epoch), screen.file)
            XCTAssertLessThan(epoch.upperBound, try XCTUnwrap(source.range(of: screen.save)).lowerBound, screen.file)
        }
        // The Moments board follows the wallet signed in, so a sign-out or an erase restarts its reads (and, since build 23,
        // the app coming to the front: it polls only then).
        let moments = try DocsLinksTests.appSource("Moments/MomentsView.swift")
        XCTAssertTrue(moments.contains(".task(id: \"\\(session.address?.hex ?? \"\")-\\(scenePhase == .active)\") {\n"
                                       + "                guard scenePhase == .active else { return }\n"
                                       + "                await model.poll(env: env, account: session.address)\n"))
        XCTAssertTrue(moments.contains("if !Task.isCancelled { env.savedScreens.save("))
        let board = try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(board.contains("if listing.complete, held != nil, prices != nil, !Task.isCancelled, account == loadedFor {"), "the board saves only a full read")
        XCTAssertTrue(board.contains("guard launches.isEmpty, let saved"), "never over what this session read")
    }

    /// Whatever shows from a save says so ("Updated 3 min ago", `SavedLine`) until it is read again: on Home, the
    /// Portfolio, both boards and My Launchpad.
    func testEveryScreenSaysWhenWhatItShowsFromASaveWasRead() throws {
        let line = try DocsLinksTests.appSource("Design/Components.swift")
        XCTAssertTrue(line.contains("Text(\"Updated \\(date, style: .relative) ago\")"), "the Portfolio's own words")
        for (file, use) in [("Home/HomeView.swift", "SavedLine(date: date, reading: model.loading)"),
                            ("Home/HomeView.swift", "SavedLine(date: volumeSavedAt, reading: env.portfolio.loading)"),
                            ("Portfolio/PortfolioView.swift", "SavedLine(date: saved, reading: model.loading)"),
                            ("Launchpad/LaunchpadView.swift", "if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }"),
                            ("Launchpad/LaunchpadView.swift", "if model.savedAt == nil, let heldAt = model.heldSellOnlySavedAt { SavedLine(date: heldAt, reading: model.loading) }"),
                            ("Moments/MomentsView.swift", "if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }"),
                            ("Launchpad/LaunchpadProfileView.swift", "if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }")] {
            XCTAssertTrue(try DocsLinksTests.appSource(file).contains(use), file)
        }
        // Home's line beside the balance is its own parts' alone; Total Volume says its own under it, so a balance read
        // again is never said to be hours old for want of the Portfolio's heavier load.
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        XCTAssertTrue(home.contains("if let savedAt = model.savedAt { savedLine(savedAt) }"))
        XCTAssertTrue(home.contains("private var volumeSavedAt: Date? { liveVolume ? nil : env.portfolio.savedAt(router.period) }"))
        XCTAssertFalse(home.contains("[model.savedAt, liveVolume ? nil : env.portfolio.savedAt(router.period)]"))
        // The board's and the Moments' saved line goes once every launchpad was read, or the Moments were.
        XCTAssertTrue(try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift").contains("if listing.complete { savedAt = nil }"))
        XCTAssertTrue(try DocsLinksTests.appSource("Moments/MomentsView.swift").contains("if error != nil { error = nil }\n            if savedAt != nil { savedAt = nil }"))
    }

    /// No animation follows a saved line (build 23): one keyed to it animated everything that changed with it — the
    /// launches or Moments a read brought, the tab's first layout, `Paragraph`'s Korean words — and the Moments board's
    /// first opening after a launch drew the filter over its header, the subtitle's words scattered and its cards' titles
    /// twice. A line comes and goes with what it labels; where it would move the screen, it sits in a row it doesn't make
    /// taller: the Moments board's eyebrow, Home's balance beside Total Volume.
    func testNoSavedLineAnimatesTheScreen() throws {
        for file in ["Home/HomeView.swift", "Launchpad/LaunchpadView.swift", "Moments/MomentsView.swift", "Launchpad/LaunchpadProfileView.swift",
                     "Portfolio/PortfolioView.swift", "Moments/MomentDetailView.swift"] {
            let source = try DocsLinksTests.appSource(file)
            for pattern in [#"\.animation\([^)]*,\s*value:[^)]*[sS]avedAt"#, #"SavedLine\([^)]*\)\s*\.transition"#, #"savedLine\([^)]*\)\s*\.transition"#] {
                XCTAssertNil(source.range(of: pattern, options: .regularExpression), "\(file): \(pattern)")
            }
        }
        // The Moments board's line is in its eyebrow's row, never a row of its own above the filter.
        let moments = try DocsLinksTests.appSource("Moments/MomentsView.swift")
        let header = try XCTUnwrap(moments.range(of: "private var header: some View {"))
        // Centered on the eyebrow, never on its baseline: aligned so, the line (a spinner beside its text) hung below it.
        let eyebrow = try XCTUnwrap(moments.range(of: "HStack(spacing: 8) {\n                Text(\"MOMENTS\"", range: header.upperBound..<moments.endIndex))
        let line = try XCTUnwrap(moments.range(of: "if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }"))
        XCTAssertLessThan(eyebrow.upperBound, line.lowerBound)
        XCTAssertLessThan(line.upperBound, try XCTUnwrap(moments.range(of: "Text(\"Make your favorite moments last forever.\")")).lowerBound)
        XCTAssertEqual(moments.components(separatedBy: "SavedLine(").count - 1, 1)
        // Home's under the balance and its day's move, in the column beside Total Volume, never above the card.
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let hero = try XCTUnwrap(home.range(of: "private var heroCard: some View {"))
        let move = try XCTUnwrap(home.range(of: "ChangeBadge(value: unread ? 0 : model.change24h ?? 0)\n                    }\n                    .unreadFigure(unread)\n", range: hero.upperBound..<home.endIndex))
        XCTAssertTrue(home[move.upperBound...].hasPrefix("                    if let savedAt = model.savedAt { savedLine(savedAt) }\n                }\n                Spacer(minLength: 8)\n                totalVolume"))
        XCTAssertEqual(home.components(separatedBy: "savedLine(savedAt)").count - 1, 1)
        XCTAssertFalse(home.contains("if let savedAt = model.savedAt { savedLine(savedAt) }\n                    heroCard"))
    }

    /// Each screen takes in what was saved for the wallet before its first frame — in `onAppear`, which completes before
    /// the first frame is drawn, never animated — rather than in its load's task, which starts after that frame: a warm
    /// launch never paints placeholders or a spinner under figures the phone has. Each load does the same first, for a
    /// wallet that changed in place, and a sign-out clears what the environment's models hold of the last wallet.
    func testEveryScreenShowsWhatWasSavedInItsFirstFrame() throws {
        let screens: [(file: String, appear: String)] = [
            ("Home/HomeView.swift", "withTransaction(\\.disablesAnimations, true) {\n                    model.showSaved(env: env, address: session.address)\n                    env.portfolio.showSaved(env: env, address: session.address)\n                }"),
            ("Launchpad/LaunchpadView.swift", "withTransaction(\\.disablesAnimations, true) { model.showSaved(env: env, account: session.address) }"),
            ("Moments/MomentsView.swift", "withTransaction(\\.disablesAnimations, true) { model.showSaved(env: env, account: session.address) }"),
            ("Launchpad/LaunchpadProfileView.swift", "withTransaction(\\.disablesAnimations, true) { model.showSaved(env: env, address: address) }"),
        ]
        for screen in screens {
            let source = try DocsLinksTests.appSource(screen.file)
            let appear = try XCTUnwrap(source.range(of: ".onAppear {"), screen.file)
            let call = try XCTUnwrap(source.range(of: screen.appear), screen.file)
            XCTAssertLessThan(appear.upperBound, call.lowerBound, screen.file)
            XCTAssertLessThan(source.distance(from: appear.upperBound, to: call.lowerBound), 700, "\(screen.file): in the onAppear")
        }
        // Each load takes the wallet in through the same door first, so a wallet changed in place clears and restores too.
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        XCTAssertTrue(home.contains("func load(env: AppEnvironment, address: Address?) async {\n        loading = true\n        defer { loading = false }\n        // Already done before Home's first frame (`showSaved`), unless the account changed since.\n        showSaved(env: env, address: address)"))
        let show = try XCTUnwrap(home.range(of: "func showSaved(env: AppEnvironment, address: Address?) {"))
        let reset = try XCTUnwrap(home.range(of: "if address != loadedFor {\n            rows = []; launchHoldings = []; positions = []; perpEquity = nil; momentRows = []; updatedAt = nil; reads = HomeReadState(); readAt = [:]\n            loadedFor = address\n            restoreSaved(env: env, address: address)\n        }", range: show.upperBound..<home.endIndex))
        XCTAssertLessThan(home.distance(from: show.upperBound, to: reset.lowerBound), 600)
        let board = try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(board.contains("loading = true\n        defer { loading = false }\n        // Already done before the board's first frame (`showSaved`), unless the account changed since.\n        showSaved(env: env, account: account)"))
        let moments = try DocsLinksTests.appSource("Moments/MomentsView.swift")
        XCTAssertTrue(moments.contains("func showSaved(env: AppEnvironment, account: Address?) {\n        guard env.config.moments.isDeployed else { return }\n        restoreSaved(env: env, account: account)\n    }"))
        let profile = try DocsLinksTests.appSource("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(profile.contains("guard let address else {\n            reset()\n            return\n        }\n        // Already done before the sheet's first frame (`showSaved`), unless the wallet changed since.\n        showSaved(env: env, address: address)\n        loading = true"))
        // The Portfolio's saved figures, for Total Volume: only while nothing of the wallet is on hand, another wallet's
        // figures cleared first; and a sign-out, or another wallet, clears what it holds (RootView).
        let portfolio = try DocsLinksTests.appSource("Portfolio/PortfolioModel.swift")
        XCTAssertTrue(portfolio.contains("guard let address, loadedFor != address, loadingFor != address, savedFor != address else { return }\n        reset()\n        restoreSaved(env: env, address: address)"))
        XCTAssertTrue(portfolio.contains("let held = [loadedFor, loadingFor, savedFor].compactMap { $0 }\n        guard !held.isEmpty, !held.contains(where: { $0 == address }) else { return }\n        reset()"))
        XCTAssertTrue(portfolio.contains("saved = nil; lastSaved = nil; savedFor = nil"), "reset forgets whose figures were taken in")
        XCTAssertTrue(try DocsLinksTests.appSource("App/RootView.swift").contains("env.launchpadProfile.follow(session.address)\n            // So does the Portfolio, Total Volume's figures and those saved for the wallet among them.\n            env.portfolio.follow(session.address)"))
    }

    /// With nothing saved, a board shows its spinner until a read answers, never "No Moments yet" or "No Launches Yet" —
    /// not even in the frames before its first read's task starts (`BoardFirstRead`); a read that failed says so with
    /// Retry instead.
    func testABoardWithNothingReadIsLoadingNeverEmpty() throws {
        XCTAssertTrue(BoardFirstRead.isLoading(empty: true, answered: false, reading: false), "before the first read's task starts")
        XCTAssertTrue(BoardFirstRead.isLoading(empty: true, answered: false, reading: true))
        XCTAssertFalse(BoardFirstRead.isLoading(empty: true, answered: true, reading: false), "an answer: empty, or why it couldn't be read")
        XCTAssertTrue(BoardFirstRead.isLoading(empty: true, answered: true, reading: true), "read again, still empty")
        XCTAssertFalse(BoardFirstRead.isLoading(empty: false, answered: false, reading: true), "what is on screen stays")
        XCTAssertFalse(BoardFirstRead.isLoading(empty: false, answered: true, reading: true))

        let moments = try DocsLinksTests.appSource("Moments/MomentsView.swift")
        XCTAssertTrue(moments.contains("private var firstLoad: Bool { BoardFirstRead.isLoading(empty: model.moments.isEmpty, answered: model.listed, reading: model.loading) }"))
        XCTAssertTrue(moments.contains(".overlay { if firstLoad { ProgressView().controlSize(.large) } }"))
        XCTAssertTrue(moments.contains("if model.listed, model.error == nil || !model.moments.isEmpty { emptyState }"))
        XCTAssertFalse(moments.contains("if model.moments.isEmpty, model.loading { ProgressView()"))
        // Listed by a read that answered, the Moments or an error (never one cut short), or by a saved board shown.
        XCTAssertTrue(moments.contains("if moments != list { moments = list }\n            if !listed { listed = true }"))
        XCTAssertTrue(moments.contains("if !Task.isCancelled {\n                self.error = describe(error)\n                if !listed { listed = true }\n            }"))
        XCTAssertTrue(moments.contains("moments = saved.value.moments\n        listed = true\n        savedAt = saved.savedAt"))
        XCTAssertEqual(moments.components(separatedBy: "listed = true").count - 1, 3)

        let board = try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(board.contains("private var firstLoad: Bool { BoardFirstRead.isLoading(empty: model.launches.isEmpty, answered: model.listed, reading: model.loading) }"))
        XCTAssertTrue(board.contains("error = listing.firstError.map(describe)\n        if !listed { listed = true }"), "after a read that wasn't cut short")
        XCTAssertTrue(board.contains("savedAt = saved.savedAt\n        listed = true"))
        XCTAssertEqual(board.components(separatedBy: "listed = true").count - 1, 2)
    }

    /// The Portfolio saves a period's figures only once they are final — the load read everything, and the history has
    /// read the period's whole window, the chain reachable — never a part as the whole; shows saved ones only until its
    /// load lands; and shows placeholders, never $0.00, when it has neither.
    func testThePortfolioSavesOnlyFinalFiguresAndShowsPlaceholdersOtherwise() throws {
        let model = try DocsLinksTests.appSource("Portfolio/PortfolioModel.swift")
        XCTAssertTrue(model.contains("guard let address = loadedFor, hasLoaded, error == nil, !history.unreachable, history.read, let savedScreens else { return }"))
        XCTAssertTrue(model.contains("for period in VolumePeriod.allCases where history.covers(since: historyStart(period), scans: WalletHistoryScans.ids, now: now) {"))
        XCTAssertTrue(model.contains("figures.periods = figures.periods.filter { SavedScreens.isShowable(savedAt: $0.value.savedAt, now: now) }"), "each period under a day old")
        // Each final period is dated by the load its prices and Perpl fills come from, never by the history round that
        // saved it: a cold start never says "Updated 1 min ago" of hours-old prices.
        XCTAssertTrue(model.contains("let readAt = min(updatedAt ?? now, now)"))
        XCTAssertTrue(model.contains("periods[period.rawValue] = SavedFigures.Period(savedAt: readAt, sections:"))
        XCTAssertFalse(model.contains("SavedFigures.Period(savedAt: now, sections:"))
        // The saved figures stay until a load lands whole: one that left the prices or a launchpad unread after `reset`
        // counts what they price at $0.
        XCTAssertTrue(model.contains("func showsLive(_ period: VolumePeriod) -> Bool {\n        hasLoaded && (landedWhole || savedTotals(period) == nil)\n    }"))
        XCTAssertEqual(model.components(separatedBy: "landedWhole = true").count - 1, 1)
        XCTAssertTrue(model.contains("error = nil\n            updatedAt = .now\n            landedWhole = true"), "only a load with nothing unread")
        XCTAssertTrue(model.contains("hasLoaded = false; landedWhole = false;"), "another wallet starts again")
        let view = try DocsLinksTests.appSource("Portfolio/PortfolioView.swift")
        XCTAssertTrue(view.contains("private var live: Bool { model.showsLive(router.period) }"))
        XCTAssertTrue(view.contains("private var shownTotals: PortfolioModel.Stats? { live ? model.totals(router.period) : model.savedTotals(router.period) }"))
        XCTAssertTrue(view.contains("private var shownSavedAt: Date? { live ? nil : model.savedAt(router.period) }"))
        XCTAssertTrue(view.contains("live ? model.stats(section, router.period) : model.savedStats(section, router.period)"))
        XCTAssertTrue(view.contains("let perpsNote = live ? model.perpsNote : model.savedPerpsNote(router.period)"))
        XCTAssertFalse(view.contains("model.hasLoaded ? model.totals("))
        // A saved figure kept beside the load's error says both.
        XCTAssertTrue(view.contains("SavedLine(date: saved, reading: model.loading)\n                if let error = model.error, !model.loading {"))
        XCTAssertFalse(view.contains(".redacted(reason: model.loading && !model.hasLoaded"), "a placeholder whenever there is no figure, loading or not")
        XCTAssertGreaterThanOrEqual(view.components(separatedBy: ".unreadFigure(unread)").count - 1, 5)
        // Home's Total Volume: the Portfolio's once landed with the history read, else the saved one, else a placeholder.
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        XCTAssertTrue(home.contains("liveVolume ? env.portfolio.totals(router.period).volume : env.portfolio.savedTotals(router.period)?.volume"))
        XCTAssertTrue(home.contains("private var liveVolume: Bool { env.portfolio.showsLive(router.period) && (session.address == nil || env.history.snapshot.anchor != nil) }"))
        XCTAssertFalse(home.contains("env.portfolio.hasLoaded &&"))
        XCTAssertTrue(home.contains(".unreadFigure(volume == nil)"))
        // The header says why when the Portfolio's load left part of Total Volume unread, beside a saved one kept meanwhile.
        XCTAssertTrue(home.contains("error: model.error ?? volumeError"))
        XCTAssertTrue(home.contains("env.portfolio.historyUnreachable || env.portfolio.error != nil"))
    }

    /// A reset of the wallet's history — the owner's epoch raised, or the day's spot check finding the server's history
    /// wrong — drops the Portfolio's figures saved for the wallet, on the device and in the model, before the rounds start
    /// over: built on the history dropped, they were otherwise shown on Home and in the Portfolio for up to a day. None is
    /// saved again from a snapshot published before the reset, so the next round's save can't carry one back.
    func testAHistoryResetDropsThePortfoliosSavedFigures() throws {
        let history = try DocsLinksTests.appSource("Wallet/HistoryModel.swift")
        XCTAssertTrue(history.contains("func epochReset(env: AppEnvironment) {\n        restart(env: env)\n    }"))
        XCTAssertTrue(history.contains("guard await sync.spotCheck(wallet: wallet) == .mismatched, let self, self.wallet == wallet else { return }\n            restart(env: env)"))
        let restart = try XCTUnwrap(history.range(of: "    private func restart(env: AppEnvironment) {\n        guard let wallet else { return }\n        env.portfolio.dropSaved(env: env, for: wallet, historyVersion: version)\n"))
        let rerun = try XCTUnwrap(history.range(of: "run(env: env, wallet: wallet, fromStore: true, afterReset: true)", range: restart.upperBound..<history.endIndex))
        XCTAssertLessThan(restart.upperBound, rerun.lowerBound)

        let portfolio = try DocsLinksTests.appSource("Portfolio/PortfolioModel.swift")
        XCTAssertTrue(portfolio.contains("""
            func dropSaved(env: AppEnvironment, for wallet: Address, historyVersion version: Int) {
                env.savedScreens.remove(.portfolio, wallet: wallet)
                droppedThrough = max(droppedThrough ?? version, version)
                guard [loadedFor, loadingFor, savedFor].contains(where: { $0 == wallet }) else { return }
                saved = nil
                lastSaved = nil
            }
        """), "the file, what shows and what the next save starts from")
        // The figures saved next start from nothing of the dropped ones, and none is built on a snapshot from before.
        let save = try XCTUnwrap(portfolio.range(of: "    private func saveFigures() {"))
        let guarded = try XCTUnwrap(portfolio.range(of: "if let droppedThrough, historyVersion <= droppedThrough { return }", range: save.upperBound..<portfolio.endIndex))
        let carried = try XCTUnwrap(portfolio.range(of: "var periods = lastSaved?.periods", range: save.upperBound..<portfolio.endIndex))
        XCTAssertLessThan(guarded.upperBound, carried.lowerBound)
        XCTAssertEqual(portfolio.components(separatedBy: "historyVersion = version").count - 1, 1, "set only from a snapshot applied")
    }

    /// My Launchpad's saved escrows are marked as last read and its saved rewards not current, so Claim All never claims
    /// what was saved; it saves only a load that read every part.
    func testMyLaunchpadNeverClaimsWhatWasSaved() throws {
        let source = try DocsLinksTests.appSource("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(source.contains("balances: $0.balances, kept: true) }"))
        XCTAssertTrue(source.contains("return RewardClaim(launch: launch, amount: amount, current: !saved && !held.rewardsUnread.contains(coin))"))
        XCTAssertTrue(source.contains("var claimAllRewardClaimables: [RewardClaim] { rewardClaimables.filter(\\.current) }"))
        XCTAssertTrue(source.contains("if !unread, launchesRead, let held, held.complete {"))
        XCTAssertTrue(source.contains("savedParts = [.launches, .holdings, .escrows, .prices]"))
        for part in ["savedParts.remove(.launches)", "savedParts.remove(.holdings)", "savedParts.remove(.escrows)", "savedParts.remove(.prices)"] {
            XCTAssertTrue(source.contains(part), part)
        }
        // A saved launch opens by reference: its page reads it now, never showing the saved one as current.
        XCTAssertTrue(source.contains("if model.launchesSaved {\n            router.openLaunch(LaunchReference(token: launch.token, factory: launch.factory))"))
    }

    /// Home restores its saved parts only for the wallet it now reads, each under a day old, and saves the parts it has
    /// figures of with when each was read; the Perps positions are never saved, so that tab says "none" only once read.
    func testHomeRestoresAndSavesPartByPart() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let reset = try XCTUnwrap(home.range(of: "perpEquity = nil; momentRows = []; updatedAt = nil; reads = HomeReadState(); readAt = [:]"))
        let restore = try XCTUnwrap(home.range(of: "restoreSaved(env: env, address: address)", range: reset.upperBound..<home.endIndex))
        XCTAssertLessThan(reset.upperBound, restore.lowerBound, "another wallet's figures go before this one's saved ones show")
        XCTAssertTrue(home.contains("for (part, at) in saved.readAt where SavedScreens.isShowable(savedAt: at, now: now) {"))
        XCTAssertTrue(home.contains("let times = readAt.filter { reads.hasFigures($0.key) }"))
        XCTAssertTrue(home.contains("if model.reads.isRead(.perps) { holdingsEmpty(\"No open positions\""))
        // The saved launches are taken only while no launchpad was listed in this session, and then none counts as listed
        // until a read of it lands: a part kept from a copy up to a day old is never counted as read now, and its coins
        // open by reference.
        XCTAssertTrue(home.contains("if launches.isEmpty {\n                    launches = saved.launches\n                    listedFactories = []\n                }"))
        XCTAssertEqual(home.components(separatedBy: "launches = saved.launches").count - 1, 1)
        XCTAssertTrue(home.contains("record(.launch, answered: holdings != nil && priceMap != nil && listing.factories.allSatisfy(listedFactories.contains))"))
        // Balances shown from a save are the last ones read: a failed read says so beside them.
        XCTAssertTrue(home.contains("error = reads.hasFigures(.spot) ? tr(\"Your balances couldn't be read just now — showing the last ones read.\")"))
        // A token page shows the row it is given as current: a saved one opens with the token alone, read by the page.
        XCTAssertTrue(home.contains("model.reads.isSaved(.spot) ? MarketRow(token: row.token, usd: nil, change24h: nil, balance: 0) : row"))
        XCTAssertEqual(home.components(separatedBy: "NavigationLink(value: pageRow(row))").count - 1, 2, "Top Tokens and the holdings")
        XCTAssertFalse(home.contains("NavigationLink(value: row)"))
        let saved = try XCTUnwrap(home.range(of: "struct Saved: Codable, Sendable {"))
        let savedEnd = try XCTUnwrap(home.range(of: "}", range: saved.upperBound..<home.endIndex))
        XCTAssertFalse(home[saved.upperBound..<savedEnd.lowerBound].contains("positions"), "the positions aren't saved")
    }
}
