@testable import DyorLite
import StellarKit
import XCTest

/// `LiteStore`'s actions and reads (docs/DESIGN-stellar-parity.md §7.2): one signing run per confirmed action (App Lock
/// once when it applies, the passkey once per step), a plan that settles once from the store's own task whether or not
/// a view still watches it (LiteSettled), plans priced on the phone, Max from the account's own XLM figures, and the
/// history parts of a passkey account in the public view.
@MainActor
final class LiteStoreTests: XCTestCase {
    private var server: FakeLite!
    private var backend: TestBackend!
    private var vault: MemoryVault!
    private var defaults: UserDefaults!
    /// The test's own defaults, removed after it.
    private var suite = ""
    private var tally: Tally!
    /// The sessions the tests made, kept alive as the app keeps its own (a store only holds its session weakly).
    private var sessions: [LiteSession] = []

    override func setUp() async throws {
        server = FakeLite()
        server.serve()
        backend = TestBackend(api: server.api())
        vault = MemoryVault()
        suite = "lite.store.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        tally = Tally()
    }

    override func tearDown() async throws {
        server.stop()
        defaults.removePersistentDomain(forName: suite)
        sessions = []
    }

    private var env: LiteEnvironment { LiteEnvironment(apiURL: server.base, pinned: .testnet, buildNumber: 23) }

    /// A ready session for an account set up on this iPhone, with a live session saved.
    private func readySession(keys: LiteKeyProvider, setupKey: (@Sendable (String) async throws -> LiteSession.UnlockResult)? = nil,
                              saved: Bool = true) async throws -> (LiteSession, LiteStore) {
        defaults.set(true, forKey: LiteSession.activatedKey(keys.address))
        if saved { vault.save(server.issueSession(), account: keys.address, network: "testnet") }
        let session = LiteSession(env: env, stellarAddress: keys.address, monad: nil, keys: keys, setupKey: setupKey, backend: backend, vault: vault,
                                  defaults: defaults)
        sessions.append(session)
        await session.resumeAtLaunch()
        return (session, try XCTUnwrap(session.store))
    }

    /// A two-step swap (Enable USDC, then the swap), built by the fake server.
    private func swapAction(_ store: LiteStore) async throws -> PreparedAction {
        let quote = try await store.swapQuote(sell: "XLM", buy: "USDC", amount: 100_000_000, slippageBps: 100)
        return try await store.swapPlan(quote)
    }

    // MARK: - Signing runs

    func testASeedActionAsksAppLockOnceAndReadsTheSeedPerStep() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: true, tally: tally))
        let action = try await swapAction(store)
        XCTAssertEqual(action.plan.steps.count, 2)
        XCTAssertEqual(tally.prompts, 0, "building and pricing ask nothing")
        _ = try await store.run(action, reason: "Confirm Swap")
        XCTAssertEqual(tally("appLock"), 1, "App Lock once for the whole action")
        XCTAssertEqual(tally("seedRead"), 2, "each step's signature read the seed for itself")
        XCTAssertEqual(backend.signatures, 2)
    }

    func testWithAppLockOffAnActionSignsWithNoPrompt() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        _ = try await store.run(try await swapAction(store), reason: "Confirm Swap")
        XCTAssertEqual(tally.prompts, 0)
        XCTAssertEqual(backend.signatures, 2)
    }

    func testAPasskeyActionAsksThePasskeyPerStepAndNeverAppLock() async throws {
        let (_, store) = try await readySession(keys: TestAccount.passkeyKeys(tally: tally))
        _ = try await store.run(try await swapAction(store), reason: "Confirm Swap")
        XCTAssertEqual(tally("passkey"), 2, "one passkey prompt per signed step")
        XCTAssertEqual(tally("appLock"), 0)
    }

    func testACancelledPromptSendsNothingAndTheRunEnds() async throws {
        let keys = StoredSeedKeyProvider(address: TestAccount.seedSigner.address, methodLabel: "Test", network: "testnet", appLock: { true },
                                         seed: { TestAccount.seed }, authenticate: { _ in throw LiteSession.Failure.cancelled })
        let (_, store) = try await readySession(keys: keys)
        do {
            _ = try await store.run(try await swapAction(store), reason: "Confirm Swap")
            XCTFail("signed past a cancelled prompt")
        } catch {
            XCTAssertEqual(error as? LiteSession.Failure, .cancelled)
        }
        XCTAssertEqual(backend.plans, [], "nothing was sent")
    }

    func testARunEndsItsSigningRun() async throws {
        let run = SeedSigningRun(address: TestAccount.seedSigner.address, seed: { TestAccount.seed })
        _ = try await run.signer(reason: "step")
        run.end()
        do {
            _ = try await run.signer(reason: "step")
            XCTFail("a signer after the run ended")
        } catch {}
    }

    // MARK: - Settled once (LiteSettled)

    func testAPlanSettlesOnceWithItsSectionAndReference() async throws {
        let (session, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        var settled: [LiteSettledAction] = []
        session.onSettled = { settled.append($0) }
        let action = try await swapAction(store)
        let results = try await store.run(action, reason: "Confirm Swap")
        _ = try await store.run(action, reason: "Confirm Swap")
        XCTAssertEqual(settled.count, 1, "once per plan, however often it is run")
        let first = try XCTUnwrap(settled.first)
        XCTAssertEqual(first.planId, action.id)
        XCTAssertEqual(first.kind, "swap")
        XCTAssertEqual(first.section, .spot)
        XCTAssertEqual(first.reference, "stellar:swap")
        XCTAssertEqual(first.hashes, results.map(\.hash))
        XCTAssertEqual(first.title, tr("Swap complete"))
        XCTAssertTrue(first.body.contains("XLM") && first.body.contains("USDC"), first.body)
    }

    func testAPlanSettlesWithNoViewWatching() async throws {
        let (session, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        var settled = 0
        session.onSettled = { _ in settled += 1 }
        backend.stepPause = 0.2
        let action = try await swapAction(store)
        // The sheet that confirmed it goes away at once: its task is cancelled.
        let sheet = Task { try await store.run(action, reason: "Confirm Swap") }
        sheet.cancel()
        await waitUntil { settled == 1 }
        XCTAssertEqual(settled, 1, "the store's own task saw the plan through")
    }

    // MARK: - Prepared actions

    func testAnActionIsPricedOnThePhone() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        let action = try await swapAction(store)
        XCTAssertEqual(action.fees.userMax, 410_000, "the steps' ceilings: Enable USDC, then the swap")
        XCTAssertEqual(action.fees.newReserves, 1)
        XCTAssertFalse(action.sponsorVerified, "nothing here says DyorHQ pays")
        XCTAssertEqual(StellarFeeSummary(action.fees).value, .pricedAsSigned)
        XCTAssertEqual(action.section, .spot)
        XCTAssertEqual(action.title(of: action.plan.steps[1]), action.titles["s2"])
        XCTAssertEqual(action.spends, ["XLM"], "what a shortfall on the network names")
    }

    func testAStepAboveThePinnedCapIsRefusedBeforeTheReview() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        let plan = try JSONDecoder().decode(PlanView.self, from: Data(FakeLite.plan(id: "p", steps: [("s1", "swap_soroswap", "Swap", 40_000_000)]).utf8))
        XCTAssertThrowsError(try store.prepare(plan, limits: [:], title: "Swap", section: .spot, reference: nil,
                                               summary: .swap(amountIn: 1, sell: "XLM", buy: "USDC", quotedOut: 1)))
    }

    func testANewCoinOrMomentIsReferencedByWhatItsTransactionReturned() throws {
        func status(_ value: String) throws -> TxStatus {
            try JSONDecoder().decode(TxStatus.self, from: Data(#"{"hash":"h","status":"success","returnValue":\#(value)}"#.utf8))
        }
        let token = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
        XCTAssertEqual(LiteStore.reference(.launchCreate(symbol: "ECAT", name: "E Cat"), results: [try status("\"\(token)\"")]), "stellar:launch/\(token)")
        XCTAssertEqual(LiteStore.reference(.launchCreate(symbol: "ECAT", name: "E Cat"), results: [try status("\"not a contract\"")]), "stellar:launch")
        XCTAssertEqual(LiteStore.reference(.publish(title: "Sunset"), results: [try status("7")]), "stellar:moment/7")
        XCTAssertEqual(LiteStore.reference(.publish(title: "Sunset"), results: []), "stellar:moment")
        XCTAssertNil(LiteStore.reference(.swap(amountIn: 1, sell: "XLM", buy: "USDC", quotedOut: 1), results: []))
    }

    // MARK: - Max

    func testMaxOfXLMKeepsTheMinimumBalanceAndTheFee() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        await store.refreshAccount()
        await store.refreshFees()
        // §4.5: 10,000 XLM, one subentry: 9,998.5 spendable; a Soroswap swap's estimate 0.05 XLM, kept with a quarter more.
        XCTAssertEqual(store.maxAmount(asset: "XLM", stepKind: "swap_soroswap"), 99_984_375_000)
        XCTAssertEqual(store.maxAmount(asset: "XLM", stepKind: "swap_soroswap", newReserves: 1), 99_984_375_000 - 5_000_000)
        XCTAssertEqual(store.maxAmount(asset: "USDC", stepKind: "swap_soroswap"), 52_300_000, "any other asset: its whole balance")
        XCTAssertEqual(store.maxAmount(asset: "XLM", stepKind: "launch_buy"), 99_985_000_000 - 625_000, "an estimate the server didn't send: the default")
    }

    // MARK: - History parts

    func testHistoryNeedsASignInOnlyForAPasskeyAccountWithNoSession() async throws {
        let (passkey, store) = try await readySession(keys: TestAccount.passkeyKeys(tally: tally), saved: false)
        XCTAssertEqual(passkey.access, .publicView)
        await store.refreshActivity()
        await store.refreshPortfolio(.week)
        XCTAssertEqual(store.status(.activity), .needsSignIn)
        XCTAssertEqual(store.status(.portfolio), .needsSignIn)
        do {
            _ = try await store.myMoments()
            XCTFail("a history read without a session")
        } catch {}
        XCTAssertEqual(store.status(.myMoments), .needsSignIn)
        XCTAssertEqual(tally.prompts, 0, "reads never prompt")

        // A seed account in the public view signs in silently and reads.
        server.forget()
        let (seed, seedStore) = try await readySession(keys: TestAccount.seedKeys(appLock: true, tally: tally), saved: false)
        XCTAssertEqual(seed.access, .session, "renewed at launch, silently")
        await seedStore.refreshActivity()
        XCTAssertEqual(seedStore.status(.activity), .read)
        XCTAssertFalse(seedStore.activity.isEmpty)
        XCTAssertEqual(tally.prompts, 0)
    }

    /// Today's screens, hosted by the app's seams, in the public view: Home's Activity card offers the sign-in instead of
    /// reading forever, asks nothing until it is tapped, and lists the history once signed in.
    func testTheActivityCardOffersTheSignInInThePublicView() async throws {
        let (session, store) = try await readySession(keys: TestAccount.passkeyKeys(tally: tally), setupKey: TestAccount.setupKey(tally: tally),
                                                      saved: false)
        XCTAssertEqual(LiteHomeView.activityCard(store), .reading, "before the first read")
        XCTAssertEqual(session.home, .ready)
        XCTAssertEqual(session.access, .publicView)
        await store.refreshActivity()
        XCTAssertEqual(store.status(.activity), .needsSignIn)
        XCTAssertEqual(LiteHomeView.activityCard(store), .signIn, "never “Reading your activity…” for good")
        XCTAssertEqual(tally.prompts, 0)

        try await session.signIn()
        await store.refreshActivity()
        XCTAssertEqual(LiteHomeView.activityCard(store), .list)
        XCTAssertEqual(tally.prompts, 1, "the one passkey sign-in")
        XCTAssertEqual(tally("reason:\(tr("Sign in to DyorHQ on Stellar"))"), 1)
    }

    func testAPasskeyAccountWithNoSessionSignsInOnceWhenItStartsAnAction() async throws {
        let (session, store) = try await readySession(keys: TestAccount.passkeyKeys(tally: tally), setupKey: TestAccount.setupKey(tally: tally),
                                                      saved: false)
        XCTAssertEqual(session.access, .publicView)
        _ = try await swapAction(store)
        XCTAssertEqual(tally("ceremony"), 1, "one passkey sign-in, then the action is built")
        XCTAssertEqual(session.access, .session)
        _ = try await swapAction(store)
        XCTAssertEqual(tally("ceremony"), 1, "a session is held now")
    }
}
