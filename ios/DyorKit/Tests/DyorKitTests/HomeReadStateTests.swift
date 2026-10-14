import XCTest
@testable import DyorKit

/// Home never shows a figure it hasn't read as $0.00 (`HomeReadState`): each of its four parts of the wallet is unread
/// until a read of it answers for the wallet, a figure from an unread part is a placeholder, a tab says "none" only once
/// its part was read, and a read that fails before any answered says so, with Retry. A part once read keeps its last good
/// figures through a later failure.
final class HomeReadStateTests: XCTestCase {
    /// A wallet nothing has been read for: every part still reading, no figure to show, nothing failed.
    func testANewWalletHasNothingRead() {
        let state = HomeReadState()
        for part in HomeReadState.Part.allCases {
            XCTAssertEqual(state.status(part), .reading, "\(part)")
            XCTAssertFalse(state.isRead(part), "\(part)")
            XCTAssertFalse(state.showsValue(of: part), "\(part): a placeholder, never $0.00")
        }
        XCTAssertEqual(state.failed, [])
    }

    /// A part is read once a read of it answers. Perps, Launch and Moments then show their own figure; Spot's waits for
    /// the Launch and Moments tabs as well, since what they count is taken out of it (`HomeTotals`).
    func testEachPartShowsOnceReadAndSpotWaitsForLaunchAndMoments() {
        var state = HomeReadState()
        state.record(.spot, answered: true)
        XCTAssertTrue(state.isRead(.spot))
        XCTAssertFalse(state.showsValue(of: .spot), "Spot's figure still holds the coins Launch and Moments will count")
        state.record(.perps, answered: true)
        XCTAssertTrue(state.showsValue(of: .perps))
        XCTAssertFalse(state.showsValue(of: .launch))
        state.record(.launch, answered: true)
        XCTAssertTrue(state.showsValue(of: .launch))
        XCTAssertFalse(state.showsValue(of: .spot), "Moments not read yet")
        state.record(.moments, answered: true)
        XCTAssertTrue(state.showsValue(of: .moments))
        XCTAssertTrue(state.showsValue(of: .spot))
        XCTAssertTrue(HomeReadState.Part.allCases.allSatisfy(state.showsValue(of:)), "every figure, so the total too")
        XCTAssertEqual(state.failed, [])
    }

    /// A read that fails before any answered marks its part failed (its tab says so, with Retry), in `Part` order, and the
    /// part stays unread: a failed Perps read is a placeholder, never $0.00. The read that then answers clears it.
    func testAFailedFirstReadIsUnreadUntilOneAnswers() {
        var state = HomeReadState()
        state.record(.moments, answered: false)
        state.record(.perps, answered: false)
        state.record(.spot, answered: true)
        state.record(.launch, answered: true)
        XCTAssertEqual(state.status(.perps), .failed)
        XCTAssertEqual(state.failed, [.perps, .moments], "in Part order")
        XCTAssertFalse(state.showsValue(of: .perps), "a failed read is unread, not 0")
        XCTAssertFalse(state.showsValue(of: .spot), "Spot waits for Moments")
        state.record(.perps, answered: false)
        XCTAssertEqual(state.status(.perps), .failed, "still failed while no read answers")
        state.record(.perps, answered: true)
        state.record(.moments, answered: true)
        XCTAssertEqual(state.failed, [])
        XCTAssertTrue(HomeReadState.Part.allCases.allSatisfy(state.showsValue(of:)))
    }

    /// Once read, a part stays read for the wallet: a later read that fails keeps the last good figures (the screen says
    /// so), never going back to a placeholder or to $0.00. Another wallet starts again from nothing.
    func testAFailureAfterAReadKeepsTheLastGoodFigures() {
        var state = HomeReadState()
        for part in HomeReadState.Part.allCases { state.record(part, answered: true) }
        for part in HomeReadState.Part.allCases { state.record(part, answered: false) }
        for part in HomeReadState.Part.allCases {
            XCTAssertEqual(state.status(part), .read, "\(part)")
            XCTAssertTrue(state.showsValue(of: part), "\(part)")
        }
        XCTAssertEqual(state.failed, [])
        XCTAssertNotEqual(state, HomeReadState())
        state = HomeReadState()
        XCTAssertEqual(state.failed, [])
        XCTAssertFalse(state.showsValue(of: .perps), "another wallet: unread again")
    }

    // MARK: The app's wiring

    private static func homeModel(_ home: String) throws -> String {
        let model = try XCTUnwrap(home.range(of: "final class HomeModel {")).upperBound
        let end = try XCTUnwrap(home.range(of: "struct TokenDetailView: View {")).lowerBound
        return String(home[model..<end])
    }

    /// Each part is recorded from its own read in Home's load as that read lands, and published then — only while the load
    /// stands (the account unchanged, not cancelled) — and starts again for another account. A failed Perps read is nil
    /// (unread), and an account without a Perpl account is $0 read; every figure is nil while its part can't be told.
    func testHomeRecordsEachPartAndNeverTakesUnreadForZero() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let model = try Self.homeModel(home)
        XCTAssertTrue(model.contains("perpEquity = nil; momentRows = []; updatedAt = nil; reads = HomeReadState()"), "another account starts unread")
        // Each read publishes its part as it lands, only while the load stands (RS-10), never held back by the slowest.
        XCTAssertTrue(model.contains("await withTaskGroup(of: Answer.self) { group in"))
        XCTAssertTrue(model.contains("while let answer = await group.next() {\n                let stands = !Task.isCancelled && address == loadedFor"))
        for publish in ["if stands, balancesIn { publishSpot(tokens: tokens, priceMap: priceMap, balanceMap: balanceMap, notTrading: notTrading) }",
                        "if stands, pricesIn { publishSpot(tokens: tokens, priceMap: priceMap, balanceMap: balanceMap, notTrading: notTrading) }",
                        "if stands, let listing { publishLaunch(holdings, priceMap: priceMap, listing: listing) }",
                        "if stands { publishPerps(state) }", "if stands { publishMoments(state) }"] {
            XCTAssertTrue(model.contains(publish), publish)
        }
        XCTAssertTrue(model.contains("if stands, !holdingsAsked, pricesIn, let listing {"), "the launch coins are read once the launches and the prices are in")
        for record in ["record(.spot, answered: priceMap != nil && balanceMap != nil)", "record(.perps, answered: state != nil)",
                       "record(.launch, answered: holdings != nil && priceMap != nil && listing.factories.allSatisfy(listedFactories.contains))",
                       "record(.moments, answered: state != nil)", "if next != reads { reads = next }"] {
            XCTAssertTrue(model.contains(record), record)
        }
        XCTAssertTrue(model.contains("listedFactories.formUnion(read.factories.filter { read.unread[$0] == nil })"))
        // What is decided once every read is in waits for the load to stand as well.
        let publish = try XCTUnwrap(model.range(of: "guard !Task.isCancelled, address == loadedFor, let listing else { return }"))
        let errors = try XCTUnwrap(model.range(of: "if let priceError {", range: publish.upperBound..<model.endIndex))
        XCTAssertLessThan(publish.upperBound, errors.lowerBound)
        XCTAssertTrue(model.contains("var perpsValue: Double? { reads.showsValue(of: .perps) ? perpEquity : nil }"))
        XCTAssertFalse(model.contains("perpEquity ?? 0"), "a Perps figure not read is never $0.00")
        XCTAssertTrue(model.contains("guard let account = found else { return ([], 0) }"), "no Perpl account: $0, read")
        XCTAssertTrue(model.contains("do { found = try await env.perpl.account(address) } catch { return nil }"), "a failed read: unread")
        XCTAssertTrue(model.contains("var availableBalance: Double? { spotValue }"))
        XCTAssertTrue(model.contains("var inUse: Double? { perpsValue }"))
        XCTAssertTrue(model.contains("guard let spot = spotValue, let perps = perpsValue, let launch = launchpadValue, let moments = momentsValue else { return nil }"))
        // A part never read whose read failed is the header's warning too, so the screen isn't said to be up to date.
        XCTAssertTrue(model.contains("} else if let part = reads.failed.first {\n            // A part not read for the wallet yet: its tab says so, with Retry, and the total waits for it.\n            error = tr(Self.unreadMessage(part))"))
    }

    /// The hero's total and its day's move, Avail. Balance, In Use and the four split figures are placeholders while
    /// unread, which VoiceOver says are loading; the allocation ring waits for every part; and each holdings tab shows a
    /// loading row, or that its part couldn't be read with Retry, before it would say it holds none.
    func testHomeShowsUnreadFiguresAsPlaceholdersAndTabsAsLoading() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let hero = try XCTUnwrap(home.range(of: "private var heroCard: some View {"))
        let heroEnd = try XCTUnwrap(home.range(of: "private var changeAmount: Double {", range: hero.upperBound..<home.endIndex))
        let card = String(home[hero.upperBound..<heroEnd.lowerBound])
        XCTAssertTrue(card.contains("let unread = model.totalValue == nil"))
        XCTAssertEqual(card.components(separatedBy: ".unreadFigure(unread)").count - 1, 2, "the total and the change line")
        XCTAssertTrue(card.contains("ChangeBadge(value: unread ? 0 : model.change24h ?? 0)"))
        XCTAssertTrue(card.contains("statColumn(\"Avail. Balance\", value: model.availableBalance, tint: .primary)"))
        XCTAssertTrue(card.contains("statColumn(\"In Use\", value: model.inUse, tint: (model.inUse ?? 0) > 0 ? .positive : .primary, alignment: .trailing)"))
        XCTAssertFalse(card.contains(".redacted(reason: model.totalValue == nil"), "through unreadFigure, which VoiceOver says is loading")
        XCTAssertTrue(home.contains("private func statColumn(_ title: LocalizedStringKey, value: Double?, tint: Color,"))
        XCTAssertTrue(home.contains("private func splitStat(_ category: HoldingCategory, _ value: Double?, _ dot: Color) -> some View {"))
        XCTAssertEqual(home.components(separatedBy: ".unreadFigure(value == nil)").count - 1, 2, "statColumn and splitStat")
        let modifier = try XCTUnwrap(home.range(of: "@ViewBuilder func unreadFigure(_ unread: Bool) -> some View {"))
        let modifierBody = String(home[modifier.upperBound...].prefix(300))
        XCTAssertTrue(modifierBody.contains("redacted(reason: .placeholder)"))
        XCTAssertTrue(modifierBody.contains(".accessibilityLabel(Text(\"Loading…\"))"), "never read out as $0.00")
        XCTAssertTrue(home.contains("if let split = model.split, split.total > 0 || !model.holdings.isEmpty { allocationCard(split) }"))

        // A tab says "none" only once its part has figures: read, or saved when last read (said so above the balance). The
        // Perps positions are never saved, so that tab waits for a read.
        for (part, empty, reading) in [("spot", "No spot balances", "Reading your balances…"), ("perps", "No open positions", "Reading your positions…"),
                                       ("launch", "No launch holdings", "Reading your balances…"), ("moments", "No Moments yet", "Reading your Moments…")] {
            let shown = part == "perps" ? "isRead" : "hasFigures"
            XCTAssertTrue(home.contains("if model.reads.\(shown)(.\(part)) { holdingsEmpty(\"\(empty)\""), "\(part): none only once read")
            XCTAssertTrue(home.contains("else { holdingsUnreadRow(.\(part), reading: \"\(reading)\") }"), "\(part): a loading row before")
            XCTAssertEqual(home.components(separatedBy: "holdingsEmpty(\"\(empty)\"").count - 1, 1, empty)
        }
        let row = try XCTUnwrap(home.range(of: "@ViewBuilder private func holdingsUnreadRow(_ part: HomeReadState.Part, reading: LocalizedStringKey) -> some View {"))
        let rowBody = String(home[row.upperBound...].prefix(400))
        XCTAssertTrue(rowBody.contains("if model.reads.status(part) == .failed {\n            holdingsRetryRow(HomeModel.unreadMessage(part))"))
        XCTAssertTrue(home.contains("Button(\"Retry\") { Task { await model.load(env: env, address: session.address) } }"))
    }
}
