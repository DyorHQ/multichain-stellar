import BigInt
import CoreGraphics
import XCTest
@testable import DyorKit

/// Build 17: DyorHQ's coins in every screen — their pictures, their labels and the create guard. The rules are tested
/// here directly (`TokenPickerList`, `CoinIcon`, `SymbolSafety`, `LaunchImage`); the app's wiring of them is read from
/// its sources (R10: update these with the code they pin). A DyorHQ coin sent to the wallet is labelled for what it is
/// and is still what IOST-12 protects against: never where a send starts, never in Top Tokens, never funds arriving,
/// never in the picker's main list.
final class DyorCoinWiringTests: XCTestCase {
    private let creator = Address(literal: "0x6115cAF237026B45B037191B20056d1e4AfAfFa3")

    private func launchCoin(_ token: Token, logo: String = "") -> DyorCoin {
        DyorCoin(address: token.address, origin: .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), symbol: token.symbol,
                 name: token.name, creator: creator, logo: logo, pair: .zero)
    }

    // MARK: The rules

    /// A received DyorHQ coin keeps its DyorHQ label and stays out of the picker's main list, however much of it is held
    /// (held tokens float to the top); a search finds it in its own section, never under Unverified. A DyorHQ coin with a
    /// warning, and any other received token, is under Unverified. And it is never where a send starts.
    func testAReceivedDyorHQCoinNeverEntersThePickersMainList() {
        let qt = Token(address: DyorCoinChain.qt, symbol: "QT", name: "Quet", decimals: 18)
        let quack = Token(address: Address(literal: "0x0000000000000000000000000000000000000d01"), symbol: "QUACK", name: "Quack", decimals: 18)
        let fakeUSDC = Token(address: Address(literal: "0x0000000000000000000000000000000000000d02"), symbol: "USDC.e", name: "Quick Dollar", decimals: 6)
        let chosen = Token(address: Address(literal: "0x0000000000000000000000000000000000000d03"), symbol: "MEME", name: "Meme", decimals: 18)
        let coins = [qt.address: launchCoin(qt), fakeUSDC.address: launchCoin(fakeUSDC)]
        let isDyorHQ = { (token: Token) in TokenBadge.of(token, coin: coins[token.address], receivedUnasked: true).isDyorHQ }
        let universe = Token.core + [qt, quack, fakeUSDC, chosen]
        let received: Set<Address> = [qt.address, quack.address, fakeUSDC.address]
        let lots = BigUInt(10).power(30)
        let balances = [qt.address: lots, quack.address: lots, fakeUSDC.address: lots, chosen.address: 1]

        XCTAssertTrue(isDyorHQ(qt), "labelled DyorHQ Launch")
        for query in ["", "Q", "QT", "Quet"] {
            let main = TokenPickerList.main(universe, unverified: received, balances: balances, query: query, tradableOnly: true)
            XCTAssertFalse(main.contains(qt), "never in the main list: \(query)")
            XCTAssertTrue(main.allSatisfy { !received.contains($0.address) }, query)
        }
        XCTAssertEqual(TokenPickerList.main(universe, unverified: received, balances: balances, query: "", tradableOnly: true).first, chosen,
                       "a chosen token the wallet holds floats to the top")
        XCTAssertTrue(TokenPickerList.received(universe, unverified: received, query: "", excluding: nil, tradableOnly: true, isDyorHQ: isDyorHQ) == ([], []),
                      "only a search shows received tokens")
        let found = TokenPickerList.received(universe, unverified: received, query: "Q", excluding: nil, tradableOnly: true, isDyorHQ: isDyorHQ)
        XCTAssertEqual(found.dyorHQ, [qt], "its own section")
        XCTAssertEqual(found.unverified, [quack, fakeUSDC], "every other one, a DyorHQ look-alike included, under Unverified")
        XCTAssertTrue(TokenPickerList.received(universe, unverified: received, query: "Q", excluding: qt.address, tradableOnly: true, isDyorHQ: isDyorHQ).dyorHQ.isEmpty,
                      "not twice when a pasted address shows it")
        // Chosen in the app (a swap into it, or the wallet's own coin), it is listed like any other.
        XCTAssertTrue(TokenPickerList.main(universe, unverified: [], balances: balances, query: "", tradableOnly: true).contains(qt))

        let held = HeldToken(token: qt, balance: lots, usd: 1_000, unverified: true)
        XCTAssertEqual(held.badge(coins[qt.address]), .dyorLaunch)
        XCTAssertNil(WalletHoldings.defaultChoice([held]), "never preselected to send")
        XCTAssertEqual(WalletHoldings.defaultChoice([held, HeldToken(token: .usdc, balance: 1_000_000, usd: 1)])?.token, .usdc)
    }

    /// A bundled logo is a curated address's alone: a token that carries a curated token's symbol or name — a list token,
    /// a DyorHQ launch, one with a list logo of its own — never wears it.
    func testABundledLogoIsOnlyEverACuratedAddresss() {
        let policy = ImageSourcePolicy.dyorhq
        var n = 0
        for curated in Token.core where !curated.isNative {
            XCTAssertEqual(CoinIcon.resolve(curated, coin: nil, policy: policy), curated.logoURL == nil ? .letters : .bundled(symbol: curated.symbol))
            n += 1
            let address = Address(literal: "0x" + String(repeating: "0", count: 36) + String(format: "%04x", 0xe000 + n))
            let copy = Token(address: address, symbol: curated.symbol, name: curated.name, decimals: curated.decimals, logoURL: curated.logoURL)
            let kuru = Token(address: address, symbol: curated.symbol, name: "Anything", decimals: 18,
                             logoURL: URL(string: "https://dsvxs4ecepqgj.cloudfront.net/\(curated.symbol).png"))
            let launch = Token(address: address, symbol: curated.symbol, name: "A coin", decimals: 18, isLaunchpad: true)
            for token in [copy, kuru, launch] {
                for coin in [nil, launchCoin(launch, logo: DyorCoinChain.media(creator, "art.jpg"))] {
                    if case .bundled = CoinIcon.resolve(token, coin: coin, policy: policy) { XCTFail("\(curated.symbol) at \(address.hex) wears the curated logo") }
                }
            }
        }
        XCTAssertGreaterThan(n, 10)
        // A DyorHQ launch with any other symbol shows its own art, filled.
        let qt = Token(address: DyorCoinChain.qt, symbol: "QT", name: "Quet", decimals: 18)
        if case .remote(_, let fill) = CoinIcon.resolve(qt, coin: launchCoin(qt, logo: DyorCoinChain.media(creator, "qt.jpg")), policy: policy) {
            XCTAssertTrue(fill)
        } else {
            XCTFail("QT shows its art")
        }
    }

    /// The create forms' guard allows what their ticker filter lets through in the scripts the owner asked for, and refuses
    /// a curated or major token's name or a ticker that doesn't show as itself.
    func testTheCreateGuardKeepsAccentedLatinAndEastAsianTickers() {
        for symbol in ["QT", "CAFÉ", "PIÑA", "狗狗", "강아지", "ドージ", "PEPE2"] {
            XCTAssertNil(SymbolSafety.createRefusal(name: "My Coin", symbol: symbol), symbol)
            XCTAssertNil(SymbolSafety.createRefusal(name: "My Coin", symbol: symbol, maxName: SymbolSafety.maxMomentNameLength), symbol)
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "My Coin", symbol: "USDC"), .symbolImitates(.usdc))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Quiet", symbol: "Q\u{0422}"), .symbolNotDisplaySafe)
        XCTAssertEqual(SymbolSafety.createRefusal(name: String(repeating: "n", count: 33), symbol: "SAFE"), .nameTooLong(32))
        XCTAssertNil(SymbolSafety.createRefusal(name: String(repeating: "n", count: 33), symbol: "SAFE", maxName: SymbolSafety.maxMomentNameLength))
    }

    /// The uploaded launch picture is the photo's middle square.
    func testALaunchPictureIsTheMiddleSquare() {
        XCTAssertEqual(LaunchImage.side, 512)
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: 4000, height: 3000)), CGRect(x: 500, y: 0, width: 3000, height: 3000))
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: 300, height: 600)), CGRect(x: 0, y: 150, width: 300, height: 300))
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: 512, height: 512)), CGRect(x: 0, y: 0, width: 512, height: 512))
        XCTAssertEqual(LaunchImage.centreSquare(.zero), .zero)
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: CGFloat.nan, height: 10)), .zero)
    }

    // MARK: The app's wiring

    /// The app's sources (ios/DyorHQ), whitespace squeezed to single spaces, or a skip when this checkout has only the
    /// package.
    private static func app() throws -> URL {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return app
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private static func source(_ path: String) throws -> String {
        squeezed(try String(contentsOf: try app().appendingPathComponent(path), encoding: .utf8))
    }

    /// Every Swift file of the app, by its path under ios/DyorHQ, squeezed.
    private static func sources() throws -> [(path: String, text: String)] {
        let root = try app()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { file in
            (String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)), squeezed(try String(contentsOf: file, encoding: .utf8)))
        }
    }

    /// The text of `source` from `start` to `end`.
    private static func between(_ source: String, _ start: String, _ end: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), start)
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex), end)
        return String(source[from.lowerBound..<to.lowerBound])
    }

    /// Top Tokens and the Add funds card's "funds arriving" go by the token store's Unverified mark alone, which a DyorHQ
    /// label never changes: only the wallet's own coins are taken out of it, as chosen.
    func testAReceivedDyorHQCoinNeverRanksInTopTokensNorCountsAsArrivingFunds() throws {
        let home = try Self.source("Home/HomeView.swift")
        let model = try Self.between(home, "final class HomeModel {", "struct TokenDetailView: View {")
        let top = try Self.between(model, "func topTokens(_ tab: HomeTokenTab) -> [MarketRow] {", "private var discoveredFor")
        XCTAssertTrue(top.contains("let priced = rows.filter { $0.usd != nil && !unverified.contains($0.id) }"))
        XCTAssertFalse(top.contains("dyorCoins") || top.contains("badge"), "no label decides what ranks")
        // Set from the store's mark only: before the reads (each part is published as its read lands, so received tokens
        // never rank meanwhile), and again once the wallet's own coins were marked.
        XCTAssertEqual(model.components(separatedBy: "unverified = ").count - 1, 2, "set in two places")
        XCTAssertEqual(model.components(separatedBy: "unverified = KnownTokenStore.unverified(owner: address)").count - 1, 2, "both from the store's mark")
        XCTAssertFalse(model.contains("unverified.subtract") || model.contains("unverified.remove"))

        let funds = try Self.source("Home/AddFundsCard.swift")
        let read = try Self.between(funds, "private func read(env: AppEnvironment, address: Address, home: HomeModel)", "extension FirstFunding.Phase")
        XCTAssertTrue(read.contains("let unverified = KnownTokenStore.unverified(owner: address)"))
        XCTAssertTrue(read.contains("let tokens = KnownTokenStore.universe(owner: address).filter { !unverified.contains($0.address) }"))
        XCTAssertFalse(funds.contains("dyorCoins"), "no label makes a received coin funds arriving")

        // The Swap picker and Home's search list through `TokenPickerList`: received tokens only on a search.
        let swap = try Self.source("Swap/SwapView.swift")
        XCTAssertTrue(swap.contains("TokenPickerList.main(universe, unverified: unverified, balances: balances, query: query, tradableOnly: tradableOnly)"))
        XCTAssertTrue(swap.contains("TokenPickerList.received(universe, unverified: unverified, query: query, excluding: custom?.address, tradableOnly: tradableOnly) { env.dyorCoins.badge($0, receivedUnasked: true).isDyorHQ }"))
        XCTAssertTrue(swap.contains("Text(\"DyorHQ coins in your wallet\")"))
        XCTAssertTrue(swap.contains("Text(\"Unverified — in your wallet\")"))
    }

    /// Home's balances and prices never wait on the registry taking in the launches and Moments it read: those reads run
    /// on their own, one at a time, after the reads. The rows are published as their reads land, beside the proof of the
    /// wallet's tokens (whose labels follow as the coins model re-renders the rows), and only the own-coin mark waits for
    /// that proof: the reads, the proof among them, all answer before it.
    func testHomesRowsNeverWaitOnTheRegistrysIngests() throws {
        let home = try Self.source("Home/HomeView.swift")
        let load = try Self.between(home, "func load(env: AppEnvironment, address: Address?) async {", "/// One of `load`'s reads, as it answers.")
        let proof = try XCTUnwrap(load.range(of: "group.addTask { await env.dyorCoins.prove(tokens); return .proven }"))
        let rows = try XCTUnwrap(load.range(of: "if stands, balancesIn { publishSpot("))
        XCTAssertLessThan(proof.upperBound, rows.lowerBound, "the proof runs beside the reads, never ahead of the rows")
        let started = try XCTUnwrap(load.range(of: "if ingesting == nil { let readLaunches = launchList let readMoments = momentState?.map(\\.moment) ?? [] ingesting = Task { await env.dyorCoins.ingest(readLaunches) await env.dyorCoins.ingest(readMoments) ingesting = nil } }"))
        let own = try XCTUnwrap(load.range(of: "let ownCoins = address == nil ? [] : await env.dyorCoins.created(by: address ?? .zero)"))
        let publish = try XCTUnwrap(load.range(of: "guard !Task.isCancelled, address == loadedFor, let listing else { return }"))
        XCTAssertLessThan(rows.upperBound, started.lowerBound, "the rows never wait on an ingest")
        XCTAssertLessThan(started.upperBound, own.lowerBound)
        XCTAssertLessThan(own.upperBound, publish.lowerBound)
        XCTAssertEqual(load.components(separatedBy: "dyorCoins.ingest(").count - 1, 2, "only inside the task")
        XCTAssertTrue(home.contains("@ObservationIgnored private var ingesting: Task<Void, Never>?"))
    }

    /// Home marks the coins the registry says this wallet made as chosen through the helper the Portfolio and the Send
    /// sheet use, before it reads the Unverified mark it shows and ranks by.
    func testHomeMarksTheWalletsOwnCoinsThroughTheSharedHelper() throws {
        let home = try Self.source("Home/HomeView.swift")
        let load = try Self.between(home, "func load(env: AppEnvironment, address: Address?) async {", "/// The wallet's Moments stakes")
        let own = try XCTUnwrap(load.range(of: "let ownCoins = address == nil ? [] : await env.dyorCoins.created(by: address ?? .zero)"))
        let mark = try XCTUnwrap(load.range(of: "if let address { WalletTokens.markOwnCoins(ownCoins, among: tokens, owner: address) }"))
        let read = try XCTUnwrap(load.range(of: "unverified = KnownTokenStore.unverified(owner: address)", range: mark.upperBound..<load.endIndex))
        XCTAssertLessThan(own.upperBound, mark.lowerBound)
        XCTAssertLessThan(mark.upperBound, read.lowerBound, "marked before the mark is read")
        // The rows published before then carry the mark as the store has it already: received tokens never rank meanwhile.
        let early = try XCTUnwrap(load.range(of: "unverified = KnownTokenStore.unverified(owner: address)"))
        XCTAssertLessThan(early.upperBound, try XCTUnwrap(load.range(of: "await withTaskGroup(of: Answer.self)")).lowerBound)
        XCTAssertFalse(load.contains("KnownTokenStore.markChosen"), "no way of its own")

        let tokens = try Self.source("Wallet/WalletTokens.swift")
        let helper = try Self.between(tokens, "static func markOwnCoins(_ own: Set<Address>, among tokens: [Token], owner: Address) {", "/// DyorHQ's own coins among")
        XCTAssertTrue(helper.contains("for token in tokens where own.contains(token.address) { KnownTokenStore.add(token, owner: owner) KnownTokenStore.markChosen(token.address, owner: owner) }"))
        XCTAssertTrue(tokens.contains("markOwnCoins(ownCoins, among: read.tokens, owner: read.owner)"))
        XCTAssertEqual(tokens.components(separatedBy: "KnownTokenStore.markChosen").count - 1, 1, "the helper is the one way")

        let model = try Self.source("App/DyorCoinsModel.swift")
        XCTAssertTrue(model.contains("Set(await registry.coins(createdBy: owner).map(\\.address))"), "the coins the factories record it made")
    }

    /// Deleting the account (or this device's data) clears every image cache — the one image pipeline's, in memory and
    /// its folder in Caches, its warm-ups cancelled (synchronously: `ImagePipelineTests` erases it), and URLCache's, on
    /// disk — and Kuru's saved logo directory, and deletes the registry's file, before the sign-out. The registry's erase
    /// (a hop to its actor) runs before the wipe of the settings, so nothing suspends between the wipe and the sign-out: a
    /// Home load in flight can't resume for the erased wallet and write its token keys back.
    func testErasingThisDeviceClearsTheImageCachesAndTheRegistry() throws {
        let session = try Self.source("Wallet/Session.swift")
        let erase = try Self.between(session, "func eraseLocalData() async {", "private var relyingParty")
        let signedOut = try XCTUnwrap(erase.range(of: "state = .signedOut"))
        for step in ["RemoteImageLoader.shared.removeAll()", "URLCache.shared.removeAllCachedResponses()", "KuruTokenListClient.removeSavedLogos()",
                     "await dyorCoins?.erase()"] {
            let found = try XCTUnwrap(erase.range(of: step), step)
            XCTAssertLessThan(found.upperBound, signedOut.lowerBound, step)
        }
        // One pipeline for every picture, Moments' included, with its disk cache in Caches: no other image cache to forget.
        let files = try Self.sources()
        for file in files {
            XCTAssertFalse(file.text.contains("MomentMediaLoader"), file.path)
            XCTAssertFalse(file.text.contains("NSCache<"), "\(file.path): images are cached by the pipeline alone")
            XCTAssertFalse(file.text.contains("ImagePipeline(") && file.path != "Design/RemoteImage.swift", "\(file.path): one pipeline")
        }
        XCTAssertTrue(try Self.source("Design/RemoteImage.swift").contains("@MainActor static let shared = ImagePipeline(policy: .app, directory: ImageDiskCache.defaultDirectory)"))
        let wipe = try XCTUnwrap(erase.range(of: "WatchOnlyStore.clear()"))
        XCTAssertLessThan(try XCTUnwrap(erase.range(of: "await dyorCoins?.erase()")).upperBound, wipe.lowerBound, "the registry before the wipe")
        XCTAssertFalse(erase[wipe.lowerBound..<signedOut.lowerBound].contains("await"), "no suspension between the wipe and the sign-out")
        XCTAssertTrue(try Self.source("App/AppEnvironment.swift").contains("session.dyorCoins = dyorCoins"))
        let model = try Self.source("App/DyorCoinsModel.swift")
        XCTAssertTrue(try Self.between(model, "func erase() async {", "extension ImageSourcePolicy").contains("await registry.erase() coins = [:]"))
        // The pipeline's erase is synchronous and takes everything: the epoch first (nothing a load under way finishes is
        // kept), memory, the fetched bytes, both kinds of miss, every warm-up (cancelled, queued or under way), and the
        // folder.
        let pipeline = Self.squeezed(try String(contentsOf: try Self.app().deletingLastPathComponent()
            .appendingPathComponent("DyorKit/Sources/DyorKit/Core/ImagePipeline.swift"), encoding: .utf8))
        XCTAssertTrue(pipeline.contains("public func removeAll() { epoch.advance() memory.removeAllObjects() bytes.removeAllObjects() "
            + "misses = RecentMisses() prefetchMisses = RecentMisses() for warming in prefetching.values { warming.task.cancel() } prefetching = [:] "
            + "if let directory = disk.directory { ImageDiskCache.discardFiles(at: directory) } }"))
    }

    /// The image pipeline's disk index is read as the app starts, off the main thread, so pictures kept on the phone paint
    /// on a cold launch without waiting behind it; a new avatar is drawn from the bytes just uploaded, under the very link
    /// the profile shows; and a picture with no letters to stand in for it waits a moment before its spinner, so one kept
    /// on the phone never flashes one.
    func testPicturesKeptOrJustUploadedPaintWithoutASpinner() throws {
        let app = Self.squeezed(try Self.source("App/DyorHQApp.swift"))
        XCTAssertTrue(app.contains("Notifications.configure() // The image cache's index is read off the main thread now, before the first screen asks it for a picture. RemoteImageLoader.shared.prepare() return true"))
        let social = Self.squeezed(try Self.source("Social/SocialSession.swift"))
        let upload = try Self.between(social, "func uploadAvatar(jpeg: Data) async throws {", "/// A public DyorHQ profile row.")
        let seeded = try XCTUnwrap(upload.range(of: "if let shown = URL(string: updated.avatar_url ?? cacheBusted) { RemoteImageLoader.shared.seed(jpeg, for: [RemoteImageSource(url: shown)]) }"))
        XCTAssertLessThan(seeded.upperBound, try XCTUnwrap(upload.range(of: "profile = updated")).lowerBound, "seeded before the profile shows the new link")
        for path in ["Design/Components.swift", "Moments/MomentsUI.swift", "Launchpad/LaunchpadView.swift"] {
            XCTAssertTrue(try Self.source(path).contains("if loading { ZStack { Color(.tertiarySystemFill); ImageLoadingSpinner() } } else { placeholder }"), path)
        }
        XCTAssertTrue(try Self.source("Portfolio/AssetsModel.swift").contains("if loading { ImageLoadingSpinner() } else { Image(systemName: \"photo\").foregroundStyle(.secondary) }"))
        for file in try Self.sources() where file.text.contains("RemoteImage(") {
            XCTAssertFalse(Self.squeezed(file.text).contains("if loading { ProgressView()"), "\(file.path): a spinner at once")
            XCTAssertFalse(Self.squeezed(file.text).contains("if loading { ZStack { Color(.tertiarySystemFill); ProgressView()"), "\(file.path): a spinner at once")
        }
        let image = Self.squeezed(try Self.source("Design/RemoteImage.swift"))
        XCTAssertTrue(image.contains(".task { if await RemoteImageWait.graceElapses(RemoteImageWait.spinnerDelay) { spinning = true } }"))
        // The first frame: this picture's from memory whatever the view held; the stand-in only for this picture.
        XCTAssertTrue(image.contains("RemoteImageWait.drawn(held: image, heldKey: imageKey, key: key) { RemoteImageLoader.shared.memoryImage(sources, bucket: bucket)?.image }"))
        XCTAssertTrue(image.contains("RemoteImageWait.failed(failedKey: failedKey, key: key, hasURL: !sources.isEmpty) { RemoteImageLoader.shared.failedLately(sources, caps: caps) }"))
        // A miss is waited out once while the view is there, then asked again.
        XCTAssertTrue(image.contains("if let wait = loader.retryAfter(sources, caps: caps) { giveUp() guard !waited, await RemoteImageWait.graceElapses(.seconds(wait)) else { return } waited = true continue }"))
    }

    /// The registry erase deletes its file.
    func testTheRegistrysEraseDeletesItsFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "b2-erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DyorCoinStore(url: folder.appending(path: DyorCoinStore.fileName()))
        try store.save(DyorCoinStore.Snapshot(coins: [], checkpoints: [.init(factory: DyorCoinChain.legacy, count: 1)]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
        await registry.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(DyorCoinStore.fileName(), "dyor-coins-143.json")
    }

    /// The registry is made once, by `AppEnvironment`, and only `DyorCoinsModel` holds it. Its reads start from loads
    /// (Home's, the Portfolio's and the Send sheet's), a settled launch or publish, and RootView's foreground loop — never
    /// from a view appearing.
    func testTheRegistryIsMadeOnceAndNoViewAsksIt() throws {
        let files = try Self.sources()
        let made = files.filter { $0.text.contains("DyorCoinRegistry(") }
        XCTAssertEqual(made.map(\.path), ["App/AppEnvironment.swift"])
        XCTAssertEqual(made.first?.text.components(separatedBy: "DyorCoinRegistry(").count, 2, "once")
        XCTAssertTrue(made.first?.text.contains("DyorCoinRegistry(rpc: rpc, live: config.launchpad, liveMoments: config.moments, store: .applicationSupport(fork: isFork))") == true)
        let model = try Self.source("App/DyorCoinsModel.swift")
        XCTAssertTrue(model.contains("@ObservationIgnored private let registry: DyorCoinRegistry"), "no one else can ask it")
        for file in files where file.path != "App/DyorCoinsModel.swift" {
            XCTAssertFalse(file.text.contains("DyorCoinRegistry") && file.path != "App/AppEnvironment.swift", file.path)
        }

        // Where each read starts.
        let reads = ["dyorCoins.prove(", "dyorCoins.ingest(", "dyorCoins.created(", "dyorCoins.refresh(", "dyorCoins.keepFresh(", "coins.refresh("]
        var where_: [String: Int] = [:]
        for file in files {
            for read in reads { where_[file.path, default: 0] += file.text.components(separatedBy: read).count - 1 }
        }
        XCTAssertEqual(where_.filter { $0.value > 0 }.keys.sorted(), ["App/RootView.swift", "Home/HomeView.swift", "Launchpad/LaunchpadView.swift",
                                                                     "Moments/CreateMomentView.swift", "Portfolio/AssetsModel.swift", "Wallet/WalletTokens.swift"])
        let home = try Self.source("Home/HomeView.swift")
        let homeModel = try Self.between(home, "final class HomeModel {", "struct TokenDetailView: View {")
        for read in reads { XCTAssertEqual(home.components(separatedBy: read).count, homeModel.components(separatedBy: read).count, "Home reads only in its model's load: \(read)") }
        let assets = try Self.source("Portfolio/AssetsModel.swift")
        let assetsModel = try Self.between(assets, "final class AssetsModel {", "struct AssetsCard: View {")
        XCTAssertEqual(assets.components(separatedBy: "dyorCoins.").count, assetsModel.components(separatedBy: "dyorCoins.").count)
        let root = try Self.source("App/RootView.swift")
        XCTAssertTrue(root.contains(".task(id: scenePhase == .active) { if scenePhase == .active { await env.dyorCoins.keepFresh() } }"))
        XCTAssertTrue(model.contains("await registry.refreshIfStale(maxAge: Self.refreshInterval)"))
        XCTAssertTrue(model.contains("static let refreshInterval: TimeInterval = 300"))
        for path in ["Launchpad/LaunchpadView.swift", "Moments/CreateMomentView.swift"] {
            let text = try Self.source(path)
            let settled = try XCTUnwrap(text.range(of: "Task { [coins = env.dyorCoins] in await coins.refresh() }"), path)
            let completed = try XCTUnwrap(text.range(of: "onCompleted: { hash in", options: .backwards, range: text.startIndex..<settled.lowerBound), path)
            XCTAssertLessThan(text.distance(from: completed.upperBound, to: settled.lowerBound), 800, "in the settle hook: \(path)")
        }
    }

    /// Every Monad token's logo is decided by its address (`TokenLogo(token:)` through `CoinIcon`); a symbol-keyed logo is
    /// Perps' and Bridge's alone (`MarketLogo`). Launch and Moment artwork load through `ImageSourcePolicy`. News and NFT
    /// art stay as they are under Smart Invert.
    func testEveryTokenLogoIsByAddress() throws {
        let files = try Self.sources()
        for file in files {
            XCTAssertFalse(file.text.contains("TokenLogo(symbol:"), file.path)
            XCTAssertFalse(file.text.contains("UnverifiedBadge()") && !file.path.hasPrefix("Portfolio/AssetsModel.swift"), "tokens show TokenBadgeView: \(file.path)")
            if file.text.contains("MarketLogo(symbol:") {
                XCTAssertTrue(file.path.hasPrefix("Perps/") || file.path.hasPrefix("Bridge/"), file.path)
            }
        }
        let components = try Self.source("Design/Components.swift")
        let logo = try Self.between(components, "struct TokenLogo: View {", "struct MarketLogo: View {")
        XCTAssertTrue(logo.contains("switch env?.dyorCoins.icon(token) ?? CoinIcon.resolve(token, coin: nil, policy: .app) {"))
        let bundled = try XCTUnwrap(logo.range(of: "case .bundled(let symbol):"))
        let named = try XCTUnwrap(logo.range(of: "UIImage(named: \"logo-\\(symbol)\")"))
        XCTAssertLessThan(bundled.upperBound, named.lowerBound)
        XCTAssertLessThan(named.lowerBound, try XCTUnwrap(logo.range(of: "case .remote(let sources, let fill):")).lowerBound, "only for a curated address")
        XCTAssertTrue(logo.contains("RemoteImage(sources: sources, pointSize: size, contentMode: fill ? .fill : .fit, grace: RemoteImageWait.grace)"))
        XCTAssertEqual(components.components(separatedBy: "UIImage(named: \"logo-").count - 1, 2, "TokenLogo's curated case and MarketLogo")
        let assets = try Self.source("Portfolio/AssetsModel.swift")
        XCTAssertTrue(assets.contains("if unverified { UnverifiedBadge() }"), "kept for NFTs")
        XCTAssertTrue(assets.contains(".accessibilityIgnoresInvertColors() // art"))
        XCTAssertTrue(try Self.source("News/NewsView.swift").contains(".accessibilityIgnoresInvertColors() // a photo"))

        let launchpad = try Self.source("Launchpad/LaunchpadView.swift")
        let artwork = try Self.between(launchpad, "struct LaunchArtwork: View {", "private var placeholder")
        XCTAssertTrue(artwork.contains("let sources = ImageSourcePolicy.app.creatorSources(logo).map { RemoteImageSource(url: $0) }"))
        XCTAssertFalse(artwork.contains("URL(string: logo)"), "never the launcher's own host")
        let moments = try Self.source("Moments/MomentsUI.swift")
        let momentSources = try Self.between(moments, "static func imageSources(provenance: MomentProvenance, creator: Address?) -> [RemoteImageSource] {", "private var placeholder")
        XCTAssertTrue(momentSources.contains("policy.momentSources(mediaURI: provenance.mediaURI, mediaHash: provenance.mediaHash, isVideo: !provenance.animationURI.isEmpty, creator: creator)"))
        XCTAssertTrue(momentSources.contains("policy.creatorSources(provenance.mediaURI)"))
        XCTAssertFalse(momentSources.contains("gatewayURLs"), "never the creator's own host")
        // A Moment's art loads through the same pipeline as every picture, at the size of the frame it is drawn in, under
        // the full caps (a photo's checked original), and the share preview reads the page's artwork from it.
        let artworkView = try Self.between(moments, "struct MomentArtwork: View {", "static func imageSources(")
        XCTAssertTrue(artworkView.contains("static let caps = RemoteMedia.caps(forThumbnail: ImageSizeBucket.largest)"))
        XCTAssertTrue(artworkView.contains("GeometryReader { frame in let side = max(frame.size.width, frame.size.height)"))
        XCTAssertTrue(artworkView.contains("RemoteImage(sources: Self.imageSources(provenance: provenance, creator: creator), pointSize: side, caps: Self.caps)"))
        XCTAssertTrue(try Self.source("Moments/MomentLinkView.swift").contains("RemoteImageLoader.shared.memoryImage(sources, bucket: ImageSizeBucket.largest)"))
        XCTAssertTrue(try Self.source("App/AppEnvironment.swift").contains("policy: ImageSourcePolicy(supabaseURL: config.supabaseURL))"))
    }

    /// The Moments and Launch boards warm their next rows' pictures as each card comes on screen (`BoardPrefetch`), with
    /// the very sources, size bucket and caps the card will ask for, through the one pipeline — which asks only DyorHQ's
    /// hosts and the gateways for a picture nobody is looking at yet (`ImagePipelineTests`).
    func testTheBoardsWarmTheirNextRows() throws {
        let moments = try Self.source("Moments/MomentsView.swift")
        XCTAssertTrue(moments.contains("ForEach(shown) { info in card(info) .buttonStyle(.plain) .onAppear { prefetch(after: info) } }"))
        // Each card the board draws, opening the Moment as read, or its link while the board shows what it saved.
        XCTAssertTrue(moments.contains("if model.savedAt != nil, let link = MomentLink(key: info.key) { NavigationLink(value: link) { MomentCard(info: info) } } "
                                       + "else { NavigationLink(value: info) { MomentCard(info: info) } }"))
        XCTAssertTrue(moments.contains(".onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }"))
        XCTAssertTrue(moments.contains("private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]"), "two columns, 12 pt apart")
        XCTAssertTrue(moments.contains("let side = (gridWidth - 12) / 2 for next in BoardPrefetch.following(info.id, in: shown) { MomentArtwork.prefetch(next, side: side) }"))
        let ui = try Self.source("Moments/MomentsUI.swift")
        XCTAssertTrue(ui.contains(".overlay { MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: info.moment.creator) }"), "the card, a column wide")
        XCTAssertTrue(ui.contains("RemoteImageLoader.shared.prefetch(imageSources(provenance: info.provenance, creator: info.moment.creator), bucket: ImageSizeBucket.bucket(points: side), caps: caps)"))
        let launchpad = try Self.source("Launchpad/LaunchpadView.swift")
        XCTAssertEqual(launchpad.components(separatedBy: "{ LaunchCard(launch: launch) } .buttonStyle(.plain) .onAppear { prefetch(after: launch, in: coins) }").count - 1, 2,
                       "every section's grid")
        XCTAssertEqual(launchpad.components(separatedBy: "{ LaunchCard(launch: launch) }").count - 1, 2)
        XCTAssertTrue(launchpad.contains("for next in BoardPrefetch.following(launch.id, in: coins) { LaunchArtwork.prefetch(logo: next.logo) }"))
        XCTAssertTrue(launchpad.contains(".overlay { LaunchArtwork(symbol: launch.symbol, logo: launch.logo) }"), "the card at the card's size")
        XCTAssertTrue(launchpad.contains("var pointSize: CGFloat = LaunchArtwork.cardPointSize"))
        let warm = try Self.between(launchpad, "static func prefetch(logo: String) {", "var body: some View {")
        XCTAssertTrue(warm.contains("let bucket = ImageSizeBucket.bucket(points: cardPointSize)"))
        XCTAssertTrue(warm.contains("RemoteImageLoader.shared.prefetch(ImageSourcePolicy.app.creatorSources(logo).map { RemoteImageSource(url: $0) }, bucket: bucket, caps: RemoteMedia.caps(forThumbnail: bucket))"))
        let artwork = try Self.between(launchpad, "var body: some View { Group { let sources = ImageSourcePolicy.app.creatorSources(logo)", "private var placeholder")
        XCTAssertTrue(artwork.contains("RemoteImage(sources: sources, pointSize: pointSize) {"), "the card's caps come from its size, as the warm-up's")
    }

    /// The token page shows the coin's logo at 44 pt, and for a DyorHQ coin where it was launched in place of the
    /// Unverified card; a look-alike keeps its warning, before anything else.
    func testTheTokenPageSaysWhereADyorHQCoinWasLaunched() throws {
        let home = try Self.source("Home/HomeView.swift")
        let page = try Self.between(home, "struct TokenDetailView: View {", "struct PriceChart: View {")
        XCTAssertTrue(page.contains("TokenLogo(token: row.token, size: 44)"))
        XCTAssertTrue(page.contains("private var badge: TokenBadge { env.dyorCoins.badge(row.token, receivedUnasked: received) }"))
        let imitation = try XCTUnwrap(page.range(of: "if badge.isImitation, let title = badge.title {"))
        let dyorHQ = try XCTUnwrap(page.range(of: "} else if badge.isDyorHQ, let coin = env.dyorCoins.coin(row.token.address) { launchedOnDyorHQ(coin) }"))
        let unverified = try XCTUnwrap(page.range(of: "} else if received || badge == .unverified {"))
        XCTAssertLessThan(imitation.upperBound, dyorHQ.lowerBound)
        XCTAssertLessThan(dyorHQ.lowerBound, unverified.lowerBound, "a DyorHQ coin never shows the Unverified card")
        let section = try Self.between(page, "private func launchedOnDyorHQ(_ coin: DyorCoin) -> some View {", "private var launchPhase")
        for part in ["AddressRow(title: \"Creator\", address: coin.creator)", "if let link = MomentLink(key: key) {", "router.pendingMomentLink = link",
                     "router.openLaunch(LaunchReference(token: coin.address, factory: coin.factory))", "Text(\"Launched on DyorHQ\")"] {
            XCTAssertTrue(section.contains(part), part)
        }
    }

    /// The create forms say the guard's refusal under the field it is about and keep Review off; a launch's name is held to
    /// 32 characters, a Moment's to 48. The upload is the middle 512-pixel square, under the object name migration 26 pins.
    func testTheCreateFormsSayTheGuard() throws {
        let launchpad = try Self.source("Launchpad/LaunchpadView.swift")
        let create = try Self.between(launchpad, "struct CreateLaunchView: View {", "private struct LaunchPreviewCard")
        XCTAssertTrue(create.contains("SymbolSafety.createRefusal(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, maxName: SymbolSafety.maxLaunchNameLength)"))
        XCTAssertTrue(create.contains("private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && symbolValid && refusal == nil }"))
        XCTAssertTrue(create.contains(".onChange(of: name) { _, v in if v.count > SymbolSafety.maxLaunchNameLength { name = String(v.prefix(SymbolSafety.maxLaunchNameLength)) } }"))
        XCTAssertTrue(create.contains(".onChange(of: symbol) { _, v in symbol = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }"))
        XCTAssertTrue(create.contains(".disabled(!valid || blocker != nil)"))
        XCTAssertTrue(create.contains("let jpeg = image.launchJPEG() else {"))
        XCTAssertTrue(create.contains("logo = try await social.uploadLaunchImage(jpeg: jpeg).absoluteString"))
        let moment = try Self.source("Moments/CreateMomentView.swift")
        XCTAssertTrue(moment.contains("SymbolSafety.createRefusal(name: trimmedName, symbol: symbol, maxName: SymbolSafety.maxMomentNameLength)"))
        XCTAssertTrue(moment.contains("symbolValid && refusal == nil &&"))
        XCTAssertTrue(moment.contains(".disabled(!valid || !session.canSign)"))
        for form in [create, moment] {
            XCTAssertTrue(form.contains("if let refusal, !refusal.isAboutSymbol { InlineError(message: refusal.message) }"))
            XCTAssertTrue(form.contains("if let refusal, refusal.isAboutSymbol { InlineError(message: refusal.message) }"))
        }
        let components = try Self.source("Design/Components.swift")
        XCTAssertTrue(components.contains("let crop = LaunchImage.centreSquare(size)"))
        XCTAssertTrue(components.contains("UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)"))
    }
}
