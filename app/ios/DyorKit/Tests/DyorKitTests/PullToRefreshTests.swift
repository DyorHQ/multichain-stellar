import DyorKit
import XCTest

/// A pull to refresh waits for the screen's own reads only, never for a round of the wallet's history
/// (`HistoryModel.kick`). A round reads for thirty seconds or more while the history fills in, and it used to hold the
/// spinner of Home, My Launchpad, My Moments and Recent Activity that long, the last three before their own reload even
/// started. The screens follow the history model's `version` for what a round brings.
final class PullToRefreshTests: XCTestCase {
    /// Every app source, its comments left out.
    private func appSources() throws -> [(file: String, code: [Character])] {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try files.map { file in
            let code = String(TradeStringsTests.uncommented(Array(try String(contentsOf: file, encoding: .utf8))))
            return (file.lastPathComponent, Array(code))
        }
    }

    /// Every `.refreshable` in the app: the file, and its closure as written.
    private func pulls() throws -> [(file: String, body: String)] {
        var pulls: [(file: String, body: String)] = []
        for (file, code) in try appSources() {
            let text = String(code)
            var from = text.startIndex
            while let found = text.range(of: ".refreshable {", range: from..<text.endIndex) {
                let open = text.distance(from: text.startIndex, to: found.upperBound) - 1
                let close = try XCTUnwrap(TradeStringsTests.closing(code, open), file)
                pulls.append((file, String(code[open...close])))
                from = found.upperBound
            }
        }
        return pulls
    }

    /// No pull and no Retry awaits a round of the history: the screens that read it on kick it (`kick`) and await only
    /// their own reads. The only round waited for is the history model's own (`refresh`, private), started by `kick`
    /// between rounds; rounds waiting out a stall go on at once (`resume`), and a round reading now is left to finish.
    func testNoPullWaitsForARoundOfTheHistory() throws {
        let pulls = try pulls()
        XCTAssertGreaterThanOrEqual(pulls.count, 10, "every screen's pull is found")
        for pull in pulls {
            XCTAssertFalse(pull.body.contains("history.refresh("), pull.file)
        }
        XCTAssertEqual(Set(pulls.filter { $0.body.contains("env.history.kick(env: env)") }.map(\.file)),
                       ["HomeView.swift", "LaunchpadProfileView.swift", "MomentsPortfolioView.swift", "RecentActivityView.swift"])
        for (file, code) in try appSources() where file != "HistoryModel.swift" {
            XCTAssertFalse(String(code).contains("history.refresh("), "\(file): a screen kicks the history, never waits for a round")
        }
        // The Retries that read the history on kick it: Recent Activity's, then reads the screen again; My Launchpad's
        // after reading the screen again, so the round reads a head at or after the block its balances were read at,
        // which each holding's profit and loss waits for (`WalletHistorySnapshot.fillsCoverage`). Its pull likewise.
        let profile = try DocsLinksTests.appSource("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(profile.contains("""
                    Task {
                        await model.load(env: env, address: session.address)
                        if history { env.history.kick(env: env) }
                    }
        """))
        XCTAssertTrue(profile.contains("""
                    .refreshable {
                        env.invalidateChainReads()
                        await model.load(env: env, address: session.address)
                        env.history.kick(env: env)
                    }
        """))
        XCTAssertTrue(try DocsLinksTests.appSource("Profile/RecentActivityView.swift").contains(
            #"Button("Retry") { env.history.kick(env: env); Task { await model.load(env: env, address: session.address) } }"#))

        let model = try DocsLinksTests.appSource("Wallet/HistoryModel.swift")
        XCTAssertTrue(model.contains("""
            func kick(env: AppEnvironment) {
                guard let wallet else { return }
                if filler == nil || backingOff {
                    resume(env: env)
                } else if inFlight?.wallet != wallet {
                    Task { [weak self] in await self?.refresh(env: env) }
                }
            }
        """))
        XCTAssertTrue(model.contains("    private func refresh(env: AppEnvironment) async {"), "no screen can wait for a round")
    }

    /// A trade or a claim made in the app is in the wallet's history in seconds, not at the next top-up: each settles by
    /// kicking it. My Launchpad kicks it too once its balances are read at a block the history's head hasn't reached, so a
    /// holding's profit and loss and the Activity tab wait for one short round, not a top-up's 90 seconds.
    func testTradesClaimsAndBalancesKickTheHistory() throws {
        let launchpad = try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift")
        let buy = try XCTUnwrap(launchpad.range(of: "ConfirmationSheet(title: \"Buy \\(launch.symbol)\""))
        let buyIntent = try XCTUnwrap(launchpad.range(of: "}, intent: .launchpadBuy(", range: buy.upperBound..<launchpad.endIndex))
        XCTAssertTrue(launchpad[buy.upperBound..<buyIntent.lowerBound].contains("env.history.kick(env: env)"), "a curve buy")
        let sell = try XCTUnwrap(launchpad.range(of: "ConfirmationSheet(title: \"Sell \\(launch.symbol)\""))
        let sellIntent = try XCTUnwrap(launchpad.range(of: "}, intent: .launchpadSell(", range: sell.upperBound..<launchpad.endIndex))
        XCTAssertTrue(launchpad[sell.upperBound..<sellIntent.lowerBound].contains("env.history.kick(env: env)"), "a curve sell")

        let profile = try DocsLinksTests.appSource("Launchpad/LaunchpadProfileView.swift")
        let sheets = try XCTUnwrap(profile.range(of: "@ViewBuilder private func claimSheet(for target: ClaimTarget) -> some View {"))
        let rows = try XCTUnwrap(profile.range(of: "// MARK: - Rows", range: sheets.upperBound..<profile.endIndex))
        XCTAssertEqual(profile[sheets.upperBound..<rows.lowerBound].components(separatedBy: "env.history.kick(env: env)").count - 1, 3, "each claim: creator fees, rewards, Claim All")
        XCTAssertTrue(profile.contains("if let block = held?.block, !history.status(WalletHistoryScans.launchpadId).isCurrent(through: block, at: Date()) { env.history.kick(env: env) }"))
        XCTAssertTrue(profile.contains("through: held?.block, now: now)"), "the profit and loss waits for the balances' block")
        XCTAssertTrue(profile.contains("history.fillsCoverage(curves: Set(lastLaunches.map(\\.curve)), through: held?.block)"), "and the Activity tab")
    }

    /// The history model's rounds, pinned where no test can drive them: a round whose window grew (the transfer scans
    /// reading back to the first transaction) isn't a stall; a snapshot built with fewer curves than the model has now is
    /// built again at once; a screen's curves only rebuild when one is new. The pause between top-ups and a round's budget
    /// come from DyorKit (`HistoryCadence`), whose `freshFor` — how long a scan counts as up to now — outlasts them both:
    /// a longer pause would otherwise flip every final figure back to "Reading" between top-ups.
    func testTheRoundsKeepTheirCadenceAndGuards() throws {
        let model = try DocsLinksTests.appSource("Wallet/HistoryModel.swift")
        XCTAssertTrue(model.contains("let widened = floors.contains { id, floor in lastFloors[id].map { floor < $0 } ?? false }"))
        XCTAssertTrue(model.contains("(!widened && round.progress <= lastProgress)"))
        XCTAssertTrue(model.contains("if snapshot.curves != curves { rebuild(env: env) }"))
        XCTAssertTrue(model.contains("guard !more.isSubset(of: curves) else { return }"))
        XCTAssertTrue(model.contains("static let topUpPause: Duration = .seconds(HistoryCadence.topUpPause)"))
        XCTAssertTrue(model.contains("static let roundBudget = LogsBudget(requests: 40, seconds: HistoryCadence.roundSeconds)"))
        XCTAssertFalse(model.contains("static let topUpPause: Duration = .seconds(9"), "never a pause of its own")
        XCTAssertLessThan(HistoryCadence.topUpPause + HistoryCadence.roundSeconds, HistoryCadence.freshFor)
        XCTAssertEqual(HistoryCadence.freshFor, 180)
    }

    /// A pull asks for what is on chain now: every screen whose figures come from the reads the screens share (the launch
    /// list, the Moments lists, prices: `ChainCache`, and the head: `HeadClock`) forgets them first, so its reads go to the
    /// chain rather than take a copy another screen read seconds ago; a pull never waits for that (it is a synchronous
    /// call). A transaction of the user's that settled does the same, once, in the one sheet every plan runs in, before
    /// the caller records or reloads; and an erase of this device's data forgets them with what is kept on the device.
    func testAPullAndASettledTransactionReadTheSharedReadsAgain() throws {
        let pulls = try pulls()
        let sharing: Set<String> = ["HomeView.swift", "LaunchpadView.swift", "LaunchpadProfileView.swift", "MomentsView.swift", "MomentsPortfolioView.swift", "RecentActivityView.swift"]
        for pull in pulls where sharing.contains(pull.file) {
            let body = pull.body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            XCTAssertEqual(body.dropFirst().first, "env.invalidateChainReads()", "\(pull.file): first, before any read")
        }
        XCTAssertEqual(Set(pulls.filter { $0.body.contains("env.invalidateChainReads()") }.map(\.file)), sharing)
        XCTAssertTrue(try DocsLinksTests.appSource("Portfolio/PortfolioView.swift").contains("if force {\n            env.invalidateChainReads()"), "the Portfolio's, through its reload")

        let environment = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        XCTAssertTrue(environment.contains("let chainCache = ChainCache()"))
        XCTAssertTrue(environment.contains("chainStore = isFork ? ChainStore(directory: nil) : ChainStore.applicationSupport()"), "a fork keeps nothing on disk")
        XCTAssertTrue(environment.contains("func invalidateChainReads() {\n        chainCache.invalidate()\n        clock.head.forget()\n    }"),
                      "the shared reads, and the shared head they are measured from (`HeadClock.forget`)")
        XCTAssertEqual(environment.components(separatedBy: "cache: chainCache, store: chainStore").count - 1, 4, "prices, the launchpad, Moments, past cohorts")

        let sheet = try DocsLinksTests.appSource("Wallet/TransactionRun.swift")
        XCTAssertTrue(sheet.contains("""
                    completed = true
                    // The plan changed what is on chain (a buy, a sell, a launch, a collect, a claim, a swap): every read the
                    // screens share is read again (`AppEnvironment.invalidateChainReads`), before the caller records or reloads.
                    env.invalidateChainReads()
                    onCompleted?(hash)
        """))

        let session = try DocsLinksTests.appSource("Wallet/Session.swift")
        let erase = try XCTUnwrap(session.range(of: "func eraseLocalData() async {"))
        let signedOut = try XCTUnwrap(session.range(of: "state = .signedOut", range: erase.upperBound ..< session.endIndex))
        let wipe = session[erase.upperBound ..< signedOut.lowerBound]
        XCTAssertTrue(wipe.contains("chainStore?.erase()\n        chainCache?.invalidate()"), "with no suspension before the sign-out")
        XCTAssertTrue(environment.contains("session.chainStore = chainStore\n        session.chainCache = chainCache"))
    }

    /// Home's pull reads Home's figures and the Portfolio's side by side, not one after the other. The Portfolio's pull
    /// still reads all three of its parts again in full (`force`), side by side, with the history kicked on behind them.
    func testAPullReadsTheScreensPartsSideBySide() throws {
        let home = try XCTUnwrap(pulls().first { $0.file == "HomeView.swift" }).body
        XCTAssertTrue(home.contains("env.history.kick(env: env)"))
        XCTAssertTrue(home.contains("async let home: () = model.load(env: env, address: session.address)"))
        XCTAssertTrue(home.contains("async let portfolio: () = env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: true, passkey: session.isPasskeyAccount)"))
        XCTAssertTrue(home.contains("_ = await (home, portfolio)"))
        // In a task of their own: SwiftUI cancels a pull's action when the list redraws under it, and a cancelled load
        // publishes nothing (seen on the simulator: 21 requests cancelled, Home unchanged after the pull).
        XCTAssertTrue(home.contains("await Task {\n                    async let home: () = model.load(env: env, address: session.address)"))
        XCTAssertTrue(home.contains("}.value"))
        XCTAssertEqual(home.components(separatedBy: "await ").count - 1, 2, "the pull waits for the task, and the task for both reads together")

        let portfolio = try DocsLinksTests.appSource("Portfolio/PortfolioView.swift")
        XCTAssertTrue(portfolio.contains(".refreshable { await reload(force: true) }"))
        XCTAssertTrue(portfolio.contains("""
            private func reload(force: Bool) async {
                if force {
                    env.invalidateChainReads()
                    env.history.kick(env: env)
                }
                async let portfolio: () = model.load(env: env, address: session.address, perplKey: perplTrading.key, force: force, passkey: session.isPasskeyAccount)
                async let holdings: () = assets.load(env: env, address: session.address, force: force)
                async let past: () = pastMoments.load(env: env, address: session.address, force: force)
                _ = await (portfolio, holdings, past)
            }
        """))
    }
}
