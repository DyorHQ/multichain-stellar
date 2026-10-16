@testable import DyorLite
import StellarKit
import XCTest

/// `MomentsV2Store` (docs/DESIGN-stellar-contracts-v2.md §20.2–20.3, §21): v2 Moments keyed by their NFT address. Reads
/// ask for their routes without a prompt; every plan is built once a session is held, then priced and verified on the
/// phone; a collect confirms the USDC its plan pulls and never more than price × quantity; a ticker the contracts would
/// refuse is refused before anything is sent; the terms guard names what a publish binds that its review didn't show,
/// and refuses a publish it can't see yet; claims, withdrawals, graduations (or a recorded failed attempt) and expiries
/// settle with their own words; a Moment's phase moves with its deadline; settled publishes and collects read their NFT
/// address and edition numbers.
@MainActor
final class MomentsV2StoreTests: XCTestCase {
    private var server: FakeLite!
    private var backend: TestBackend!
    private var vault: MemoryVault!
    private var defaults: UserDefaults!
    private var suite = ""
    private var tally: Tally!
    private var sessions: [LiteSession] = []
    /// The v2 plan the server answers `POST /v1/moments/build` with.
    private var answer = Answer()

    final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var json = ""
        var plan: String {
            get { lock.withLock { json } }
            set { lock.withLock { json = newValue } }
        }
    }

    override func setUp() async throws {
        server = FakeLite()
        let fake = server!
        let answer = answer
        // The v2 routes on top of the fake server's own.
        StubServer.handle(host: fake.host) { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/economics"): return (200, Data(Self.economics.utf8))
            case ("GET", "/v1/moments/\(Self.nft)/status"): return (200, Data(Self.status(state: "collecting").utf8))
            case ("GET", "/v1/moments/v2/\(Self.nft)"): return (200, FakeLite.fixture("moment-v2"))
            case ("GET", "/v1/moments/\(Self.nft)/vesting"):
                guard request.token != nil || request.route.contains("address=") else { return (401, FakeLite.error("unauthorized", "Sign in.")) }
                return (200, Data(Self.vesting.utf8))
            case ("POST", "/v1/moments/metadata"):
                guard request.token != nil else { return (401, FakeLite.error("unauthorized", "Sign in.")) }
                return (200, Data(#"{"uri":"https://media.test/m/1.json","posterUrl":"https://media.test/u/p.jpg"}"#.utf8))
            case ("POST", "/v1/moments/build"):
                guard request.token != nil else { return (401, FakeLite.error("unauthorized", "Sign in.")) }
                return (200, Data(answer.plan.utf8))
            default:
                return fake.answer(request)
            }
        }
        backend = TestBackend(api: server.api())
        vault = MemoryVault()
        suite = "lite.moments.v2.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        tally = Tally()
    }

    override func tearDown() async throws {
        server.stop()
        defaults.removePersistentDomain(forName: suite)
        sessions = []
    }

    private var env: LiteEnvironment { LiteEnvironment(apiURL: server.base, pinned: .testnet, buildNumber: 23) }

    private func ready() async throws -> (LiteSession, MomentsV2Store) {
        let keys = TestAccount.seedKeys(appLock: false, tally: tally)
        defaults.set(true, forKey: LiteSession.activatedKey(keys.address))
        vault.save(server.issueSession(), account: keys.address, network: "testnet")
        let session = LiteSession(env: env, stellarAddress: keys.address, monad: nil, keys: keys, setupKey: nil, backend: backend, vault: vault,
                                  defaults: defaults)
        sessions.append(session)
        await session.resumeAtLaunch()
        return (session, MomentsV2Store(store: try XCTUnwrap(session.store)))
    }

    private var builds: [[String: Any]] {
        server.seen.filter { $0.method == "POST" && $0.path == "/v1/moments/build" }
            .compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    // MARK: - Reads

    func testReadsAskForTheirRoutesWithoutAPrompt() async throws {
        let (_, moments) = try await ready()
        let read = try await moments.economics()
        let economics = try XCTUnwrap(read)
        XCTAssertEqual(economics.policy.royaltyBps, 500)
        XCTAssertEqual(economics.maxPerCollect, 20)
        let status = try await moments.status(Self.nft)
        XCTAssertEqual(status.nft, Self.nft)
        let vesting = try await moments.vesting(Self.nft)
        XCTAssertEqual(vesting.claimable.total, "200000000")
        let detail = try await moments.detail(Self.nft)
        XCTAssertEqual(detail.you?.editions, [3])
        let listing = StellarMomentListingV2(detail.moment)
        XCTAssertEqual([listing.name, listing.symbol, listing.place, listing.takenOn], ["Harbour at dusk", "DUSK", "Accra", "2026-10-13"])
        XCTAssertEqual(listing.image, detail.moment.posterUrl, "a video's image is its cover frame")
        XCTAssertEqual(listing.video, detail.moment.mediaUrl)
        XCTAssertEqual(tally.prompts, 0, "reads ask nothing")
    }

    /// Publish enables USDC first when the account can't hold it: the publish is then built at once, and its review can
    /// check it.
    func testAnAccountWithoutUSDCEnablesItBeforeItPublishes() async throws {
        let (_, moments) = try await ready()
        let enabled = await moments.needsUSDC()
        XCTAssertFalse(enabled, "USDC enabled")
        server.update { $0.usdc = false }
        let needs = await moments.needsUSDC()
        XCTAssertTrue(needs, "read again: USDC not enabled")
    }

    func testAV1ServerHasNoV2Moments() async throws {
        let (_, moments) = try await ready()
        let fake = server!
        StubServer.handle(host: fake.host) { request in
            request.path == "/v1/economics" ? (200, FakeLite.fixture("economics")) : fake.answer(request)
        }
        let economics = try await moments.economics()
        XCTAssertNil(economics, "a v1 block reads as not deployed")
    }

    // MARK: - Collect

    func testACollectConfirmsTheUSDCItsPlanPulls() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.collectPlan(total: "30000000", editions: 3)
        let action = try await moments.collectPlan(nft: Self.nft, quantity: 3, price: 10_000_000, name: "Dusk", title: "Collect DUSK")
        XCTAssertEqual(action.limits, [Self.usdc: 30_000_000], "USDC max_total, nothing else")
        XCTAssertEqual(action.reference, "stellar:moment/\(Self.nft)")
        XCTAssertEqual(action.section, .moments)
        XCTAssertEqual(MomentsV2Store.collect(in: action.plan), StellarCollectV2(editions: 3, total: 30_000_000, entitlement: "6000000000", terminal: false))
        let sent = try XCTUnwrap(builds.last)
        XCTAssertEqual(sent["action"] as? String, "collect")
        XCTAssertEqual(sent["nft"] as? String, Self.nft)
        XCTAssertEqual(sent["quantity"] as? Int, 3)
    }

    func testTheCollectThatCompletesAMomentConfirmsOnlyWhatItPulls() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.collectPlan(total: "13333334", editions: 2, terminal: true)
        let action = try await moments.collectPlan(nft: Self.nft, quantity: 5, price: 10_000_000, name: "Dusk", title: "Collect DUSK")
        XCTAssertEqual(action.limits, [Self.usdc: 13_333_334])
        XCTAssertEqual(MomentsV2Store.collect(in: action.plan)?.terminal, true)
        XCTAssertEqual(MomentsV2Store.collect(in: action.plan)?.editions, 2)
    }

    func testACollectThatWouldPullMoreThanPriceTimesQuantityIsRefused() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.collectPlan(total: "30000001", editions: 3)
        do {
            _ = try await moments.collectPlan(nft: Self.nft, quantity: 3, price: 10_000_000, name: "Dusk", title: "Collect DUSK")
            XCTFail("a collect above price × quantity")
        } catch {
            XCTAssertEqual(error as? LiteAPIError, .decoding("the collect"))
        }
        answer.plan = Self.collectPlan(total: "30000000", editions: 3, asset: "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC")
        do {
            _ = try await moments.collectPlan(nft: Self.nft, quantity: 3, price: 10_000_000, name: "Dusk", title: "Collect DUSK")
            XCTFail("a collect that spends another asset")
        } catch {
            XCTAssertEqual(error as? LiteAPIError, .decoding("the collect"))
        }
    }

    // MARK: - Publish

    func testATickerTheContractsRefuseIsRefusedBeforeAnythingIsSent() async throws {
        let (_, moments) = try await ready()
        let media = StellarMomentUploadV2(mediaUrl: "https://media.test/u/a.jpg", posterUrl: nil)
        for symbol in ["", "D", "DUSKDUSKDUS", "DÜSK", "DU SK", "DU-SK"] {
            let form = StellarMomentFormV2(name: "Dusk", symbol: symbol, price: 10_000_000, allocationBps: 1_000, windowSecs: 86_400)
            do {
                _ = try await moments.publishPlan(form, media: media, title: "Publish")
                XCTFail("published \(symbol)")
            } catch {
                XCTAssertEqual(error as? LiteAPIError, StellarTickerV2.refusal)
            }
        }
        XCTAssertFalse(server.paths.contains { $0.hasPrefix("POST /v1/moments") }, "nothing was sent")
    }

    func testAPublishWritesItsMetadataThenBindsTheTerms() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.publishPlan()
        let form = StellarMomentFormV2(name: "Dusk", symbol: "dusk", place: "Accra", takenOn: "2026-10-14", price: 10_000_000, allocationBps: 1_000,
                                       windowSecs: 86_400)
        let video = StellarMomentUploadV2(mediaUrl: "https://media.test/u/v.mp4", posterUrl: "https://media.test/u/p.jpg")
        let action = try await moments.publishPlan(form, media: video, title: "Publish DUSK")
        XCTAssertEqual(action.limits, [:])
        XCTAssertEqual(action.reference, "stellar:moment/\(Self.publishedNft)", "the predicted NFT address")
        let metadata = try XCTUnwrap(server.seen.first { $0.path == "/v1/moments/metadata" }?.body)
        let sentMetadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(sentMetadata["mediaType"] as? String, "video")
        XCTAssertEqual(sentMetadata["posterUrl"] as? String, "https://media.test/u/p.jpg")
        let sent = try XCTUnwrap(builds.last)
        XCTAssertEqual(sent["action"] as? String, "publish")
        XCTAssertEqual(sent["symbol"] as? String, "DUSK", "upper-cased")
        XCTAssertEqual(sent["price"] as? String, "10000000")
        XCTAssertEqual(sent["allocationBps"] as? Int, 1_000)
        XCTAssertEqual(sent["windowSecs"] as? Int, 86_400)
        XCTAssertEqual(sent["uri"] as? String, "https://media.test/m/1.json")
    }

    // MARK: - The terms guard

    private func terms() throws -> StellarMomentsTermsV2 {
        try JSONDecoder().decode(StellarEconomicsV2.self, from: Data(Self.economics.utf8)).moments!.terms
    }

    private var form: StellarMomentFormV2 {
        StellarMomentFormV2(name: "Dusk", symbol: "DUSK", price: 10_000_000, allocationBps: 1_000, windowSecs: 86_400)
    }

    private func plan(_ json: String) throws -> PlanView { try JSONDecoder().decode(PlanView.self, from: Data(json.utf8)) }

    func testTheTermsGuardPassesAPublishOfTheReviewedTerms() throws {
        XCTAssertEqual(MomentsV2Store.termsChanges(try plan(Self.publishPlan()), terms: try terms(), form: form), [])
        XCTAssertFalse(MomentsV2Store.publishWaits(try plan(Self.publishPlan())))
        // The step kind v2's builder gives a step, built or not, or v1's: the built publish is found by its intent.
        for kind in ["moment_publish", "moment_v2_publish"] {
            let shape = Self.publishPlan().replacingOccurrences(of: #""stepKind":"moment_v2_publish""#, with: #""stepKind":"\#(kind)""#)
            XCTAssertEqual(MomentsV2Store.termsChanges(try plan(shape), terms: try terms(), form: form), [], kind)
        }
    }

    func testTheTermsGuardNamesWhatChanged() throws {
        let changed = try plan(Self.publishPlan(overrides: ["royaltyBps": "300", "treasury": #""GBQ4""#, "minPrice": #""2000000""#]))
        XCTAssertEqual(MomentsV2Store.termsChanges(changed, terms: try terms(), form: form), ["minPrice", "royaltyBps", "treasury"])
        var other = form
        other.price = 20_000_000
        XCTAssertEqual(MomentsV2Store.termsChanges(try plan(Self.publishPlan()), terms: try terms(), form: other), ["price"])
    }

    func testTheTermsGuardFailsClosed() throws {
        let missing = try plan(Self.publishPlan(overrides: ["pendingBackstop": "null"]))
        XCTAssertEqual(MomentsV2Store.termsChanges(missing, terms: try terms(), form: form), ["pendingBackstop"])
        XCTAssertEqual(MomentsV2Store.termsChanges(try plan(Self.collectPlan(total: "1", editions: 1)), terms: try terms(), form: form), ["publish"])
        // Behind the account's USDC trustline the publish isn't built yet (the API's shape: no intent, v2's step kind):
        // nothing it binds can be compared, so it doesn't go.
        let trustFirst = try plan(Self.trustThenPublish)
        XCTAssertEqual(MomentsV2Store.termsChanges(trustFirst, terms: try terms(), form: form), ["publish"])
        XCTAssertTrue(MomentsV2Store.publishWaits(trustFirst))
    }

    // MARK: - Claims

    func testClaimAllTakesAtMostItsLimitAndSendsEachMomentOnce() async throws {
        let (_, moments) = try await ready()
        let many = (0...20).map { _ in Self.nft + "\(UUID())" }
        do {
            _ = try await moments.claimAllPlan(nfts: many, maxClaimIds: 20, title: "Claim all")
            XCTFail("21 Moments in one claim")
        } catch {
            XCTAssertEqual((error as? LiteAPIError)?.code, "bad_arg")
        }
        XCTAssertTrue(builds.isEmpty, "nothing was sent")
        answer.plan = Self.claimAllPlan
        let action = try await moments.claimAllPlan(nfts: [Self.nft, Self.nft, Self.publishedNft], maxClaimIds: 20, title: "Claim all")
        XCTAssertEqual(action.limits, [:])
        XCTAssertEqual(builds.last?["nfts"] as? [String], [Self.nft, Self.publishedNft])
        XCTAssertEqual(action.summary.kind, "moment_claim_all")
        XCTAssertEqual(action.section, .moments)
        let words = LiteTitles.settled(action.summary, results: [])
        XCTAssertEqual([words.title, words.body], ["Claimed vested coins", "across 2 Moments"])
        XCTAssertEqual(action.titles, ["s1": "Claim vested coins from 2 Moments"], "never the server's English")
    }

    // MARK: - Claim, withdraw, graduate and expire: each with its own words

    func testAClaimSettlesWithItsOwnWords() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.plan("moment_claim", display: #"{"generation":2,"nft":"\#(Self.nft)","collectorAmount":"200000000","creatorAmount":"0","total":"200000000"}"#)
        let action = try await moments.claimPlan(nft: Self.nft, name: "Dusk", symbol: "DUSK", title: "Claim")
        XCTAssertEqual(builds.last?["action"] as? String, "claim")
        XCTAssertEqual(action.summary.kind, "moment_claim")
        XCTAssertEqual(action.reference, "stellar:moment/\(Self.nft)")
        let words = LiteTitles.settled(action.summary, results: [])
        XCTAssertEqual([words.title, words.body], ["Claimed $DUSK", "\(MomentsV2Store.written(200_000_000)) vested coins"])
        XCTAssertEqual(action.title(of: action.plan.steps[0]), "Claim your vested coins")
    }

    func testAWithdrawalSettlesAsTheCreatorsProceeds() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.plan("moment_withdraw", display: #"{"generation":2,"nft":"\#(Self.nft)","amount":"40000000","quote":"USDC","to":"G"}"#)
        var action = try await moments.withdrawPlan(nft: Self.nft, name: "Dusk", symbol: nil, proceeds: 125_000_000, title: "Withdraw")
        XCTAssertEqual(action.summary.kind, "moment_withdraw", "never a launch's creator fees")
        var words = LiteTitles.settled(action.summary, results: [])
        XCTAssertEqual([words.title, words.body], ["Collected Dusk proceeds", "\(MomentsV2Store.written(40_000_000)) USDC creator proceeds"], "the plan's own amount")
        // Behind the account's USDC trustline the withdrawal isn't built: the page's figure, and the phone's title.
        answer.plan = Self.trustThen("moment_v2_withdraw", label: "Withdraw proceeds")
        action = try await moments.withdrawPlan(nft: Self.nft, name: "Dusk", symbol: "DUSK", proceeds: 125_000_000, title: "Withdraw")
        words = LiteTitles.settled(action.summary, results: [])
        XCTAssertEqual([words.title, words.body], ["Collected $DUSK proceeds", "\(MomentsV2Store.written(125_000_000)) USDC creator proceeds"])
        XCTAssertEqual(action.titles, ["s2": "Withdraw your proceeds"])
    }

    /// The API offers an attempt that only records a failure: its review and its notification say so, never that the
    /// Moment graduated.
    func testAGraduationThatOnlyRecordsAFailureIsNeverAnnouncedAsAGraduation() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.plan("moment_graduate", display: #"{"generation":2,"nft":"\#(Self.nft)","outcome":"failed","failureOrigin":10,"failureCode":11003,"failureName":"GraduationInvalid"}"#)
        var action = try await moments.graduatePlan(nft: Self.nft, name: "Dusk", symbol: "DUSK", reserve: 75_000_000, title: "Graduate")
        XCTAssertEqual(MomentsV2Store.graduation(in: action.plan), StellarGraduationAttemptV2(failed: true, failure: "GraduationInvalid"))
        XCTAssertEqual(action.summary.kind, "moment_graduate")
        var words = LiteTitles.settled(action.summary, results: [])
        XCTAssertEqual([words.title, words.body], ["Recorded a failed graduation of $DUSK", "GraduationInvalid"])
        XCTAssertEqual(action.title(of: action.plan.steps[0]), "Record a failed graduation attempt")

        answer.plan = Self.plan("moment_graduate", display: #"{"generation":2,"nft":"\#(Self.nft)","outcome":"failed","failureOrigin":10,"failureCode":11003,"failureName":null}"#)
        action = try await moments.graduatePlan(nft: Self.nft, name: "Dusk", symbol: "DUSK", reserve: 75_000_000, title: "Graduate")
        XCTAssertEqual(MomentsV2Store.graduation(in: action.plan)?.failure, "10 · 11003", "a failure the API's table doesn't name")

        answer.plan = Self.plan("moment_graduate", display: #"{"generation":2,"nft":"\#(Self.nft)","outcome":"graduated","failureOrigin":null,"failureCode":null,"failureName":null}"#)
        action = try await moments.graduatePlan(nft: Self.nft, name: "Dusk", symbol: "DUSK", reserve: 75_000_000, title: "Graduate")
        XCTAssertEqual(MomentsV2Store.graduation(in: action.plan), StellarGraduationAttemptV2(failed: false, failure: nil))
        words = LiteTitles.settled(action.summary, results: [])
        XCTAssertEqual([words.title, words.body], ["Graduated $DUSK", "\(MomentsV2Store.written(75_000_000)) USDC reserve into a locked pool"])
        XCTAssertEqual(action.title(of: action.plan.steps[0]), "Graduate this Moment")
    }

    func testAnExpirySettlesWithItsOwnWords() async throws {
        let (_, moments) = try await ready()
        answer.plan = Self.plan("moment_expire", display: #"{"generation":2,"nft":"\#(Self.nft)","backstop":false,"reserve":"40000000","creatorShare":"28000000","treasuryShare":"12000000","quote":"USDC"}"#)
        let action = try await moments.expirePlan(nft: Self.nft, name: "Dusk", title: "Expire")
        XCTAssertEqual(builds.last?["action"] as? String, "expire")
        XCTAssertEqual(action.summary.kind, "moment_expire")
        let words = LiteTitles.settled(action.summary, results: [])
        XCTAssertEqual([words.title, words.body], ["Expired Dusk", "\(MomentsV2Store.written(40_000_000)) USDC reserve wound down"])
        XCTAssertEqual(action.title(of: action.plan.steps[0]), "Expire this Moment")
    }

    // MARK: - The words' table

    /// Resources/MomentsV2.xcstrings: every entry has a note for its translator and the four languages the app ships,
    /// with the values its key takes, and names as they are.
    func testEveryWordHasANoteAndTheFourLanguages() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() } // MomentsV2StoreTests.swift → DyorLiteTests → Tests → DyorLite
        url.appendPathComponent("Sources/DyorLite/Resources/MomentsV2.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("the package's sources aren't readable from here") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 10)
        let specifier = try NSRegularExpression(pattern: #"%(?:\d+\$)?(@|lld)"#)
        func specifiers(_ text: String) -> [String] {
            specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) }.sorted()
        }
        func values(_ localization: [String: Any]) -> [String] {
            if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return [value] }
            let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
            return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        for (key, entry) in strings {
            XCTAssertFalse((entry["comment"] as? String ?? "").isEmpty, "no note for the translator: \(key)")
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in ["es", "fr", "ko", "zh-Hans"] {
                let found = localizations[language].map(values) ?? []
                XCTAssertFalse(found.isEmpty, "\(language) is missing: \(key)")
                for value in found {
                    XCTAssertEqual(specifiers(value), specifiers(key), "\(language) takes other values than its key: \(key) → \(value)")
                    for name in ["Moment", "USDC", "Soroswap"] where key.contains(name) {
                        XCTAssertTrue(value.contains(name), "\(language) translates or drops \(name): \(key) → \(value)")
                    }
                }
            }
        }
    }

    // MARK: - Phases

    private func status(_ state: String, deadline: String = "2026-10-15T11:00:00.000Z", stuckSince: String? = nil, failure: Bool = false) throws -> StellarMomentStatusV2 {
        try JSONDecoder().decode(StellarMomentStatusV2.self, from: Data(Self.status(state: state, deadline: deadline, stuckSince: stuckSince, failure: failure).utf8))
    }

    func testAPhaseMovesWithTheDeadlineAndARecordedFailure() throws {
        let before = try XCTUnwrap("2026-10-15T10:59:59.000Z".liteDate)
        let after = try XCTUnwrap("2026-10-15T11:00:00.000Z".liteDate)
        XCTAssertEqual(StellarMomentPhaseV2(try status("collecting"), now: before), .collecting)
        XCTAssertEqual(StellarMomentPhaseV2(try status("collecting"), now: after), .windowClosed, "from the deadline on")
        XCTAssertEqual(StellarMomentPhaseV2(try status("graduation_pending"), now: after), .graduating)
        XCTAssertEqual(StellarMomentPhaseV2(try status("graduation_pending", stuckSince: "2026-10-15T11:00:00.000Z", failure: true), now: after), .graduationFailed)
        XCTAssertEqual(StellarMomentPhaseV2(try status("graduated"), now: before), .graduated)
        XCTAssertEqual(StellarMomentPhaseV2(try status("expired"), now: before), .expired)
        XCTAssertEqual(StellarMomentPhaseV2(try status("rescued"), now: before), .windowClosed, "a state this build doesn't know offers nothing")
        XCTAssertTrue(StellarMomentPhaseV2.collecting.isCollecting)
        XCTAssertFalse(StellarMomentPhaseV2.windowClosed.isCollecting)
    }

    // MARK: - Settled results

    private func results(_ returnValue: String) throws -> [TxStatus] {
        [try JSONDecoder().decode(TxStatus.self, from: Data(#"{"hash":"\#(String(repeating: "a", count: 64))","status":"success","returnValue":\#(returnValue)}"#.utf8))]
    }

    func testASettledCollectNamesItsEditions() throws {
        XCTAssertEqual(MomentsV2Store.collectedEditions(try results(#"{"first_rank":12,"editions":3,"gross":"30000000","entitlement":"6000000000"}"#)), 12...14)
        XCTAssertEqual(MomentsV2Store.collectedEditions(try results(#"{"first_rank":"1","editions":"1"}"#)), 1...1)
        XCTAssertNil(MomentsV2Store.collectedEditions(try results(#"{"first_rank":0,"editions":3}"#)))
        XCTAssertNil(MomentsV2Store.collectedEditions(try results(#"{"editions":3}"#)))
        XCTAssertNil(MomentsV2Store.collectedEditions(try results("null")))
    }

    func testASettledPublishNamesItsNFT() throws {
        XCTAssertEqual(MomentsV2Store.publishedNFT(try results(#""\#(Self.publishedNft)""#)), Self.publishedNft)
        XCTAssertNil(MomentsV2Store.publishedNFT(try results(#""GBQ4""#)), "only a contract")
        XCTAssertNil(MomentsV2Store.publishedNFT(try results("7")))
        XCTAssertEqual(MomentsV2Store.publishing(try plan(Self.publishPlan())), Self.publishedNft)
    }

    // MARK: - Fixtures (the API's moments_v2.ts shapes, as StellarKit's V2Fixtures capture them)

    nonisolated static let nft = "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5"
    nonisolated static let publishedNft = "CACB5AH45XMW4BHBYUUPEEZDMXGX5LBBBMSZRBS7YUUXGGQLZVM7FN7Z"
    nonisolated static let usdc = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"
    nonisolated static let contract = "CACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQLC2U"

    nonisolated static let policy = """
    {"threshold":"100000000","minPrice":"1000000","creatorBps":2000,"platformBps":500,"reserveBps":7500,"maxCreatorAllocBps":1000,
     "expiryCreatorBps":7000,"royaltyBps":500,"platform":"GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N",
     "treasury":"GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK"}
    """

    nonisolated static let economics = """
    {"launchpad":null,"moments":{"generation":2,"contract":"\(contract)","quote":{"asset":"USDC","contract":"\(usdc)"},
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
     "fdvAtOpen":"259259259","fdvAtOpenUsd":25.93,"fdvByAllocation":[{"allocationBps":0,"fdv":"233333333","fdvUsd":23.33}]}}
    """

    nonisolated static func status(state: String, deadline: String = "2026-10-15T11:00:00.000Z", stuckSince: String? = nil, failure: Bool = false) -> String {
        let quoted = { (text: String?) in text.map { "\"\($0)\"" } ?? "null" }
        let failed = failure ? #"{"origin":10,"code":11003,"name":"GraduationInvalid","source":"moments-graduator","seen":"recorded"}"# : "null"
        return """
        {"generation":2,"nft":"\(nft)","creator":"GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG",
         "coin":"CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6","pool":null,"state":"\(state)","price":"10000000",
         "threshold":"100000000","reserve":"0","totalGross":"0","progress":0,"collects":0,"editions":0,"entitlements":"0",
         "creatorAllocBps":1000,"creatorBps":2000,"platformBps":500,"reserveBps":7500,"expiryCreatorBps":7000,"royaltyBps":500,
         "rate":{"num":"1","den":"1"},"publishedAt":"2026-10-13T11:00:00.000Z","deadline":"\(deadline)","completedAt":null,
         "stuckSince":\(quoted(stuckSince)),"graduatedAt":null,"endedAt":null,"expiresAt":null,"expiresBy":null,"backstopAt":null,
         "failureExpiresAt":null,"expirable":false,"graduatable":false,"failure":\(failed),
         "proceeds":{"creator":"0","platform":"0","treasury":"0"}}
        """
    }

    nonisolated static let vesting = """
    {"generation":2,"nft":"\(nft)","account":"G","coin":"CAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCRUA6","state":"graduated",
     "vests":true,"vestPeriodSecs":2592000,"startsAt":"2026-09-14T12:00:00.000Z","periodsElapsed":1,
     "claimable":{"collector":"200000000","creator":"0","total":"200000000"},
     "collector":{"total":"1000000000","claimed":"600000000","claimable":"200000000","vested":"800000000",
      "tranches":[{"period":0,"at":"2026-09-14T12:00:00.000Z","vestedBps":6000,"vested":"600000000"}],
      "nextAt":null,"fullAt":null},"creator":null}
    """

    nonisolated static func collectPlan(total: String, editions: Int, terminal: Bool = false, asset: String = usdc) -> String {
        """
        {"planId":"collect-\(total)","kind":"moment_collect","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
         {"id":"s1","label":"Collect \(editions)","status":"pending","stepKind":"moment_v2_collect","maxFee":"51250","feePayer":"user","reserveDelta":0,
          "intent":{"kind":"moment_collect","summary":"Collect","spend":{"\(asset)":"\(total)"},"calls":[{"contract":"\(contract)","fn":"collect"}],
           "display":{"generation":2,"nft":"\(nft)","quantity":3,"editions":\(editions),"total":"\(total)","quote":"USDC",
            "entitlement":"6000000000","terminal":\(terminal)}}}]}
        """
    }

    /// A publish plan whose display states the economics fixture's terms; `overrides` replace display values (JSON).
    nonisolated static func publishPlan(overrides: [String: String] = [:]) -> String {
        var display: [(String, String)] = [
            ("generation", "2"), ("nft", "\"\(publishedNft)\""), ("coin", "\"CBEEYJQJF3KCSHZISRFMHPZIGYPBINQKBCKMSUNJOLUGUWTRGRLZ3YD2\""),
            ("name", "\"Dusk\""), ("symbol", "\"DUSK\""), ("price", "\"10000000\""), ("quote", "\"USDC\""), ("allocationBps", "1000"),
            ("windowSecs", "86400"), ("threshold", "\"100000000\""), ("minPrice", "\"1000000\""), ("creatorBps", "2000"), ("platformBps", "500"),
            ("reserveBps", "7500"), ("maxCreatorAllocBps", "1000"), ("expiryCreatorBps", "7000"), ("royaltyBps", "500"),
            ("platform", "\"GACQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKG7N\""),
            ("treasury", "\"GADAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDANWXK\""), ("externalBase", "\"https://dyorhq.fun/moments/\""),
            ("nftWasmHash", "\"0606060606060606060606060606060606060606060606060606060606060606\""),
            ("coinWasmHash", "\"0707070707070707070707070707070707070707070707070707070707070707\""),
            ("graduator", "\"CABQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGAYDAMBQGCK3\""),
            ("executor", "\"CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526\""),
            ("locker", "\"CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ\""), ("vestPeriod", "2592000"), ("stuckExpiry", "604800"),
            ("pendingBackstop", "2592000"), ("timelock", "172800"), ("timelockWindow", "604800"), ("minWindow", "3600"), ("maxWindow", "2592000"),
            ("harvestInterval", "3600"), ("harvestBps", "6667"), ("harvestCreatorBps", "4000"),
        ]
        display = display.map { ($0.0, overrides[$0.0] ?? $0.1) }
        let fields = display.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return """
        {"planId":"publish-1","kind":"moment_publish","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
         {"id":"s1","label":"Publish DUSK","status":"pending","stepKind":"moment_v2_publish","maxFee":"51250","feePayer":"user","reserveDelta":0,
          "intent":{"kind":"moment_publish","summary":"Publish","spend":{},"calls":[{"contract":"\(contract)","fn":"publish"}],"display":{\(fields)}}}]}
        """
    }

    nonisolated static let trustThenPublish = """
    {"planId":"publish-2","kind":"moment_publish","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
     {"id":"s1","label":"Enable USDC","status":"pending","stepKind":"trust","maxFee":"10000","feePayer":"user","reserveDelta":1,
      "intent":{"kind":"trust","summary":"Enable USDC","spend":{},"display":{"asset":"USDC"}}},
     {"id":"s2","label":"Publish DUSK","status":"pending","stepKind":"moment_v2_publish","maxFee":"51250","feePayer":"user","reserveDelta":0}]}
    """

    nonisolated static let claimAllPlan = plan("moment_claim_all", display: #"{"generation":2,"moments":2,"nfts":"\#(nft),\#(publishedNft)","total":"400000000"}"#)

    /// A plan of one built `kind` step (v2's builder kind as its step kind) whose intent displays `display`.
    nonisolated static func plan(_ kind: String, display: String) -> String {
        let builder = "moment_v2_" + kind.dropFirst("moment_".count)
        return """
        {"planId":"\(kind)-\(UUID().uuidString)","kind":"\(kind)","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
         {"id":"s1","label":"Server words","status":"pending","stepKind":"\(builder)","maxFee":"51250","feePayer":"user","reserveDelta":0,
          "intent":{"kind":"\(kind)","summary":"Server words","spend":{},"calls":[{"contract":"\(contract)","fn":"x"}],"display":\(display)}}]}
        """
    }

    /// The account's USDC trustline, then the `builder` step the server builds once it confirmed.
    nonisolated static func trustThen(_ builder: String, label: String) -> String {
        """
        {"planId":"trust-\(builder)","kind":"x","expiresAt":"2030-01-01T00:00:00.000Z","steps":[
         {"id":"s1","label":"Enable USDC","status":"pending","stepKind":"trust","maxFee":"10000","feePayer":"user","reserveDelta":1,
          "intent":{"kind":"trust","summary":"Enable USDC","spend":{},"display":{"asset":"USDC"}}},
         {"id":"s2","label":"\(label)","status":"pending","stepKind":"\(builder)","maxFee":"51250","feePayer":"user","reserveDelta":0}]}
        """
    }
}
