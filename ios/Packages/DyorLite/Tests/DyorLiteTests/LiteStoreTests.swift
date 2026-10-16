@testable import DyorLite
import StellarKit
import XCTest

/// `LiteStore`'s actions and reads (docs/DESIGN-stellar-parity.md §7.2): one signing run per confirmed action (App Lock
/// once when it applies, the passkey once per step), a plan that settles once from the store's own task whether or not
/// a view still watches it (LiteSettled), plans priced on the phone, Max from the account's own XLM figures, the
/// history parts of a passkey account in the public view, Friendbot's one claim, and a new coin's ticker.
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

    // MARK: - What the user confirmed besides the spends (PlanBindings)

    func testASwapBindsTheMinimumItsQuoteShowedAndTheRunIsHeldToIt() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        let action = try await swapAction(store)
        let usdc = try XCTUnwrap(store.asset("USDC")?.contract)
        XCTAssertEqual(action.bindings, PlanBindings(minimums: [usdc: 18_843_341]), "the quote's 18.938032 USDC less its 0.5%")
        _ = try await store.run(action, reason: "Confirm Swap")
        XCTAssertEqual(backend.lastBindings, action.bindings)
    }

    func testTheAssetASwapBuysIsWorkedOutOnThePhone() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        let pinned = PinnedContracts.testnet.contracts("token")
        XCTAssertEqual(store.contract("USDC"), "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA")
        XCTAssertTrue(pinned.contains(store.contract("USDC")) && pinned.contains(store.contract("XLM")), "the build's pinned token contracts")
        let issuer = "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"
        XCTAssertEqual(store.contract("EURC:\(issuer)"), AssetContract.id(.credit(code: "EURC", issuer: issuer), network: .testnet))
        XCTAssertEqual(LiteStore.assetContract("native", network: .testnet), AssetContract.id(.native, network: .testnet))
        XCTAssertEqual(store.contract("not an asset"), PlanBindings.anyAsset)
        // A quote whose bought asset can't be worked out is never built into a swap.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: FakeLite.fixture("swap-quote")) as? [String: Any])
        json["buy"] = "not an asset"
        let quote = try JSONDecoder().decode(SwapQuote.self, from: JSONSerialization.data(withJSONObject: json))
        do {
            _ = try await store.swapPlan(quote)
            XCTFail("a swap into an asset the phone can't check")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .refused(step: "Swap", reason: "the asset you buy can't be checked"))
        }
    }

    func testASwapsMinimumIsTheQuotesNeverLessAndNeverNothing() throws {
        XCTAssertEqual(try LiteStore.swapMinimum(quoted: "18938032", minOut: "18843341", slippageBps: 50), 18_843_341)
        XCTAssertEqual(try LiteStore.swapMinimum(quoted: "18938032", minOut: "1", slippageBps: 50), 18_843_341,
                       "a route minimum below the quote less its slippage")
        XCTAssertEqual(try LiteStore.swapMinimum(quoted: "18938032", minOut: nil, slippageBps: 50), 18_843_341)
        XCTAssertEqual(try LiteStore.swapMinimum(quoted: String(Int64.max), minOut: nil, slippageBps: 100), Int64.max / 100 * 99 + Int64.max % 100 * 99 / 100)
        XCTAssertThrowsError(try LiteStore.swapMinimum(quoted: "0", minOut: "0", slippageBps: 50))
    }

    func testASendsMemoIsBoundAsTheServerBindsIt() {
        XCTAssertNil(LiteStore.boundMemo(nil, type: nil))
        XCTAssertNil(LiteStore.boundMemo("", type: "text"))
        XCTAssertEqual(LiteStore.boundMemo("hello", type: nil), Intent.Memo(type: "text", value: "hello"))
        XCTAssertEqual(LiteStore.boundMemo("00042", type: "id"), Intent.Memo(type: "id", value: "42"))
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(LiteStore.boundMemo(hex.uppercased(), type: "hash"), Intent.Memo(type: "hash", value: hex))
        XCTAssertEqual(LiteStore.boundMemo(Data(repeating: 0xab, count: 32).base64EncodedString(), type: "hash"), Intent.Memo(type: "hash", value: hex))
    }

    func testABuiltSendToAnotherAddressOrMemoIsRefusedBeforeTheReview() throws {
        let me = "GAQKCKSB3YEAQDIBZAVHMAL5PBFCPWIA52TKIUXYIBNSJRQIDVHQB4SF"
        let friend = "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR"
        let lookalike = "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG"
        func plan(to: String, memo: String?) throws -> PlanView {
            let memoJSON = memo.map { #","memo":{"type":"id","value":"\#($0)"}"# } ?? ""
            let json = #"{"planId":"p","kind":"payment","expiresAt":"2026-10-15T14:47:36.511Z","steps":[{"id":"s1","label":"Send","status":"built","#
                + #""intent":{"kind":"payment","summary":"Send 1 XLM","spend":{"XLM":"10000000"},"to":"\#(to)"\#(memoJSON)},"#
                + #""maxFee":"100","feePayer":"user","reserveDelta":0}]}"#
            return try JSONDecoder().decode(PlanView.self, from: Data(json.utf8))
        }
        let typed = PlanBindings(destination: .confirmed(to: friend, memo: Intent.Memo(type: "id", value: "42")))
        XCTAssertNoThrow(try LiteStore.checkBuilt(plan(to: friend, memo: "42"), bindings: typed, user: me, pinned: .testnet))
        for (other, memo) in [(lookalike, "42"), (friend, "43"), (friend, nil)] as [(String, String?)] {
            XCTAssertThrowsError(try LiteStore.checkBuilt(plan(to: other, memo: memo), bindings: typed, user: me, pinned: .testnet)) { error in
                XCTAssertEqual(error as? PlanRunner.Failure, .destinationNotConfirmed(step: "Send"))
            }
        }
        // Nothing typed: a step may pay only the user.
        XCTAssertThrowsError(try LiteStore.checkBuilt(plan(to: friend, memo: nil), bindings: .none, user: me, pinned: .testnet))
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

    /// A screen's own activity list (Swap History) never stands in for the shared one: Portfolio and the add-funds card
    /// read `activity` again only while its status isn't `.read`, so a filtered read kept there would leave them showing
    /// one screen's filters.
    func testAScreensOwnActivityReadLeavesTheSharedListAlone() async throws {
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        let swaps = await store.readActivity(kind: "swap", period: .day)
        XCTAssertEqual(swaps.status, .read)
        XCTAssertFalse(swaps.items.isEmpty)
        XCTAssertTrue(store.activity.isEmpty, "the shared list wasn't read")
        XCTAssertEqual(store.status(.activity), .unread, "and doesn't say it was")
        await store.refreshActivity()
        let shared = store.activity
        _ = await store.readActivity(kind: "swap", period: .week)
        XCTAssertEqual(store.activity, shared)
        XCTAssertEqual(store.status(.activity), .read)

        // A passkey account with no session: the sign-in row, with no prompt and no part marked.
        server.forget()
        let (passkey, publicStore) = try await readySession(keys: TestAccount.passkeyKeys(tally: tally), saved: false)
        XCTAssertEqual(passkey.access, .publicView)
        let none = await publicStore.readActivity(kind: "swap")
        XCTAssertEqual(none.status, .needsSignIn)
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertEqual(publicStore.status(.activity), .unread)
        XCTAssertEqual(tally.prompts, 0, "reads never prompt")
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

    // MARK: - Friendbot's one claim (decision 7)

    /// Deposit offers "Fund with Friendbot" only while the server says the claim is open: not before the account is
    /// read, not in the public view, and never again once claimed.
    func testFriendbotIsOfferedOnlyWhileTheClaimIsOpen() async throws {
        server.update { $0.claimed = false }
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        XCTAssertFalse(store.canClaimFriendbot, "unknown before the account is read")
        await store.refreshAccount()
        XCTAssertTrue(store.canClaimFriendbot)
        XCTAssertEqual(ReceiveSheet.faucetAmount(store.config), "10,000")

        try await store.faucet()
        XCTAssertEqual(store.account?.firstFunding?.faucet?.claimed, true, "the account is read again after the claim")
        XCTAssertFalse(store.canClaimFriendbot)
        do {
            try await store.faucet()
            XCTFail("a second claim went through")
        } catch {
            XCTAssertEqual(LiteErrorText.describe(error), "You already claimed your test XLM.")
        }
        XCTAssertEqual(server.paths.filter { $0 == "POST /v1/account/faucet" }.count, 2)
        XCTAssertEqual(tally.prompts, 0, "claiming signs nothing")
    }

    /// A refused claim reads the account again too: an account the phone last read as unclaimed, whose claim the server
    /// already holds, loses "Fund with Friendbot" at the first refusal instead of offering it again.
    func testARefusedClaimHidesFriendbot() async throws {
        server.update { $0.claimed = false }
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        await store.refreshAccount()
        XCTAssertTrue(store.canClaimFriendbot)
        server.update { $0.claimed = true }
        do {
            try await store.faucet()
            XCTFail("a second claim went through")
        } catch {
            XCTAssertEqual(LiteErrorText.describe(error), "You already claimed your test XLM.")
        }
        XCTAssertEqual(store.account?.firstFunding?.faucet?.claimed, true, "the account is read again after the refusal")
        XCTAssertFalse(store.canClaimFriendbot)
    }

    /// Home's actions are Monad's: adding cash is removed until mainnet, and so is its tile.
    func testHomeHasNoAddCash() {
        XCTAssertEqual(LiteHomeAction.all.map(\.id), [.bridge, .deposit, .withdraw, .swap])
    }

    func testAnAccountThatClaimedIsNeverOfferedFriendbot() async throws {
        server.update { $0.claimed = true }
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: false, tally: tally))
        await store.refreshAccount()
        XCTAssertEqual(store.account?.firstFunding?.faucet?.claimed, true)
        XCTAssertFalse(store.canClaimFriendbot)
    }

    func testAnAccountReadInThePublicViewIsNeverOfferedFriendbot() async throws {
        server.update { $0.claimed = false }
        let (passkey, store) = try await readySession(keys: TestAccount.passkeyKeys(tally: tally), saved: false)
        XCTAssertEqual(passkey.access, .publicView)
        await store.refreshAccount()
        XCTAssertEqual(store.account?.view, "public")
        XCTAssertNil(store.account?.firstFunding?.faucet?.claimed, "DyorHQ's own record: null in the public view")
        XCTAssertFalse(store.canClaimFriendbot)
        XCTAssertEqual(tally.prompts, 0)
    }

    // MARK: - A new coin's ticker

    /// Soroswap reads a token's symbol as UTF-8, so Create refuses a ticker that isn't 2 to 10 ASCII letters or digits
    /// before it uploads, writes or builds anything, with the server's own words.
    func testANewCoinsTickerIsCheckedBeforeAnythingIsSent() async throws {
        for symbol in ["ECAT", "ecat", "AB", "ABCDEFGHIJ", "ECAT2", " ECAT "] {
            XCTAssertTrue(LiteStore.isLaunchSymbol(symbol), symbol)
        }
        for symbol in ["E", "ABCDEFGHIJK", "EC-AT", "EC AT", "ÉCAT", "ßCAT", "ıCAT", "ＥＣＡＴ", "🐱CAT", "", "ßcat", "ﬁre", "ıcat"] {
            XCTAssertFalse(LiteStore.isLaunchSymbol(symbol), symbol)
            XCTAssertNil(LiteStore.launchSymbol(symbol), symbol)
        }
        // Sent upper-cased, once checked as typed: upper-casing first would turn "ßcat" into "SSCAT", "ﬁre" into "FIRE"
        // and "ıcat" into "ICAT", tickers the user never typed.
        XCTAssertEqual(["ecat", " ecat2 ", "AB", "aBcDeFgHiJ"].map(LiteStore.launchSymbol), ["ECAT", "ECAT2", "AB", "ABCDEFGHIJ"])
        let (_, store) = try await readySession(keys: TestAccount.seedKeys(appLock: true, tally: tally))
        server.forget()
        for symbol in ["ÉCAT", "ßcat"] {
            let form = StellarLaunchForm(name: "E Cat", symbol: symbol, quote: "XLM", creatorFeeBps: 0)
            do {
                _ = try await store.launchCreatePlan(form, image: Data([0xFF, 0xD8]))
                XCTFail("a ticker outside ASCII went out: \(symbol)")
            } catch let LiteAPIError.server(status, code, _, _) {
                XCTAssertEqual([String(status), code], ["422", "bad_symbol"], symbol)
            }
        }
        XCTAssertEqual(server.paths, [], "nothing uploaded, written or built")
        XCTAssertEqual(tally.prompts, 0)
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
