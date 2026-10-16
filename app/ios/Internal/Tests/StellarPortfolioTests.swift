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
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // StellarPortfolioTests.swift → Tests → Internal → ios → app → S
        let file = root.appending(path: "ios/Packages/StellarKit/Tests/LiteClientTests/Fixtures/\(name)")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }

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

    /// `/v1/portfolio` over `period`, every section's figures `volume` apart, read `asOf`.
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
        XCTAssertEqual(figures.totals.volume, read.totals.volume)
        XCTAssertEqual(figures.totals.fees, read.totals.fees, "Fees paid is the server's: DyorHQ's fees only")
        XCTAssertEqual(figures.totals.pnl, read.totals.pnl)
        XCTAssertEqual(figures.totals.claimedFees, read.totals.claimedFees)
        XCTAssertEqual(figures.totals.trades, read.totals.trades)
        XCTAssertEqual(figures.totals.pnlComplete, read.totals.pnlComplete)
        XCTAssertEqual(figures.totals.networkFeesStroops, Int64(read.totals.networkFeesXlm), "network fees in XLM, on their own line")
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
        XCTAssertEqual(StellarPortfolioModel.Section.allCases.map(\.rawValue), ["spot", "earn", "launch", "moments", "bridge"],
                       "Monad's five sections, Earn in Perps' place")
    }

    func testEachPeriodShowsItsOwnRead() throws {
        let model = model(temporarySaved())
        let week = try portfolio("week", volume: 2)
        let all = try portfolio("all", volume: 7)
        XCTAssertNil(model.shown(.week, live: nil, status: .unread), "nothing read or saved: placeholders, never $0.00")
        let shownWeek = try XCTUnwrap(model.shown(.week, live: week, status: .read))
        XCTAssertEqual(shownWeek.figures.totals.volume, 10)
        XCTAssertNil(shownWeek.savedAt, "this session's figures")
        XCTAssertEqual(model.shown(.all, live: all, status: .read)?.figures.totals.volume, 35)
        XCTAssertEqual(model.shown(.all, live: all, status: .failed)?.figures.totals.volume, 35, "a failed read keeps the last figures read")
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
        XCTAssertEqual(week.figures.totals.volume, 10)
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

    // MARK: - Section headers

    func testASectionHeaderLandsOnItsStellarTabOrSide() {
        let expected: [(StellarPortfolioModel.Section, StellarTab, StellarTradeMode?)] = [
            (.spot, .earn, .swap), (.earn, .earn, .earn), (.launch, .launch, nil), (.moments, .moments, nil), (.bridge, .home, nil),
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
        XCTAssertEqual(rows.map(\.section), [.launch, .bridge])
        XCTAssertTrue(rows.allSatisfy { $0.time != nil })
        XCTAssertEqual(read.coverage.note, "Swaps made outside DyorHQ between non-launch assets aren't counted.", "shown verbatim under Activity")

        let other = try decode(StellarPortfolio.self, """
            {"period": "all", "since": null, "asOf": "2026-10-15T09:41:00.000Z",
             "pricing": {"kind": "reference", "source": "Kraken", "network": "mainnet", "note": null},
             "totals": \(Self.zero), "sections": {"spot": \(Self.zero), "earn": \(Self.zero), "launch": \(Self.zero), "moments": \(Self.zero), "bridge": \(Self.zero)},
             "activity": [{"id": "a", "section": "account", "kind": "trust", "title": "Enabled USDC", "subtitle": null, "at": "2026-10-15T09:00:00.000Z", "usd": null, "hash": null},
                          {"id": "b", "section": "spot", "kind": "swap", "title": "Swapped", "subtitle": "XLM → USDC", "at": "2026-10-15T08:00:00.000Z", "usd": 1.5, "hash": "ab"}],
             "coverage": {"from": null, "note": null}}
            """)
        XCTAssertEqual(StellarPortfolioModel.rows(other).map(\.id), ["b"], "only the five sections' items")
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

        let mine = try fixture(StellarMyLaunchpad.self, "launchpad-me.json")
        let retired = StellarPortfolioModel.retired(in: mine)
        XCTAssertEqual(retired, Set((mine.held.map(\.launch) + mine.created.map(\.launch)).filter { $0.generation == 1 }.map(\.token)))
        XCTAssertFalse(retired.isEmpty, "the fixture's coins are v1's")
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
