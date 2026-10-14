import BigInt
import XCTest
@testable import DyorKit

/// The launches of every launchpad (`LaunchpadService.launchListing`): a launchpad whose launches can't be read is named,
/// never taken for one with none. The Launch board shows the error with Retry and keeps that launchpad's last good coins;
/// the readers that total what coins are worth (the Portfolio, My Launchpad, Home) say their figures are incomplete.
final class LaunchListingTests: XCTestCase {
    func testALiveLaunchpadThatCantBeReadIsNamedAndItsLastCoinsAreKept() async throws {
        var chain = HonestyLaunchpad()
        chain.retiredCoin = HonestyLaunchpad.old
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        let good = await service.launchListing()
        XCTAssertTrue(good.complete)
        XCTAssertEqual(good.launches.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha, HonestyLaunchpad.old], "the live launchpad's, then the retired ones'")
        XCTAssertEqual(good.factories.first, HonestyLaunchpad.live.factory)
        let all = try await service.allLaunches()
        XCTAssertEqual(all.map(\.token), good.launches.map(\.token))

        chain.liveFails = true
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
        let failed = await service.launchListing()
        XCTAssertFalse(failed.complete)
        XCTAssertEqual(Array(failed.unread.keys), [HonestyLaunchpad.live.factory])
        XCTAssertNotNil(failed.firstError)
        XCTAssertEqual(failed.launches.map(\.token), [HonestyLaunchpad.old], "what could be read")
        XCTAssertEqual(failed.keeping(good.launches).map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha, HonestyLaunchpad.old],
                       "the board keeps the live launchpad's last good coins, in their place")
        XCTAssertEqual(failed.keeping([]).map(\.token), [HonestyLaunchpad.old])
        do {
            _ = try await service.allLaunches()
            XCTFail("allLaunches answered without the live launchpad")
        } catch {}
    }

    /// A retired launchpad that can't be read is named too, and keeps its last coins, after the live one's fresh ones.
    func testARetiredLaunchpadThatCantBeReadIsNamedToo() async throws {
        let retired = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first)
        let previous = LaunchListing(factories: [HonestyLaunchpad.live.factory, retired.factory], launches: [])
        XCTAssertTrue(previous.complete)
        var chain = HonestyLaunchpad()
        chain.retiredCoin = HonestyLaunchpad.old
        MomentsChainStub.install { [chain] in chain.answer($0, $1) }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: HonestyLaunchpad.live)
        let good = await service.launchListing()
        MomentsChainStub.install({ [chain] in chain.answer($0, $1) }, breaking: [retired.factory])
        let failed = await service.launchListing()
        XCTAssertEqual(Array(failed.unread.keys), [retired.factory])
        XCTAssertEqual(failed.launches.map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha])
        XCTAssertEqual(failed.keeping(good.launches).map(\.token), [HonestyLaunchpad.beta, HonestyLaunchpad.alpha, HonestyLaunchpad.old])
    }

    /// The screens wire it in: the board shows its error with Retry (and no "No Launches Yet" beside it) and keeps a
    /// launchpad's last coins; the Portfolio, My Launchpad and Home say a load was incomplete.
    func testTheScreensSayALaunchpadCouldntBeRead() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        func source(_ path: String) throws -> String { try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8) }
        let board = try source("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(board.contains("let listing = await env.launchpad.launchListing(limit: 60)\n        launches = listing.keeping(launches)"))
        XCTAssertTrue(board.contains("error = listing.firstError.map(describe)"))
        XCTAssertTrue(board.contains("if let error = model.error {\n                    HStack(alignment: .firstTextBaseline) {\n                        InlineError(message: error)"))
        XCTAssertTrue(board.contains("Button(\"Retry\") { Task { await model.load(env: env, account: session.address) } }"))
        XCTAssertTrue(board.contains("if model.error == nil { emptyState }"))
        let portfolio = try source("Portfolio/PortfolioModel.swift")
        XCTAssertTrue(portfolio.contains("let launches = listing.keeping(Array(launchesByCurve.values))"))
        XCTAssertTrue(portfolio.contains("if !listing.complete || fetchedMoments == nil || !retired.complete || fetchedPrices == nil {"))
        let profile = try source("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(profile.contains("let launches = listing.keeping(lastLaunches)"))
        XCTAssertTrue(profile.contains("var unread = !listing.complete"))
        XCTAssertTrue(profile.contains("incomplete = unread ?"))
        XCTAssertTrue(profile.contains("if let incomplete = model.incomplete {\n                HStack(alignment: .firstTextBaseline) {\n                    InlineError(message: incomplete)\n                    Spacer(minLength: 8)\n                    retryButton()"), "said, with Retry")
        let home = try source("Home/HomeView.swift")
        XCTAssertTrue(home.contains("launchList = read.keeping(self.launches)"))
        XCTAssertTrue(home.contains("} else if !listing.complete {"))
        for (path, text) in [("Launchpad/LaunchpadView.swift", board), ("Portfolio/PortfolioModel.swift", portfolio), ("Launchpad/LaunchpadProfileView.swift", profile), ("Home/HomeView.swift", home)] {
            XCTAssertFalse(text.contains("allLaunches("), "\(path) reads every launchpad through launchListing")
        }
    }
}
