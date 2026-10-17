// Stellar Portfolio (docs/DESIGN-stellar-parity.md §8.12.1; decision 6): the figures are /v1/portfolio's for each period
// with the network fees apart, saved figures show until a read and go at sign-out, nothing shows while the history needs a
// sign-in, a section header lands on its Stellar tab or side, Activity keeps the server's list, My Holdings lists every
// held token and edition with the retired v1 ones said to be, and the source rules Portfolio keeps.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarPortfolioTests: XCTestCase {
    private let owner = Address(data: Data(repeating: 4, count: 20))!
    private let stellar = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH"
    /// The retired v1 Moments contract, as the pins name it ("moments").
    private let v1Moments = "CCWP4LEV74P26RQ44EG4BBC2BD66YMDTFTR4UNCEINOSXEMG2GQA2YIR"
    /// A v2 Moment's own NFT contract.
    private let v2Nft = "CDOYEDV4D3XQ7IP6R2SQXR5IIQYQRYLIVV53XSPTFKSNHUE22QKQ2JFT"

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// StellarKit's API fixture `name` (ios/Packages/StellarKit/Tests/LiteClientTests/Fixtures), read from this checkout:
    /// the answers the client is held to.
    private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtureURL(name)))
    }

    nonisolated fileprivate static func fixtureURL(_ name: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // StellarPortfolioTests.swift → Tests → Internal → ios → app → S
        return root.appending(path: "ios/Packages/StellarKit/Tests/LiteClientTests/Fixtures/\(name)")
    }

    private func fixtureURL(_ name: String) -> URL { Self.fixtureURL(name) }

    private func temporarySaved() -> StellarSaved {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stellar-portfolio-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return StellarSaved(screens: SavedScreens(directory: folder, build: "test"))
    }

    private func model(_ saved: StellarSaved, stellar: String? = nil) -> StellarPortfolioModel {
        let model = StellarPortfolioModel(saved: saved)
        model.showSaved(owner: owner, stellar: stellar ?? self.stellar)
        return model
    }

    /// `/v1/portfolio` over `period`, every section's figures `volume` apart (a past bridge's too, which the server's
    /// totals count), read `asOf`.
    private func portfolio(_ period: String, volume: Double, asOf: Date = Date().addingTimeInterval(-120)) throws -> StellarPortfolio {
        func stats(_ v: Double) -> String {
            #"{"volume": \#(v), "fees": 0.5, "pnl": -1.25, "claimedFees": 0.25, "trades": 3, "pnlComplete": false, "networkFeesXlm": "1500000", "networkFeesUsd": 0.03}"#
        }
        return try decode(StellarPortfolio.self, """
            {"period": "\(period)", "since": null, "asOf": "\(ISO8601DateFormatter().string(from: asOf))",
             "pricing": {"kind": "reference", "source": "Kraken", "network": "mainnet", "note": null},
             "totals": \(stats(volume * 5)), "sections": {"spot": \(stats(volume)), "earn": \(stats(volume)), "launch": \(stats(volume)),
             "moments": \(stats(volume)), "bridge": \(stats(volume))},
             "activity": [], "coverage": {"from": null, "note": null}}
            """)
    }

    /// Waits until the account's Portfolio is saved with `periods` periods (saves are written off the main thread).
    private func waitForSave(_ saved: StellarSaved, periods: Int) async throws {
        for _ in 0..<300 {
            if let file = saved.load(StellarPortfolioModel.Saved.self, .portfolio, owner: owner)?.value, file.periods.count == periods { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Portfolio was never saved")
    }

    // MARK: - Figures

    func testTheFiguresAreTheServersForThePeriodAndNetworkFeesStayApart() throws {
        let read = try fixture(StellarPortfolio.self, "portfolio.json")
        let figures = StellarPortfolioModel.Figures(read)
        // The totals are the four sections': the server's, less its Bridge's (a completed transfer in the fixture).
        let bridge = read.sections.bridge
        XCTAssertGreaterThan(bridge.volume, 0)
        XCTAssertEqual(figures.totals.volume, read.totals.volume - bridge.volume, accuracy: 1e-9)
        XCTAssertEqual(figures.totals.fees, read.totals.fees - bridge.fees, accuracy: 1e-9, "Fees paid is the server's: DyorHQ's fees only")
        XCTAssertEqual(figures.totals.pnl, read.totals.pnl - bridge.pnl, accuracy: 1e-9)
        XCTAssertEqual(figures.totals.claimedFees, read.totals.claimedFees - bridge.claimedFees, accuracy: 1e-9)
        XCTAssertEqual(figures.totals.trades, read.totals.trades - bridge.trades)
        XCTAssertEqual(figures.totals.pnlComplete, read.totals.pnlComplete)
        XCTAssertEqual(figures.totals.networkFeesStroops, try XCTUnwrap(Int64(read.totals.networkFeesXlm)) - (Int64(bridge.networkFeesXlm) ?? 0),
                       "network fees in XLM, on their own line")
        XCTAssertEqual(StellarPortfolioModel.totals(read), figures.totals, "Home's Total Volume is Portfolio's")
        for section in StellarPortfolioModel.Section.allCases {
            let server = section.stats(read.sections)
            let shown = try XCTUnwrap(figures.stats(section), section.rawValue)
            XCTAssertEqual(shown.volume, server.volume, section.rawValue)
            XCTAssertEqual(shown.fees, server.fees, section.rawValue)
            XCTAssertEqual(shown.pnl, server.pnl, section.rawValue)
            XCTAssertEqual(shown.claimedFees, server.claimedFees, section.rawValue)
            XCTAssertEqual(shown.trades, server.trades, section.rawValue)
            XCTAssertEqual(shown.networkFeesStroops, Int64(server.networkFeesXlm), section.rawValue)
        }
        XCTAssertEqual(StellarPortfolioModel.Section.allCases.map(\.rawValue), ["spot", "earn", "launch", "moments"],
                       "Monad's sections, Earn in Perps' place and no Bridge: Stellar doesn't have one for now")
        XCTAssertNil(figures.sections["bridge"], "nothing of the Bridge is kept or saved")
    }

    func testEachPeriodShowsItsOwnRead() throws {
        let model = model(temporarySaved())
        let week = try portfolio("week", volume: 2)
        let all = try portfolio("all", volume: 7)
        XCTAssertNil(model.shown(.week, live: nil, status: .unread), "nothing read or saved: placeholders, never $0.00")
        let shownWeek = try XCTUnwrap(model.shown(.week, live: week, status: .read))
        XCTAssertEqual(shownWeek.figures.totals.volume, 8, "the four sections: the server's Bridge isn't counted")
        XCTAssertNil(shownWeek.savedAt, "this session's figures")
        XCTAssertEqual(model.shown(.all, live: all, status: .read)?.figures.totals.volume, 28)
        XCTAssertEqual(model.shown(.all, live: all, status: .failed)?.figures.totals.volume, 28, "a failed read keeps the last figures read")
    }

    // MARK: - Saved figures and sign-in

    func testSavedFiguresShowUntilAReadAndGoAtSignOut() async throws {
        let saved = temporarySaved()
        let first = model(saved)
        first.take([.week: try portfolio("week", volume: 2), .all: try portfolio("all", volume: 7)])
        try await waitForSave(saved, periods: 2)

        // A cold launch: each period's figures are there before any read, said to be saved.
        let relaunched = model(saved)
        let week = try XCTUnwrap(relaunched.shown(.week, live: nil, status: .unread))
        XCTAssertEqual(week.figures.totals.volume, 8)
        XCTAssertEqual(week.figures.stats(.earn)?.volume, 2)
        XCTAssertNotNil(week.savedAt, "a SavedLine says when they were read")
        XCTAssertNil(relaunched.shown(.day, live: nil, status: .unread), "a period never read has none")
        // A read replaces them: no longer said to be saved.
        XCTAssertNil(relaunched.shown(.week, live: try portfolio("week", volume: 3), status: .read)?.savedAt)

        // Another Stellar account under the same Monad account sees none of them.
        XCTAssertNil(model(saved, stellar: "GBQ4LKCDNTRJWJTWV2WOUO5M3HKFQGZTRRJMWPJ5YRHJ5AM2ZYQB7ZKD").shown(.week, live: nil, status: .unread))

        // Sign-out: the file goes, and the figures on screen with it.
        saved.forget(owner)
        relaunched.forget()
        XCTAssertNil(relaunched.shown(.week, live: nil, status: .unread))
        XCTAssertNil(model(saved).shown(.all, live: nil, status: .unread))
    }

    func testAHistoryThatNeedsASignInShowsNoFigures() async throws {
        let saved = temporarySaved()
        let first = model(saved)
        let week = try portfolio("week", volume: 2)
        first.take([.week: week])
        try await waitForSave(saved, periods: 1)
        // A passkey account whose session is gone: the hero stays unread, with the sign-in row, whatever was read or saved.
        let relaunched = model(saved)
        XCTAssertNil(relaunched.shown(.week, live: nil, status: .needsSignIn))
        XCTAssertNil(relaunched.shown(.week, live: week, status: .needsSignIn))
        let source = try source("StellarPortfolioView.swift")
        XCTAssertTrue(source.contains("if status == .needsSignIn { StellarSignInRow() }"), "the row sits under the hero's volume")
        XCTAssertTrue(source.contains("if status != .needsSignIn {"), "no activity to read without the sign-in")
        XCTAssertFalse(source.contains("actions.signIn()"), "nothing prompts until the row's button is tapped")
    }

    /// Acceptance 5, against a Lite server: a passkey account whose refresh token was revoked opens Portfolio in the public
    /// view. The history waits for the sign-in with no prompt, the holdings fill in with v1's coins said to be Retired,
    /// and the load after the row's sign-in reads the figures and the activity the rows are worded from.
    func testAPasskeyAccountWithARevokedRefreshTokenIsAskedNothingUntilItSignsIn() async throws {
        URLProtocol.registerClass(PortfolioStub.self)
        defer { URLProtocol.unregisterClass(PortfolioStub.self) }
        let server = try PortfolioServer()
        let prompts = PromptCount()
        let signer = try StellarSigner(seed: (0..<32).map { _ in UInt8.random(in: 0...255) })
        let address = signer.address
        defer { server.stop(); Self.forget(address) }
        // Set up on this iPhone; its saved session has ended, and the server refuses its refresh token.
        UserDefaults.standard.set(true, forKey: LiteSession.activatedKey(address))
        try StellarKeychain.saveSession(token: "jwt-ended", expiresAt: Date().addingTimeInterval(-3600), refreshToken: "lrt_revoked",
                                        refreshExpiresAt: Date().addingTimeInterval(86_400), account: address, network: "testnet")
        let keys = PhraseKeyProvider(address: address, methodLabel: "Passkey") { _ in
            prompts.add()
            throw LiteSession.Failure.cancelled
        }
        let session = LiteSession(env: server.env, stellarAddress: address, monad: nil, keys: keys, setupKey: { _ in
            prompts.add()
            return LiteSession.UnlockResult(keys: keys, signer: signer)
        })
        await session.resumeAtLaunch()
        XCTAssertEqual(server.paths.filter { $0.contains("/v1/auth/") }, ["POST /v1/auth/refresh"], "refused, and no sign-in: that needs the passkey")
        XCTAssertEqual(session.access, .publicView)
        let store = try XCTUnwrap(session.store)

        // Portfolio opens, then the period changes: the hero stays unread with the sign-in row, and the holdings fill in.
        let model = self.model(temporarySaved(), stellar: address)
        await model.load(store, period: .week, force: false)
        await model.load(store, period: .month, force: false)
        XCTAssertEqual(prompts.value, 0, "nothing prompts until the row is tapped")
        XCTAssertEqual(store.status(.portfolio), .needsSignIn)
        XCTAssertEqual(store.status(.activity), .needsSignIn)
        XCTAssertNil(model.shown(.week, live: store.portfolio[.week], status: store.status(.portfolio)), "the sign-in row in the figures' place")
        XCTAssertTrue(StellarPortfolioModel.waitsForSignIn(store))
        XCTAssertEqual(store.holdings?.view, "public")
        XCTAssertEqual(StellarPortfolioModel.assets(store.holdings).map(\.id), StellarPortfolioModel.assets(try fixture(StellarHoldings.self, "holdings.public.json")).map(\.id))
        XCTAssertEqual(model.retiredCoins, [PortfolioServer.coin], "a v1 coin says Retired with no session: its own page says so")
        let history = ["GET /v1/portfolio", "GET /v1/activity", "GET /v1/launchpad/me", "POST /v1/auth/challenge"]
        XCTAssertEqual(server.paths.filter(history.contains), [], "no history read is even asked")
        XCTAssertEqual(server.paths.filter { $0 == "GET /v1/launches/\(PortfolioServer.coin)" }.count, 1, "once per session")

        // The row's button: one passkey prompt. The load it brings reads the history it waited for, activity included.
        try await session.signIn()
        XCTAssertEqual(prompts.value, 1)
        XCTAssertEqual(session.access, .session)
        XCTAssertTrue(StellarPortfolioModel.waitsForSignIn(store), "so Portfolio reads again")
        await model.load(store, period: .week, force: false)
        XCTAssertEqual(store.status(.portfolio), .read)
        XCTAssertEqual(store.status(.activity), .read, "read again too: its rows are worded in the app's language")
        XCTAssertEqual(store.activity.map(\.id), try fixture(ActivityPage.self, "activity.json").items.map(\.id))
        let shown = try XCTUnwrap(model.shown(.week, live: store.portfolio[.week], status: store.status(.portfolio)))
        XCTAssertEqual(shown.figures.totals, StellarPortfolioModel.totals(try fixture(StellarPortfolio.self, "portfolio.json")))
        XCTAssertNil(shown.savedAt, "this session's figures")
        XCTAssertFalse(StellarPortfolioModel.waitsForSignIn(store))
        XCTAssertEqual(prompts.value, 1, "the reads ask nothing more")
    }

    private struct ActivityPage: Decodable { let items: [StellarActivityItem] }

    /// What a run left on this iPhone for `address`: its saved session and its setup notes.
    private static func forget(_ address: String) {
        StellarKeychain.erase(account: address)
        UserDefaults.standard.removeObject(forKey: LiteSession.activatedKey(address))
        UserDefaults.standard.removeObject(forKey: LiteSession.signedOutKey(address))
    }

    // MARK: - Section headers

    func testASectionHeaderLandsOnItsStellarTabOrSide() {
        let expected: [(StellarPortfolioModel.Section, StellarTab, StellarTradeMode?)] = [
            (.spot, .earn, .swap), (.earn, .earn, .earn), (.launch, .launch, nil), (.moments, .moments, nil),
        ]
        for (section, tab, mode) in expected {
            let router = Router()
            router.network = .stellar
            router.stellarAvailable = true
            router.stellarIsSetUp = { true }
            router.stellarTab = tab == .home ? .launch : .home
            router.stellarTradeMode = mode == .swap ? .earn : .swap
            router.presented = .portfolio
            router.open(section.menuItem)
            XCTAssertEqual(router.network, .stellar, section.rawValue)
            XCTAssertEqual(router.stellarTab, tab, section.rawValue)
            if let mode { XCTAssertEqual(router.stellarTradeMode, mode, section.rawValue) }
            XCTAssertNil(router.presented, "\(section.rawValue): over the tabs, nothing else")
        }
        XCTAssertEqual(StellarPortfolioModel.Section.earn.title, MenuItem.earnTitle)
        XCTAssertEqual(StellarPortfolioModel.Section.spot.title, PortfolioModel.Section.spot.title, "Monad's names")
    }

    // MARK: - Activity

    func testActivityIsTheServersListInItsOrder() throws {
        let read = try fixture(StellarPortfolio.self, "portfolio.json")
        let rows = StellarPortfolioModel.rows(read)
        XCTAssertEqual(rows.map(\.id), read.activity.map(\.id))
        XCTAssertEqual(read.activity.map(\.section), ["launch", StellarPortfolioModel.pastBridge])
        // A past bridge stays, as plain history: in no section (so no card or total counts it), Monad's Bridge mark, and
        // worded as Recent Activity words it.
        XCTAssertEqual(rows.map(\.section), [.launch, nil])
        XCTAssertEqual(rows.map(\.symbol), [PortfolioModel.Section.launch.symbol, PortfolioModel.Section.bridge.symbol])
        XCTAssertEqual(rows.map(\.sectionTitle), [PortfolioModel.Section.launch.title, PortfolioModel.Section.bridge.title])
        let pastBridge = try XCTUnwrap(rows.first { $0.section == nil }, "a past bridge's row")
        let bridge = try XCTUnwrap(try fixture(ActivityPage.self, "activity.json").items.first { $0.id == pastBridge.id })
        XCTAssertEqual(StellarActivityPresenter.present(bridge).title, .bridged(code: "USDC"), "Bridged USDC")
        XCTAssertTrue(rows.allSatisfy { $0.time != nil })
        XCTAssertEqual(read.coverage.note, "Swaps made outside DyorHQ between non-launch assets aren't counted.", "shown verbatim under Activity")

        let other = try decode(StellarPortfolio.self, """
            {"period": "all", "since": null, "asOf": "2026-10-15T09:41:00.000Z",
             "pricing": {"kind": "reference", "source": "Kraken", "network": "mainnet", "note": null},
             "totals": \(Self.zero), "sections": {"spot": \(Self.zero), "earn": \(Self.zero), "launch": \(Self.zero), "moments": \(Self.zero), "bridge": \(Self.zero)},
             "activity": [{"id": "a", "section": "account", "kind": "trust", "title": "Enabled USDC", "subtitle": null, "at": "2026-10-15T09:00:00.000Z", "usd": null, "hash": null},
                          {"id": "b", "section": "spot", "kind": "swap", "title": "Swapped", "subtitle": "XLM → USDC", "at": "2026-10-15T08:00:00.000Z", "usd": 1.5, "hash": "ab"},
                          {"id": "c", "section": "cash", "kind": "deposit", "title": "Transaction", "subtitle": null, "at": "2026-10-15T07:00:00.000Z", "usd": 2, "hash": null},
                          {"id": "d", "section": "bridge", "kind": "stellar_to_monad", "title": "Bridged USDC", "subtitle": "Stellar → Monad", "at": "2026-10-15T06:00:00.000Z", "usd": 3, "hash": "cd"}],
             "coverage": {"from": null, "note": null}}
            """)
        XCTAssertEqual(StellarPortfolioModel.rows(other).map(\.id), ["b", "d"], "only the four sections' items, and a past bridge's")
        XCTAssertTrue(StellarPortfolioModel.rows(nil).isEmpty)
    }

    private static let zero = #"{"volume": 0, "fees": 0, "pnl": 0, "claimedFees": 0, "trades": 0, "pnlComplete": true, "networkFeesXlm": "0", "networkFeesUsd": 0}"#

    // MARK: - My Holdings

    func testMyHoldingsListsEveryHeldTokenTheMostValuableFirst() throws {
        let holdings = try fixture(StellarHoldings.self, "holdings.json")
        let assets = StellarPortfolioModel.assets(holdings)
        XCTAssertEqual(assets.map(\.code), ["XLM", "ECAT", "USDC", "AQUA"], "Spot and launch coins together, by value; unpriced last")
        XCTAssertEqual(StellarPortfolioModel.tokensValue(holdings) ?? 0, 1906.2295 + 9.48, accuracy: 1e-9, "the server's Spot and Launch totals")
        XCTAssertEqual(StellarPortfolioModel.unpricedCodes(assets), ["AQUA"], "an unverified asset has no price, and the total says so")
        XCTAssertTrue(StellarPortfolioModel.assets(nil).isEmpty)

        let partial = try fixture(StellarHoldings.self, "holdings.partial.json")
        XCTAssertEqual(partial.parts["launch"], "failed")
        XCTAssertNil(StellarPortfolioModel.tokensValue(partial), "a part that failed: no total passed off as the whole")
    }

    func testRetiredEditionsAndCoinsAreSaidToBe() throws {
        func edition(_ contract: String?) throws -> StellarEdition {
            try decode(StellarEdition.self, """
                {"tokenId": 7, "momentId": 3, "title": "Harbour", "mediaUrl": null, "posterUrl": null, "mediaType": "image",
                 "contract": \(contract.map { "\"\($0)\"" } ?? "null")}
                """)
        }
        let v1 = try edition(v1Moments)
        let v2 = try edition(v2Nft)
        let older = try edition(nil)
        XCTAssertTrue(StellarPortfolioModel.isRetired(v1, v1Moments: [v1Moments]))
        XCTAssertFalse(StellarPortfolioModel.isRetired(v2, v1Moments: [v1Moments]))
        XCTAssertTrue(StellarPortfolioModel.isRetired(older, v1Moments: [v1Moments]), "an edition with no contract is from before v2")
        XCTAssertEqual(StellarPortfolioModel.destination(v1, v1Moments: [v1Moments]), .moment(id: 3), "a retired Moment by its number")
        XCTAssertEqual(StellarPortfolioModel.destination(v2, v1Moments: [v1Moments]), .momentV2(nft: v2Nft), "a v2 Moment by its NFT")
        XCTAssertEqual(StellarPortfolioModel.destination(older, v1Moments: [v1Moments]), .moment(id: 3))
    }

    func testACoinsGenerationComesFromMyLaunchpadElseFromItsOwnPage() throws {
        let mine = try fixture(StellarMyLaunchpad.self, "launchpad-me.json")
        let listed = StellarPortfolioModel.retiredByToken(in: mine)
        let launches = mine.held.map(\.launch) + mine.created.map(\.launch)
        XCTAssertEqual(Set(listed.keys), Set(launches.map(\.token)))
        XCTAssertEqual(Set(listed.filter(\.value).keys), Set(launches.filter { $0.generation == 1 }.map(\.token)))
        XCTAssertFalse(listed.filter(\.value).isEmpty, "the fixture's coins are v1's")

        // What was read of each held coin (My Launchpad's lists, or a coin's own page) says; a coin nothing was read of
        // keeps what was known of it, and a coin no longer held is gone.
        XCTAssertEqual(StellarPortfolioModel.retired(["A", "B", "C"], read: ["A": true, "B": false], known: ["B", "C", "D"]), ["A", "C"])
        XCTAssertEqual(StellarPortfolioModel.retired(["A"], read: [:], known: []), [])
    }

    func testEditionsAreKeyedByTheirNFTContractAndNumber() throws {
        // Edition #1 of two v2 Moments, each numbered by its own NFT contract, and v1's #1, as /v1/holdings lists them.
        let other = "CBQ6XKZKRQAJDNNLSQ2VXGNQIK6CHVIZHXYAPDBYVKA6RLZEFPI7SIIJ"
        let holdings = try holdings(editions: [(1, v2Nft), (1, other), (1, v1Moments), (2, v2Nft), (1, nil)])
        let rows = StellarPortfolioModel.editions(holdings)
        XCTAssertEqual(rows.map(\.edition.tokenId), [1, 1, 1, 2, 1], "in the server's order")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "no two tiles share an id")
        XCTAssertEqual(rows.map(\.id), ["\(v2Nft)#1", "\(other)#1", "\(v1Moments)#1", "\(v2Nft)#2", "#1"])
        XCTAssertTrue(StellarPortfolioModel.editions(nil).isEmpty)
    }

    /// The holdings fixture with `editions` (its number and NFT contract each) in place of its own.
    private func holdings(editions: [(tokenId: Int, contract: String?)]) throws -> StellarHoldings {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("holdings.json"))) as? [String: Any])
        object["moments"] = ["count": editions.count, "editions": editions.map { edition -> [String: Any] in
            ["tokenId": edition.tokenId, "momentId": 3, "title": "Harbour", "mediaUrl": NSNull(), "posterUrl": NSNull(), "mediaType": "image",
             "contract": edition.contract.map { $0 as Any } ?? NSNull()]
        }]
        return try JSONDecoder().decode(StellarHoldings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testTheCodeListIsOneList() {
        XCTAssertEqual(StellarPortfolioModel.codeList(["AQUA"]), "AQUA")
        XCTAssertTrue(StellarPortfolioModel.codeList(["AQUA", "EURC"]).contains("AQUA"))
        XCTAssertTrue(StellarPortfolioModel.codeList(["AQUA", "EURC"]).contains("EURC"))
    }

    // MARK: - Source rules

    /// Portfolio's sources (ios/DyorHQ/Lite/Portfolio), read from this checkout.
    private func source(_ name: String) throws -> String {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() } // StellarPortfolioTests.swift → Tests → Internal → ios
        return try String(contentsOf: folder.appending(path: "DyorHQ/Lite/Portfolio/\(name)"), encoding: .utf8)
    }

    private func sources() throws -> [(name: String, text: String)] {
        try ["StellarPortfolioView.swift", "StellarPortfolioModel.swift"].map { ($0, try source($0)) }
    }

    func testPortfolioIsMonadsCopyWithNoSeamAndNoLegacyScreen() throws {
        let literal = try NSRegularExpression(pattern: #""[^"\n]*\b(Lite|Pro)\b[^"\n]*""#)
        for (name, text) in try sources() {
            XCTAssertFalse(text.contains("SEAM("), name)
            for gone in ["LiteLegacyScreens", "LiteChrome", "LiteStyle", "LiteTheme", "AnyView", "env.history"] {
                XCTAssertFalse(text.contains(gone), "\(name): \(gone)")
            }
            XCTAssertNil(literal.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(name): never the words Lite or Pro on screen")
        }
        let view = try source("StellarPortfolioView.swift")
        XCTAssertTrue(view.contains("// Stellar copy of ios/DyorHQ/Portfolio/PortfolioView.swift PortfolioView ("))
        XCTAssertTrue(view.contains(".background(Color(.systemGroupedBackground))"), "Monad's palette, light and dark")
        XCTAssertTrue(view.contains(".cardBackground()"))
        XCTAssertTrue(view.contains("try? await Task.sleep(for: .milliseconds(300))\n            router.open(section.menuItem)"),
                      "a header closes Portfolio, then opens its section")
        var covers = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { covers.deleteLastPathComponent() }
        let appCovers = try String(contentsOf: covers.appending(path: "DyorHQ/Lite/AppCovers.swift"), encoding: .utf8)
        XCTAssertTrue(appCovers.contains("if router.network == .stellar { StellarPortfolioView() } else { PortfolioView() }"),
                      "Monad's Portfolio is Monad's, Stellar's on Stellar")
    }

    func testPasteboardAndCoinValueRules() throws {
        let coinValue = try NSRegularExpression(pattern: #"priceNumber|LaunchpadMath\.marketCap\(|\b(launch|\$0|\$1)\.(price|marketCap)\b"#)
        for (name, text) in try sources() {
            XCTAssertNil(coinValue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), name)
            XCTAssertFalse(text.contains("UIPasteboard"), name)
            XCTAssertFalse(text.contains("UserDefaults"), name)
        }
    }
}

/// Passkey prompts, counted from the session's own task.
final class PromptCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// A Lite server for one test, on a host of its own under `.stellar-portfolio.test`, answering with StellarKit's API
/// fixtures: a refresh refused as reused (the token revoked), the passkey sign-in (challenge and verification), the
/// public view's holdings and the v1 coin's launch page, and, only with the session the sign-in issued, the portfolio,
/// the activity and My Launchpad. It keeps every request's method and path.
final class PortfolioServer: @unchecked Sendable {
    /// The holdings fixture's one coin, a v1 launch (`launch.public.json`).
    static let coin = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V"

    let host = "lite-\(UUID().uuidString.lowercased()).stellar-portfolio.test"
    private let fixtures: [String: Data]
    private let lock = NSLock()
    private var seen: [String] = []
    private var issued: String?

    init() throws {
        var fixtures: [String: Data] = [:]
        for name in ["error-refresh-reused.json", "holdings.public.json", "launch.public.json", "portfolio.json", "activity.json", "launchpad-me.json"] {
            fixtures[name] = try Data(contentsOf: StellarPortfolioTests.fixtureURL(name))
        }
        self.fixtures = fixtures
        PortfolioStub.serve(host: host) { [self] request in answer(request) }
    }

    var env: LiteEnvironment { LiteEnvironment(apiURL: URL(string: "https://\(host)/lite")!, pinned: .testnet, buildNumber: 1000) }

    /// Every request, in order: "GET /v1/holdings".
    var paths: [String] { lock.withLock { seen } }

    func stop() { PortfolioStub.serve(host: host, nil) }

    private func answer(_ request: PortfolioStub.Request) -> (status: Int, body: Data) {
        let session = lock.withLock {
            seen.append("\(request.method) \(request.path)")
            return issued.map { request.authorization == "Bearer \($0)" } ?? false
        }
        switch (request.method, request.path) {
        case ("POST", "/v1/auth/refresh"): return (401, fixtures["error-refresh-reused.json"]!)
        case ("POST", "/v1/auth/challenge"):
            let nonce = "portfolio-nonce-0123456789"
            let message = ["DyorHQ Lite sign-in", "Network: testnet", "Address: \(request.json["address"] ?? "")", "Nonce: \(nonce)",
                           "Issued: 2026-10-15T09:41:00.000Z"].joined(separator: "\n")
            return (200, Self.json(["nonce": nonce, "message": message, "expiresAt": Self.time(300)]))
        case ("POST", "/v1/auth/verify"):
            let token = "jwt-\(UUID().uuidString)"
            lock.withLock { issued = token }
            let body: [String: Any] = ["token": token, "expiresAt": Self.time(3600), "refreshToken": "lrt_fresh", "refreshExpiresAt": Self.time(30 * 86_400),
                                       "tester": ["address": request.json["address"] ?? "", "label": NSNull()]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        case ("GET", "/v1/holdings"): return (200, fixtures["holdings.public.json"]!)
        case ("GET", "/v1/launches/\(Self.coin)"): return (200, fixtures["launch.public.json"]!)
        case ("GET", "/v1/portfolio"), ("GET", "/v1/activity"), ("GET", "/v1/launchpad/me"):
            guard session else { return (401, Self.error("not_signed_in", "Sign in again.")) }
            let name = ["/v1/portfolio": "portfolio.json", "/v1/activity": "activity.json", "/v1/launchpad/me": "launchpad-me.json"][request.path]!
            return (200, fixtures[name]!)
        default:
            return (404, Self.error("not_found", "No such route."))
        }
    }

    private static func json(_ fields: [String: String]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }

    private static func error(_ code: String, _ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
    }

    /// `seconds` from now, as the API writes times.
    private static func time(_ seconds: TimeInterval) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds)) }
}

/// Answers the requests to `.stellar-portfolio.test` hosts (`URLSession.shared`, which `LiteAPI` uses, asks the
/// registered protocols), each with its host's handler.
final class PortfolioStub: URLProtocol {
    struct Request: Sendable {
        let method: String
        /// The path below the API's base, without the query: "/v1/holdings".
        let path: String
        let authorization: String?
        let body: Data?

        var json: [String: String] { body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
    }

    typealias Handler = @Sendable (Request) -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func serve(host: String, _ handler: Handler?) { lock.withLock { handlers[host] = handler } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".stellar-portfolio.test") ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let seen = Request(method: request.httpMethod ?? "GET", path: url.path.replacingOccurrences(of: "/lite", with: ""),
                           authorization: request.value(forHTTPHeaderField: "authorization"), body: Self.body(of: request))
        guard let handler = Self.lock.withLock({ Self.handlers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = handler(seen)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
