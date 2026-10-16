// The network sheet's Setup (docs/DESIGN-stellar-parity.md §8.14, §1.1 decisions 6 and 7): the account step's copy and
// button on each network, Friendbot's amount from the server's config (before a passkey account's sign-in too), the
// Enable USDC row's reserve and fee before the step signs and its own transaction's fee once built, no unlock row, no
// invite step where no code is asked for, a seed account's sign-in with no prompt and App Lock only at its Set Up tap and
// only when it applies, and a passkey account's checklist, invite field and one ceremony, which the background ends.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarSetupTests: XCTestCase {
    typealias Sheet = NetworkSheetContent
    typealias Row = NetworkSheetContent.Row

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(SetupStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(SetupStub.self)
        super.tearDown()
    }

    // MARK: - The account step's copy and button (§8.14, decision 7)

    func testOnTestnetTheAccountStepIsFriendbotsOneClaimInTheConfigsAmount() {
        let step = Sheet.accountStep(testnet: true, friendbotAmount: "25000")
        XCTAssertEqual(step.button, "Fund with Friendbot")
        XCTAssertEqual(step.line, "Get 25,000 free test XLM from Stellar's Friendbot (one claim per account), then enable USDC. "
                       + "Enabling USDC holds 0.5 XLM and costs a small network fee, paid from your test XLM.")
        // The figure is the server's, whatever it says: never one of the app's own.
        XCTAssertTrue(Sheet.accountStep(testnet: true, friendbotAmount: "10000").line.hasPrefix("Get 10,000 free test XLM"))
        // Not read yet, or not a number: the same copy with no figure at all.
        let unknown = Sheet.accountStep(testnet: true, friendbotAmount: nil)
        XCTAssertEqual(unknown.line, "Get free test XLM from Stellar's Friendbot (one claim per account), then enable USDC. "
                       + "Enabling USDC holds 0.5 XLM and costs a small network fee, paid from your test XLM.")
        XCTAssertEqual(unknown.button, "Fund with Friendbot")
        XCTAssertEqual(Sheet.accountStep(testnet: true, friendbotAmount: "plenty"), unknown)
    }

    func testOnMainnetTheAccountStepIsTheSetupDyorHQPays() {
        let step = Sheet.accountStep(testnet: false, friendbotAmount: nil)
        XCTAssertEqual(step.button, "Set up")
        XCTAssertEqual(step.line, "Creates your Stellar account and enables USDC. DyorHQ pays this one-time setup. After it, you pay "
                       + "Stellar's network fees in XLM.")
        XCTAssertEqual(Sheet.accountStep(testnet: false, friendbotAmount: "10000"), step, "mainnet has no faucet")
    }

    func testNoAccountStepSaysTheUserSpendsNothing() {
        // Hybrid fees (decision 3): the user pays every network fee after the one-time setup.
        for step in [Sheet.accountStep(testnet: true, friendbotAmount: "10000"), Sheet.accountStep(testnet: true, friendbotAmount: nil),
                     Sheet.accountStep(testnet: false, friendbotAmount: nil)] {
            XCTAssertFalse(step.line.contains("spend nothing"), step.line)
            XCTAssertFalse(step.line.contains("network fees and the reserve"), step.line)
        }
    }

    // MARK: - The Enable USDC row (§8.14)

    func testTheEnableRowShowsItsReserveAndTheMostItsFeeMayBe() throws {
        let estimate = try fees([step(built: false, maxFee: "10000")])
        XCTAssertEqual(Sheet.enableLine(fee: estimate, baseReserve: 5_000_000, testnet: true), "Holds 0.5 XLM · network fee up to 0.001 XLM")
        // The ledger's reserve, as `/v1/fees` gives it, never a constant.
        XCTAssertEqual(Sheet.enableLine(fee: estimate, baseReserve: 10_000_000, testnet: true), "Holds 1 XLM · network fee up to 0.001 XLM")
        // Once built, the step's own transaction's fee replaces the estimate.
        let higher = try fees([step(built: false, maxFee: "500000")])
        XCTAssertEqual(Sheet.enableLine(fee: higher, baseReserve: 5_000_000, testnet: true), "Holds 0.5 XLM · network fee up to 0.05 XLM")
        let built = try fees([step(built: true, maxFee: "500000")])
        XCTAssertEqual(Sheet.enableLine(fee: built, baseReserve: 5_000_000, testnet: true), "Holds 0.5 XLM · network fee up to 0.001 XLM")
        // Nothing to say until the price and the reserve are read.
        XCTAssertNil(Sheet.enableLine(fee: nil, baseReserve: 5_000_000, testnet: true))
        XCTAssertNil(Sheet.enableLine(fee: estimate, baseReserve: nil, testnet: true))
    }

    func testOnMainnetTheEnableRowPricesOnlyAStepTheUserPays() throws {
        // DyorHQ pays the one-time setup: an estimate says nothing there.
        XCTAssertNil(Sheet.enableLine(fee: try fees([step(built: false, maxFee: "10000")]), baseReserve: 5_000_000, testnet: false))
        // A built step the phone found the user's is still priced.
        XCTAssertEqual(Sheet.enableLine(fee: try fees([step(built: true, maxFee: "10000")]), baseReserve: 5_000_000, testnet: false),
                       "Holds 0.5 XLM · network fee up to 0.001 XLM")
    }

    // MARK: - The checklist (§8.14, decision 6)

    func testTheChecklistIsSignInTheAccountAndEnableUSDC() {
        let first = [Row(kind: .signIn, status: .running), Row(kind: .setUp, status: .pending)]
        XCTAssertEqual(Sheet.displayRows(steps: first, state: .running, inviteRequired: false).map(\.kind), [.signIn, .setUp, .enableUSDC])
        // After Sign out of Stellar: the sign-in only.
        XCTAssertEqual(Sheet.displayRows(steps: [Row(kind: .signIn, status: .running)], state: .running, inviteRequired: false).map(\.kind), [.signIn])
        // Enable USDC goes with the account step.
        let sending = [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .running)]
        XCTAssertEqual(Sheet.displayRows(steps: sending, state: .running, inviteRequired: false).map(\.status), [.done, .running, .running])
        let failed = [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .failed(.setUpFailed))]
        XCTAssertEqual(Sheet.displayRows(steps: failed, state: .failed(.setUp, .setUpFailed), inviteRequired: false).map(\.status),
                       [.done, .failed(.setUpFailed), .pending])
        XCTAssertEqual(Sheet.RowKind(.signIn), .signIn)
        XCTAssertEqual(Sheet.RowKind(.invite), .invite)
        XCTAssertEqual(Sheet.RowKind(.setUp), .setUp)
    }

    func testTheAccountStepNeedsTheUserOnlyWhileTheRunWaitsForItsTap() {
        let waiting = [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .needsYou)]
        XCTAssertEqual(Sheet.displayRows(steps: waiting, state: .waiting(.setUp), inviteRequired: false).map(\.status), [.done, .needsYou, .pending])
        // A seed account's code asked for meanwhile: the account step waits.
        let inviting = [Row(kind: .invite, status: .needsYou), Row(kind: .setUp, status: .needsYou)]
        XCTAssertEqual(Sheet.displayRows(steps: inviting, state: .waiting(.invite), inviteRequired: true),
                       [Row(kind: .invite, status: .needsYou), Row(kind: .setUp, status: .pending), Row(kind: .enableUSDC, status: .pending)])
        XCTAssertFalse(Sheet.runsFromSetUp(steps: inviting, state: .running, passkey: false), "seed accounts sign in before their tap")
    }

    func testAPasskeyChecklistStartsWithTheAccountStepItsTapRuns() {
        // Before the tap: Set up first, with its button; Sign in and Enable USDC wait.
        let waiting = [Row(kind: .signIn, status: .pending), Row(kind: .setUp, status: .needsYou)]
        XCTAssertEqual(Sheet.displayRows(steps: waiting, state: .waiting(.setUp), inviteRequired: false, passkey: true),
                       [Row(kind: .setUp, status: .needsYou), Row(kind: .signIn, status: .pending), Row(kind: .enableUSDC, status: .pending)])
        // The tap's one passkey prompt signs in: the account step shows the run ("Confirm with your passkey").
        let signingIn = [Row(kind: .signIn, status: .running), Row(kind: .setUp, status: .needsYou)]
        XCTAssertTrue(Sheet.runsFromSetUp(steps: signingIn, state: .running, passkey: true))
        XCTAssertEqual(Sheet.displayRows(steps: signingIn, state: .running, inviteRequired: false, passkey: true),
                       [Row(kind: .setUp, status: .running), Row(kind: .signIn, status: .pending), Row(kind: .enableUSDC, status: .pending)])
        // Signed in: the account is read, then set up, and Enable USDC goes with it.
        let signedIn = [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .needsYou)]
        XCTAssertEqual(Sheet.displayRows(steps: signedIn, state: .running, inviteRequired: false, passkey: true).map(\.status), [.running, .done, .pending])
        let sending = [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .running)]
        XCTAssertFalse(Sheet.runsFromSetUp(steps: sending, state: .running, passkey: true))
        XCTAssertEqual(Sheet.displayRows(steps: sending, state: .running, inviteRequired: false, passkey: true).map(\.status), [.running, .done, .running])
        // The prompt cancelled: the sign-in says so, and the account step waits for Try again.
        let cancelled = [Row(kind: .signIn, status: .failed(.cancelled)), Row(kind: .setUp, status: .needsYou)]
        XCTAssertEqual(Sheet.displayRows(steps: cancelled, state: .failed(.signIn, .cancelled), inviteRequired: false, passkey: true),
                       [Row(kind: .setUp, status: .pending), Row(kind: .signIn, status: .failed(.cancelled)), Row(kind: .enableUSDC, status: .pending)])
        // A code the server turned out to need: its step under the account step.
        let inviting = [Row(kind: .invite, status: .needsYou), Row(kind: .setUp, status: .needsYou)]
        XCTAssertEqual(Sheet.displayRows(steps: inviting, state: .waiting(.invite), inviteRequired: true, passkey: true).map(\.kind),
                       [.setUp, .invite, .enableUSDC])
        // Set up already on this iPhone, signed out since: the sign-in alone, its prompt under it.
        let signInOnly = [Row(kind: .signIn, status: .running)]
        XCTAssertFalse(Sheet.runsFromSetUp(steps: signInOnly, state: .running, passkey: true))
        XCTAssertEqual(Sheet.displayRows(steps: signInOnly, state: .running, inviteRequired: false, passkey: true), signInOnly)
    }

    func testWithoutInviteCodesThereIsNoInviteStep() {
        // A session that lists the invite step in sign-in's place.
        let asked = [Row(kind: .invite, status: .needsYou), Row(kind: .setUp, status: .needsYou)]
        let none = Sheet.displayRows(steps: asked, state: .waiting(.invite), inviteRequired: false)
        XCTAssertEqual(none.map(\.kind), [.signIn, .setUp, .enableUSDC], "testnet: never an invite step")
        XCTAssertFalse(none.contains { $0.kind == .invite })
        XCTAssertFalse(Sheet.displayRows(steps: asked, state: .waiting(.invite), inviteRequired: false, passkey: true).contains { $0.kind == .invite })
        // Where codes are asked for (mainnet), the step shows while the server asks.
        XCTAssertEqual(Sheet.displayRows(steps: asked, state: .waiting(.invite), inviteRequired: true).map(\.kind), [.invite, .setUp, .enableUSDC])
        let refused = Sheet.displayRows(steps: [Row(kind: .invite, status: .failed(.inviteRejected)), Row(kind: .setUp, status: .pending)],
                                        state: .failed(.invite, .inviteRejected), inviteRequired: true)
        XCTAssertEqual(refused.first, Row(kind: .invite, status: .failed(.inviteRejected)))
        // A passkey account's optional field, likewise, only where codes are asked for.
        let first = [Row(kind: .signIn, status: .pending), Row(kind: .setUp, status: .needsYou)]
        XCTAssertTrue(Sheet.asksInviteAtSetUp(steps: first, state: .waiting(.setUp), passkey: true, inviteRequired: true))
        XCTAssertFalse(Sheet.asksInviteAtSetUp(steps: first, state: .waiting(.setUp), passkey: true, inviteRequired: false))
        XCTAssertFalse(Sheet.asksInviteAtSetUp(steps: first, state: .waiting(.setUp), passkey: false, inviteRequired: true), "seed accounts: the invite step")
        // Signed in already on this iPhone, or the tap's run under way: no field.
        XCTAssertFalse(Sheet.asksInviteAtSetUp(steps: [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .needsYou)],
                                               state: .waiting(.setUp), passkey: true, inviteRequired: true))
        XCTAssertFalse(Sheet.asksInviteAtSetUp(steps: first, state: .running, passkey: true, inviteRequired: true))
    }

    func testARunEndedOrCancelledSaysNotFinished() {
        XCTAssertEqual(NetworkSetup.Failure.cancelled.message(method: .meraPasskey), "Not finished. Try again.")
        XCTAssertEqual(NetworkSetup.Failure.cancelled.message(method: .emailPassword), "Not finished. Try again.")
    }

    // MARK: - Runs against a Lite server

    func testASeedRunSignsInWithNoPromptAndAsksAppLockOnlyAtSetUpWhenItApplies() async throws {
        for appLock in [false, true] {
            let server = SetupServer(inviteRequired: false, friendbot: "25000")
            let asked = Asked()
            let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
            let address = try StellarSigner(seed: seed).address
            defer { server.stop(); Self.forget(address) }
            let keys = GatedSeedKeyProvider(
                address: address, methodLabel: "Email & Password", network: "testnet",
                appLockApplies: { asked.appLockReads += 1; return appLock },
                seed: { seed },
                ownerCheck: StellarOwnerCheck(canAuthenticate: { true }, authenticate: { _ in asked.prompts += 1; return true }))
            let session = LiteSession(env: server.env, stellarAddress: address, monad: nil, keys: keys)

            await session.run()
            XCTAssertEqual(session.state, .waiting(.setUp))
            XCTAssertEqual(session.steps.map(\.step), [.signIn, .setUp], "no unlock step")
            let rows = Sheet.displayRows(steps: session.rows, state: session.state, inviteRequired: session.inviteRequired)
            XCTAssertEqual(rows, [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .needsYou), Row(kind: .enableUSDC, status: .pending)])
            XCTAssertEqual(asked.prompts, 0, "the sign-in signs only its challenge, with no prompt")
            XCTAssertEqual(asked.appLockReads, 0)
            XCTAssertEqual(server.inviteCodes, [nil], "no code is asked for on testnet")
            XCTAssertFalse(Sheet.asksInviteAtSetUp(steps: session.rows, state: session.state, passkey: false, inviteRequired: session.inviteRequired))

            // Before the tap: Friendbot's amount from the config, and Enable USDC's reserve and fee from `/v1/fees`.
            XCTAssertEqual(session.friendbotAmount, "25000")
            let amount = await session.readFriendbotAmount()
            XCTAssertEqual(amount, "25000")
            let step = Sheet.accountStep(testnet: session.isTestnet, friendbotAmount: session.friendbotAmount)
            XCTAssertEqual(step.button, "Fund with Friendbot")
            XCTAssertTrue(step.line.hasPrefix("Get 25,000 free test XLM"), step.line)
            XCTAssertEqual(Sheet.enableLine(fee: session.setupFee, baseReserve: session.baseReserve, testnet: session.isTestnet),
                           "Holds 0.5 XLM · network fee up to 0.001 XLM")
            XCTAssertTrue(server.submitted.isEmpty, "nothing is signed before the tap")

            await session.setUp(invite: nil)
            XCTAssertEqual(session.state, .ready)
            XCTAssertEqual(asked.appLockReads, 1, "App Lock is read once, at the Set Up tap")
            XCTAssertEqual(asked.prompts, appLock ? 1 : 0, "Face ID or the passcode once, only while App Lock applies")
            // That one tap covered Enable USDC's own transaction: signed by the account's key, then sent.
            XCTAssertEqual(server.submitted.count, 1)
            XCTAssertTrue(try server.submitted.allSatisfy { try TransactionEnvelope(base64: $0).isSigned(by: address, network: PinnedContracts.testnet.network) })
            // Its decoded fee replaced the estimate, within the one shown.
            XCTAssertEqual(session.setupFee?.step("trust")?.built, true)
            XCTAssertEqual(session.setupFee?.maxFee("trust"), 5_000)
            XCTAssertEqual(Sheet.enableLine(fee: session.setupFee, baseReserve: session.baseReserve, testnet: session.isTestnet),
                           "Holds 0.5 XLM · network fee up to 0.0005 XLM")
            XCTAssertEqual(session.plan(), .instant, "set up on this iPhone: the next switch never opens Setup")
        }
    }

    func testAnEnableUSDCStepBuiltAboveTheFeeShownIsNeverSigned() async throws {
        let server = SetupServer(inviteRequired: false, friendbot: "10000", trustFee: 20_000)
        let seed = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let address = try StellarSigner(seed: seed).address
        defer { server.stop(); Self.forget(address) }
        let keys = GatedSeedKeyProvider(address: address, methodLabel: "Email & Password", network: "testnet", appLockApplies: { false },
                                        seed: { seed }, ownerCheck: StellarOwnerCheck(canAuthenticate: { true }, authenticate: { _ in true }))
        let session = LiteSession(env: server.env, stellarAddress: address, monad: nil, keys: keys)

        await session.run()
        let shown = try XCTUnwrap(session.setupFee)
        XCTAssertEqual(shown.maxFee("trust"), 10_000)

        // The server builds the step at 0.002 XLM, above the 0.001 XLM shown before the tap: it is refused unsigned.
        await session.setUp(invite: nil)
        XCTAssertEqual(session.state, .failed(.setUp, .setUpFailed))
        XCTAssertTrue(server.submitted.isEmpty, "nothing was signed or sent")
        XCTAssertEqual(session.setupFee, shown, "the figure shown stays")
        XCTAssertEqual(Sheet.displayRows(steps: session.rows, state: session.state, inviteRequired: session.inviteRequired),
                       [Row(kind: .signIn, status: .done), Row(kind: .setUp, status: .failed(.setUpFailed)), Row(kind: .enableUSDC, status: .pending)])
        XCTAssertEqual(NetworkSetup.Failure.setUpFailed.message(method: .emailPassword), "Couldn't set up your Stellar account. Nothing was spent.")
    }

    func testAPasskeyRunShowsTheInviteFieldBeforeItsOneCeremony() async throws {
        let server = SetupServer(inviteRequired: true, friendbot: "10000")
        let ceremonies = Count()
        let signer = try StellarSigner(seed: (0..<32).map { _ in UInt8.random(in: 0...255) })
        defer { server.stop(); Self.forget(signer.address) }
        let session = LiteSession(env: server.env, stellarAddress: nil, monad: nil, keys: nil, setupKey: { _ in
            ceremonies.add()
            let keys = PhraseKeyProvider(address: signer.address, methodLabel: "Passkey") { _ in throw LiteSession.Failure.cancelled }
            return LiteSession.UnlockResult(keys: keys, signer: signer)
        })

        // The Set Up tap comes first, with the optional invite field; nothing is asked before it.
        await session.run()
        XCTAssertEqual(session.state, .waiting(.setUp))
        XCTAssertEqual(ceremonies.value, 0)
        XCTAssertTrue(Sheet.asksInviteAtSetUp(steps: session.rows, state: session.state, passkey: true, inviteRequired: session.inviteRequired))
        XCTAssertEqual(Sheet.displayRows(steps: session.rows, state: session.state, inviteRequired: session.inviteRequired, passkey: true),
                       [Row(kind: .setUp, status: .needsYou), Row(kind: .signIn, status: .pending), Row(kind: .enableUSDC, status: .pending)])

        // One passkey prompt signs in, with the code, and sets the account up: Enable USDC's transaction included.
        await session.setUp(invite: "k7q2 xm9p")
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(ceremonies.value, 1, "exactly one passkey prompt for the sign-in and Enable USDC together")
        XCTAssertEqual(server.inviteCodes, ["K7Q2XM9P"])
        XCTAssertEqual(server.submitted.count, 1)
        XCTAssertTrue(try server.submitted.allSatisfy { try TransactionEnvelope(base64: $0).isSigned(by: signer.address, network: PinnedContracts.testnet.network) })
        XCTAssertFalse(Sheet.asksInviteAtSetUp(steps: session.rows, state: session.state, passkey: true, inviteRequired: session.inviteRequired))
    }

    func testAPasskeyRunOnTestnetHasNoInviteFieldAndShowsFriendbotsAmountBeforeItsTap() async throws {
        let server = SetupServer(inviteRequired: false, friendbot: "25000")
        let ceremonies = Count()
        let signer = try StellarSigner(seed: (0..<32).map { _ in UInt8.random(in: 0...255) })
        defer { server.stop(); Self.forget(signer.address) }
        let session = LiteSession(env: server.env, stellarAddress: nil, monad: nil, keys: nil, setupKey: { _ in
            ceremonies.add()
            let keys = PhraseKeyProvider(address: signer.address, methodLabel: "Passkey") { _ in throw LiteSession.Failure.cancelled }
            return LiteSession.UnlockResult(keys: keys, signer: signer)
        })

        await session.run()
        XCTAssertEqual(session.state, .waiting(.setUp))
        XCTAssertFalse(session.inviteRequired)
        XCTAssertFalse(Sheet.asksInviteAtSetUp(steps: session.rows, state: session.state, passkey: true, inviteRequired: session.inviteRequired))
        XCTAssertEqual(Sheet.displayRows(steps: session.rows, state: session.state, inviteRequired: session.inviteRequired, passkey: true),
                       [Row(kind: .setUp, status: .needsYou), Row(kind: .signIn, status: .pending), Row(kind: .enableUSDC, status: .pending)])

        // Before the tap, with no sign-in yet: Friendbot's amount from the server's config, and Enable USDC's price.
        let amount = await session.readFriendbotAmount()
        XCTAssertEqual(amount, "25000")
        let step = Sheet.accountStep(testnet: session.isTestnet, friendbotAmount: session.friendbotAmount ?? amount)
        XCTAssertEqual(step.button, "Fund with Friendbot")
        XCTAssertTrue(step.line.hasPrefix("Get 25,000 free test XLM"), step.line)
        XCTAssertEqual(Sheet.enableLine(fee: session.setupFee, baseReserve: session.baseReserve, testnet: session.isTestnet),
                       "Holds 0.5 XLM · network fee up to 0.001 XLM")
        XCTAssertEqual(ceremonies.value, 0, "reading them asks nothing")
        XCTAssertEqual(server.inviteCodes, [], "and signs nothing in")

        await session.setUp(invite: nil)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(ceremonies.value, 1)
        XCTAssertEqual(server.inviteCodes, [nil])
        XCTAssertEqual(server.submitted.count, 1)
        XCTAssertEqual(session.setupFee?.maxFee("trust"), 5_000)
        XCTAssertFalse(Sheet.displayRows(steps: session.rows, state: session.state, inviteRequired: session.inviteRequired, passkey: true)
            .contains { $0.kind == .invite })
    }

    func testAPasskeyRunEndedByTheBackgroundSaysNotFinishedAndTheNextTapAsksAgain() async throws {
        let server = SetupServer(inviteRequired: false, friendbot: "10000")
        let ceremonies = Count()
        let words = try XCTUnwrap(Mnemonic.phrase(entropy: (0..<16).map { _ in UInt8.random(in: 0...255) }))
        let signer = try StellarDerivation.sep5(mnemonic: words)
        defer { server.stop(); Self.forget(signer.address) }
        let keys = PhraseKeyProvider(address: signer.address, methodLabel: "Passkey") { _ in
            ceremonies.add()
            return words
        }
        let session = LiteSession(env: server.env, stellarAddress: nil, monad: nil, keys: nil, setupKey: { _ in
            ceremonies.add()
            return LiteSession.UnlockResult(keys: keys, signer: signer)
        })
        await session.run()
        XCTAssertEqual(session.state, .waiting(.setUp))

        // The app goes to the background while Friendbot creates the account: the run ends, and its signer with it.
        let activation = server.hold("/v1/account/activate")
        let tap = Task { await session.setUp(invite: nil) }
        try await activation.arrival()
        session.appDidEnterBackground()
        activation.release()
        await tap.value
        XCTAssertEqual(session.state, .failed(.setUp, .cancelled))
        XCTAssertEqual(ceremonies.value, 1)
        XCTAssertTrue(server.submitted.isEmpty, "nothing is signed once the run has ended")
        XCTAssertEqual(Sheet.displayRows(steps: session.rows, state: session.state, inviteRequired: session.inviteRequired, passkey: true),
                       [Row(kind: .setUp, status: .failed(.cancelled)), Row(kind: .signIn, status: .done), Row(kind: .enableUSDC, status: .pending)])
        XCTAssertEqual(NetworkSetup.Failure.cancelled.message(method: .meraPasskey), "Not finished. Try again.")

        // Try again asks for the passkey again: the run kept no signer.
        session.appDidBecomeActive()
        await session.retry()
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(ceremonies.value, 2)
        XCTAssertEqual(server.submitted.count, 1)
        XCTAssertTrue(try server.submitted.allSatisfy { try TransactionEnvelope(base64: $0).isSigned(by: signer.address, network: PinnedContracts.testnet.network) })
    }

    // MARK: - Support

    /// What a seed account's provider asked: App Lock's setting read, and the owner's prompts.
    @MainActor
    final class Asked {
        var appLockReads = 0
        var prompts = 0
    }

    /// Passkey ceremonies, counted from the session's own task.
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    /// The API's plan fixture's built step: an Enable USDC transaction declaring 0.001 XLM, from GCLJ….
    private static let trustXDR = "AAAAAgAAAACWkx+5IqHDdKtQ/Z773xUBaGRNzFg8rllQIi8Zjpt54AAAJxAAToEGAAAAAQAAAAEAAAAAas9OLAAAAABqz1CEAAAAAAAAAAEAAAAAAAAABgAAAAFVU0RDAAAAAEI+fQXy7K+/7BkrIVo/G+lq7bjY5wJUq+NBPgIH3layf/////////8AAAAAAAAAAA=="

    /// Enable USDC as a plan's step: built (`trustXDR`, 0.001 XLM), or not yet, priced by its ceiling `maxFee`.
    private func step(built: Bool, maxFee: String) -> [String: Any] {
        var step: [String: Any] = ["id": "trust", "label": "Enable USDC", "status": built ? "built" : "pending", "stepKind": "trust",
                                   "maxFee": maxFee, "feePayer": "user", "reserveDelta": 1]
        if built {
            step["xdr"] = Self.trustXDR
            step["intent"] = SetupServer.trustIntent
        }
        return step
    }

    private func fees(_ steps: [[String: Any]]) throws -> PlanFees {
        let json: [String: Any] = ["planId": "setup", "kind": "trust", "expiresAt": "2026-10-15T09:56:00.000Z", "steps": steps]
        let plan = try JSONDecoder().decode(PlanView.self, from: JSONSerialization.data(withJSONObject: json))
        return try PlanFees(plan: plan, pinned: .testnet)
    }

    /// What a run left on this iPhone for `address`: its saved session and its setup notes.
    private static func forget(_ address: String) {
        StellarKeychain.erase(account: address)
        UserDefaults.standard.removeObject(forKey: LiteSession.activatedKey(address))
        UserDefaults.standard.removeObject(forKey: LiteSession.signedOutKey(address))
    }
}

/// A Lite server for one test, on a host of its own under `.stellar-setup.test`: the config (with `inviteRequired` and
/// Friendbot's amount), the fees, the sign-in (a code needed where `inviteRequired` says so: K7Q2XM9P), the account, an
/// activation that creates it and answers the plan that enables USDC (one trust step, built for the account at
/// `trustFee` stroops), and the submission of that step, which enables USDC. It keeps the invite code each sign-in sent
/// and every transaction sent, and can keep one request waiting (`hold`).
final class SetupServer: @unchecked Sendable {
    let host = "lite-\(UUID().uuidString.lowercased()).stellar-setup.test"
    private let inviteRequired: Bool
    private let friendbot: String
    private let trustFee: UInt32
    private let lock = NSLock()
    private var exists = false
    private var usdc = false
    private var invited = false
    private var codes: [String?] = []
    private var sent: [String] = []
    private var address: String?
    private var holds: [String: Hold] = [:]
    private var issued = 0

    /// `trustFee`: Enable USDC's fee as the server builds it; `/v1/fees` estimates 10,000 stroops (0.001 XLM).
    init(inviteRequired: Bool, friendbot: String, trustFee: UInt32 = 5_000) {
        self.inviteRequired = inviteRequired
        self.friendbot = friendbot
        self.trustFee = trustFee
        SetupStub.serve(host: host) { [self] request in answer(request) }
    }

    var env: LiteEnvironment { LiteEnvironment(apiURL: URL(string: "https://\(host)/lite")!, pinned: .testnet, buildNumber: 1000) }

    /// The invite code of each sign-in, in order (nil: none sent).
    var inviteCodes: [String?] { lock.withLock { codes } }

    /// The signed transactions sent, in order (base64 envelopes).
    var submitted: [String] { lock.withLock { sent } }

    func stop() { SetupStub.serve(host: host, nil) }

    /// Keeps the next request to `path` waiting until the test releases it.
    func hold(_ path: String) -> Hold {
        let hold = Hold()
        lock.withLock { holds[path] = hold }
        return hold
    }

    /// The Enable USDC step's intent: one `changeTrust`, for Circle's testnet USDC.
    static var trustIntent: [String: Any] {
        ["kind": "trust", "summary": "Enable USDC", "spend": [String: String](), "ops": ["changeTrust"],
         "trust": ["USDC:\(usdcIssuer)"], "display": ["asset": "USDC"]]
    }

    private static let usdcIssuer = "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"

    private func answer(_ request: SetupStub.Request) -> (status: Int, body: Data) {
        if let hold = lock.withLock({ holds.removeValue(forKey: request.path) }) { hold.wait() }
        switch (request.method, request.path) {
        case ("GET", "/v1/config"): return (200, config)
        case ("GET", "/v1/fees"): return (200, Self.fees)
        case ("POST", "/v1/auth/challenge"):
            let nonce = "setup-nonce-0123456789"
            let address = request.json["address"] ?? ""
            lock.withLock { self.address = address }
            let message = ["DyorHQ Lite sign-in", "Network: testnet", "Address: \(address)", "Nonce: \(nonce)",
                           "Issued: 2026-10-15T09:41:00.000Z"].joined(separator: "\n")
            return (200, Self.json(["nonce": nonce, "message": message, "expiresAt": Self.time(300)]))
        case ("POST", "/v1/auth/verify"):
            let code = request.json["inviteCode"]
            return lock.withLock {
                codes.append(code)
                if inviteRequired, !invited {
                    guard let code else { return (403, Self.error("not_invited", "Enter your invite code.")) }
                    guard code == "K7Q2XM9P" else { return (403, Self.error("bad_invite", "That code isn't valid.")) }
                    invited = true
                }
                issued += 1
                return (200, Self.json(["token": "jwt\(issued)", "expiresAt": Self.time(3600), "refreshToken": "lrt_\(issued)",
                                        "refreshExpiresAt": Self.time(30 * 86_400)], tester: true))
            }
        case ("GET", "/v1/account"):
            return (200, lock.withLock { Self.account(exists: exists, usdc: usdc) })
        case ("POST", "/v1/account/activate"):
            // Friendbot creates the account; USDC waits for the user's own trust transaction.
            let address = lock.withLock { exists = true; return self.address }
            guard let address, let plan = try? Self.trustPlan(for: address, fee: trustFee) else {
                return (500, Self.error("internal", "No sign-in."))
            }
            return (200, plan)
        case ("POST", "/v1/tx/submit"):
            lock.withLock {
                sent.append(request.json["signedXdr"] ?? "")
                usdc = true
            }
            return (200, Self.json(["hash": Self.hash, "status": "pending"]))
        case ("GET", "/v1/tx/\(Self.hash)"):
            return (200, Self.json(["hash": Self.hash, "status": "success"]))
        default:
            return (404, Self.error("not_found", "No such route."))
        }
    }

    private var config: Data {
        Data("""
        {"network":"testnet","passphrase":"Test SDF Network ; September 2015","rpcUrl":"http://127.0.0.1:9/rpc",
         "horizonUrl":"http://127.0.0.1:9/horizon","activation":"friendbot","sponsor":"\(PinnedContracts.testnet.sponsor)",
         "assets":[{"id":"XLM","code":"XLM","name":"Stellar Lumens","decimals":7,"contract":"CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC","classic":"native","note":null},
                   {"id":"USDC","code":"USDC","name":"USD Coin","decimals":7,"contract":"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA","classic":"USDC:G","note":null}],
         "contracts":{"launchpad":null,"moments":null,"soroswapRouter":"C","blendPools":[]},"allowlist":{},
         "bridge":{"routes":[],"monad":null},"flags":{"enabled":true},"minBuild":1,"inviteRequired":\(inviteRequired),
         "faucet":{"amount":"\(friendbot)"}}
        """.utf8)
    }

    private static let fees = Data("""
    {"network":"testnet","baseReserve":"5000000","baseFee":"100","inclusionFee":{"classic":"100","soroban":"150"},
     "estimates":{"trust":"10000","payment":"10000"},"estimateBasis":{"trust":"default"},"updatedAt":null}
    """.utf8)

    /// The hash the server gives the one transaction it is sent.
    private static let hash = String(repeating: "5e", count: 32)

    /// An account not on the ledger yet, or one Friendbot created (10,000 XLM), with USDC enabled or not.
    private static func account(exists: Bool, usdc: Bool) -> Data {
        Data("""
        {"address":"G","exists":\(exists),"network":"testnet","activation":"friendbot","sponsor":"G","reserves":null,"view":"owner",
         "balances":[{"asset":"XLM","code":"XLM","name":"Stellar Lumens","contract":"CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC","classic":"native","decimals":7,"balance":"\(exists ? "100000000000" : "0")","enabled":\(exists)},
                     {"asset":"USDC","code":"USDC","name":"USD Coin","contract":"CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA","classic":"USDC:G","decimals":7,"balance":"0","enabled":\(usdc)}],
         "xlm":null}
        """.utf8)
    }

    /// The setup plan's one step, built: the account's `changeTrust` for USDC at `fee`, valid for five minutes.
    private static func trustPlan(for address: String, fee: UInt32) throws -> Data {
        let step: [String: Any] = ["id": "trust", "label": "Enable USDC", "status": "built", "stepKind": "trust", "maxFee": String(fee),
                                   "feePayer": "user", "reserveDelta": 1, "xdr": try trustXDR(source: address, fee: fee), "intent": trustIntent]
        return try JSONSerialization.data(withJSONObject: ["planId": "setup", "kind": "trust", "expiresAt": time(300), "steps": [step]])
    }

    /// A v1 envelope, unsigned: `source`'s `changeTrust` for USDC with the largest limit, at `fee`, until five minutes
    /// from now.
    private static func trustXDR(source: String, fee: UInt32) throws -> String {
        var w = XDRWriter()
        w.uint32(2) // ENVELOPE_TYPE_TX
        w.uint32(0) // KEY_TYPE_ED25519
        w.raw(try StrKey.decode(.accountID, source))
        w.uint32(fee)
        w.int64(1) // sequence number
        w.uint32(1) // PRECOND_TIME
        w.uint64(0)
        w.uint64(UInt64(Date().timeIntervalSince1970) + 300)
        w.uint32(0) // MEMO_NONE
        w.uint32(1) // one operation
        w.uint32(0) // with no source of its own
        w.uint32(6) // CHANGE_TRUST
        w.uint32(1) // ASSET_TYPE_CREDIT_ALPHANUM4
        w.raw(Array("USDC".utf8))
        w.uint32(0)
        w.raw(try StrKey.decode(.accountID, usdcIssuer))
        w.int64(.max)
        w.uint32(0) // no extension
        w.uint32(0) // no signatures
        return Data(w.bytes).base64EncodedString()
    }

    private static func json(_ fields: [String: String], tester: Bool = false) -> Data {
        var object: [String: Any] = fields
        if tester { object["tester"] = ["address": "G", "label": NSNull()] }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func error(_ code: String, _ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
    }

    /// `seconds` from now, as the API writes times.
    private static func time(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
    }

    /// A request kept waiting on the stub's thread (10 seconds at most) until the test releases it: the test acts while
    /// the run waits on it.
    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var arrived = false
        private let released = DispatchSemaphore(value: 0)

        /// The stub's side: the request has arrived; it waits for `release()`.
        func wait() {
            lock.withLock { arrived = true }
            _ = released.wait(timeout: .now() + 10)
        }

        func release() { released.signal() }

        /// The test's side: returns once the request has arrived, or fails after 10 seconds.
        func arrival() async throws {
            let deadline = Date().addingTimeInterval(10)
            while !lock.withLock({ arrived }) {
                guard Date() < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

/// Answers the requests to `.stellar-setup.test` hosts (`URLSession.shared`, which `LiteAPI` uses, asks the registered
/// protocols), each with its host's handler; every other request goes out as usual.
final class SetupStub: URLProtocol {
    struct Request: Sendable {
        let method: String
        /// The path below the API's base: "/v1/account".
        let path: String
        let body: Data?

        var json: [String: String] { body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
    }

    typealias Handler = @Sendable (Request) -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func serve(host: String, _ handler: Handler?) { lock.withLock { handlers[host] = handler } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".stellar-setup.test") ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let seen = Request(method: request.httpMethod ?? "GET", path: url.path.replacingOccurrences(of: "/lite", with: ""), body: Self.body(of: request))
        let handler = Self.lock.withLock { Self.handlers[url.host ?? ""] }
        guard let handler else {
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
