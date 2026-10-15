// The Moment page, Publish and View in Freighter (docs/DESIGN-stellar-parity.md §8.11.2–8.11.6;
// docs/DESIGN-stellar-contracts-v2.md §21): the publish review's terms guard, Freighter's contract and token id, the
// collect ticket's limits, a v2 Moment's times and figures, and the new Moment Publish opens.
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

    /// Behind the account's USDC trustline the publish isn't built yet: the review shows the enable step, and the server
    /// builds the publish with the terms as they stand once that step confirmed.
    func testAPublishBehindATrustlineIsCheckedOnceBuilt() throws {
        let trustFirst = try JSONDecoder().decode(PlanView.self, from: Data(Self.trustThenPublish.utf8))
        XCTAssertNil(StellarCreateMomentView.termsCheck(trustFirst, reviewed: try reviewed()))
        XCTAssertTrue(StellarConfirmationSheet<EmptyView>.enables(trustFirst.steps[0]), "the review's enable section shows it")
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
         {"id":"s1","label":"Publish DUSK","status":"pending","stepKind":"moment_publish","maxFee":"51250","feePayer":"user","reserveDelta":0,
          "intent":{"kind":"moment_publish","summary":"Publish","spend":{},"display":{\(fields)}}}]}
        """
    }

    static let trustThenPublish = """
    {"planId":"publish-2","kind":"moment_publish","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
     {"id":"s1","label":"Enable USDC","status":"pending","stepKind":"trust","maxFee":"10000","feePayer":"user","reserveDelta":1,
      "intent":{"kind":"trust","summary":"Enable USDC","spend":{},"display":{"asset":"USDC"}}},
     {"id":"s2","label":"Publish DUSK","status":"pending","stepKind":"moment_publish","maxFee":"51250","feePayer":"user","reserveDelta":0}]}
    """

    static func status(reserve: String, state: String = "collecting", completedAt: String? = nil, expiresAt: String? = nil) throws -> StellarMomentStatusV2 {
        let quoted = { (text: String?) in text.map { "\"\($0)\"" } ?? "null" }
        let json = """
        {"generation":2,"nft":"\(nft)","creator":"GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
         "coin":"CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6","pool":null,"state":"\(state)","price":"10000000",
         "threshold":"100000000","reserve":"\(reserve)","totalGross":"0","progress":0,"collects":0,"editions":0,"entitlements":"0",
         "creatorAllocBps":1000,"creatorBps":2000,"platformBps":500,"reserveBps":7500,"expiryCreatorBps":7000,"royaltyBps":500,
         "rate":{"num":"1","den":"1"},"publishedAt":"2026-10-13T11:00:00.000Z","deadline":"2026-10-15T11:00:00.000Z",
         "completedAt":\(quoted(completedAt)),"stuckSince":null,"graduatedAt":null,"endedAt":null,"expiresAt":\(quoted(expiresAt)),
         "expiresBy":null,"backstopAt":null,"failureExpiresAt":null,"expirable":false,"graduatable":false,"failure":null,
         "proceeds":{"creator":"0","platform":"0","treasury":"0"}}
        """
        return try JSONDecoder().decode(StellarMomentStatusV2.self, from: Data(json.utf8))
    }
}
