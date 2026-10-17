// The Moment page, Publish and View in Freighter (docs/DESIGN-stellar-parity.md §8.11.2–8.11.6;
// docs/DESIGN-stellar-contracts-v2.md §21): the publish review's terms guard, Freighter's contract and token id, the
// collect ticket's limits, what it pulls and what it gets, a v2 Moment's times, figures and stats, its Share, the day its
// When shows, Publish's links, the new Moment Publish opens, and the references that open a Moment.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import SwiftUI
import XCTest

@MainActor
final class StellarMomentsTests: XCTestCase {
    // MARK: - The publish review's terms guard (§8.11.4)

    private func reviewed(form: StellarMomentFormV2? = nil) throws -> StellarCreateMomentView.Reviewed {
        let economics = try XCTUnwrap(try JSONDecoder().decode(StellarEconomicsV2.self, from: Data(Self.economics.utf8)).moments)
        return StellarCreateMomentView.Reviewed(form: form ?? Self.form, economics: economics,
                                                upload: StellarMomentUploadV2(mediaUrl: Self.photo, posterUrl: nil))
    }

    /// A publish plan as the API builds it (a fake action's plan): its display states the terms it binds.
    private func plan(_ overrides: [String: String] = [:]) throws -> PlanView {
        try JSONDecoder().decode(PlanView.self, from: Data(Self.publishPlan(overrides).utf8))
    }

    func testTheTermsGuardBlocksConfirmWhenThePolicyDiffers() throws {
        let reviewed = try reviewed()
        for change in [["royaltyBps": "300"], ["platformBps": "600"], ["minPrice": #""2000000""#], ["treasury": #""\#(Self.otherAccount)""#],
                       ["pendingBackstop": "60"], ["nftWasmHash": #""\#(String(repeating: "09", count: 32))""#]] {
            let message = StellarCreateMomentView.termsCheck(try plan(change), reviewed: reviewed)
            XCTAssertEqual(message.map(liteTr), "The Moments terms changed since you started. Review them again.", "\(change)")
        }
    }

    func testTheTermsGuardBlocksAPublishOfAnotherForm() throws {
        var other = Self.form
        other.price = 20_000_000
        XCTAssertNotNil(StellarCreateMomentView.termsCheck(try plan(), reviewed: try reviewed(form: other)), "the plan's price isn't the form's")
    }

    func testTheTermsGuardLetsTheReviewedTermsThrough() throws {
        XCTAssertNil(StellarCreateMomentView.termsCheck(try plan(), reviewed: try reviewed()))
    }

    /// Behind the account's USDC trustline the publish isn't built yet (the API's shape: no intent, v2's step kind), so it
    /// can't be checked: Confirm stays off and the review says to enable USDC first, which the next Review does.
    func testAPublishBehindATrustlineDoesntGoUnchecked() throws {
        let trustFirst = try JSONDecoder().decode(PlanView.self, from: Data(Self.trustThenPublish.utf8))
        XCTAssertEqual(StellarCreateMomentView.termsCheck(trustFirst, reviewed: try reviewed()).map(liteTr), "Enable USDC first, then review your Moment again.")
        XCTAssertTrue(StellarConfirmationSheet<EmptyView>.enables(trustFirst.steps[0]), "the review's enable section shows it")
    }

    /// Behind a restore of archived data the publish isn't built yet either: a restore changes no terms, and the policy
    /// changes only through a queued proposal, so it goes unless one is queued that could apply first.
    func testAPublishBehindARestoreWaitsForAQueuedPolicy() throws {
        let restoreFirst = try JSONDecoder().decode(PlanView.self, from: Data(Self.trustThenPublish.replacingOccurrences(of: #""stepKind":"trust""#, with: #""stepKind":"restore""#)
            .replacingOccurrences(of: #""kind":"trust","summary":"Enable USDC","spend":{},"display":{"asset":"USDC"}"#, with: #""kind":"restore","summary":"Restore","spend":{},"display":{"name":"Moments"}"#).utf8))
        XCTAssertNil(StellarCreateMomentView.termsCheck(restoreFirst, reviewed: try reviewed()))
        let economics = try XCTUnwrap(try JSONDecoder().decode(StellarEconomicsV2.self, from: Data(Self.economics.replacingOccurrences(
            of: #""pendingPolicy":null"#, with: #""pendingPolicy":{"policy":\#(Self.policy),"eta":"2026-10-15T10:00:00.000Z","expires":"2026-10-16T10:00:00.000Z","state":"ready"}"#).utf8)).moments)
        let queued = StellarCreateMomentView.Reviewed(form: Self.form, economics: economics, upload: StellarMomentUploadV2(mediaUrl: Self.photo, posterUrl: nil))
        let during = try XCTUnwrap(StellarFormat.date("2026-10-15T12:00:00.000Z"))
        XCTAssertEqual(StellarCreateMomentView.termsCheck(restoreFirst, reviewed: queued, now: during).map(liteTr),
                       "A Moments policy change is queued. Publish once it takes effect or lapses.")
        let soon = try XCTUnwrap(StellarFormat.date("2026-10-15T09:55:00.000Z"))
        XCTAssertNotNil(StellarCreateMomentView.termsCheck(restoreFirst, reviewed: queued, now: soon), "it can apply within minutes")
        let early = try XCTUnwrap(StellarFormat.date("2026-10-14T10:00:00.000Z"))
        XCTAssertNil(StellarCreateMomentView.termsCheck(restoreFirst, reviewed: queued, now: early), "a day before it can apply")
        let lapsed = try XCTUnwrap(StellarFormat.date("2026-10-17T12:00:00.000Z"))
        XCTAssertNil(StellarCreateMomentView.termsCheck(restoreFirst, reviewed: queued, now: lapsed), "a lapsed proposal can't apply")
    }

    /// The API's own publish step: v2's builder kind, its intent the publish's.
    func testTheTermsGuardFindsTheAPIsPublishStep() throws {
        for kind in ["moment_v2_publish", "moment_publish"] {
            let shape = Self.publishPlan([:]).replacingOccurrences(of: #""stepKind":"moment_v2_publish""#, with: #""stepKind":"\#(kind)""#)
            XCTAssertNil(StellarCreateMomentView.termsCheck(try JSONDecoder().decode(PlanView.self, from: Data(shape.utf8)), reviewed: try reviewed()), kind)
        }
    }

    // MARK: - View in Freighter (§8.11.6)

    func testFreighterGetsTheMomentsContractAndTheEditionsTokenId() throws {
        let contract = try XCTUnwrap(StellarAccountID(" \(Self.nft.lowercased())\n"), "pasted with blanks and in lower case")
        XCTAssertEqual(contract.kind, .contract)
        XCTAssertEqual(contract.checksummed, Self.nft, "the copy is the checksummed address, never what was typed")
        let edition = StellarFreighterEdition(contract: contract, tokenId: 1_234, name: "Dusk", image: nil, isVideo: false)
        XCTAssertEqual(edition.tokenText, "1234", "digits only, never grouped")
        XCTAssertNil(StellarAccountID("S" + Self.nft.dropFirst()), "never a seed")
    }

    func testACollectsEditionsAreItsTokenIds() throws {
        let results = [try JSONDecoder().decode(TxStatus.self, from: Data(#"{"hash":"\#(String(repeating: "b", count: 64))","status":"success","returnValue":{"first_rank":12,"editions":3,"gross":"30000000","entitlement":"6000000000"}}"#.utf8))]
        XCTAssertEqual(MomentsV2Store.collectedEditions(results).map(Array.init), [12, 13, 14])
        XCTAssertEqual(StellarMomentText.editions([12, 13, 14, 15, 16, 17]), "#12, #13 +4")
        XCTAssertEqual(StellarMomentText.editions([7]), "#7")
    }

    // MARK: - The collect ticket (§8.11.2)

    func testTheCollectStepperIsNeverEmpty() {
        XCTAssertEqual(StellarMomentText.collectLimit(maxPerCollect: nil), 1)
        XCTAssertEqual(StellarMomentText.collectLimit(maxPerCollect: 0), 1)
        XCTAssertEqual(StellarMomentText.collectLimit(maxPerCollect: 20), 20)
    }

    func testTheCollectThatReachesTheThresholdCompletesTheMoment() throws {
        // 10 USDC threshold, 75% reserve, 6 USDC in: 4 USDC to go, 1 USDC an edition.
        let status = try Self.status(reserve: "60000000")
        XCTAssertFalse(StellarMomentText.completes(status, quantity: 5), "5 × 0.75 = 3.75 USDC")
        XCTAssertTrue(StellarMomentText.completes(status, quantity: 6), "6 × 0.75 = 4.5 USDC")
        XCTAssertEqual(StellarMomentText.remaining(status), 40_000_000)
        XCTAssertNil(StellarMomentText.remaining(try Self.status(reserve: "100000000")))
    }

    /// The ticket's "You pay" and its shortfall: price × quantity, and for the collect that completes the Moment only what
    /// its reserve still needs, as moments-v2 pulls it (ceil(remaining × 10,000 / reserve share)).
    func testTheCollectThatCompletesAMomentPullsOnlyWhatItsReserveNeeds() throws {
        let status = try Self.status(reserve: "60000000")
        XCTAssertEqual(StellarMomentText.gross(status, quantity: 5), 50_000_000, "not terminal: price × quantity")
        XCTAssertEqual(StellarMomentText.gross(status, quantity: 6), 53_333_334, "4 USDC to go at 75%: 5.3333334 USDC, rounded up")
        XCTAssertEqual(StellarMomentText.gross(status, quantity: 20), 53_333_334, "never more than the reserve needs")
        XCTAssertEqual(StellarMomentText.gross(try Self.status(reserve: "0"), quantity: 1), 10_000_000)
    }

    /// Monad's "You get": the editions the stepper's collect mints and the coins promised for them (gross × the Moment's
    /// rate), following the stepper; the collect that completes the Moment mints only what its gross pays for.
    func testYouGetFollowsTheStepper() throws {
        // 1 USDC an edition, 10,000 coin units per USDC unit promised.
        let status = try Self.status(reserve: "0", rate: ("10000", "1"))
        let one = try XCTUnwrap(StellarMomentText.collectGets(status, quantity: 1))
        XCTAssertEqual(one.editions, 1)
        XCTAssertEqual(one.coins, "100000000000", "1 USDC (10,000,000 units) × 10,000")
        let five = try XCTUnwrap(StellarMomentText.collectGets(status, quantity: 5))
        XCTAssertEqual(five.editions, 5)
        XCTAssertEqual(five.coins, "500000000000")
        // 4 USDC to go at 75%: 6 asked, 5.3333334 USDC pulled, 6 editions minted.
        let terminal = try XCTUnwrap(StellarMomentText.collectGets(try Self.status(reserve: "60000000", rate: ("3", "2")), quantity: 20))
        XCTAssertEqual(terminal.editions, 6)
        XCTAssertEqual(terminal.coins, "80000001", "53,333,334 × 3 / 2, rounded down")
        XCTAssertNil(StellarMomentText.collectGets(try Self.status(reserve: "0", rate: ("1", "0")), quantity: 1), "no rate, no row")
    }

    /// The stats strip as Monad's: dollars, compact ("$1.00", "$25.93" for the FDV), never "25.9259259 USDC".
    func testTheStatsAreDollarsAsOnMonad() throws {
        XCTAssertEqual(StellarMomentText.perEdition("10000000"), PriceFormat.usdValue(1, fractionDigits: 2...4))
        XCTAssertEqual(StellarMomentText.perEdition("259259259"), PriceFormat.usdValue(25.9259, fractionDigits: 2...4))
        XCTAssertFalse(StellarMomentText.perEdition("259259259").contains("USDC"))
        XCTAssertEqual(StellarMomentText.fdv(20_000_000_000), MomentsFormat.fdv(2_000))
        XCTAssertEqual(StellarMomentText.perEdition("n/a"), "—")
    }

    /// Share sends the Moment's title and ticker with its NFT contract's page on StellarExpert, the build's own network:
    /// never a local stack's address.
    func testShareSendsTheTitleTickerAndTheContractsPage() throws {
        let link = try XCTUnwrap(StellarMomentText.shareLink(nft: Self.nft))
        XCTAssertEqual(link, StellarAccountID(Self.nft)?.explorerURL())
        XCTAssertEqual(link.scheme, "https")
        XCTAssertTrue(link.absoluteString.contains(Self.nft))
        XCTAssertFalse(["127.0.0.1", "localhost"].contains(link.host() ?? ""))
        XCTAssertEqual(StellarMomentText.shareMessage(title: "Harbour at dusk", symbol: "DUSK"), "Harbour at dusk ($DUSK)")
        XCTAssertEqual(StellarMomentText.shareMessage(title: "Harbour at dusk", symbol: nil), "Harbour at dusk")
        XCTAssertNil(StellarMomentText.shareLink(nft: "not-an-address"))
        // What the button hands its ShareLink: that link, the title as the subject and preview, title and ticker as the words.
        XCTAssertEqual(StellarMomentText.share(nft: Self.nft, title: "Harbour at dusk", symbol: "DUSK"),
                       StellarMomentShare(link: link, subject: "Harbour at dusk", message: "Harbour at dusk ($DUSK)"))
        XCTAssertNil(StellarMomentText.share(nft: "not-an-address", title: "Harbour at dusk", symbol: "DUSK"), "no link, no button")
    }

    /// Share is one of the navigation bar's own buttons, enabled, so the whole round button takes the tap, as Back's does.
    /// A ShareLink labelled with a bare image was hosted in the bar as a view of its own, the glyph's width: a tap on the
    /// rest of the button did nothing.
    func testShareIsOneOfTheNavigationBarsOwnButtons() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            Color.clear.toolbar {
                ToolbarItem(placement: .topBarTrailing) { StellarMomentShareButton(nft: Self.nft, name: "Harbour at dusk", symbol: "DUSK", image: nil) }
            }
        })
        window.makeKeyAndVisible()
        var items: [UIBarButtonItem] = []
        let deadline = Date().addingTimeInterval(5)
        while items.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            items = Self.barButtons(in: window)
        }
        let share = try XCTUnwrap(items.first, "the toolbar shows the Share button")
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(share.customView, "a button of the bar's own, not a view hosted in it")
        XCTAssertTrue(share.isEnabled)
    }

    /// The preview is the picture the page's header keeps: the header's art box is a page header's size on every iPhone,
    /// so the Share button looks up the header's own sources.
    func testSharesPreviewIsTheHeadersPicture() {
        for side: CGFloat in [288, 343, 370, 408] {
            XCTAssertEqual(ImageSizeBucket.bucket(points: side), ImageSizeBucket.largest, "\(side) pt")
            XCTAssertEqual(StellarMomentShareButton.artworkSources(Self.photo).map(\.url), StellarImages.sources(Self.photo, pointSize: side).map(\.url), "\(side) pt")
        }
        XCTAssertFalse(StellarMomentShareButton.artworkSources(Self.photo).isEmpty, "an upload of this build's media base")
        XCTAssertTrue(StellarMomentShareButton.artworkSources(nil).isEmpty, "no picture: the wordmark")
    }

    /// The bar buttons of every navigation bar in `window`, each once.
    private static func barButtons(in window: UIWindow) -> [UIBarButtonItem] {
        var bars: [UINavigationBar] = []
        var views: [UIView] = [window]
        while let view = views.popLast() {
            if let bar = view as? UINavigationBar { bars.append(bar) }
            views += view.subviews
        }
        var buttons: [UIBarButtonItem] = []
        var seen = Set<ObjectIdentifier>()
        for item in bars.flatMap({ $0.items ?? [] }) {
            let groups: [UIBarButtonItemGroup] = item.leadingItemGroups + item.trailingItemGroups
            let all: [UIBarButtonItem] = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) + groups.flatMap(\.barButtonItems)
            buttons += all.filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
        return buttons
    }

    /// When is a day and a time: the page shows its day, Monad's way, where it is read; a day alone is that day anywhere.
    func testWhenIsShownAsItsDay() throws {
        var style = Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale)
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        style.timeZone = tokyo
        let taken = "2026-10-14T18:30:00-05:00" // 23:30 UTC: the 15th in Tokyo
        XCTAssertEqual(StellarMomentText.day(taken, timeZone: tokyo), try XCTUnwrap(StellarFormat.date(taken)).formatted(style))
        style.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(StellarMomentText.day("2026-10-14", timeZone: tokyo), Date(timeIntervalSince1970: 1_791_936_000).formatted(style))
        XCTAssertNil(StellarMomentText.day("2026-10-14T18:30", timeZone: tokyo))
    }

    /// Publish's links: an ipfs:// CID through the app's gateways, an https link as it is, nothing else; a fetched video
    /// is an MP4 or QuickTime movie by its bytes.
    func testPublishLinksAreFetchedOnlyFromWhatTheyName() throws {
        let cid = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"
        XCTAssertEqual(StellarMediaLink.sources("ipfs://\(cid)"), MomentsMath.ipfsGateways.compactMap { URL(string: $0 + cid) })
        XCTAssertEqual(StellarMediaLink.sources(" https://example.com/dusk.jpg "), [URL(string: "https://example.com/dusk.jpg")!])
        for refused in ["http://example.com/dusk.jpg", "ipfs://not-a-cid", "ftp://example.com/a.jpg", "https://user:pw@example.com/a.jpg", "dusk.jpg",
                        "https://example.com/" + String(repeating: "a", count: 2_100)] {
            XCTAssertNil(StellarMediaLink.sources(refused), refused)
        }
        let mp4 = Data([0, 0, 0, 0x18] + Array("ftypisom".utf8) + [0, 0, 2, 0])
        let mov = Data([0, 0, 0, 0x14] + Array("ftypqt  ".utf8) + [0, 0, 2, 0])
        XCTAssertEqual(StellarMediaLink.videoType(mp4), "video/mp4")
        XCTAssertEqual(StellarMediaLink.videoType(mov), "video/quicktime")
        XCTAssertNil(StellarMediaLink.videoType(Data("<!doctype html><html>".utf8)))
        XCTAssertNil(StellarMediaLink.videoType(Data([0xFF, 0xD8, 0xFF])))
        XCTAssertEqual(StellarMediaLink.problem(RemoteMedia.Failure.notAnImage, video: false), liteTr(LocalizedStringResource("That link isn't an image DyorHQ can use.", table: "StellarMoments")))
        XCTAssertEqual(StellarMediaLink.problem(StellarMediaLink.Failure.notAVideo, video: true), liteTr(LocalizedStringResource("That link isn't an MP4 or MOV video.", table: "StellarMoments")))
    }

    func testAMomentsFigures() throws {
        let status = try Self.status(reserve: "0")
        XCTAssertEqual(StellarMomentText.fdvAtOpen(status), 259_259_259, "the API's FDV at open for 10%: 25.9259259 USDC")
        XCTAssertEqual(StellarMomentText.usdc("10000000"), "\(StellarFormat.units(10_000_000)) USDC")
        XCTAssertEqual(StellarMomentText.coins("6000000000", symbol: "DUSK"), "\(StellarFormat.units("6000000000", compact: true)) $DUSK")
        var style = Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale)
        style.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(StellarMomentText.day("2026-10-14"), Date(timeIntervalSince1970: 1_791_936_000).formatted(style), "the day itself, in any time zone")
        XCTAssertNil(StellarMomentText.day("14/10/2026"))
    }

    // MARK: - Graduation's times (contracts v2 §21)

    func testGraduationTurnsSlowAfterAnHour() throws {
        let pending = try Self.status(reserve: "100000000", state: "graduation_pending", completedAt: "2026-10-15T10:00:00.000Z")
        XCTAssertFalse(StellarMomentText.isSlow(pending, at: try XCTUnwrap(StellarFormat.date("2026-10-15T10:59:59.000Z"))))
        XCTAssertTrue(StellarMomentText.isSlow(pending, at: try XCTUnwrap(StellarFormat.date("2026-10-15T11:00:00.000Z"))))
        let collecting = try Self.status(reserve: "0", completedAt: "2026-10-15T10:00:00.000Z")
        XCTAssertFalse(StellarMomentText.isSlow(collecting, at: try XCTUnwrap(StellarFormat.date("2026-10-16T10:00:00.000Z"))))
    }

    /// An attempt that records the first failure starts the stuck clock: the Moment can expire from the later of its
    /// deadline and the earlier of that clock and the backstop.
    func testAFailedAttemptsExpiryDate() throws {
        let now = try XCTUnwrap(StellarFormat.date("2026-10-16T10:00:00.000Z"))
        let pending = try Self.status(reserve: "100000000", state: "graduation_pending", completedAt: "2026-10-15T10:00:00.000Z",
                                      backstopAt: "2026-11-14T10:00:00.000Z")
        XCTAssertEqual(StellarMomentText.expiry(afterFailureOf: pending, stuckExpiry: 604_800, at: now), StellarFormat.date("2026-10-23T10:00:00.000Z"), "7 days after the attempt")
        XCTAssertEqual(StellarMomentText.expiry(afterFailureOf: pending, stuckExpiry: 60 * 86_400, at: now), StellarFormat.date("2026-11-14T10:00:00.000Z"), "the backstop comes first")
        XCTAssertEqual(StellarMomentText.expiry(afterFailureOf: pending, stuckExpiry: 300, at: try XCTUnwrap(StellarFormat.date("2026-10-15T08:00:00.000Z"))),
                       StellarFormat.date("2026-10-15T11:00:00.000Z"), "never before the deadline")
        XCTAssertNil(StellarMomentText.expiry(afterFailureOf: try Self.status(reserve: "0"), stuckExpiry: 300, at: now), "only while it waits to graduate")
    }

    /// An expired Moment's coins never exist: nothing is owed.
    func testAnExpiredMomentOwesNoCoins() throws {
        let vesting = try JSONDecoder().decode(StellarMomentVestingV2.self, from: Data(Self.vesting(vests: true).utf8))
        XCTAssertEqual(StellarMomentText.owedCoins(vesting: vesting, you: nil, phase: .collecting), "1000000000")
        XCTAssertNil(StellarMomentText.owedCoins(vesting: vesting, you: nil, phase: .expired))
        let ended = try JSONDecoder().decode(StellarMomentVestingV2.self, from: Data(Self.vesting(vests: false).utf8))
        XCTAssertNil(StellarMomentText.owedCoins(vesting: ended, you: nil, phase: .windowClosed), "the vesting read says it doesn't vest")
    }

    func testAMomentCanExpireFromItsExpiry() throws {
        let status = try Self.status(reserve: "0", expiresAt: "2026-10-22T11:00:00.000Z")
        XCTAssertFalse(StellarMomentText.isExpirable(status, at: try XCTUnwrap(StellarFormat.date("2026-10-22T10:59:59.000Z"))))
        XCTAssertTrue(StellarMomentText.isExpirable(status, at: try XCTUnwrap(StellarFormat.date("2026-10-22T11:00:00.000Z"))))
        XCTAssertFalse(StellarMomentText.isExpirable(try Self.status(reserve: "0"), at: .distantFuture), "no expiry: graduated or expired")
    }

    // MARK: - Publish opens the new Moment (§8.11.4)

    func testAPublishOpensTheNewMomentWithItsMedia() throws {
        let results = [try JSONDecoder().decode(TxStatus.self, from: Data(#"{"hash":"\#(String(repeating: "c", count: 64))","status":"success","returnValue":"\#(Self.nft)"}"#.utf8))]
        let video = StellarMomentUploadV2(mediaUrl: Self.video, posterUrl: Self.photo)
        let listing = try XCTUnwrap(StellarCreateMomentView.listing(results: results, form: Self.form, upload: video))
        XCTAssertEqual(listing.nft, Self.nft)
        XCTAssertEqual([listing.name, listing.symbol, listing.image, listing.video], ["Dusk", "DUSK", Self.photo, Self.video], "the poster is the image")
        let photo = try XCTUnwrap(StellarCreateMomentView.listing(results: results, form: Self.form, upload: StellarMomentUploadV2(mediaUrl: Self.photo, posterUrl: nil)))
        XCTAssertNil(photo.video)
        let none = [try JSONDecoder().decode(TxStatus.self, from: Data(#"{"hash":"\#(String(repeating: "d", count: 64))","status":"success"}"#.utf8))]
        XCTAssertNil(StellarCreateMomentView.listing(results: none, form: Self.form, upload: video), "nothing to open without the new address")
    }

    /// A page opened by its NFT address shows what the indexer recorded: the name, media, place and date.
    func testAPageOpenedByItsAddressShowsTheMomentAsRecorded() throws {
        let bare = StellarMomentListingV2(nft: Self.nft)
        XCTAssertEqual(StellarMomentText.merged(bare, detail: nil), bare)
        let detail = try JSONDecoder().decode(StellarMomentDetailV2.self, from: Data(Self.detail.utf8))
        let shown = StellarMomentText.merged(bare, detail: detail)
        XCTAssertEqual([shown.name, shown.symbol, shown.place, shown.takenOn, shown.image, shown.video], ["Dusk", "DUSK", "Accra", "2026-10-14", Self.photo, Self.video])
        let other = StellarMomentListingV2(nft: Self.otherNft, name: "Elsewhere")
        XCTAssertEqual(StellarMomentText.merged(other, detail: detail), other, "another Moment's read never shows")
    }

    // MARK: - References (§3.7)

    /// A v2 Moment's reference opens it by its NFT address; a number still opens a retired v1 Moment.
    func testAV2MomentsReferenceNamesItsAddress() {
        XCTAssertEqual(StellarDestination(reference: MomentsV2Store.reference(Self.nft)), .momentV2(nft: Self.nft))
        XCTAssertEqual(StellarDestination.momentV2(nft: Self.nft).reference, "stellar:moment/\(Self.nft)")
        XCTAssertEqual(StellarDestination.momentV2(nft: Self.nft).tab, .moments)
        XCTAssertEqual(StellarDestination(reference: "stellar:moment/7"), .moment(id: 7))
        XCTAssertNil(StellarDestination(reference: "stellar:moment/G\(Self.nft.dropFirst())"), "an account isn't a Moment")
        XCTAssertNil(StellarDestination(reference: "stellar:moment/\(Self.nft.dropLast())"), "a malformed contract")
    }

    func testAQueuedPolicyNamesWhatItChanges() throws {
        let economics = try XCTUnwrap(try JSONDecoder().decode(StellarEconomicsV2.self, from: Data(Self.economics.utf8)).moments)
        var next = try JSONSerialization.jsonObject(with: Data(Self.policy.utf8)) as! [String: Any]
        next["royaltyBps"] = 300
        next["treasury"] = Self.otherAccount
        let changed = try JSONDecoder().decode(StellarMomentsPolicyV2.self, from: JSONSerialization.data(withJSONObject: next))
        XCTAssertEqual(StellarCreateMomentView.changes(from: economics.policy, to: changed), [.royalty, .treasury])
        XCTAssertEqual(StellarCreateMomentView.changes(from: economics.policy, to: economics.policy), [])
    }

    func testCoinsOfTheSupply() {
        XCTAssertEqual(StellarCreateMomentView.coins("1000000000000000", bps: 1_000), "100000000000000")
        XCTAssertEqual(StellarCreateMomentView.coins("1000000000000000", bps: 0), "0")
    }

    // MARK: - Fixtures (the API's moments_v2.ts shapes)

    static let nft = "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5"
    static let otherNft = "CACB5AH45XMW4BHBYUUPEEZDMXGX5LBBBMSZRBS7YUUXGGQLZVM7FN7Z"
    static let otherAccount = "GBQ7Y7NAGZ3BGF2D3BKGOOQV3MX6DVAGOVQLH4NJAZG5MBUVOMHAZKZD"
    static let photo = "http://127.0.0.1:8000/lite/v1/local-media/lite-media/uploads/GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR/41019444-f54f-4a9e-ac88-2667a92257fa.jpg"
    static let video = "http://127.0.0.1:8000/lite/v1/local-media/lite-media/uploads/GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR/41019444-f54f-4a9e-ac88-2667a92257fb.mp4"

    static var form: StellarMomentFormV2 {
        StellarMomentFormV2(name: "Dusk", symbol: "DUSK", place: "Accra", takenOn: "2026-10-14", price: 10_000_000, allocationBps: 1_000, windowSecs: 86_400)
    }

    static let policy = """
    {"threshold":"100000000","minPrice":"1000000","creatorBps":2000,"platformBps":500,"reserveBps":7500,"maxCreatorAllocBps":1000,
     "expiryCreatorBps":7000,"royaltyBps":500,"platform":"GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
     "treasury":"GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK"}
    """

    static let economics = """
    {"launchpad":null,"moments":{"generation":2,"contract":"CACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQLC2U",
     "quote":{"asset":"USDC","contract":"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"},
     "supply":"1000000000000000","maxPerCollect":20,"maxClaimIds":20,"policy":\(policy),"pendingPolicy":null,
     "terms":{"policy":\(policy),"externalBase":"https://dyorhq.fun/moments/",
      "nftWasmHash":"0606060606060606060606060606060606060606060606060606060606060606",
      "coinWasmHash":"0707070707070707070707070707070707070707070707070707070707070707",
      "graduator":"CABQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGCK3",
      "executor":"CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526",
      "locker":"CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ",
      "durations":{"vestPeriod":2592000,"stuckExpiry":604800,"pendingBackstop":2592000,"timelock":172800,"timelockWindow":604800,
       "minWindow":3600,"maxWindow":2592000,"harvestInterval":3600},
      "harvestBps":6667,"harvestCreatorBps":4000,
      "harvest":{"intervalSecs":3600,"harvestedBps":6667,"compoundedBps":3333,"ratio":"3,333 : 6,667",
       "quoteSide":{"creatorBps":4000,"platformBps":6000},"coinSide":"burned"}},
     "publishingPaused":false,"guardianPaused":false,"completionGross":"133333334","maxPrice":"133333334",
     "fdvAtOpen":"259259259","fdvAtOpenUsd":25.93,"fdvByAllocation":[{"allocationBps":1000,"fdv":"259259259","fdvUsd":25.93}]}}
    """

    static func publishPlan(_ overrides: [String: String]) -> String {
        let display: [(String, String)] = [
            ("generation", "2"), ("nft", "\"\(nft)\""), ("name", "\"Dusk\""), ("symbol", "\"DUSK\""), ("price", "\"10000000\""),
            ("quote", "\"USDC\""), ("allocationBps", "1000"), ("windowSecs", "86400"), ("threshold", "\"100000000\""),
            ("minPrice", "\"1000000\""), ("creatorBps", "2000"), ("platformBps", "500"), ("reserveBps", "7500"), ("maxCreatorAllocBps", "1000"),
            ("expiryCreatorBps", "7000"), ("royaltyBps", "500"), ("platform", "\"GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N\""),
            ("treasury", "\"GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK\""), ("externalBase", "\"https://dyorhq.fun/moments/\""),
            ("nftWasmHash", "\"0606060606060606060606060606060606060606060606060606060606060606\""),
            ("coinWasmHash", "\"0707070707070707070707070707070707070707070707070707070707070707\""),
            ("graduator", "\"CABQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGCK3\""),
            ("executor", "\"CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526\""),
            ("locker", "\"CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ\""), ("vestPeriod", "2592000"), ("stuckExpiry", "604800"),
            ("pendingBackstop", "2592000"), ("timelock", "172800"), ("timelockWindow", "604800"), ("minWindow", "3600"), ("maxWindow", "2592000"),
            ("harvestInterval", "3600"), ("harvestBps", "6667"), ("harvestCreatorBps", "4000"),
        ]
        let fields = display.map { "\"\($0.0)\":\(overrides[$0.0] ?? $0.1)" }.joined(separator: ",")
        return """
        {"planId":"publish","kind":"moment_publish","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
         {"id":"s1","label":"Publish DUSK","status":"pending","stepKind":"moment_v2_publish","maxFee":"51250","feePayer":"user","reserveDelta":0,
          "intent":{"kind":"moment_publish","summary":"Publish","spend":{},"display":{\(fields)}}}]}
        """
    }

    static let trustThenPublish = """
    {"planId":"publish-2","kind":"moment_publish","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
     {"id":"s1","label":"Enable USDC","status":"pending","stepKind":"trust","maxFee":"10000","feePayer":"user","reserveDelta":1,
      "intent":{"kind":"trust","summary":"Enable USDC","spend":{},"display":{"asset":"USDC"}}},
     {"id":"s2","label":"Publish DUSK","status":"pending","stepKind":"moment_v2_publish","maxFee":"51250","feePayer":"user","reserveDelta":0}]}
    """

    static func status(reserve: String, state: String = "collecting", completedAt: String? = nil, expiresAt: String? = nil,
                       backstopAt: String? = nil, rate: (num: String, den: String) = ("1", "1")) throws -> StellarMomentStatusV2 {
        let quoted = { (text: String?) in text.map { "\"\($0)\"" } ?? "null" }
        let json = """
        {"generation":2,"nft":"\(nft)","creator":"GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
         "coin":"CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6","pool":null,"state":"\(state)","price":"10000000",
         "threshold":"100000000","reserve":"\(reserve)","totalGross":"0","progress":0,"collects":0,"editions":0,"entitlements":"0",
         "creatorAllocBps":1000,"creatorBps":2000,"platformBps":500,"reserveBps":7500,"expiryCreatorBps":7000,"royaltyBps":500,
         "rate":{"num":"\(rate.num)","den":"\(rate.den)"},"publishedAt":"2026-10-13T11:00:00.000Z","deadline":"2026-10-15T11:00:00.000Z",
         "completedAt":\(quoted(completedAt)),"stuckSince":null,"graduatedAt":null,"endedAt":null,"expiresAt":\(quoted(expiresAt)),
         "expiresBy":null,"backstopAt":\(quoted(backstopAt)),"failureExpiresAt":null,"expirable":false,"graduatable":false,"failure":null,
         "proceeds":{"creator":"0","platform":"0","treasury":"0"}}
        """
        return try JSONDecoder().decode(StellarMomentStatusV2.self, from: Data(json.utf8))
    }

    static func vesting(vests: Bool) -> String {
        """
        {"generation":2,"nft":"\(nft)","account":"G","coin":"CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6","state":"collecting",
         "vests":\(vests),"vestPeriodSecs":2592000,"startsAt":null,"periodsElapsed":null,
         "claimable":{"collector":"0","creator":"0","total":"0"},
         "collector":{"total":"1000000000","claimed":"0","claimable":"0","vested":"0","tranches":[],"nextAt":null,"fullAt":null},"creator":null}
        """
    }

    /// `GET /v1/moments/v2/:nft`, as the API's fixture moment-v2.json shapes it.
    static let detail = """
    {"moment":{"generation":2,"nft":"\(nft)","number":2,"creator":"GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN","uri":"https://media.test/m/1.json",
      "name":"Dusk","symbol":"DUSK","title":"Dusk","description":null,"place":"Accra","takenOn":"2026-10-14","mediaUrl":"\(video)","mediaType":"video",
      "posterUrl":"\(photo)","price":"10000000","quote":"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA","quoteCode":"USDC","priceUsd":1,
      "threshold":"100000000","totalGross":"0","reserve":"0","progress":0,"minted":0,"collects":0,"collectors":0,"creatorAllocBps":1000,
      "platformBps":500,"royaltyBps":500,"deadline":"2026-10-22T09:00:00.000Z","state":"collecting","open":true,"coin":null,"pool":null,
      "durations":{"vestPeriod":2592000,"stuckExpiry":604800,"pendingBackstop":2592000,"timelock":172800,"timelockWindow":604800,"minWindow":3600,
       "maxWindow":2592000,"harvestInterval":3600},
      "publishedAt":"2026-10-15T09:41:00.000Z","completedAt":null,"graduatedAt":null,"expiredAt":null},
     "collectors":[],"collectorsSummary":{"count":0,"largest":null},"you":null,"creatorEarned":"0","view":"public"}
    """
}
