import BigInt
import DyorKit
import Foundation
import Observation
import os
import Security
import UIKit

/// Coordinates authenticated Perpl trading: enroll an Ed25519 API key with the wallet's EIP-712 signature (stored
/// in the Keychain), sign in to the trading WebSocket, enable one-click order forwarding, and place market / limit
/// orders with optional take-profit and stop-loss triggers. This is the only path that yields real TP/SL, because
/// the on-chain Exchange has no trigger primitive — Perpl's keeper watches the mark and fires the close.
///
/// Exactly ONE trading socket is ever open per app. Perpl caps a wallet at 4 concurrent trading connections (shared
/// with the Perpl web app) and closes any beyond that with 1008 "too many connections" — so every connect goes
/// through a single in-flight task, tears the previous socket down first, and failed attempts back off before an
/// automatic retry.
///
/// A passkey (Mera) account's trading key is different (MERA-PLAN §3): its Ed25519 secret is derived from the passkey's
/// utility output when a session opens and held in memory only — the Keychain keeps just the token, which can't sign
/// in to the socket alone. The key, the socket and the keep-alive live exactly as long as the session: `end()` drops
/// all three (`MeraSessionLifecycle`), nothing reconnects while it is locked, and orders need the live session and fit
/// its caps, or a step-up.
@Observable
@MainActor
final class PerplTrading: MeraSessionLifecycle {
    enum Status: Equatable {
        case notEnrolled          // no key on this device
        case enrolled             // key stored, not connected
        case connecting
        case connected            // signed in, order forwarding on — ready to trade
        case needsForwarding      // signed in, but one-click trading is off
        case failed(String)
    }

    private(set) var status: Status = .notEnrolled
    private(set) var key: PerplApiKey?
    /// The account's open orders + pending keeper triggers, mirrored from the trading socket (mt:23/24). The
    /// authoritative source for TP/SL — the on-chain order book has none — but only while `ordersAreLive`: after the
    /// socket drops on its own this is the LAST KNOWN list (a trigger may have fired or been cancelled since), and it is
    /// emptied when the session is deliberately closed, the wallet changes or the key is removed.
    private(set) var openOrders: [PerplOpenOrder] = []
    /// A take-profit / stop-loss fired or failed, or a position was liquidated, since the app opened (security audit
    /// GT-9) — for the trade screen to show in place, besides the notification.
    private(set) var protectionNotice: ProtectionNotice?
    /// Markets the app has seen, for naming and scaling what the trading stream reports (`noteMarkets`).
    private var markets: [Int: PerpMarket] = [:]
    /// Orders (by market and id) a cancel was already sent for, so the automatic sibling cleanup never sends one twice.
    private var cancelsSent: Set<PerplOpenOrder.Key> = []
    /// Sides of markets an entry was sent to recently: its triggers may be on the stream before the entry is.
    private var recentEntries: [PerplMarketSide: Date] = [:]
    /// Markets whose position the trading stream explained as it happened — liquidated, deleveraged or unwound by Perpl,
    /// or a take-profit / stop-loss on it triggered — and when, so the app-wide watcher doesn't report the ending again
    /// (`endingExplained`, `PerpEndingNotice`).
    private var explainedEndings: [Int: Date] = [:]
    private var client: PerplTradeClient?
    /// The wallet (checksummed address) the trading session is bound to, so a wallet change tears the session down.
    private var boundAddress: String?
    /// The one connect in flight, if any — concurrent callers await it instead of opening a second socket.
    private var connectTask: Task<Void, Error>?
    /// Automatic reconnects (watchers, order submission) wait until this instant; a user's tap always tries.
    private var retryAfter: Date = .distantPast
    private var consecutiveFailures = 0
    /// Perpl rejected the key (close 3401). Automatic reconnects stop: the same key can never sign in again.
    private var keyRejected = false
    /// Set once `allowOrderForwarding(true)` has CONFIRMED on-chain for the bound wallet this session. There is no
    /// on-chain getter for the flag and Perpl's WS `fw` push can lag the keeper by seconds, so a confirmed tx is the
    /// authority: forwarding is treated as on from that moment, regardless of the (possibly stale) WS `fw`. Cleared
    /// on a wallet change / forget.
    private var forwardingGrantedOnChain = false
    /// Keeps the single trading socket alive for as long as a key is enrolled, reconnecting automatically after any
    /// drop (network change, server restart, app resume) so the user never has to reconnect by hand to place TP/SL.
    /// It runs from the moment a key is present until the key is removed or the wallet changes; only Perpl rejecting
    /// the key (close 3401) makes it stand down (that key can never sign in again — the user must re-enroll). For a
    /// passkey account it runs only while the session is live.
    private var keepAlive: Task<Void, Never>?
    /// The passkey session a Mera account's trading key lives in.
    private let mera: MeraSession?
    /// The bound wallet is a passkey (Mera) account: its key exists only while that account's session is live.
    private var boundToPasskey = false
    /// A passkey account's stored token (never its secret).
    private var storedToken: PerplToken?
    /// Reads a wallet's open positions on-chain over the given markets (set by AppEnvironment), throwing when the read
    /// is incomplete. The automatic clean-up of leftover TP/SL cancels only what the chain agrees has closed.
    @ObservationIgnored var readPositions: ((Address, [PerpMarket]) async throws -> [PerpPosition])?
    /// The highest request id this device wrote per Perpl account (persisted, not a secret): every new socket starts
    /// above it, so an order never reuses the id of one the previous socket sent that Perpl hasn't forwarded yet.
    private let requestIds = PerplRequestIdStore()
    /// The owner's kill switch for showing Perpl's real order outcome (`RemoteFlags.perpsLiveOutcome`, on unless the row
    /// says JSON `false`), set by `AppEnvironment.apply`. Off: today's acknowledgement sheet (`placeLegacy`), and Close /
    /// Add Margin / Cancel Order go on-chain. Read once, at the tap that sends an order or opens a sheet: a request
    /// already sent keeps the mode of its tap. Until a check of this launch reads the row, the last values read
    /// (`PerpsSwitchStore`) decide, so an OFF the owner engaged survives a relaunch or an offline start; with none
    /// stored, it is on. A DEBUG build run with `-perpsLiveOutcome YES|NO` forces it for simulator QA.
    @ObservationIgnored var liveOutcomes = PerplTrading.debugSwitch("perpsLiveOutcome") ?? PerpsSwitchStore.last?.perpsLiveOutcome ?? RemoteFlags.on.perpsLiveOutcome {
        didSet { if let forced = Self.debugSwitch("perpsLiveOutcome"), liveOutcomes != forced { liveOutcomes = forced } }
    }

    /// The owner's kill switch for Close / Add Margin / Cancel Order over the trading connection
    /// (`RemoteFlags.perpsApiActions`, on unless the row says JSON `false`), set by `AppEnvironment.apply`. Off: they go
    /// on-chain, as before; the order sheet is unaffected. Read at the tap that opens the sheet: a request already sent
    /// keeps the path of its tap. Restored from `PerpsSwitchStore` like `liveOutcomes`. A DEBUG build run with
    /// `-perpsApiActions YES|NO` forces it for simulator QA.
    @ObservationIgnored var apiActions = PerplTrading.debugSwitch("perpsApiActions") ?? PerpsSwitchStore.last?.perpsApiActions ?? RemoteFlags.on.perpsApiActions {
        didSet { if let forced = Self.debugSwitch("perpsApiActions"), apiActions != forced { apiActions = forced } }
    }

    /// DEBUG builds only: `-perpsLiveOutcome YES|NO` / `-perpsApiActions YES|NO` force a switch for simulator QA; absent,
    /// the row (or its last persisted value) decides. Always nil in Release.
    private static func debugSwitch(_ name: String) -> Bool? {
        #if DEBUG
        UserDefaults.standard.object(forKey: name) == nil ? nil : UserDefaults.standard.bool(forKey: name)
        #else
        nil
        #endif
    }

    /// TP/SL a cancel was sent for, by the socket that sent it and when: the trade screen doesn't offer them again while
    /// that cancel is on its way (a second tap would send a second cancel). One leaves when it is no longer listed on THE
    /// SOCKET THAT SENT IT while that socket is signed in with its orders snapshot, or after 15 s. A drain, a disconnect
    /// or a wallet change never removes one early: an emptied list proves nothing.
    private(set) var cancelsPending: [PerplOpenOrder.Key: PendingCancel] = [:]
    /// Sides of markets whose leftover TP/SL the automatic clean-up is about to cancel (key accounts), and since when.
    /// Removed when it sends (its orders move to `cancelsPending`), when it gives up, or after 20 s.
    private(set) var cleanupScheduled: [PerplMarketSide: Date] = [:]

    struct PendingCancel {
        weak var client: PerplTradeClient?
        let at: Date
    }

    /// What became of an order a cancel was sent for (`cancelAndConfirm`), as the sending socket's list shows it.
    typealias CancelResult = PerplCancelResult

    /// The cancels the sheets sent, by the order each cancels: the socket that sent it and its request id. Only that
    /// socket's live list can confirm it (`cancelLiveResult`): a list a dropped or new socket emptied proves nothing (I9).
    @ObservationIgnored private var cancelRequests: [PerplOpenOrder.Key: CancelRequest] = [:]

    struct CancelRequest {
        weak var client: PerplTradeClient?
        let rq: Int
        let sentAt: Date
    }

    static let cancelPendingWindow: TimeInterval = 15
    static let cleanupWindow: TimeInterval = 20

    /// The orders sent from this device, followed to what Perpl (or the chain) showed they did (`track`): for the order
    /// sheet and the trade screen's status row. Never a source for positions.
    let orders = PerplOrderTracker()
    /// Bumped the moment an order's result is in, and soon after any report on the account from the live trading stream
    /// (`streamActivity`), so the Perps screens read the chain again then instead of at their next poll. The position
    /// cards still come from the chain only: a report is a reason to read, never the data shown.
    private(set) var streamRevision = 0
    /// Bumped a second after the live stream reports a fill or a position change on the account (`historyActivity`): the
    /// portfolio's history reads again.
    private(set) var historyRevision = 0
    /// The stream's reload request: when the last one went out, since when a report waits for the next, and its timer.
    @ObservationIgnored private var streamBumpedAt: Date = .distantPast
    @ObservationIgnored private var streamPendingSince: Date?
    @ObservationIgnored private var streamBump: Task<Void, Never>?
    @ObservationIgnored private var historyBump: Task<Void, Never>?
    /// A burst of reports is one reload, 250 ms after the last of them, but never more than a second after the first, and
    /// reloads are at least a second apart. The history waits a second after the last fill.
    static let streamDebounce: TimeInterval = 0.25
    static let streamSpacing: TimeInterval = 1
    static let historyDebounce: TimeInterval = 1

    // What the order outcomes need from the rest of the app (set by AppEnvironment).
    /// Fill notices are on (notifications and "Swaps & Fills").
    @ObservationIgnored var notifyFills: () -> Bool = { false }
    /// `AlertCenter.expectFill`: an order sent can grow (market, side) by up to this much until its deadline.
    @ObservationIgnored var expectFill: (UUID, Int, PositionSide, Double, Date) -> Void = { _, _, _, _, _ in }
    /// `AlertCenter.fillAnnounced`: the order announced its own fill for this much growth.
    @ObservationIgnored var fillAnnounced: (UUID, Double) -> Void = { _, _ in }
    /// `AlertCenter.releaseFill`: the order's result is in and it posts no fill notice.
    @ObservationIgnored var releaseFill: (UUID) -> Void = { _ in }
    /// `AlertCenter.watcherAnnounced`: the watcher announced a fill on (market, side) since the date.
    @ObservationIgnored var watcherAnnounced: (Int, PositionSide, Date) -> Bool = { _, _, _ in false }
    /// `AlertCenter.reconsiderFills`: an order's result is in; growths that waited for it are decided now.
    @ObservationIgnored var wakeWatcher: () -> Void = {}
    /// `AlertCenter.forgetUserClose`: a close the app noted executed nothing.
    @ObservationIgnored var userCloseVoided: (Int) -> Void = { _ in }
    /// The account's signed order history (`PerplService.orderEvents`), for an order whose result the stream never gave.
    @ObservationIgnored var orderHistory: ((PerplApiKey) async throws -> [PerplOrderEvent])?

    /// A passkey order's charge against its session, given back if the order provably executed nothing (memory only).
    @ObservationIgnored private var charges: [UUID: MeraSession.Charge] = [:]
    /// Orders a live task follows: their sheet-time wait, then the reads of an unconfirmed result. The reconcile leaves
    /// them alone. Observed: the sheet's "checking" lines end when it does.
    private(set) var following: Set<UUID> = []
    /// Orders whose entry executed nothing and whose take-profit / stop-loss are being looked for on Perpl's live list now
    /// (`checkLeftTriggers`). Observed: the sheet says "Checking…" until it is done.
    private(set) var checkingLeft: Set<UUID> = []
    @ObservationIgnored private var resolving: Set<UUID> = []
    /// Orders whose signed history was already read in this process (once each).
    @ObservationIgnored private var historyRead: Set<UUID> = []
    /// Bumped on any own-account report on any socket: an unconfirmed order's evidence is read again then.
    @ObservationIgnored private var accountActivity = 0
    @ObservationIgnored private var reconciling = false
    /// Orders the reconcile is done with in this process (their row written, or out of the store): never read again by
    /// it, so a row is written once. A late report on the stream still reaches them (`reevaluate`).
    @ObservationIgnored private var reconciled: Set<UUID> = []

    /// The stream's census (counts only), merged across sockets and app launches.
    private let censusStore = PerplCensusStore()
    @ObservationIgnored private var censusTask: Task<Void, Never>?
    @ObservationIgnored private var censusLoggedAt: Date = .distantPast
    @ObservationIgnored private var censusLogged: PerplStreamCensus?

    init(mera: MeraSession? = nil) {
        self.mera = mera
        mera?.lifecycle = self
    }

    var isReady: Bool { status == .connected }
    /// A key is enrolled for this wallet: loaded, or — for a passkey account whose session is locked — its token only. (The
    /// DEBUG scripted demo's session, which has neither, stands for an enrolled one: `demoSession`.)
    var isEnrolled: Bool { key != nil || storedToken != nil || demoSession }
    /// The signed-in account id from the trading WS (same value the on-chain account reports).
    var accountId: Int? { client?.accountId }
    /// The most recent failure, for callers that need to say why an authenticated action couldn't run.
    var failureMessage: String? { if case .failed(let why) = status { return why } else { return nil } }
    /// Live socket diagnostics, so the connection screen can show the ground truth behind `status`.
    var isSignedIn: Bool { client?.signedIn == true }
    var isForwarding: Bool { client?.forwardingEnabled == true || forwardingGrantedOnChain }
    /// `openOrders` is Perpl's current, complete list: the socket is signed in (one-click on or not) and has sent its
    /// open-orders snapshot. Otherwise the TP/SL on screen can't be verified (security audit GT-3).
    var ordersAreLive: Bool { client?.signedIn == true && client?.hasOrdersSnapshot == true }
    /// The request an order on the live socket's list belongs to (its own report named it), or nil.
    func requestId(for key: PerplOpenOrder.Key) -> Int? { client?.requestId(for: key) }
    /// The account's open positions as the live trading socket reports them — the position id a TP/SL links to.
    /// Empty when the socket isn't live, or before its positions snapshot.
    var livePositions: [PerplLivePosition] { client?.hasPositionsSnapshot == true ? client?.positions ?? [] : [] }
    /// `livePositions` is Perpl's current, complete list (the socket is signed in and sent its positions snapshot).
    var positionsAreLive: Bool { client?.signedIn == true && client?.hasPositionsSnapshot == true }
    /// The live socket's heartbeat skipped since its snapshots: updates may have been missed, so its lists may be out of
    /// date (the TP/SL rows say "Last seen on Perpl" until the next snapshots).
    var streamSuspect: Bool { client?.streamSuspect == true }

    /// Load any stored key for this account so the UI shows "enrolled" without a network call. Rebinds to the given
    /// wallet: when the wallet changes (or signs out) it tears down the previous wallet's authenticated session first,
    /// so a `connected` / one-click-ready state can never carry over to a different account. A passkey account loads
    /// its token only; its key exists while its session is live.
    func refresh(account: Session.Account?) {
        let address = account?.address
        let passkey = account?.method == .meraPasskey
        let target = address?.checksummed
        if target != boundAddress || passkey != boundToPasskey {
            disconnect()
            key = nil
            storedToken = nil
            status = .notEnrolled
            boundAddress = target
            boundToPasskey = passkey
            keyRejected = false
            forwardingGrantedOnChain = false
            // A refusal of the trading route belongs to the account it was for.
            apiBlocked = nil
            lastSignedInAt = .distantPast
            resetProtection()
            resetRetry()
        }
        // The orders sent for this account that a closed or killed app left waiting: reconciled on the next return.
        orders.load(owner: address)
        guard let address else { stopKeepAlive(); return }
        if passkey {
            storedToken = PerplKeychain.loadToken(address: address.checksummed)
            syncSessionKey()
        } else {
            key = PerplKeychain.load(address: address.checksummed)
        }
        if status == .notEnrolled || status == .enrolled { status = isEnrolled ? .enrolled : .notEnrolled }
        if key != nil { startKeepAlive() } else { stopKeepAlive() }
    }

    // MARK: Passkey (Mera) accounts

    /// Whether automatic reconnects may run: always, except for a passkey account whose session is locked.
    private var sessionAllowsTrading: Bool { !boundToPasskey || mera?.isUnlocked == true }

    /// A passkey account's key: its stored token with the live session's trading secret. Nil while locked.
    private func sessionKey() -> PerplApiKey? {
        guard boundToPasskey, let storedToken, let mera, let boundAddress, mera.address?.checksummed == boundAddress else { return nil }
        return mera.perplKey(token: storedToken.token, scopeMask: storedToken.scopeMask, keyNonce: storedToken.keyNonceData)
    }

    /// Brings a passkey account's `key` in line with its session: the live session's key (the socket and keep-alive
    /// follow it), or none.
    private func syncSessionKey() {
        let fresh = sessionKey()
        if fresh != key {
            // A socket signed in with another key must not outlive it.
            if key != nil { disconnect() }
            key = fresh
        }
        if key != nil {
            if status == .notEnrolled { status = .enrolled }
            startKeepAlive()
        } else {
            stopKeepAlive()
        }
    }

    func meraSessionDidOpen(_ session: MeraSession) {
        guard boundToPasskey else { return }
        syncSessionKey()
    }

    /// MERA-PLAN §3 `end()`: the socket closes, the keep-alive stops and the key is dropped. The token stays.
    ///
    /// An order already on the wire keeps its socket until Perpl answers it (security audit GL-1): the session often
    /// ends because the app left the foreground mid-bracket, and closing then fails the unanswered frames — the entry
    /// may be live at Perpl while its stop-loss was never sent. So does an approved operation still running (a bracket,
    /// a cancel-then-place of a TP/SL, a cancel): between its steps nothing is in flight, but closing then would leave
    /// the old stop cancelled and the new one unsent. The socket is detached at once, so nothing new can use it, and
    /// closed as soon as its acks are in and its operation is done — after the 8 s an ack is given at most, or 20 s for
    /// a running operation. Whatever is still waiting then fails as "outcome unknown", which the sheets show as such,
    /// never as a failure to retry.
    func meraSessionDidEnd(_ session: MeraSession) {
        guard boundToPasskey else { return }
        stopKeepAlive()
        key = nil
        if let busy = client, busy.hasRequestsInFlight || operationsRunning > 0 {
            client = nil
            openOrders = []
            drain(busy)
        } else {
            disconnect()
        }
        // A key Perpl rejected keeps saying so; anything else reads as enrolled (token kept) or not.
        if !keyRejected { status = storedToken != nil ? .enrolled : .notEnrolled }
    }

    /// A socket detached from the session, kept only until the requests already on it are answered.
    private var draining: PerplTradeClient?
    /// Approved operations still running (`operation`), which keep a detached socket open until they finish.
    private var operationsRunning = 0

    private func drain(_ socket: PerplTradeClient) {
        draining?.disconnect()
        draining = socket
        // Held so iOS doesn't suspend the app, and freeze the socket, before its answers are in (GL-1).
        let background = PerplBackgroundTime("Perpl trading") // not localized: the task's name, never shown
        Task { @MainActor [weak self] in
            defer { background.end() }
            let start = Date()
            while Date().timeIntervalSince(start) < PerplTimeouts.drainOperation {
                let operating = (self?.operationsRunning ?? 0) > 0
                guard socket.hasRequestsInFlight || operating else { break }
                if !operating, Date().timeIntervalSince(start) >= PerplTimeouts.drainAcks { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.flushCensus(socket)
            socket.disconnect()
            if self?.draining === socket { self?.draining = nil }
        }
    }

    /// Starts an operation the user approved (a bracket, a TP/SL change, a cancel): it holds background time, and a
    /// passkey session that ends meanwhile keeps its socket until it is done (`drain`, GL-1). Call the result when it is.
    /// `name` names the background task for iOS (not localized: never shown).
    private func operation(_ name: String) -> () -> Void {
        let background = PerplBackgroundTime(name)
        operationsRunning += 1
        return { [weak self] in
            background.end()
            self?.operationsRunning -= 1
        }
    }

    /// For a tap on a passkey account: opens the session when it is locked (one pinned ceremony), and fetches the
    /// utility output if the provider evaluated one salt only. Automatic reconnects never come here.
    private func unlockPasskeyKey() async throws {
        guard let mera, storedToken != nil else { throw PerplTradeError.notSignedIn }
        try await mera.unlock()
        if sessionKey() == nil { try await mera.loadUtility() }
        syncSessionKey()
        guard key != nil else { throw PerplTradeError.notSignedIn }
    }

    /// MERA-PLAN §3 for a passkey account's order: it goes out only inside a live session and within its caps (the
    /// order's worst-case notional, at most $100 per order and $250 per session), and a reduce-only close always needs
    /// a step-up. Otherwise `MeraSession.StepUpRequired`: the sheet answers it with one pinned ceremony and retries with
    /// the approval, which covers that one order. Other accounts are unaffected.
    private func authorize(_ input: OrderInput, approval: MeraSession.StepUp?) throws -> MeraSession.Charge? {
        guard boundToPasskey else { return nil }
        guard let mera else { throw PerplTradeError.notSignedIn }
        if input.reduceOnly {
            try mera.requireStepUp(approval, for: .reduceOnlyClose)
            return nil
        }
        return try mera.authorize(usd: Mera.SpendingCaps.notionalUSD(of: input), approval: approval)
    }

    /// Starts the always-on reconnect loop (idempotent). While a key is enrolled and Perpl hasn't rejected it, this
    /// brings the socket back within seconds of any drop, so `isReady` stays true across the whole app without the
    /// user reconnecting. It never opens a second socket — `ensureConnected` is single-flight and backs off on failure.
    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        keepAlive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Only act when the socket is actually down. A live socket (signed in — whether `.connected` or
                // `.needsForwarding`) is left alone; the client's own ping keeps it from idling out.
                if let self, self.key != nil, !self.keyRejected, self.sessionAllowsTrading, self.client?.signedIn != true {
                    await self.ensureConnected()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopKeepAlive() {
        keepAlive?.cancel()
        keepAlive = nil
    }

    /// Full one-time enrollment: generate a key, sign the server's typed data with the wallet, store, and connect.
    /// Any wallet that can sign a digest (Privy embedded or an imported local wallet) can enroll. The typed data is
    /// validated before the wallet sees anything (`PerplEnrollment`): it must register exactly this key for exactly
    /// this wallet on the terms the app asked for, and the digest signed is recomputed on device.
    ///
    /// A passkey (Mera) account enrols inside its session instead: the trading key is derived from the passkey
    /// (utility namespace, purpose-scoped, with a fresh nonce per enrolment because Perpl never registers a key twice —
    /// never stored, never backed up), and the session validates the typed data and signs its digest itself. Only the
    /// token and its nonce are stored, so a new device, or this one after it forgot the token, simply enrols again.
    func enroll(wallet: any Wallet, address: Address) async throws {
        let passkeyWallet = wallet is MeraWallet
        status = .connecting
        do {
            // The payload is bound to `address`; only that wallet may sign it.
            guard wallet.address == address else { throw PerplEnrollmentError.foreignSigner }
            if let passkey = wallet as? MeraWallet {
                guard boundToPasskey, boundAddress == address.checksummed else { throw PerplTradeError.notSignedIn }
                // A fresh key for every enrolment (Perpl never registers one twice), so a new device — or this one after
                // it forgot its token — enrols again with one passkey prompt at most, none inside a live session.
                let enrolled = try await passkey.session.enrollPerpl(label: "DyorHQ") // not localized: the key's label at Perpl
                let token = PerplToken(enrolled.key, keyNonce: enrolled.keyNonce)
                // Stored under the address it was enrolled for, whoever is signed in now (the Keychain is per address).
                PerplKeychain.saveToken(token, address: address.checksummed)
                try requireBound(to: address, passkey: true)
                storedToken = token
                // From the live session, not the enrolment's copy: nothing outlives a session that ended meanwhile.
                key = sessionKey()
                guard key != nil else { throw Mera.SessionError.sessionEnded }
            } else if let signer = wallet as? DigestSigner {
                let secret = PerplAuth.newSecret()
                let publicKeyHex = try PerplAuth.publicKeyHex(secret: secret)
                let auth = PerplAuthClient(chainId: Monad.chainId)
                let payload = try await auth.requestPayload(address: address.checksummed, publicKeyHex: publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ") // not localized: the key's label
                let walletSignature = try await signer.signDigest(payload.digest)
                let enrolled = try await auth.enroll(address: address.checksummed, secret: secret, payload: payload, walletSignature: walletSignature, scopeMask: PerplScope.trade)
                PerplKeychain.save(enrolled, address: address.checksummed)
                // The user may have signed out or switched wallets while the wallet signed: this key belongs to
                // `address`, and must never become the key of whichever account is bound now.
                try requireBound(to: address, passkey: false)
                key = enrolled
            } else {
                throw PerplTradeError.notSignedIn
            }
            keyRejected = false
            resetRetry()
            startKeepAlive()
            try await connect()
        } catch {
            // A failure that belongs to another account (the wallet changed mid-enrolment) doesn't overwrite this one's.
            if isBound(to: address, passkey: passkeyWallet) { status = .failed(describe(error)) }
            throw error
        }
    }

    /// The trading session is still bound to `address` (and the same kind of account) — checked after every await
    /// that a sign-out or wallet switch could have outlived.
    private func isBound(to address: Address, passkey: Bool) -> Bool {
        boundAddress == address.checksummed && boundToPasskey == passkey
    }

    private func requireBound(to address: Address, passkey: Bool) throws {
        guard isBound(to: address, passkey: passkey) else {
            throw PerplTradeError.unavailable(tr("You switched accounts while this was in progress. Nothing was applied to the account you're signed in to now."))
        }
    }

    /// Sign in to the trading WebSocket with the stored key, for a tap (Reconnect, Try Again, after enrolling or
    /// enabling forwarding). A passkey account whose session is locked asks for the passkey first; automatic
    /// reconnects go through `ensureConnected`, which never asks.
    func connect() async throws {
        if boundToPasskey { try await unlockPasskeyKey() }
        try await openSocket()
    }

    /// Opens the one trading socket. Single-flight: a call made while a connect is already in progress awaits that one
    /// instead of opening a second socket.
    private func openSocket() async throws {
        if let connectTask { try await connectTask.value; return }
        let task = Task<Void, Error> { [self] in
            defer { self.connectTask = nil }
            try await self.performConnect()
        }
        connectTask = task
        try await task.value
    }

    private func performConnect() async throws {
        guard let key else { throw PerplTradeError.notSignedIn }
        // One socket per app: close whatever was open before opening another.
        if let previous = client { flushCensus(previous) }
        client?.disconnect()
        client = nil
        status = .connecting
        startCensusLog()
        let client = PerplTradeClient(key: key, chainId: Monad.chainId)
        wire(client)
        self.client = client
        do {
            try await client.connect()
            // Disconnected while signing in (a wallet change, or a passkey session that ended): the catch below closes
            // this socket too, rather than leaving it signed in with nobody holding it.
            guard self.client === client else { throw PerplTradeError.notSignedIn }
            keyRejected = false
            resetRetry()
            // A new socket: a refusal of the trading route recorded before it no longer stands (`apiRefusedSinceSignIn`).
            lastSignedInAt = Date()
            syncStatus()
        } catch {
            client.disconnect()
            // Report only if this attempt is still current — a deliberate disconnect() or a newer connect has already
            // moved status on, and a stale failure must not overwrite it.
            guard self.client === client else { throw error }
            self.client = nil
            noteFailure(client.lastClose)
            status = .failed(describe(error))
            throw error
        }
    }

    /// Hands the client's reports to this session: status, the device's request-id high-water mark, the open orders, the
    /// snapshots' clean-up and reconcile, order outcomes, reloads, TP/SL events and the drop. Every callback checks what it
    /// must of the client it came from, so a superseded or draining socket never touches the live one's state.
    private func wire(_ client: PerplTradeClient) {
        // Both callbacks check the client is still the current one, so a superseded socket can't touch status.
        client.onAccountUpdate = { [weak self, weak client] in
            guard let self, let client else { return }
            // Runs inside the WalletSnapshot's handling, before the connect resolves, so before any order can use the
            // socket: its ids start above every id this device ever wrote for the account.
            if let id = client.accountId {
                client.seedRequestIds(atLeast: self.requestIds.highWater(chainId: Monad.chainId, accountId: id))
            }
            guard self.client === client else { return }
            self.syncStatus()
        }
        // Every id written is remembered, by a draining socket too (its ids were sent all the same).
        client.onRequestIdIssued = { [requestIds, weak client] rq in
            guard let id = client?.accountId else { return }
            requestIds.record(rq, chainId: Monad.chainId, accountId: id)
        }
        client.onOrdersUpdate = { [weak self, weak client] in
            guard let self, let client else { return }
            // Any socket's list can confirm the cancels IT sent, a draining one's included.
            self.settleCancelsPending()
            guard self.client === client else { return }
            self.openOrders = client.openOrders
        }
        client.onSnapshotsComplete = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.sweepLeftovers()
            // The snapshots carry the request ids of orders still open: orders no task follows are read again, and the
            // TP/SL of entries that executed nothing that no list could place yet are looked for once more.
            Task { await self.reconcileLoadedOrders() }
            self.recheckLeftTriggers()
        }
        // An order's late result can arrive on any socket that has it, a draining one's included (GL-1).
        client.onOrderEvents = { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.reevaluate(using: client)
        }
        client.onFills = { [weak self, weak client] fills in
            guard let self, let client else { return }
            self.reevaluate(using: client)
            // The live socket's own fills: the portfolio's history has new rows.
            if self.client === client, fills.contains(where: { $0.accountId == nil || $0.accountId == client.accountId }) { self.historyActivity() }
        }
        client.onPositionEvents = { [weak self, weak client] events in
            guard let self, let client else { return }
            self.reevaluate(using: client)
            if self.client === client, events.contains(where: { $0.accountId == nil || $0.accountId == client.accountId }) { self.historyActivity() }
        }
        client.onAccountActivity = { [weak self, weak client] in
            guard let self else { return }
            self.accountActivity &+= 1
            // A report on the account from the live socket (an order, a fill, a position, the balance): the Perps screens
            // read the chain again soon, not at their next poll.
            if let client, self.client === client { self.streamActivity() }
        }
        client.onTriggerEvent = { [weak self, weak client] event in
            guard let self, let client, self.client === client else { return }
            self.triggerChanged(event)
        }
        client.onPositionEnded = { [weak self, weak client] position in
            guard let self, let client, self.client === client else { return }
            self.positionEnded(position)
        }
        client.onDisconnect = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.socketDropped(client.lastClose)
        }
    }

    /// Derives `status` from the live client's signed-in + forwarding state. Idempotent; safe to call repeatedly.
    ///
    /// Once the client is signed in, ALWAYS advance — including out of `.connecting`, which is the whole point of the
    /// call at the end of a successful connect (the socket signed in, so `.connecting` must resolve to `.connected` /
    /// `.needsForwarding`). Only when NOT yet signed in is `.connecting` held, so a spurious callback during the
    /// handshake can't prematurely downgrade a connect that is still in flight.
    private func syncStatus() {
        guard let client else { return }
        if client.signedIn {
            // What this socket itself reports (never the on-chain grant, which can run ahead of the `fw` echo): a locked
            // passkey account's Close / Add Margin may go over the trading connection after its step-up only when it was on.
            // Never the scripted demo's (DEBUG): its account is no one's.
            if let id = client.accountId, !demoSession { PerplForwardingMemory.record(client.forwardingEnabled, chainId: Monad.chainId, accountId: id) }
            // Forwarding is on if the WS says so OR we confirmed the on-chain grant this session (the WS can lag it).
            status = (client.forwardingEnabled || forwardingGrantedOnChain) ? .connected : .needsForwarding
        } else if status != .connecting {
            status = isEnrolled ? .enrolled : .notEnrolled
        }
    }

    /// The live socket closed on its own. A rejected key or the connection cap surfaces as a failure the user can
    /// read; any other drop (idle timeout, server restart, network) just leaves the session `enrolled` so the next
    /// authenticated action reconnects after backoff — that is what keeps an active trading socket self-healing.
    private func socketDropped(_ close: PerplClose?) {
        guard status != .connecting else { return } // the in-flight connect reports its own outcome
        noteFailure(close)
        if let close, close.isAuthFailure || close.isConnectionCap {
            status = .failed(close.message)
        } else {
            status = isEnrolled ? .enrolled : .notEnrolled
        }
    }

    private func noteFailure(_ close: PerplClose?) {
        if close?.isAuthFailure == true { keyRejected = true }
        consecutiveFailures += 1
        // 5s, 10s, 20s, 40s, 80s (capped at 2 min); the connection cap starts at 30s since slots free up slowly.
        let base: TimeInterval = close?.isConnectionCap == true ? 30 : 5
        retryAfter = Date().addingTimeInterval(min(120, base * pow(2, Double(min(consecutiveFailures - 1, 4)))))
    }

    private func resetRetry() {
        consecutiveFailures = 0
        retryAfter = .distantPast
    }

    func disconnect() {
        flushCensus(client, draining)
        client?.disconnect()
        client = nil
        draining?.disconnect()
        draining = nil
        openOrders = []
        if key != nil { status = .enrolled }
    }

    /// Turn on one-click trading (order forwarding) with a single on-chain call. Perpl pushes the new `fw` flag as an
    /// AccountUpdate on the live socket, so wait for that first and only reconnect (for a fresh snapshot) if it
    /// doesn't arrive — every reconnect spends one of the wallet's 4 connection slots.
    func enableForwarding(env: AppEnvironment, wallet: Wallet) async throws {
        let passkey = boundToPasskey
        let data = try ABI.encodeCall("allowOrderForwarding(bool)", [.bool(true)])
        let hash = try await env.sender.run([.call(TransactionRequest(to: Perpl.exchange, data: data), label: tr("Enable one-click trading"))], from: wallet) { _ in }
        Activity.record(ActivityRecord(kind: .perp, title: tr("One-click trading enabled"), subtitle: tr("Order forwarding authorized on Perpl"), hash: hash, section: "perps"), owner: wallet.address)
        // The grant is for `wallet`'s Perpl account. If the user switched accounts while it confirmed, the account bound
        // now must not be marked as forwarding (its orders would be sent and refused), nor reconnected on its behalf.
        try requireBound(to: wallet.address, passkey: passkey)
        // The tx confirmed, so forwarding is now enabled on-chain — the authority. Reflect it immediately instead of
        // waiting on Perpl's WS `fw` echo, which can lag the keeper by seconds and left the user stuck on
        // "Enable one-click" even after the grant landed.
        forwardingGrantedOnChain = true
        if client?.signedIn == true {
            syncStatus() // → .connected right away via the flag; no needless reconnect that spends a connection slot
        } else {
            resetRetry()
            try await connect()
        }
        // Best-effort: let the WS echo the new `fw` so the flag becomes redundant. Status is already connected.
        for _ in 0..<8 where client?.forwardingEnabled != true && isBound(to: wallet.address, passkey: passkey) {
            try? await Task.sleep(for: .seconds(1))
        }
        syncStatus()
    }

    /// The connected, forwarding-enabled client — or the most specific error for why there isn't one.
    private func liveClient() throws -> PerplTradeClient {
        guard let client, status == .connected else {
            if let failureMessage { throw PerplTradeError.unavailable(failureMessage) } // nothing was sent
            if status == .needsForwarding { throw PerplTradeError.forwardingDisabled }
            throw PerplTradeError.notSignedIn
        }
        return client
    }

    /// Places the entry order (market/limit) with optional take-profit / stop-loss triggers linked to it. Returns
    /// the entry's gateway acknowledgement.
    /// A passkey account's order must fit its live session (`authorize`) or carry a step-up `approval`.
    func submit(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int = 100,
                approval: MeraSession.StepUp? = nil) async throws -> PerplOrderAck {
        try Self.checkTriggers(input: input, takeProfit: takeProfit, stopLoss: stopLoss)
        let charge = try authorize(input, approval: approval)
        await ensureConnected()
        let client: PerplTradeClient
        do { client = try liveClient() } catch { mera?.refund(charge); throw error }
        // `lb: 0` (Perpl's own window): the head the frames once carried is no longer read, so nothing is awaited here.
        if !input.reduceOnly { recentEntries[PerplMarketSide(marketId: input.market.id, isLong: input.side == .long)] = Date() }
        var frames = [PerplOrders.entry(input, accountId: accountId, head: 0, ttlBlocks: ttlBlocks)]
        if let takeProfit {
            frames.append(PerplOrders.takeProfit(side: input.side, price: takeProfit, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil))
        }
        if let stopLoss {
            frames.append(PerplOrders.stopLoss(side: input.side, price: stopLoss, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil))
        }
        // The entry's id is reserved here, with no `await` before its write (`place` below): the triggers link to it with
        // `tr` and get their own ids as they are written, so ids rise in write order. `tr`, never a later re-link to the
        // position (`lp`): see the reasons at the same step in `submitBracket`.
        let entryRq = client.reserveRequestId()
        frames[0].requestId = entryRq
        for index in frames.indices.dropFirst() { frames[index].linkedRequestId = entryRq }
        let ack: PerplOrderAck
        do { ack = try await client.place(frames) } catch let error as PerplTradeError where !error.outcomeUnknown { mera?.refund(charge); throw error }
        if !ack.accepted, !ack.outcomeUnknown { mera?.refund(charge) }
        return ack
    }

    /// Cancels open orders or keeper triggers (TP/SL) from the live list, as ONE action: a passkey account's single
    /// step-up `approval` covers all of them (MERA-PLAN §3 — a cancel always asks). Each cancel is sent whatever the
    /// others did, and each order's ack is returned by its market and id. An accepted ack means Perpl admitted the
    /// cancel; the order leaves `openOrders` when the stream confirms it (mt:24).
    func cancel(orders: [PerplOpenOrder], approval: MeraSession.StepUp? = nil) async throws -> [PerplOpenOrder.Key: PerplOrderAck] {
        guard !orders.isEmpty else { return [:] }
        try requireCancelApproval(approval)
        let done = operation("Perpl cancel")
        defer { done() }
        await ensureConnected()
        let client = try liveClient()
        return try await sendCancels(orders, on: client).acks
    }

    /// Cancels open orders or keeper triggers (TP/SL) from the live list as ONE action — a passkey account's one step-up
    /// `approval` covers them all (MERA-PLAN §3: a cancel always asks) — and follows each until Perpl's live list confirms
    /// it, on the socket that sent it, for up to `PerplTimeouts.removal`: the order left the list (cancelled, or triggered
    /// or expired first, or already gone), or Perpl refused the cancel and still lists it, or neither in time (not
    /// confirmed: it may still be live). An admitted cancel is never called done before the list shows it.
    ///
    /// One operation holds background time across the sends and the wait (GL-1), so a sheet closed meanwhile loses
    /// nothing: this device's TP/SL records of what left the list go, and the Activity row counts the CONFIRMED cancels
    /// only, here. `onAcks` runs once every cancel is out, with the results the acks already decide (a refused ack).
    /// `check`: the caller's last word on the socket that will send them, after the step-up and before anything is sent
    /// (it throws to refuse, or returns false: nothing is sent and no result is returned). It reads that socket's own list,
    /// so a socket that just signed in is given `PerplTimeouts.ordersSnapshot` to send it first.
    func cancelAndConfirm(orders: [PerplOpenOrder], approval: MeraSession.StepUp? = nil,
                          onAcks: @MainActor ([PerplOpenOrder.Key: CancelResult]) -> Void = { _ in },
                          check: (@MainActor (PerplTradeClient) throws -> Bool)? = nil) async throws -> [PerplOpenOrder.Key: CancelResult] {
        guard !orders.isEmpty else { return [:] }
        try requireCancelApproval(approval)
        let done = operation("Perpl cancel")
        defer { done() }
        await ensureConnected()
        let client = try liveClient()
        if let check {
            let deadline = Date().addingTimeInterval(PerplTimeouts.ordersSnapshot)
            while client.signedIn, !client.hasOrdersSnapshot, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if try !check(client) { return [:] }
        }
        let owner = boundOwner
        let (acks, noted) = try await sendCancels(orders, on: client)
        var results: [PerplOpenOrder.Key: CancelResult] = [:]
        // The cancels Perpl admitted, or that went out and were never answered (they may have gone through), by order.
        var awaiting: [PerplOpenOrder.Key: Int] = [:]
        let sentAt = Date()
        for order in orders where results[order.id] == nil && awaiting[order.id] == nil {
            guard let ack = acks[order.id] else { continue }
            if let rq = ack.requestId { noteCancelRequest(order.id, client: client, rq: rq, at: sentAt) }
            if ack.accepted || ack.outcomeUnknown {
                if let rq = ack.requestId { awaiting[order.id] = rq } else { results[order.id] = .notConfirmed }
            } else {
                // Refused before Perpl forwarded it: the order is as it was.
                results[order.id] = client.openOrders.contains { $0.id == order.id }
                    ? .refused(Self.sentence(ack.error) ?? tr("Perpl refused the cancel.")) : .alreadyGone
            }
        }
        onAcks(results)
        let deadline = Date().addingTimeInterval(PerplTimeouts.removal)
        while !awaiting.isEmpty, client.signedIn, client.hasOrdersSnapshot {
            for (key, rq) in awaiting {
                guard let result = client.cancelResult(of: key, cancelRq: rq) else { continue }
                results[key] = result
                awaiting[key] = nil
            }
            guard !awaiting.isEmpty, Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Still listed at the end of the wait, or the socket stopped being live: it may still be live.
        for key in awaiting.keys { results[key] = .notConfirmed }
        settleCancels(orders, results, noted: noted, owner: owner)
        return results
    }

    /// A cancel sent from a sheet, confirmed the moment Perpl's list shows it (the sheet's live flip): non-nil only while
    /// the list is live, on the socket that sent that cancel, once the order has left that list with a status saying how
    /// — never from a list a dropped or new socket emptied (I9).
    func cancelLiveResult(_ key: PerplOpenOrder.Key) -> CancelResult? {
        guard ordersAreLive, let client, let request = cancelRequests[key], request.client === client,
              !client.openOrders.contains(where: { $0.id == key }), client.lastTerminalStatus(of: key) != nil else { return nil }
        return client.cancelResult(of: key, cancelRq: request.rq)
    }

    /// MERA-PLAN §3: a passkey account's cancel always needs a step-up `approval`.
    private func requireCancelApproval(_ approval: MeraSession.StepUp?) throws {
        guard boundToPasskey else { return }
        guard let mera else { throw PerplTradeError.notSignedIn }
        try mera.requireStepUp(approval, for: .cancelOrder)
    }

    /// Sends one cancel per order on `client`, each whatever the others did, and notes them as on their way (`noted`: the
    /// instant). Throws only when nothing was sent: they may then be offered again at once.
    private func sendCancels(_ orders: [PerplOpenOrder], on client: PerplTradeClient) async throws -> (acks: [PerplOpenOrder.Key: PerplOrderAck], noted: Date) {
        guard let accountId = client.accountId else { throw PerplTradeError.notSignedIn }
        cancelsSent.formUnion(orders.map(\.id))
        let noted = notePendingCancels(orders.map(\.id), on: client)
        let acks: [PerplOrderAck]
        do {
            acks = try await client.sendEach(orders.map { PerplOrders.cancel(perpId: $0.marketId, orderId: $0.oid, accountId: accountId, head: 0) })
        } catch {
            // Nothing was sent (`sendEach` throws only then): they may be offered again at once.
            for order in orders where cancelsPending[order.id]?.at == noted { cancelsPending[order.id] = nil }
            throw error
        }
        return (Dictionary(zip(orders.map(\.id), acks), uniquingKeysWith: { first, _ in first }), noted)
    }

    private func noteCancelRequest(_ key: PerplOpenOrder.Key, client: PerplTradeClient, rq: Int, at: Date) {
        cancelRequests[key] = CancelRequest(client: client, rq: rq, sentAt: at)
        if cancelRequests.count > 64 { cancelRequests = cancelRequests.filter { at.timeIntervalSince($0.value.sentAt) < 60 } }
    }

    /// After a cancel's wait: this device's records of the TP/SL that left Perpl's list go, a refused cancel's order may be
    /// offered again at once (no cancel is on its way for it), and the Activity row says how many Perpl's list confirmed
    /// cancelled — one row per market, none when none was.
    private func settleCancels(_ orders: [PerplOpenOrder], _ results: [PerplOpenOrder.Key: CancelResult], noted: Date, owner: Address?) {
        var cancelled: [Int: Int] = [:]
        for order in orders {
            guard let result = results[order.id] else { continue }
            if result.isGone, order.isTrigger {
                TriggerStore.remove(perpId: order.marketId, kind: order.isStopLoss ? .stopLoss : .takeProfit, positionLong: order.protectsLong, owner: owner)
            }
            if case .refused = result, cancelsPending[order.id]?.at == noted { cancelsPending[order.id] = nil }
            // A resting order's cancel has its own row (`cancelResting`): this one counts TP/SL only.
            if result == .cancelled, order.isTrigger { cancelled[order.marketId, default: 0] += 1 }
        }
        guard let owner else { return }
        for (marketId, count) in cancelled.sorted(by: { $0.key < $1.key }) {
            Activity.record(ActivityRecord(kind: .perp, title: count == 1 ? tr("Cancelled TP/SL") : tr("Cancelled \(count) TP/SL"), subtitle: marketName(marketId),
                                           hash: nil, section: "perps"), owner: owner)
        }
    }

    /// Perpl's own words as a whole sentence, a full stop added when they end without one: another sentence follows.
    private static func sentence(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), let last = text.last else { return nil }
        return ".!?。…".contains(last) ? text : text + "." // not localized: punctuation
    }

    /// One kind of trigger to set on an open position: the price for a new one (nil to only remove), and the live
    /// triggers of that kind it replaces.
    struct TriggerChange: Sendable {
        let kind: PerplTriggerKind
        let price: Double?
        let replacing: [PerplOpenOrder]
    }

    /// What happened to one `TriggerChange`, step by step, so the sheet can say exactly where the position stands.
    enum TriggerChangeOutcome: Equatable, Sendable {
        /// The new trigger was admitted (any it replaces were cancelled first) — and, when the owner's switch was on at the
        /// tap, Perpl's list shows it armed.
        case placed
        /// The old triggers were cancelled and nothing new was asked for.
        case removed
        /// Nothing changed: a cancel was refused or never sent (the old trigger stays live and nothing new was placed),
        /// or a new trigger that replaced nothing was refused.
        case unchanged(String)
        /// Some of the triggers it replaces were cancelled and another was refused (it stays live): nothing new placed.
        case partlyRemoved(String)
        /// A cancel went unanswered: nothing new was placed; the old trigger may or may not still be live.
        case cancelUnknown
        /// Perpl admitted every cancel, but its live list didn't confirm the old trigger gone (still listed when the
        /// wait ran out, or the stream dropped): nothing new was placed; the old one may still be live.
        case cancelNotConfirmed
        /// The old trigger(s) were cancelled but the new one was refused: the position has none of this kind now.
        case unprotected(String)
        /// The new trigger went unanswered (the old ones, if any, were cancelled): it may or may not be live.
        case placementUnknown
        /// Perpl admitted the new trigger but its list didn't show it armed in time (the switch on): it may be live.
        case placementNotConfirmed
        /// Perpl admitted the new trigger and it triggered as soon as it was armed: Perpl is closing the position at it.
        case placedTriggeredAtOnce
    }

    /// Where `changeTriggers` is for one kind, for the sheet's progress line.
    enum TriggerChangeStep: Equatable, Sendable {
        case cancelling, placing
    }

    /// Sets, moves or removes the take-profit / stop-loss of an open position (security audit GT-1). Each new trigger
    /// is linked to the position (`lp`), so Perpl cancels it when the position closes (documented for a close or an
    /// inversion only; any other ending is left to the chain-checked clean-up, which matches by market and side, not by
    /// link — and the ticket's own TP/SL stay `tr`-linked, see `submitBracket`), and closes the position's whole
    /// size as the stream reports it now — a fixed size, which the sheet says (GT-5). Moving a trigger is
    /// cancel-then-place: the new one is sent only once every trigger it replaces was admitted for cancellation AND
    /// has left Perpl's live list (an admitted cancel can still fail on-chain), so a refused, unanswered or unconfirmed
    /// cancel never leaves two stops behind; if the placement then fails, the outcome says the position is
    /// unprotected. Stop-loss first. One action: a passkey account's one step-up `approval` covers it.
    ///
    /// The steps are batched so the whole change fits the drain's cap (I11): every replaced trigger is cancelled at once,
    /// a kind that replaces nothing is placed before the one wait for the removals, and — with the owner's switch on at
    /// the tap — every new trigger's own answer from Perpl (armed, triggered at once, refused) is waited for under one
    /// cap. `onStep` says what each kind is doing, for the sheet.
    func changeTriggers(_ changes: [TriggerChange], market: PerpMarket, position: PerplLivePosition, reference: Double, liquidation: Double?,
                        approval: MeraSession.StepUp? = nil,
                        onStep: @MainActor (PerplTriggerKind, TriggerChangeStep) -> Void = { _, _ in }) async throws -> [PerplTriggerKind: TriggerChangeOutcome] {
        let side: PositionSide = position.isLong ? .long : .short
        let size = Double(position.sizeRaw) / pow(10, Double(market.lotDecimals))
        guard position.isOpen, position.marketId == market.id, size > 0 else { throw PerplTradeError.invalidOrder(tr("This position is no longer open.")) }
        for change in changes {
            guard change.replacing.allSatisfy({ $0.marketId == market.id && $0.isTrigger && $0.protectsLong == position.isLong }) else {
                throw PerplTradeError.invalidOrder(tr("That trigger isn't on this position."))
            }
            if let price = change.price, let problem = PerplTriggerRules.problem(change.kind, price: price, side: side, reference: reference, liquidation: liquidation, priceDecimals: market.priceDecimals) {
                throw PerplTradeError.invalidOrder(problem.message(market: market, referenceName: Self.markPriceName))
            }
        }
        if boundToPasskey {
            guard let mera else { throw PerplTradeError.notSignedIn }
            let cancels = changes.contains { !$0.replacing.isEmpty }
            try mera.requireStepUp(approval, for: cancels ? .cancelOrder : .reduceOnlyClose)
        }
        // The owner's switch, read at the tap: on, a new trigger is "set" only once Perpl's list shows it armed.
        let live = liveOutcomes
        // Cancel-then-place: leaving the app between the two must not freeze or close the socket with the old stop gone
        // and the new one unsent (GL-1).
        let done = operation("Perpl TP/SL") // not localized: the task's name
        defer { done() }
        await ensureConnected()
        let client = try liveClient()
        guard let accountId = client.accountId else { throw PerplTradeError.notSignedIn }

        // Stop-loss first, at every step.
        let ordered = changes.sorted { $0.kind == .stopLoss && $1.kind != .stopLoss }
        var outcomes: [PerplTriggerKind: TriggerChangeOutcome] = [:]
        // 1. Every trigger the changes replace is cancelled in one go.
        let replaced = ordered.flatMap(\.replacing)
        for change in ordered where !change.replacing.isEmpty { onStep(change.kind, .cancelling) }
        var cancelAcks: [PerplOpenOrder.Key: PerplOrderAck] = [:]
        var notSent: String?
        if !replaced.isEmpty {
            do {
                let acks = try await client.sendEach(replaced.map { PerplOrders.cancel(perpId: market.id, orderId: $0.oid, accountId: accountId, head: 0) })
                cancelAcks = Dictionary(zip(replaced.map(\.id), acks), uniquingKeysWith: { first, _ in first })
                cancelsSent.formUnion(replaced.map(\.id))
            } catch {
                notSent = describe(error) // nothing was sent (`sendEach` throws only then)
            }
        }
        // Per change: a refused cancel leaves it unchanged (or partly removed), an unanswered one unknown; the others wait
        // for their old triggers to leave the list.
        var awaitingRemoval: [TriggerChange] = []
        for change in ordered where !change.replacing.isEmpty {
            if let notSent { outcomes[change.kind] = .unchanged(notSent); continue }
            let acks = change.replacing.compactMap { cancelAcks[$0.id] }
            if let refused = acks.first(where: { !$0.accepted && !$0.outcomeUnknown }) {
                let why = refused.error ?? tr("Perpl refused the cancel.")
                outcomes[change.kind] = acks.contains(where: \.accepted) ? .partlyRemoved(why) : .unchanged(why)
            } else if acks.contains(where: \.outcomeUnknown) || acks.count < change.replacing.count {
                outcomes[change.kind] = .cancelUnknown
            } else {
                awaitingRemoval.append(change)
            }
        }
        // 2. A kind that replaces nothing has nothing to wait for: its new trigger goes out now.
        var admitted: [Int: TriggerChange] = [:]
        for change in ordered where change.replacing.isEmpty {
            if change.price != nil { onStep(change.kind, .placing) }
            let placed = await placeTrigger(change, side: side, size: size, market: market, position: position, accountId: accountId, on: client)
            outcomes[change.kind] = placed.outcome
            if let rq = placed.admitted { admitted[rq] = change }
        }
        // 3. GT-1: one wait for every replaced trigger to leave Perpl's live list. A kind whose old trigger is still listed
        // places nothing (that could leave two); the others place their new trigger now.
        let stillListed = await remaining(of: Set(awaitingRemoval.flatMap { $0.replacing.map(\.id) }), from: client)
        for change in awaitingRemoval {
            guard !change.replacing.contains(where: { stillListed.contains($0.id) }) else { outcomes[change.kind] = .cancelNotConfirmed; continue }
            if change.price != nil { onStep(change.kind, .placing) }
            let placed = await placeTrigger(change, side: side, size: size, market: market, position: position, accountId: accountId, on: client)
            outcomes[change.kind] = placed.outcome
            if let rq = placed.admitted { admitted[rq] = change }
        }
        // 4. The switch on: Perpl's own answer for every new trigger it admitted, under one cap. An admission alone is
        // never "set": a trigger Perpl refuses after admitting it would leave the position without it.
        var answers: [Int: PerplOrderOutcome] = [:]
        let requests = Dictionary(admitted.keys.compactMap { rq in client.sentRequest(rq: rq).map { (rq, $0) } }, uniquingKeysWith: { first, _ in first })
        if live { answers = await client.awaitOutcomes(requests, cap: PerplTimeouts.triggerOutcome) }
        for (rq, change) in admitted where live {
            outcomes[change.kind] = answers[rq].map { Self.placement($0, replacing: !change.replacing.isEmpty) } ?? .placementNotConfirmed
        }
        return outcomes
    }

    /// Places `change`'s new trigger on `client` as its own write (its request id is given as it is written): its outcome
    /// by Perpl's ack, and its request id when Perpl admitted it. A change with no price only removed triggers.
    private func placeTrigger(_ change: TriggerChange, side: PositionSide, size: Double, market: PerpMarket, position: PerplLivePosition,
                              accountId: Int, on client: PerplTradeClient) async -> (outcome: TriggerChangeOutcome, admitted: Int?) {
        guard let price = change.price else { return (.removed, nil) }
        let frame = change.kind == .takeProfit
            ? PerplOrders.takeProfit(side: side, price: price, size: size, market: market, accountId: accountId, linkedPositionId: position.pid)
            : PerplOrders.stopLoss(side: side, price: price, size: size, market: market, accountId: accountId, linkedPositionId: position.pid)
        let ack: PerplOrderAck
        do {
            ack = try await client.sendEach([frame]).first ?? PerplOrderAck(code: -1, error: tr("Not sent."))
        } catch {
            ack = PerplOrderAck(code: -1, error: describe(error)) // never sent: refused on the device or no socket
        }
        if ack.accepted { return (.placed, ack.requestId) }
        if ack.outcomeUnknown { return (.placementUnknown, nil) }
        let why = ack.error ?? tr("Perpl refused it.")
        return (change.replacing.isEmpty ? .unchanged(why) : .unprotected(why), nil)
    }

    /// A new trigger's outcome from Perpl's own answer: armed → placed; triggered at once; refused, cancelled or expired →
    /// not placed (the position is unprotected when it replaced one); no answer in time → not confirmed.
    private static func placement(_ answer: PerplOrderOutcome, replacing: Bool) -> TriggerChangeOutcome {
        switch answer {
        case .armed: return .placed
        case .triggered: return .placedTriggeredAtOnce
        case .failed(let reason), .cancelled(let reason): return replacing ? .unprotected(reason.message) : .unchanged(reason.message)
        case .expired:
            let why = PerplOrderReason(status: 6, reason: 0).message
            return replacing ? .unprotected(why) : .unchanged(why)
        default: return .placementNotConfirmed
        }
    }

    /// The keys still on `client`'s live list when the wait ended: none once all have left it (mt:24), else those not
    /// seen leaving before `timeout`, or before the list stopped being live (a closed socket's list proves nothing). A
    /// gateway ack only admits a cancel; the chain can still refuse it (a trigger that fired meanwhile, a reverted
    /// forward).
    private func remaining(of orders: Set<PerplOpenOrder.Key>, from client: PerplTradeClient,
                           timeout: TimeInterval = PerplTimeouts.removal) async -> Set<PerplOpenOrder.Key> {
        let deadline = Date().addingTimeInterval(timeout)
        var listed = orders
        while client.signedIn, client.hasOrdersSnapshot {
            // Seen gone once, gone: an order leaves the list for good.
            listed.formIntersection(client.openOrders.map(\.id))
            if listed.isEmpty { return [] }
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return listed
    }

    /// The per-frame acceptance of a bracket placement, so an automated caller can refuse to record a level whose
    /// take-profit or stop-loss trigger was rejected (which would leave a position unprotected).
    struct BracketResult {
        var entry: Bool; var takeProfit: Bool?; var stopLoss: Bool?; var error: String?
        /// A requested trigger was sent but never answered (the socket closed or the ack timed out): it may be live, so
        /// it is reported as neither placed nor refused.
        var takeProfitUnknown = false; var stopLossUnknown = false
        /// What the order sheet follows the accepted entry to its outcome with (`track`).
        var tracking: PerplOrderTracking?
    }

    /// A sent entry, for following it to Perpl's outcome on the socket that sent it (`track`).
    struct PerplOrderTracking: @unchecked Sendable {
        let client: PerplTradeClient
        let accountId: Int
        let entry: PerplSentRequest
        let entryRq: Int
        /// Nil: the entry was written and never answered (GL-1): it may be live.
        let entryAck: PerplOrderAck?
        let takeProfit: (rq: Int?, ack: PerplOrderAck)?
        let stopLoss: (rq: Int?, ack: PerplOrderAck)?
        let charge: MeraSession.Charge?
        var acknowledged: Bool { entryAck?.accepted == true }
    }

    /// The entry went out and Perpl never answered it (`PerplTradeError.outcomeUnknown`): it may be live. Its triggers
    /// were not sent. It is followed like any other order (`track`) and never resent.
    struct EntryUnanswered: LocalizedError {
        let underlying: PerplTradeError
        let tracking: PerplOrderTracking
        /// The order as it was written (a close's size is fixed right before the write: `submitClose`).
        let input: OrderInput
        var errorDescription: String? { underlying.errorDescription }
    }

    /// Places a bracket (entry + linked TP/SL) and reports whether the entry AND each requested trigger were
    /// individually accepted — unlike `submit`, which returns only the entry ack. A passkey account's bracket must fit
    /// its live session (`authorize`) or carry a step-up `approval`. `onChainPositions` / `onChainOrders`: the account's
    /// positions and orders as the Exchange last reported them, for `checkOpening`. `beforeWrite`: the caller's last check
    /// on the socket that will write the entry, run right before the write with no `await` after it (it throws to refuse,
    /// as not sent), and the order to write instead when its terms must be fixed there (`submitClose`'s size).
    func submitBracket(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int,
                       approval: MeraSession.StepUp? = nil, onChainPositions: [PerpPosition], onChainOrders: [PerpOrder],
                       beforeWrite: @MainActor (PerplTradeClient) throws -> OrderInput? = { _ in nil }) async throws -> BracketResult {
        try Self.checkTriggers(input: input, takeProfit: takeProfit, stopLoss: stopLoss)
        let charge = try authorize(input, approval: approval)
        // The entry and its stop-loss go out one after the other: leaving the app between them must not freeze or close
        // the socket with the entry live and the stop-loss unsent (GL-1).
        let done = operation("Perpl order")
        defer { done() }
        await ensureConnected()
        let client: PerplTradeClient
        var input = input
        do {
            client = try liveClient()
            try await checkOpening(input, withTriggers: takeProfit != nil || stopLoss != nil, on: client,
                                   onChainPositions: onChainPositions, onChainOrders: onChainOrders)
            if let fixed = try beforeWrite(client) { input = fixed }
        } catch {
            mera?.refund(charge)
            throw error
        }
        // From here to `placeAll` nothing is awaited: the entry's reserved id goes out before any other request can take
        // a higher one. `lb: 0` (Perpl's own window), so no head is read.
        if !input.reduceOnly { recentEntries[PerplMarketSide(marketId: input.market.id, isLong: input.side == .long)] = Date() }
        var frames = [PerplOrders.entry(input, accountId: accountId, head: 0, ttlBlocks: ttlBlocks)]
        var labels = ["entry"]
        if let takeProfit {
            frames.append(PerplOrders.takeProfit(side: input.side, price: takeProfit, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil))
            labels.append("tp")
        }
        if let stopLoss {
            frames.append(PerplOrders.stopLoss(side: input.side, price: stopLoss, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil))
            labels.append("sl")
        }
        // The entry carries its own id (its triggers link to it with `tr`); each trigger gets its id as it is written.
        //
        // Why the ticket's TP/SL stay linked to the entry request (`tr`) and are never re-linked to the position (`lp`)
        // once it fills (phase 4 item B, decided NOT to build; reviewed against api-docs@25ab6e2c, perpl-docs@3800e3fe):
        // - Perpl documents `lp` triggers as cancelled when the position is "closed or inverted" only. PositionStatus also
        //   has Liquidated, Deleveraged and Unwound, and nothing says an `lp` trigger goes away on those endings.
        // - A trigger's link can't be changed in place (`Change`, t:7, amends price, size and expiry only), and no meaning
        //   is documented for one trigger carrying both `tr` and `lp`. A re-link is therefore a second trigger plus a
        //   cancel of the first: cancel-first leaves the position without its stop until the new one is armed (st 8 can
        //   be slow or never come), and place-first leaves two live stops until the removal is confirmed, which GT-1
        //   forbids (a refused, unanswered or unconfirmed cancel must never leave two stops behind). No order meets both.
        // - Place-first also needs two free slots under `max_account_trigger_orders` (16) per bracket, and no doc says
        //   whether a trigger whose cancel is in flight still counts.
        // - Every cancel asks a passkey account for a step-up (MERA-PLAN §3), so an automatic re-link would prompt out of
        //   the blue; and a limit entry has no position until it fills, maybe while the app is closed.
        // So `tr` linking stays, backed by the chain-checked clean-up (`cancelLeftovers`, GT-2), the reconnect sweep
        // (`sweepLeftovers`), the Leftover TP/SL sheet and `checkOpening`'s refusal on leftovers. The position's own TP/SL
        // sheet (`changeTriggers`) links with `lp`, unchanged. Reopen only if Perpl documents `lp` cancellation on
        // liquidation/deleverage/unwind AND an atomic re-link (or `tr` + `lp` on one trigger).
        let entryRq = client.reserveRequestId()
        frames[0].requestId = entryRq
        for index in frames.indices.dropFirst() { frames[index].linkedRequestId = entryRq }
        // What was written for the entry (the client records it at the write; the frame says the same if it can't).
        let entryFrame = frames[0]
        func entrySent() -> PerplSentRequest {
            client.sentRequest(rq: entryRq) ?? PerplSentRequest(accountId: accountId, marketId: entryFrame.marketId, wireType: entryFrame.wireType, lotLNS: entryFrame.lotLNS,
                                                                 kind: .entry(ioc: entryFrame.ioc, sizeRaw: entryFrame.lotLNS), writtenAt: Date())
        }
        let acks: [PerplOrderAck]
        do {
            acks = try await client.placeAll(frames)
        } catch let error as PerplTradeError where !error.outcomeUnknown {
            mera?.refund(charge)
            throw error
        } catch let error as PerplTradeError {
            // Written and never answered: it may be live (no refund, never resent). Followed to whatever Perpl or the
            // chain shows it did.
            throw EntryUnanswered(underlying: error, tracking: PerplOrderTracking(client: client, accountId: accountId, entry: entrySent(), entryRq: entryRq,
                                                                                  entryAck: nil, takeProfit: nil, stopLoss: nil, charge: charge),
                                  input: input)
        }
        func ack(_ label: String) -> PerplOrderAck? {
            guard let i = labels.firstIndex(of: label), i < acks.count else { return nil }
            return acks[i]
        }
        func accepted(_ label: String) -> Bool { ack(label)?.accepted == true }
        if !accepted("entry") { mera?.refund(charge) }
        var result = BracketResult(entry: accepted("entry"),
                                   takeProfit: takeProfit != nil ? accepted("tp") : nil,
                                   stopLoss: stopLoss != nil ? accepted("sl") : nil,
                                   error: acks.first { !$0.accepted && !$0.outcomeUnknown }?.error ?? acks.first { !$0.accepted }?.error,
                                   takeProfitUnknown: ack("tp")?.outcomeUnknown == true,
                                   stopLossUnknown: ack("sl")?.outcomeUnknown == true)
        if let entryAck = ack("entry"), entryAck.accepted {
            result.tracking = PerplOrderTracking(client: client, accountId: accountId, entry: entrySent(), entryRq: entryRq, entryAck: entryAck,
                                                 takeProfit: ack("tp").map { ($0.requestId, $0) }, stopLoss: ack("sl").map { ($0.requestId, $0) },
                                                 charge: charge)
        }
        return result
    }

    /// Refuses, before anything is charged or sent, triggers that can't do what they say (security audit GT-6, GT-7):
    /// none on a reduce-only order — its triggers would close the side the account doesn't hold — and each price at
    /// least one tick and on the market's tick grid. The ticket also checks the side and the liquidation price.
    private static func checkTriggers(input: OrderInput, takeProfit: Double?, stopLoss: Double?) throws {
        guard takeProfit != nil || stopLoss != nil else { return }
        if input.reduceOnly { throw PerplTradeError.invalidOrder(PerplTriggerRules.Problem.reduceOnly.message(market: input.market)) }
        for (kind, price) in [(PerplTriggerKind.takeProfit, takeProfit), (.stopLoss, stopLoss)] {
            guard let price else { continue }
            if let problem = PerplTriggerRules.problem(kind, price: price, side: input.side, reference: 0, liquidation: nil, priceDecimals: input.market.priceDecimals) {
                throw PerplTradeError.invalidOrder(problem.message(market: input.market))
            }
        }
    }

    /// Checks an opening order against Perpl's live lists where it is sent, not only when the ticket was tapped (a
    /// passkey account's stream is down until its session opens, which is after the tap). Refused, before anything is
    /// sent (security audit GT-2, GT-6):
    /// - while TP/SL left from an earlier position on that side of the market are still armed: they would act on the
    ///   position this opens (a leftover stop-loss can close it at once);
    /// - TP/SL on an order that only shrinks the open position on the other side.
    /// It waits briefly for the stream's order and position lists; without them nothing can be checked, so nothing is
    /// sent.
    private func checkOpening(_ input: OrderInput, withTriggers: Bool, on client: PerplTradeClient,
                              onChainPositions: [PerpPosition], onChainOrders: [PerpOrder]) async throws {
        guard !input.reduceOnly else { return }
        let deadline = Date().addingTimeInterval(3)
        while client.signedIn, !(client.hasOrdersSnapshot && client.hasPositionsSnapshot), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard self.client === client, ordersAreLive, positionsAreLive else {
            throw PerplTradeError.unavailable(tr("Perpl hasn't sent your open orders yet, so take-profit and stop-loss left from an earlier position can't be checked. Nothing was sent. Try again in a moment."))
        }
        let side = PerplMarketSide(marketId: input.market.id, isLong: input.side == .long)
        let leftovers = orphanedTriggers(onChainPositions: onChainPositions, onChainOrders: onChainOrders).filter { $0.side == side }
        if !leftovers.isEmpty {
            throw PerplTradeError.invalidOrder(Self.leftoverMessage(count: leftovers.count, asset: input.market.asset, side: input.side))
        }
        guard withTriggers else { return }
        let scale = pow(10, Double(input.market.lotDecimals))
        let held = onChainPositions.filter { $0.perpId == input.market.id }.map { ($0.side, $0.size) }
            + client.positions.filter { $0.marketId == input.market.id && $0.isOpen }.map { ($0.isLong ? PositionSide.long : .short, Double($0.sizeRaw) / scale) }
        if let position = held.first(where: { PerplTriggerRules.onlyReduces(side: input.side, size: input.size, positionSide: $0.0, positionSize: $0.1) }) {
            throw PerplTradeError.invalidOrder(PerplTriggerRules.Problem.reducesPosition(position.0).message(market: input.market))
        }
    }

    /// Why an order can't open on a side of a market where TP/SL from an earlier position are still armed, in the app's
    /// language. The count is a plural.
    static func leftoverMessage(count: Int, asset: String, side: PositionSide) -> String {
        side == .long
            ? tr("\(count) take-profit/stop-loss orders from an earlier \(asset) long are still armed on Perpl and would act on this new position. Cancel them from Orders first.")
            : tr("\(count) take-profit/stop-loss orders from an earlier \(asset) short are still armed on Perpl and would act on this new position. Cancel them from Orders first.")
    }

    /// "the mark price", the price a trigger is checked against, in the app's language: it completes DyorKit's
    /// trigger messages (`PerplTriggerRules.Problem.message`).
    static var markPriceName: String {
        tr(LocalizedStringResource("the mark price", comment: "Completes a sentence about where a take-profit or stop-loss must sit: “… above the mark price”."))
    }

    /// A position by its market and side, "BTC-PERP long", in the app's language.
    static func positionName(market: String, isLong: Bool) -> String {
        isLong
            ? tr(LocalizedStringResource("\(market) long", comment: "A long position on the market that comes first: “BTC-PERP long”."))
            : tr(LocalizedStringResource("\(market) short", comment: "A short position on the market that comes first: “BTC-PERP short”."))
    }

    /// Brings the trading stream up without a prompt (a key account, or a passkey account whose session is open) and
    /// waits up to `timeout` for its order and position lists — for a check an on-chain order needs before it is signed.
    /// Returns at once when the stream can't come up without the user.
    func awaitLiveStream(timeout: TimeInterval) async {
        guard key != nil, !keyRejected, sessionAllowsTrading else { return }
        let deadline = Date().addingTimeInterval(timeout)
        Task { await self.ensureConnected() } // single-flight; keeps going if it outlasts the wait
        while !(ordersAreLive && positionsAreLive), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Ensures a LIVE trading socket before an authed operation. Reconnects when the socket isn't truly alive — even
    /// if `status` is a stale `.connected` — but never hammers Perpl: it joins an in-flight connect, waits out the
    /// backoff after a failure, and gives up on a key Perpl has rejected (the user must re-enroll). It never prompts:
    /// a passkey account reconnects only while its session is live (the keep-alive and RootView's resume come here).
    func ensureConnected() async {
        guard key != nil, !keyRejected, sessionAllowsTrading else { return }
        if status == .connected, client?.signedIn == true { return }
        if let connectTask { _ = try? await connectTask.value; return }
        guard Date() >= retryAfter else { return }
        try? await openSocket()
    }

    // MARK: Close, Cancel Order and Add Margin over the trading connection (p4 spec A)

    /// The account a Close / Add Margin / Cancel Order tap is for, fixed at the tap: what the request is refused for (as not
    /// sent) if the bound wallet or the socket's account changed before the write, and whose Activity / notices it is.
    struct ActionAccount: Equatable {
        let owner: Address?
        let accountId: Int
        let passkey: Bool
    }

    /// The trading socket a transport or permission refusal came from (`noteAPIRefusal`): Close / Add Margin / Cancel
    /// Order go on-chain again until a new socket replaces it.
    struct APIBlock {
        weak var client: PerplTradeClient?
        let at: Date
    }

    /// A socket held weakly, by what it sent.
    struct WeakClient {
        weak var client: PerplTradeClient?
    }

    @ObservationIgnored private(set) var apiBlocked: APIBlock?
    /// When the live socket last signed in (`performConnect`).
    @ObservationIgnored private var lastSignedInAt: Date = .distantPast
    /// The trading route was refused since the last sign-in — on a socket, or with none to send on (a connect that failed
    /// after a step-up): until a new socket signs in, Close and Add Margin don't go to it unless one is live.
    private var apiRefusedSinceSignIn: Bool { apiBlocked.map { $0.at >= lastSignedInAt } ?? false }
    /// The socket each close from the position's Close sheet was sent on: what says whether it ended the position.
    @ObservationIgnored private var closeClients: [UUID: WeakClient] = [:]

    /// Close, Add Margin and Cancel Order can go to Perpl over the live trading connection for `account` now: both owner
    /// switches on, this socket signed in for that account, forwarding on AS THE SOCKET REPORTS IT (what `admit` enforces;
    /// never `forwardingGrantedOnChain`, which can run ahead of the `fw` echo), and no transport or permission refusal on
    /// this socket since (`apiBlocked`).
    func apiActionsLive(for account: ActionAccount) -> Bool {
        liveOutcomes && apiActions && isReady && client?.forwardingEnabled == true
            && client?.accountId == account.accountId && boundOwner == account.owner && boundToPasskey == account.passkey
            && !(apiBlocked?.client === client && client != nil)
    }

    /// A passkey account with no live socket (session locked, or its socket down): Close and Add Margin may still go over the
    /// API, because the step-up they always ask for opens the session (and the socket follows it), when its last socket reported
    /// forwarding on (`PerplForwardingMemory`). Never a cancel: the cancel's target comes from the live list.
    ///
    /// Only while the socket can come back for it: its last connect didn't fail (a rejected key, the connection cap, a failed
    /// connect), no back-off is pending (the connect after the step-up would wait it out and send nothing), and the route
    /// wasn't refused since the last sign-in, on a socket or with none (`apiRefusedSinceSignIn`). Otherwise the Face ID the
    /// step-up costs would be spent on a request that can't go out, and the wallet's path is the one that can.
    func apiActionsAfterUnlock(for account: ActionAccount) -> Bool {
        liveOutcomes && apiActions && boundToPasskey && account.passkey && boundOwner == account.owner
            && storedToken != nil && !keyRejected && !isReady
            && PerplForwardingMemory.lastKnown(chainId: Monad.chainId, accountId: account.accountId) == true
            && failureMessage == nil && Date() >= retryAfter && !apiRefusedSinceSignIn
    }

    /// The trading connection refused to take an action (nothing was sent, the gateway refused it, forwarding is off, or
    /// Perpl answered OrderForwardingNotAllowed): Close / Add Margin / Cancel Order go on-chain while this socket lasts.
    func noteAPIRefusal(on client: PerplTradeClient?) {
        apiBlocked = APIBlock(client: client, at: Date())
    }

    /// The one line under a not-sent failure on Close / Add Margin / Cancel Order sent over the trading connection: the
    /// wallet's when reopening the sheet will send it on-chain for sure — this live socket refused the route, a switch is
    /// off, there is no key, forwarding is known off, or there is no live socket and none will be tried for it (its connect
    /// failed, a back-off is pending, or the route was refused since the last sign-in: `apiActionsAfterUnlock`) — else a
    /// plain "try again" (a dropped socket is back in seconds).
    func nothingSentLine(for account: ActionAccount) -> String {
        let live = client?.signedIn == true
        let blocked = live && apiBlocked?.client === client
        let forwardingOff = live && client?.forwardingEnabled == false
        let rememberedOff = !live && PerplForwardingMemory.lastKnown(chainId: Monad.chainId, accountId: account.accountId) == false
        let down = !live && (failureMessage != nil || Date() < retryAfter || apiRefusedSinceSignIn)
        let onChain = !liveOutcomes || !apiActions || !isEnrolled || blocked || forwardingOff || rememberedOff || down
        return onChain ? PerpActionCopy.nothingSentWallet : PerpActionCopy.nothingSent
    }

    /// The account at the tap is still the one this socket acts for, and the one bound: otherwise refused as not sent.
    private func requireAction(_ account: ActionAccount, on client: PerplTradeClient) throws {
        if let owner = account.owner { try requireBound(to: owner, passkey: account.passkey) }
        guard boundOwner == account.owner, boundToPasskey == account.passkey, client.accountId == account.accountId else {
            throw PerplTradeError.unavailable(tr("You switched accounts while this was in progress. Nothing was applied to the account you're signed in to now."))
        }
    }

    /// A close the position's Close sheet asks for, as it stood at the confirm: the position as the chain reported it, the
    /// size chip (25 / 50 / 75 / 100), and the order's terms.
    struct CloseRequest {
        let market: PerpMarket
        let position: PerpPosition
        let percent: Int
        let kind: OrderKind
        let limitPrice: Double?
        let postOnly: Bool
        /// A market close's slippage (the sheet's "1%").
        static let slippageBps = 100
    }

    /// A reduce-only close of `request.position` over the trading connection (MERA-PLAN §3: a passkey account's always asks
    /// first). The size is fixed here, right before the write (A.1): a fraction of the chain size, or for 100% the live
    /// stream's size when it lists the position (else the chain's). `onWriting(whole)` runs right before the frame is
    /// written. Returns the bracket result and the exact input sent (for `track` and the outcome's wording).
    func submitClose(_ request: CloseRequest, account: ActionAccount, env: AppEnvironment, approval: MeraSession.StepUp?,
                     onWriting: @MainActor (_ whole: Bool) -> Void) async throws -> (BracketResult, OrderInput) {
        let whole = request.percent >= 100
        let chainSize = PerplService.closeFractionSize(positionSize: request.position.size, lotDecimals: request.market.lotDecimals, percent: request.percent) ?? 0
        let input = PerplService.closeInput(market: request.market, position: request.position, size: chainSize, slippageBps: CloseRequest.slippageBps,
                                            kind: request.kind, limitPrice: request.limitPrice, postOnly: request.postOnly)
        // Refused on the device before any step-up: a size or price that rounds to nothing.
        if let problem = PerplOrders.problem(PerplOrders.entry(input, accountId: account.accountId, head: 0)) { throw PerplTradeError.invalidOrder(problem) }
        var sent = input
        var writer: PerplTradeClient?
        do {
            let result = try await submitBracket(input: input, accountId: account.accountId, takeProfit: nil, stopLoss: nil, env: env, ttlBlocks: 100,
                                                  approval: approval, onChainPositions: [], onChainOrders: [], beforeWrite: { client in
                writer = client
                // The account at the tap, on the socket that writes it; then its size, as that socket reports it now.
                try self.requireAction(account, on: client)
                sent = Self.closeInput(request, input: input, on: client)
                onWriting(whole)
                return sent
            })
            // Perpl's gateway refused it: nothing was forwarded, and this socket won't take the route again.
            if !result.entry { noteAPIRefusal(on: writer ?? client) }
            return (result, sent)
        } catch let error as PerplTradeError where !error.outcomeUnknown {
            if !error.isInvalidOrder { noteAPIRefusal(on: writer ?? client) }
            throw error
        }
    }

    /// The close to write on `client`: for 100%, the size of the position its live list shows on that side, when the list
    /// is whole and not suspect (Perpl clamps a close to the position anyway, websocket.md); otherwise as the sheet sized it.
    private static func closeInput(_ request: CloseRequest, input: OrderInput, on client: PerplTradeClient) -> OrderInput {
        guard request.percent >= 100, client.hasPositionsSnapshot, !client.streamSuspect,
              let live = client.positions.first(where: { $0.marketId == request.market.id && $0.isLong == (request.position.side == .long) && $0.isOpen }) else { return input }
        var fresh = input
        fresh.size = Double(live.sizeRaw) / pow(10, Double(request.market.lotDecimals))
        return fresh
    }

    /// Whether a close sent from the Close sheet ended the position, by Perpl's evidence on the socket that sent it: true
    /// when a position report carrying this close's own request id said it closed, or the live list (whole, not suspect)
    /// shows no position on that side any more; false when the list still shows that side open after a report that named
    /// this close; nil when nothing says (the 100% chip decides the words).
    private func positionEnded(of order: PerplTrackedOrder) -> Bool? {
        guard order.isClose, case .api(_, let rq) = order.source, let client = closeClients[order.id]?.client else { return nil }
        if client.positionClosed(byRequest: rq) { return true }
        guard client.signedIn, client.hasPositionsSnapshot, !client.streamSuspect else { return nil }
        let side = order.closes ?? order.side.opposite
        let open = client.positions.contains { $0.marketId == order.marketId && $0.isLong == (side == .long) && $0.isOpen }
        if !open { return true }
        return client.sawPositionChange(rq: rq) ? false : nil
    }

    /// An on-chain resting order, by its market and id AND its terms: the Exchange gives an order id again, and an order
    /// that holds a recycled id with other terms is never the old one.
    struct ChainOrderKey: Hashable {
        let perpId: Int
        let orderId: Int
        let side: OrderSide
        let price: Double
        let size: Double
        init(_ order: PerpOrder) { perpId = order.perpId; orderId = order.orderId; side = order.side; price = order.price; size = order.size }
    }

    /// The on-chain orders Perpl's live list showed gone after a cancel from this device, and how, until a chain read no
    /// longer lists them (or `goneWindow`): their card says so instead of offering a cancel.
    private(set) var goneChainOrders: [ChainOrderKey: (result: CancelResult, at: Date)] = [:]
    static let goneWindow: TimeInterval = 120
    /// How long the stream's word that an order's smart contract order id left its list (no cancel from this device) stands
    /// for a chain order with that id: a chain read trailing the stream, not a later order the Exchange gave the id again.
    static let scidGoneWindow: TimeInterval = 30

    /// How an on-chain order Perpl's live list showed gone ended, and whose word it is: the order card's wording, and
    /// whether its tap may still open the wallet's cancel.
    struct ChainOrderGone: Equatable {
        let result: CancelResult
        /// A cancel from this device decided it (`goneChainOrders`): the "… first" words. Otherwise the stream saw the order
        /// leave on its own (filled, expired, failed, or cancelled elsewhere), and says only that.
        let byCancel: Bool
    }

    /// Cancels `target` over the trading connection after checking, on the socket that will send it, that it is still the
    /// order the user saw (same scid, type and request: A.1); otherwise `.alreadyGone`, nothing sent. Then as
    /// `cancelAndConfirm`. Only that socket's whole list, not suspect, can say so: without one, nothing is sent
    /// (`OrdersNotChecked`, not a refusal of the route).
    func cancelResting(_ target: PerplOpenOrder, tapRq: Int?, chainOrder: ChainOrderKey, account: ActionAccount, title: String,
                       subtitle: String, approval: MeraSession.StepUp?,
                       onAcks: @MainActor ([PerplOpenOrder.Key: CancelResult]) -> Void) async throws -> CancelResult {
        // 1 (`cancelAndConfirm`'s first step): MERA-PLAN §3, a passkey account's cancel always asks. 2–3, on the socket that
        // will send it: the account at the tap, and still the order the user saw — the same smart contract order id, type
        // and request (not the price: a Change made elsewhere amends the same order). Otherwise nothing is sent.
        var sender: PerplTradeClient?
        var listedGone = false
        let stillTheOrder: @MainActor (PerplTradeClient) throws -> Bool = { client in
            try self.requireAction(account, on: client)
            // A list without its snapshot, or one that may have missed an update, can't say the order is gone.
            guard client.signedIn, client.hasOrdersSnapshot, !client.streamSuspect else { throw OrdersNotChecked() }
            sender = client
            guard let listed = client.openOrders.first(where: { $0.id == target.id }), listed.contractOrderId == target.contractOrderId,
                  listed.typeRaw == target.typeRaw, client.requestId(for: target.id) == tapRq else { listedGone = true; return false }
            return true
        }
        var refusedAtGateway = false
        let results: [PerplOpenOrder.Key: CancelResult]
        do {
            // 4. One cancel, followed on the socket that sent it until its list confirms it (`PerplTimeouts.removal`).
            results = try await cancelAndConfirm(orders: [target], approval: approval, onAcks: { acks in
                // A result the ack already decides is the gateway's refusal (code ≠ 0: nothing was forwarded): the route rests
                // on this socket before the sheet words it (`nothingSentLine`).
                if let decided = acks[target.id], decided != .notConfirmed {
                    refusedAtGateway = true
                    self.noteAPIRefusal(on: sender ?? self.client)
                }
                onAcks(acks)
            }, check: stillTheOrder)
        } catch let error as PerplTradeError where !error.outcomeUnknown {
            if !error.isInvalidOrder { noteAPIRefusal(on: client) }
            throw error
        }
        guard let result = results[target.id] else {
            // Not the order the user saw any more, by that socket's whole list: it left Perpl's list (or its id now names
            // another order). Nothing sent.
            guard listedGone else { return .notConfirmed }
            let gone = CancelResult.alreadyGone
            goneChainOrders[chainOrder] = (gone, Date())
            return gone
        }
        // 5. Done here, so a closed sheet loses nothing. Perpl answered OrderForwardingNotAllowed: the route rests on the
        // socket that sent it (the gateway's refusal already did, above).
        if !refusedAtGateway, cancelRefusedForForwarding(target.id) { noteAPIRefusal(on: cancelRequests[target.id]?.client ?? sender ?? client) }
        if result == .cancelled, let owner = account.owner {
            Activity.record(ActivityRecord(kind: .perp, title: title, subtitle: subtitle, hash: nil, section: "perps"), owner: owner)
        }
        if result.isGone { goneChainOrders[chainOrder] = (result, Date()) }
        return result
    }

    /// The order a Cancel Order sheet was about to cancel can't be checked on the socket that would send it: its open orders
    /// haven't arrived, or it may have missed an update. Nothing was sent, and the trading route isn't refused: the list is
    /// back in a moment.
    struct OrdersNotChecked: LocalizedError {
        var errorDescription: String? {
            tr(LocalizedStringResource("Perpl hasn't sent your open orders yet, so this order can't be checked. Nothing was sent. Try again in a moment.",
                                       comment: "Cancel Order sent over one-click trading: the order can't be checked against Perpl's live list yet (it is still arriving), so the cancel wasn't sent."))
        }
    }

    /// Perpl refused the cancel of `key` because order forwarding is off (OrderForwardingNotAllowed, sr 34), on the socket
    /// that sent it: the Cancel Order sheet then says the reopened sheet sends it from the wallet.
    func cancelRefusedForForwarding(_ key: PerplOpenOrder.Key) -> Bool {
        guard let request = cancelRequests[key], let sender = request.client, let sent = sender.sentRequest(rq: request.rq),
              case .failed(let reason)? = sender.outcome(rq: request.rq, sent: sent, final: false) else { return false }
        return reason.reason == 34
    }

    /// The chain order Perpl's live list already showed gone this session: a cancel from this device confirmed (`goneChainOrders`,
    /// by the order's terms, kept until a chain read no longer lists it, or 120 s), or — while the stream is live with its
    /// snapshot and not suspect — its scid left the list with a terminal status in the last `scidGoneWindow`
    /// (`client.lastTerminalStatus(marketId:contractOrderId:)`, A.5.1). Never while the live list lists an order with that
    /// smart contract order id (one the Exchange gave the id again included).
    func chainOrderGone(_ order: PerpOrder) -> ChainOrderGone? {
        if ordersAreLive, let client, client.openOrders.contains(where: { $0.marketId == order.perpId && $0.contractOrderId == order.orderId }) { return nil }
        if let gone = goneChainOrders[ChainOrderKey(order)], Date().timeIntervalSince(gone.at) < Self.goneWindow { return ChainOrderGone(result: gone.result, byCancel: true) }
        guard ordersAreLive, !streamSuspect, let client, let left = client.lastTerminalStatus(marketId: order.perpId, contractOrderId: order.orderId),
              Date().timeIntervalSince(left.at) < Self.scidGoneWindow else { return nil }
        return ChainOrderGone(result: CancelResult.left(withStatus: left.status), byCancel: false)
    }

    /// After each chain read: forgets the gone orders the chain no longer lists.
    func chainOrdersRead(_ orders: [PerpOrder]) {
        guard !goneChainOrders.isEmpty else { return }
        let listed = Set(orders.map(ChainOrderKey.init))
        let now = Date()
        let kept = goneChainOrders.filter { listed.contains($0.key) && now.timeIntervalSince($0.value.at) < Self.goneWindow }
        if kept.count != goneChainOrders.count { goneChainOrders = kept }
    }

    // MARK: Add margin over the trading connection (p4 spec A.4.3)

    enum MarginResult: Equatable {
        /// Perpl's evidence that it went in: the collateral the position gained (or the amount sent, when its success
        /// came without a measure, or the chain showed it).
        case added(amountCNS: BigUInt)
        /// Perpl refused it, in its words. `atGateway`: the gateway refused the frame, so nothing was forwarded (and the
        /// trading route rests on this socket); else a final refusal on the stream.
        case refused(String, atGateway: Bool)
        /// Neither in time: it may still be added.
        case notConfirmed
    }

    /// A margin request whose result wasn't confirmed, or which Perpl refused a moment ago: checked again on its socket's
    /// reports, the Perps screens' chain reads and the reconcile (memory only: a killed app leaves its honest row).
    struct PendingMargin {
        weak var client: PerplTradeClient?
        let rq: Int
        let id: UUID
        /// Its entry in `marginRequests`.
        let token: UUID
        let account: ActionAccount
        let market: PerpMarket
        let symbol: String
        let amountCNS: BigUInt
        let amount: Double
        let before: PerpPosition?
        /// When `before` was read on the chain (nil: unknown, the position the tap showed).
        let beforeAt: Date?
        let writtenAt: Date
        var result: MarginResult
    }

    @ObservationIgnored private var pendingMargins: [UUID: PendingMargin] = [:] {
        didSet {
            // One that leaves the re-check list can't move the collateral any more: its result is in, or it was given up on.
            for (id, entry) in oldValue where pendingMargins[id] == nil { releaseMarginRequest(entry.token) }
        }
    }
    /// Every margin request this device made, from its tap until an hour after its result stopped being able to change,
    /// whatever it was: another one on the same market makes a growth without a request id, or the chain's margin, ambiguous
    /// (`PerplMarginEvidence.otherMargin`), so one deposit is never credited to two requests.
    @ObservationIgnored private var marginRequests: [UUID: PerplMarginEvidence.Request] = [:]
    /// Margin requests (by `token`) the chain can no longer tell apart: the position's side or size changed since their
    /// "before" (a fill moves the collateral too). Their rows stay "not confirmed" unless Perpl's own report says otherwise.
    @ObservationIgnored private var marginChainExcluded: Set<UUID> = []
    /// The margin sheets on screen, by their request's row id: a result they show posts no notice.
    @ObservationIgnored private var marginPresented: Set<UUID> = []
    /// Each margin request's result as it stands (a re-check may change it), by its row id: what its sheet shows.
    private(set) var marginResults: [UUID: MarginResult] = [:]
    static let pendingMarginCapacity = 16
    static let pendingNotConfirmedKept: TimeInterval = 3600, pendingRefusedKept: TimeInterval = 60

    /// The margin sheet showing request `id` is (or is no longer) on screen.
    func setMarginPresented(_ id: UUID, _ presented: Bool) {
        if presented { marginPresented.insert(id) } else { marginPresented.remove(id) }
    }

    /// This market's position for `account` read on the chain now, and when (the margin's "before").
    func readPosition(market: PerpMarket, for account: ActionAccount) async -> (position: PerpPosition?, at: Date)? {
        guard let owner = account.owner ?? demoReadOwner, let read = readPositions, let positions = try? await read(owner, [market]) else { return nil }
        return (positions.first { $0.perpId == market.id }, Date())
    }

    /// More than the account has free on `client`, when both balances are known (saturating: a locked balance above the
    /// balance leaves nothing free, never a trap).
    private static func overAvailable(_ amountCNS: BigUInt, on client: PerplTradeClient) -> Bool {
        guard let balance = client.balanceCNS, let locked = client.lockedBalanceCNS else { return false }
        let available = balance > locked ? balance - locked : 0
        return amountCNS > available
    }

    /// Adds `amount` AUSD to `account`'s open position on `market` over the trading connection (MERA-PLAN §3: a passkey
    /// account's always asks first). One `t:6` request, never resent. Perpl's answer is read on the socket that sent it (its
    /// final report on the request, or the position's collateral under that request), the chain is read at 2, 5 and 10 s, for
    /// `PerplTimeouts.marginEvidence`; what is still open then is re-checked later (`pendingMargins`). Its Activity row and,
    /// when no sheet shows it, its notice are posted here. `onSent(id, acknowledged)`: the frame was written (Perpl took it,
    /// or never answered); `id` is the request's `marginActivityID`, for `setMarginPresented`.
    /// `beforeAt`: when `before` was read on the chain (nil: unknown).
    func addMargin(market: PerpMarket, amount: Double, account: ActionAccount, before: PerpPosition?, approval: MeraSession.StepUp?,
                   beforeAt: Date? = nil, onSent: @MainActor (_ id: UUID, _ acknowledged: Bool) -> Void) async throws -> MarginResult {
        // 1. On the device, before any step-up: an amount that rounds to zero, or more than the account has free.
        let amountCNS = PerplService.toCNS(amount)
        if let problem = PerplOrders.problem(PerplOrders.addMargin(perpId: market.id, amountCNS: amountCNS, accountId: account.accountId)) {
            throw PerplTradeError.invalidOrder(problem)
        }
        if let client, Self.overAvailable(amountCNS, on: client) { throw PerplTradeError.invalidOrder(PerpActionCopy.marginOverAvailable) }
        // 2. Moving margin is outside a passkey session's scope: it always asks, as the wallet transaction does.
        if boundToPasskey {
            guard let mera else { throw PerplTradeError.notSignedIn }
            try mera.requireStepUp(approval, for: .unlisted)
        }
        // 3. One operation from the connect to the last read of the evidence (GL-1).
        let done = operation("Perpl margin") // not localized: the task's name
        defer { done() }
        // From here this request may move the market's collateral, until its result can't change (`marginRequests`). One that
        // provably moved nothing (never written, or refused at the gateway) is forgotten at once.
        let token = UUID()
        marginRequests[token] = PerplMarginEvidence.Request(marketId: market.id, startedAt: Date())
        var movedNothing = true
        defer { if movedNothing { marginRequests[token] = nil } }
        await ensureConnected()
        let client: PerplTradeClient
        do {
            client = try liveClient()
            try requireAction(account, on: client)
            if Self.overAvailable(amountCNS, on: client) { throw PerplTradeError.invalidOrder(PerpActionCopy.marginOverAvailable) }
        } catch let error as PerplTradeError {
            if !error.isInvalidOrder { noteAPIRefusal(on: self.client) }
            throw error
        }
        // 4. The one write. It throws only when nothing was written.
        let acks: [PerplOrderAck]
        do {
            acks = try await client.sendEach([PerplOrders.addMargin(perpId: market.id, amountCNS: amountCNS, accountId: account.accountId)])
        } catch {
            noteAPIRefusal(on: client)
            throw error
        }
        movedNothing = false
        guard let ack = acks.first else { return .notConfirmed }
        // 5. The gateway refused it: no report follows (websocket.md), nothing moved, and the route rests on this socket.
        if !ack.accepted, !ack.outcomeUnknown {
            movedNothing = true
            noteAPIRefusal(on: client)
            return .refused(Self.sentence(ack.error) ?? PerpActionCopy.marginRefused, atGateway: true)
        }
        // 6. Written: Perpl took it, or never answered (it may still add it).
        guard let rq = ack.requestId else { return .notConfirmed }
        let writtenAt = client.sentRequest(rq: rq)?.writtenAt ?? ack.receivedAt
        let id = PerplOrderTracker.marginActivityID(accountId: account.accountId, rq: rq, sentAt: writtenAt)
        onSent(id, ack.accepted)
        var pending = PendingMargin(client: client, rq: rq, id: id, token: token, account: account, market: market, symbol: before?.symbol ?? market.asset,
                                    amountCNS: amountCNS, amount: amount, before: before, beforeAt: before == nil ? nil : beforeAt, writtenAt: writtenAt,
                                    result: .notConfirmed)
        // 7–8. Perpl's evidence on the socket that sent it, and the chain's.
        pending.result = await marginEvidence(pending, on: client)
        settleMargin(pending, first: true)
        return marginResults[id] ?? pending.result
    }

    /// Steps 7 and 8 of `addMargin`: every 250 ms while the sending socket is signed in, its own report on the request or
    /// the position's collateral (under the request, or — on a quiet market — grown by exactly the amount without it); the
    /// chain at 2, 5 and 10 s after the write; the first evidence wins. At the end, a provisional refusal with the socket
    /// signed in throughout is final; anything else undecided is "not confirmed".
    private func marginEvidence(_ pending: PendingMargin, on client: PerplTradeClient) async -> MarginResult {
        let deadline = pending.writtenAt.addingTimeInterval(PerplTimeouts.marginEvidence)
        var polls = [2.0, 5.0, 10.0].map { pending.writtenAt.addingTimeInterval($0) }
        let chain = MarginChainRead()
        while Date() < deadline.addingTimeInterval(5) {
            if client.signedIn, let decided = streamMarginResult(pending, on: client) { return decided }
            if chain.added { return .added(amountCNS: pending.amountCNS) }
            if !chain.reading, let next = polls.first, Date() >= next {
                polls.removeFirst()
                if let owner = pending.account.owner ?? demoReadOwner, let before = pending.before, let read = readPositions {
                    chain.reading = true
                    Task { @MainActor in
                        defer { chain.reading = false }
                        guard let positions = try? await read(owner, [pending.market]) else { return }
                        if self.chainShowsMargin(positions, pending, before: before) { chain.added = true }
                    }
                }
            }
            if Date() >= deadline, polls.isEmpty, !chain.reading { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if chain.added { return .added(amountCNS: pending.amountCNS) }
        switch client.collateralOutcome(rq: pending.rq, final: client.continuityHeld(since: pending.writtenAt)) {
        case .added(let delta)?: return .added(amountCNS: delta ?? pending.amountCNS)
        case .refused(let reason)?:
            if reason.reason == 34 { noteAPIRefusal(on: client) }
            return .refused(reason.message, atGateway: false)
        case nil: return .notConfirmed
        }
    }

    /// One chain read of the margin's position in flight (`marginEvidence`).
    @MainActor private final class MarginChainRead {
        var reading = false
        var added = false
    }

    /// What the sending socket's reports say of a margin request now: its own success or final refusal, the position's
    /// collateral grown under it, or — while no other margin request on that market could have moved it (one being sent,
    /// waited for or re-checked, or decided since this one was written, whichever list it is in) and no order of this
    /// device's there could have — the position's collateral grown by exactly the amount with its size unchanged, without
    /// the request id.
    private func streamMarginResult(_ pending: PendingMargin, on client: PerplTradeClient) -> MarginResult? {
        switch client.collateralOutcome(rq: pending.rq, final: false) {
        case .added(let delta)?: return .added(amountCNS: delta ?? pending.amountCNS)
        case .refused(let reason)?:
            if reason.reason == 34 { noteAPIRefusal(on: client) }
            return .refused(reason.message, atGateway: false)
        case nil: break
        }
        guard let side = pending.before?.side,
              let pid = client.positions.first(where: { $0.marketId == pending.market.id && $0.isLong == (side == .long) && $0.isOpen })?.pid else { return nil }
        let otherMargin = PerplMarginEvidence.otherMargin(than: pending.token, on: pending.market.id, since: pending.writtenAt, among: marginRequests)
        let otherOrder = ordersMoved(on: pending.market.id, since: pending.writtenAt)
        guard !otherMargin, !otherOrder, client.collateralGrowthWithoutRequest(pid: pid, amountCNS: pending.amountCNS, since: pending.writtenAt) else { return nil }
        return .added(amountCNS: pending.amountCNS)
    }

    /// The chain's position shows this margin request went in, and only it could have: the position's side and size as they
    /// were before (else the chain can't tell it any more: `marginChainExcluded`), its collateral grown by the amount to the
    /// cent, no other margin request on that market that could have moved it since its "before" was read, and no order of
    /// this device's on that market since then (A.4.3 step 7.3, R.1.6, R.1.7).
    private func chainShowsMargin(_ positions: [PerpPosition], _ pending: PendingMargin, before: PerpPosition) -> Bool {
        let lotDecimals = pending.market.lotDecimals
        if PerplMarginEvidence.sizeMoved(in: positions, before: before, lotDecimals: lotDecimals) { marginChainExcluded.insert(pending.token) }
        guard !marginChainExcluded.contains(pending.token),
              PerplMarginEvidence.chainShows(positions, before: before, amount: pending.amount, lotDecimals: lotDecimals),
              !PerplMarginEvidence.otherMargin(than: pending.token, on: pending.market.id, since: pending.beforeAt, among: marginRequests),
              !ordersMoved(on: pending.market.id, since: (pending.beforeAt ?? pending.writtenAt).addingTimeInterval(-PerplMarginEvidence.chainLag)) else { return false }
        return true
    }

    /// This device sent an order on `marketId` after `since`, or follows one there now: a fill moves the position's collateral.
    private func ordersMoved(on marketId: Int, since: Date) -> Bool {
        orders.orders.contains { $0.marketId == marketId && $0.sentAt > since } || following.contains { orders.order($0)?.marketId == marketId }
    }

    /// A margin request's result can't change any more: from now, its collateral is part of every later request's "before".
    private func releaseMarginRequest(_ token: UUID) {
        if marginRequests[token] != nil, marginRequests[token]?.settledAt == nil { marginRequests[token]?.settledAt = Date() }
    }

    /// A margin request's result, carried out once each time it changes: its Activity row under the request's id (added:
    /// the amount, with its notification, as the wallet's row; not confirmed: no volume, no notification; not added, after
    /// all: the row rewritten), its notice when no sheet shows it, and the re-check list. `first`: the result of the wait
    /// itself (a refusal then writes no row).
    private func settleMargin(_ pending: PendingMargin, first: Bool) {
        let previous = marginResults[pending.id]
        guard previous != pending.result || first else { return }
        marginResults[pending.id] = pending.result
        if marginResults.count > 64, let stale = marginResults.keys.first(where: { pendingMargins[$0] == nil && !marginPresented.contains($0) && $0 != pending.id }) {
            marginResults[stale] = nil
        }
        let owner = pending.account.owner
        let shown = marginPresented.contains(pending.id)
        switch pending.result {
        case .added(let cns):
            pendingMargins[pending.id] = nil
            releaseMarginRequest(pending.token)
            recordMarginAdded(pending, cns: cns)
        case .notConfirmed:
            keepPending(pending)
            var row = ActivityRecord(kind: .deposit, title: PerpActionCopy.addMarginTitle(pending.symbol),
                                     subtitle: PerpActionCopy.marginNotConfirmedSubtitle(NumberStyle.number(pending.amount)), hash: nil, section: "perps")
            row.id = pending.id
            Activity.record(row, owner: owner, notify: false)
            if !shown { postMarginNotice(PerpActionCopy.marginNotConfirmed, body: PerpActionCopy.marginCheck, pending) }
        case .refused(let why, _):
            if first {
                // A final refusal on the stream: no row; checked again for a minute (a growth under it contradicts it).
                keepPending(pending)
            } else {
                // Refused after it was "not confirmed": its row says so, and the notice.
                pendingMargins[pending.id] = nil
                var row = ActivityRecord(kind: .deposit, title: PerpActionCopy.addMarginTitle(pending.symbol),
                                         subtitle: PerpActionCopy.marginNotAddedSubtitle(NumberStyle.number(pending.amount)), hash: nil, section: "perps")
                row.id = pending.id
                Activity.record(row, owner: owner, notify: false)
            }
            if !shown { postMarginNotice(PerpActionCopy.marginNotAdded, body: why, pending) }
        }
    }

    /// The margin went in: the same row as the wallet's Add Margin (a deposit in Perps, with the amount as its `usd`), under
    /// the request's id, with its own notification.
    private func recordMarginAdded(_ pending: PendingMargin, cns: BigUInt) {
        let added = Amount.units(cns, decimals: 6)
        var row = ActivityRecord(kind: .deposit, title: tr("Added \(pending.symbol) margin"), subtitle: "\(NumberStyle.number(added)) AUSD", hash: nil,
                                 section: "perps", usd: added)
        row.id = pending.id
        Activity.record(row, owner: pending.account.owner)
    }

    private func postMarginNotice(_ title: String, body: String, _ pending: PendingMargin) {
        #if DEBUG && targetEnvironment(simulator)
        // The scripted demo's margin has no account: the notice it would post goes to its "Would notify" list instead.
        if pending.account.owner == nil, isDemo, !marginPresented.contains(pending.id) { debugNotices.append((title, body)) }
        #endif
        guard let owner = pending.account.owner, !marginPresented.contains(pending.id) else { return }
        Notifications.perpMargin(title: title, body: body, perpId: pending.market.id, owner: owner, deliver: owner == boundOwner)
    }

    private func keepPending(_ pending: PendingMargin) {
        pendingMargins[pending.id] = pending
        prunePendingMargins()
    }

    private func prunePendingMargins() {
        let now = Date()
        pendingMargins = pendingMargins.filter { _, entry in
            switch entry.result {
            case .notConfirmed: return now.timeIntervalSince(entry.writtenAt) < Self.pendingNotConfirmedKept
            case .refused: return now.timeIntervalSince(entry.writtenAt) < Self.pendingRefusedKept
            case .added: return false
            }
        }
        if pendingMargins.count > Self.pendingMarginCapacity {
            let keep = Set(pendingMargins.values.sorted { $0.writtenAt > $1.writtenAt }.prefix(Self.pendingMarginCapacity).map(\.id))
            pendingMargins = pendingMargins.filter { keep.contains($0.key) }
        }
        // A request is remembered an hour after its result stopped being able to change (one never decided: an hour and ten
        // minutes after its tap), longer than any request it could make ambiguous is re-checked.
        let kept = marginRequests.filter { _, request in
            request.settledAt.map { now.timeIntervalSince($0) < Self.pendingNotConfirmedKept }
                ?? (now.timeIntervalSince(request.startedAt) < Self.pendingNotConfirmedKept + 600)
        }
        if kept.count != marginRequests.count { marginRequests = kept }
        if !marginChainExcluded.isEmpty { marginChainExcluded.formIntersection(marginRequests.keys) }
    }

    /// A report on `client`: each margin request it sent that is still open, decided again from it. Added (a refused one
    /// included: a growth under it contradicts the refusal, and the evidence wins); not added only from a FINAL refusal of
    /// one that wasn't confirmed.
    private func recheckMargins(on client: PerplTradeClient) {
        guard !pendingMargins.isEmpty else { return }
        prunePendingMargins()
        for var entry in pendingMargins.values where entry.client === client {
            guard let decided = streamMarginResult(entry, on: client) else { continue }
            switch (entry.result, decided) {
            case (_, .added):
                entry.result = decided
                settleMargin(entry, first: false)
            case (.notConfirmed, .refused):
                entry.result = decided
                settleMargin(entry, first: false)
            default:
                continue
            }
        }
    }

    /// The Perps screens read the account's positions on the chain (`at`, for `owner`): a margin that wasn't confirmed and
    /// shows in its position now went in — when only it could have moved it (`chainShowsMargin`). Each credit is decided
    /// before the next is looked at, so two requests are never credited with one deposit.
    func marginPositionsRead(_ positions: [PerpPosition], at: Date, owner: Address?) {
        guard !pendingMargins.isEmpty else { return }
        prunePendingMargins()
        for id in pendingMargins.values.sorted(by: { $0.writtenAt < $1.writtenAt }).map(\.id) {
            guard var entry = pendingMargins[id], entry.result == .notConfirmed, entry.account.owner == owner, owner != nil, at > entry.writtenAt,
                  let before = entry.before, chainShowsMargin(positions, entry, before: before) else { continue }
            entry.result = .added(amountCNS: entry.amountCNS)
            settleMargin(entry, first: false)
        }
    }

    /// The reconcile: one chain read per margin of `owner` that wasn't confirmed.
    private func recheckMarginsOnChain(owner: Address) async {
        prunePendingMargins()
        for entry in pendingMargins.values where entry.result == .notConfirmed && entry.account.owner == owner {
            guard let read = readPositions, let positions = try? await read(owner, [entry.market]) else { continue }
            marginPositionsRead(positions, at: Date(), owner: owner)
        }
    }

    // MARK: Protection events (security audit GT-2, GT-9)

    /// A fired or failed TP/SL, or a position the protocol closed, as the trade screen shows it.
    struct ProtectionNotice: Equatable, Identifiable {
        let id = UUID()
        let marketId: Int
        let title: String
        let body: String
        /// A warning (a failed stop, a liquidation) rather than news of a trigger doing its job.
        let warning: Bool
        let time = Date()
    }

    /// Markets the trade screen loaded, so what the stream reports can be named and scaled.
    func noteMarkets(_ list: [PerpMarket]) {
        for market in list { markets[market.id] = market }
    }

    /// The trading stream already said, in the last few minutes, how this market's position ended or was closing: Perpl
    /// liquidated, deleveraged or unwound it, or a take-profit / stop-loss on it triggered. The app-wide watcher then
    /// stays quiet about the position's ending, so it is one notice, not two. An ending the stream saw but didn't explain
    /// (an order closed it, on this device or another) is the watcher's to report.
    func endingExplained(marketId: Int, within window: TimeInterval = 300) -> Bool {
        explainedEndings[marketId].map { Date().timeIntervalSince($0) < window } ?? false
    }

    func dismissProtectionNotice() { protectionNotice = nil }

    /// The live TP/SL with nothing left to protect (security audit GT-2): no open position on the side they close —
    /// neither on the stream nor in `onChainPositions` — and no entry resting on, or sent in the last minute to, that
    /// side of their market. Empty unless both of the stream's lists are live, so a gap in the data never reads as an
    /// orphan.
    func orphanedTriggers(onChainPositions: [PerpPosition], onChainOrders: [PerpOrder]) -> [PerplOpenOrder] {
        guard ordersAreLive, positionsAreLive else { return [] }
        let onChain = onChainPositions.map { PerplLivePosition(pid: -1, marketId: $0.perpId, isLong: $0.side == .long, sizeRaw: 1, statusRaw: 1) }
        let resting = Set(onChainOrders.filter { !$0.reduceOnly }.map { PerplMarketSide(marketId: $0.perpId, isLong: $0.side == .buy) }).union(recentEntrySides)
        return PerplTriggerCleanup.orphans(orders: openOrders, positions: livePositions + onChain, extraRestingEntries: resting)
    }

    /// The orphaned TP/SL (`orphanedTriggers`) the trade screen may offer to cancel: not those a cancel is already on its
    /// way for (`cancelsPending`), and not those on a side the automatic clean-up is about to cancel (`cleanupScheduled`)
    /// — offering them would send a second cancel. After those windows anything still listed is offered again.
    func orphansToOffer(onChainPositions: [PerpPosition], onChainOrders: [PerpOrder]) -> [PerplOpenOrder] {
        let now = Date()
        return orphanedTriggers(onChainPositions: onChainPositions, onChainOrders: onChainOrders).filter { !isBeingCancelled($0, now: now) }
    }

    /// The rest of the orphaned TP/SL: a cancel is on its way for them, or the automatic clean-up is about to send one.
    func orphansBeingCancelled(onChainPositions: [PerpPosition], onChainOrders: [PerpOrder]) -> [PerplOpenOrder] {
        let now = Date()
        return orphanedTriggers(onChainPositions: onChainPositions, onChainOrders: onChainOrders).filter { isBeingCancelled($0, now: now) }
    }

    /// Orders a cancel is being sent for or awaited on, whatever the screen.
    var cancellingKeys: Set<PerplOpenOrder.Key> {
        let now = Date()
        return Set(cancelsPending.filter { now.timeIntervalSince($0.value.at) < Self.cancelPendingWindow }.keys)
    }

    private func isBeingCancelled(_ order: PerplOpenOrder, now: Date) -> Bool {
        if let pending = cancelsPending[order.id], now.timeIntervalSince(pending.at) < Self.cancelPendingWindow { return true }
        if let scheduled = cleanupScheduled[order.side], now.timeIntervalSince(scheduled) < Self.cleanupWindow { return true }
        return false
    }

    /// Notes cancels `client` is about to send, and lets each go after its window (when it is still here then). Returns
    /// the instant they were noted.
    @discardableResult
    private func notePendingCancels(_ keys: [PerplOpenOrder.Key], on client: PerplTradeClient) -> Date {
        let now = Date()
        for key in keys { cancelsPending[key] = PendingCancel(client: client, at: now) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.cancelPendingWindow))
            guard let self else { return }
            for key in keys where self.cancelsPending[key]?.at == now { self.cancelsPending[key] = nil }
        }
        return now
    }

    /// Lets go of the pending cancels whose order has left the list of the socket that sent them, while that socket is
    /// signed in with its orders snapshot (an emptied list on a closed socket proves nothing).
    private func settleCancelsPending() {
        guard !cancelsPending.isEmpty else { return }
        let settled = cancelsPending.filter { key, pending in
            guard let sender = pending.client, sender.signedIn, sender.hasOrdersSnapshot else { return false }
            return !sender.openOrders.contains { $0.id == key }
        }
        for key in settled.keys { cancelsPending[key] = nil }
    }

    /// The positions poll saw this side of a market close. The stream normally reports it first (mt:27); this covers a
    /// missed update. The same guarded clean-up runs, and a cancel is never sent twice.
    func positionClosedOnChain(marketId: Int, isLong: Bool) {
        cancelLeftovers(of: PerplLivePosition(pid: -1, marketId: marketId, isLong: isLong, sizeRaw: 0, statusRaw: 2))
    }

    /// After each (re)connect, once both snapshots are in: the TP/SL left over from positions that closed while the stream
    /// was down are cancelled through the same guarded clean-up as a closing position (key accounts only; a fresh chain
    /// read must agree; never twice; never on a suspect stream).
    private func sweepLeftovers() {
        guard !boundToPasskey, let client, client.signedIn, client.hasOrdersSnapshot, client.hasPositionsSnapshot, !client.streamSuspect else { return }
        let orphans = PerplTriggerCleanup.orphans(orders: client.openOrders, positions: client.positions, extraRestingEntries: recentEntrySides)
            .filter { !cancelsSent.contains($0.id) }
        for side in Set(orphans.map(\.side)) {
            cancelLeftovers(of: PerplLivePosition(pid: -1, marketId: side.marketId, isLong: side.isLong, sizeRaw: 0, statusRaw: 2))
        }
    }

    private var recentEntrySides: Set<PerplMarketSide> { Set(recentEntries.filter { Date().timeIntervalSince($0.value) < 60 }.keys) }

    private func resetProtection() {
        protectionNotice = nil
        cancelsSent = []
        recentEntries = [:]
        explainedEndings = [:]
    }

    /// The bound wallet, for owner-keyed records.
    private var boundOwner: Address? { boundAddress.flatMap { Address($0) } }

    private func marketName(_ id: Int) -> String {
        let asset = markets[id]?.asset ?? PerplService.markets.first(where: { $0.id == id })?.symbol ?? tr("Market \(String(id))")
        return "\(asset)-PERP"
    }

    /// A take-profit / stop-loss fired, or failed after Perpl admitted it: recorded and notified (in-app and, when
    /// allowed, as a system notification) and shown on the trade screen. A failed stop-loss is the one that matters
    /// most — the position is still open without it.
    private func triggerChanged(_ event: PerplTriggerEvent) {
        let order = event.order
        let stop = order.isStopLoss
        var detail = Self.positionName(market: marketName(order.marketId), isLong: order.protectsLong)
        if let market = markets[order.marketId], let raw = order.triggerPriceRaw {
            detail += " · \(NumberStyle.number(Double(raw) / pow(10, Double(market.priceDecimals)))) · \(NumberStyle.number(Double(order.sizeRaw) / pow(10, Double(market.lotDecimals)))) \(market.asset)"
        }
        let title: String
        let body: String
        let warning: Bool
        switch event.outcome {
        case .triggered:
            title = stop ? tr("Stop-loss triggered") : tr("Take-profit triggered")
            body = tr("\(detail). Perpl is closing that part of the position.")
            warning = false
            explainedEndings[order.marketId] = Date()
        case .failed(let reason):
            // 64/67/68: it fired but couldn't execute; otherwise Perpl refused it after admitting it.
            let fired = [64, 67, 68].contains(reason)
            if fired {
                title = stop ? tr("Stop-loss couldn't execute") : tr("Take-profit couldn't execute")
                body = tr("\(detail). It triggered but Perpl couldn't close the position, so it is still open. Check the position on Perps.")
            } else {
                title = stop ? tr("Stop-loss not placed") : tr("Take-profit not placed")
                body = tr("\(detail). Perpl refused it after accepting the order, so it isn't protecting your position. Check the position on Perps.")
            }
            warning = true
        case .expired:
            title = stop ? tr("Stop-loss expired") : tr("Take-profit expired")
            body = tr("\(detail). It expired without triggering, so it no longer protects your position. Check the position on Perps.")
            warning = true
        }
        publish(ProtectionNotice(marketId: order.marketId, title: title, body: body, warning: warning))
    }

    /// A position ended on the stream. Liquidation, deleveraging or an unwind is reported like a fired trigger; any
    /// ending then cancels the TP/SL left over for that side (below).
    private func positionEnded(_ position: PerplLivePosition) {
        if position.endedByProtocol {
            explainedEndings[position.marketId] = Date()
            let name = Self.positionName(market: marketName(position.marketId), isLong: position.isLong)
            let title: String
            let body: String
            if position.wasLiquidated {
                title = tr("Position liquidated")
                body = tr("Your \(name) was liquidated by Perpl.")
            } else if position.statusRaw == 4 {
                title = tr("Position deleveraged")
                body = tr("Your \(name) was deleveraged by Perpl.")
            } else {
                title = tr("Position unwound")
                body = tr("Your \(name) was unwound by Perpl.")
            }
            publish(ProtectionNotice(marketId: position.marketId, title: title, body: body, warning: true))
        }
        cancelLeftovers(of: position)
    }

    private func publish(_ notice: ProtectionNotice) {
        protectionNotice = notice
        guard let owner = boundOwner else { return }
        // A tap opens that market's position (`PerpAlertText.reference`).
        Activity.record(ActivityRecord(kind: .perp, title: notice.title, subtitle: notice.body, hash: nil, section: "perps",
                                       reference: PerpAlertText.reference(perpId: notice.marketId)), owner: owner)
    }

    /// Cancels the TP/SL that were closing `ended`'s side of its market, once it has closed (security audit GT-2).
    /// Perpl drops a position-linked trigger itself, but the ticket's triggers are linked to their entry, and nothing
    /// documents that those go with the position: left armed, a stop-loss would fire against the NEXT position on that
    /// side. Only what is provably orphaned goes: no open position on that side, no resting entry on that side of the
    /// market (a trigger may be waiting on it) and no entry sent from here in the last minute. It waits two seconds for
    /// Perpl's own clean-up to arrive first. The stream alone never decides it: nothing is cancelled unless a fresh
    /// on-chain read agrees that side holds no position (a partial liquidation, or a stream that got it wrong, must
    /// not take the stop-loss off a position that is still open); while the chain still shows it, it tries again a
    /// few times and then leaves them to the trade screen's warning. A passkey account's cancel needs Face ID, so it
    /// is left to the trade screen's "Cancel leftover TP/SL" instead.
    private func cancelLeftovers(of ended: PerplLivePosition) {
        guard !boundToPasskey, let owner = boundOwner else { return }
        let side = PerplMarketSide(marketId: ended.marketId, isLong: ended.isLong)
        // The trade screen doesn't offer these while the clean-up is on its way (a second cancel), for 20 s at most.
        let scheduled = Date()
        cleanupScheduled[side] = scheduled
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.cleanupWindow))
            if self?.cleanupScheduled[side] == scheduled { self?.cleanupScheduled[side] = nil }
        }
        Task { @MainActor [weak self] in
            // Sent or given up: the side is no longer "about to be cleaned up" (sent keys move to `cancelsPending`).
            defer { if self?.cleanupScheduled[side] == scheduled { self?.cleanupScheduled[side] = nil } }
            for delay in [2, 4, 8] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.boundOwner == owner, self.leftovers(of: ended) != nil else { return }
                // The chain's word, read now: its position on that side is gone.
                guard let read = self.readPositions, let chain = try? await read(owner, Array(self.markets.values)),
                      !chain.contains(where: { $0.perpId == side.marketId && ($0.side == .long) == side.isLong }) else { continue }
                // Re-read after the await: the stream may have moved on (a new position, a cancel of its own).
                guard self.boundOwner == owner, let client = self.client, let accountId = client.accountId,
                      let leftovers = self.leftovers(of: ended) else { return }
                self.cancelsSent.formUnion(leftovers.map(\.id))
                let noted = self.notePendingCancels(leftovers.map(\.id), on: client)
                let background = PerplBackgroundTime("Cancel leftover TP/SL") // not localized: the task's name
                defer { background.end() }
                guard let acks = try? await client.sendEach(leftovers.map { PerplOrders.cancel(perpId: $0.marketId, orderId: $0.oid, accountId: accountId, head: 0) }) else {
                    // Nothing was sent (`sendEach` throws only then): not "Cancelling…", and a later sweep may try again.
                    for order in leftovers where self.cancelsPending[order.id]?.at == noted {
                        self.cancelsPending[order.id] = nil
                        self.cancelsSent.remove(order.id)
                    }
                    return
                }
                // Refused before Perpl forwarded it: the trigger is as it was. Not "Cancelling…" (the trade screen offers its
                // Cancel again), and a later sweep may try again.
                for (order, ack) in zip(leftovers, acks) where !ack.accepted && !ack.outcomeUnknown && self.cancelsPending[order.id]?.at == noted {
                    self.cancelsPending[order.id] = nil
                    self.cancelsSent.remove(order.id)
                }
                // Counted once Perpl's list confirms them: an admitted cancel can still fail.
                let accepted = zip(leftovers, acks).filter { $0.1.accepted }.map { $0.0.id }
                let stillListed = await self.remaining(of: Set(accepted), from: client)
                self.recordLeftoversCancelled(accepted.count - stillListed.count, of: ended, owner: owner)
                return
            }
        }
    }

    /// The live stream's triggers left over from `ended`'s side, not already being cancelled — nil when there are none,
    /// or the stream can't say (not signed in, before its snapshots, or suspect: a heartbeat gap means updates may have
    /// been missed, so its list may be out of date).
    private func leftovers(of ended: PerplLivePosition) -> [PerplOpenOrder]? {
        guard let client, client.signedIn, client.hasOrdersSnapshot, client.hasPositionsSnapshot, !client.streamSuspect else { return nil }
        let leftovers = PerplTriggerCleanup.siblings(of: ended, orders: client.openOrders, positions: client.positions, extraRestingEntries: recentEntrySides)
            .filter { !cancelsSent.contains($0.id) }
        return leftovers.isEmpty ? nil : leftovers
    }

    private func recordLeftoversCancelled(_ cancelled: Int, of ended: PerplLivePosition, owner: Address) {
        guard cancelled > 0 else { return }
        // Recorded quietly: the ending itself was the news.
        let market = marketName(ended.marketId)
        let subtitle = ended.isLong ? tr("\(market) · \(cancelled) orders from the closed long") : tr("\(market) · \(cancelled) orders from the closed short")
        Activity.record(ActivityRecord(kind: .perp, title: tr("Cancelled leftover TP/SL"), subtitle: subtitle, hash: nil, section: "perps"),
                        owner: owner, notify: false)
    }

    // MARK: Event-driven reloads (real-time spec, Phase 3)

    /// The live stream reported something on the account: `streamRevision` is bumped 250 ms after the last report of a
    /// burst, at most a second after its first, and never within a second of the previous bump. Never a reconnect, and
    /// never data for the screens: they read the chain again.
    private func streamActivity() {
        let now = Date()
        let since = streamPendingSince ?? now
        streamPendingSince = since
        let fireAt = max(min(now.addingTimeInterval(Self.streamDebounce), since.addingTimeInterval(Self.streamSpacing)),
                         streamBumpedAt.addingTimeInterval(Self.streamSpacing))
        streamBump?.cancel()
        streamBump = Task { @MainActor [weak self] in
            let wait = fireAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.streamPendingSince = nil
            self.streamBumpedAt = Date()
            self.streamRevision &+= 1
        }
    }

    /// The live stream reported a fill or a position change on the account: `historyRevision` is bumped a second after
    /// the last of them.
    private func historyActivity() {
        historyBump?.cancel()
        historyBump = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.historyDebounce))
            guard let self, !Task.isCancelled else { return }
            self.historyRevision &+= 1
        }
    }

    // MARK: Order outcomes (real-time spec, Phase 1)

    /// The app-wide watcher's wait for an order about to be sent over the trading connection (`expectOrder`), held from
    /// before its first frame is written until `track` takes it over under the order's own id.
    struct OrderExpectation {
        let id: UUID
        let since: Date
    }

    /// An order is about to be sent over the trading connection (the sheet calls this after App Lock and any approval,
    /// right before `submitBracket`): from now on the app-wide watcher waits for the order's own result rather than
    /// announcing its fill first (I5) — sending the entry and its TP/SL can take several acknowledgements. `track` takes
    /// the wait over with the order's own deadline; a sheet whose order was never followed lets it go
    /// (`releaseOrderExpectation`).
    func expectOrder(_ input: OrderInput, held: (side: PositionSide, size: Double)?) -> OrderExpectation {
        let expectation = OrderExpectation(id: UUID(), since: Date())
        if let growth = PerplPositionEvidence.expectedGrowth(orderSide: input.side, size: input.size, reduceOnly: input.reduceOnly, held: held) {
            // The connect, the checks, three acknowledgements and the outcome's own window, at most.
            let until = expectation.since.addingTimeInterval(PerplTimeouts.ack * 3 + PerplTimeouts.outcomeWallClock + 10)
            expectFill(expectation.id, input.market.id, input.side, growth, until)
        }
        return expectation
    }

    /// The order an `expectOrder` was made for wasn't sent, or was refused: nothing of it can fill.
    func releaseOrderExpectation(_ expectation: OrderExpectation) { releaseFill(expectation.id) }

    /// Follows a sent order to Perpl's outcome whether or not its sheet stays open (operation(): background time, and a
    /// passkey socket's drain waits for it, GL-1). The entry settles the moment it is decided; each TP/SL settles on its
    /// own. An entry Perpl never answered is followed too (it may be live), from the socket that sent it: a closed one
    /// answers "connection lost" at once and the order is read from the stream, its history and the chain instead.
    /// Nothing is ever resent. `echoes`: the ids of this device's echoes of its TP/SL (`TriggerStore.record`), the only
    /// echoes the order may ever remove. `expectation`: the watcher's wait made before the send, taken over here.
    @discardableResult
    func track(_ t: PerplOrderTracking, input: OrderInput, takeProfit: Double?, stopLoss: Double?, closes: PositionSide?,
               held: (side: PositionSide, size: Double)?, ttlBlocks: Int?, before: PerpPosition?, beforeReadAt: Date?,
               restingOnSide: Bool, echoes: [PerplTriggerKind: UUID] = [:], expectation: OrderExpectation? = nil,
               purpose: PerplTrackedOrder.Purpose? = nil) -> UUID {
        let sentAt = t.entry.writtenAt
        let id = PerplOrderTracker.activityID(accountId: t.accountId, rq: t.entryRq, sentAt: sentAt)
        let deadline = PerplOutcomeDeadline(ackHead: t.entryAck?.head, ttlBlocks: ttlBlocks, ackAt: t.entryAck?.receivedAt ?? t.entry.writtenAt)
        let expected = PerplPositionEvidence.expectedGrowth(orderSide: input.side, size: input.size, reduceOnly: input.reduceOnly, held: held)
        // Its triggers went out only after the entry was answered (GL-1): with no answer, they never left the device.
        let triggersSent = t.entryAck != nil
        func child(_ kind: PerplTriggerKind, _ price: Double?, _ sent: (rq: Int?, ack: PerplOrderAck)?) -> PerplTrackedOrder.Child? {
            guard let price else { return nil }
            return PerplTrackedOrder.Child(kind: kind, rq: sent?.rq ?? sent?.ack.requestId, price: price, accepted: sent?.ack.accepted == true,
                                           unknown: sent?.ack.outcomeUnknown == true, notSent: !triggersSent, echoId: triggersSent ? echoes[kind] : nil)
        }
        var order = PerplTrackedOrder(
            id: id, source: .api(accountId: t.accountId, rq: t.entryRq), owner: boundOwner, sent: t.entry, marketId: input.market.id,
            asset: input.market.asset, priceDecimals: input.market.priceDecimals, lotDecimals: input.market.lotDecimals, side: input.side,
            isMarket: input.kind == .market, requestedSize: input.size, limitPrice: input.kind == .limit ? input.price : nil,
            reduceOnly: input.reduceOnly, closes: closes, slippageBps: input.slippageBps, expectedGrowth: expected, acknowledged: t.acknowledged,
            sentAt: sentAt, deadline: deadline, before: before, beforeReadAt: beforeReadAt, restingOnSide: restingOnSide,
            takeProfit: child(.takeProfit, takeProfit, t.takeProfit), stopLoss: child(.stopLoss, stopLoss, t.stopLoss))
        order.expectedSince = expectation?.since
        // A close from the position's Close sheet: its result is said of the position, and its socket says whether the
        // position ended (`positionEnded(of:)`).
        order.purpose = purpose
        if purpose != nil {
            closeClients[id] = WeakClient(client: t.client)
            if closeClients.count > 64 { closeClients = closeClients.filter { $0.value.client != nil && orders.order($0.key) != nil } }
        }
        orders.add(order)
        if let charge = t.charge { charges[id] = charge }
        // The wait made before the send is taken over under the order's own id, with its own deadline (no await between:
        // the watcher never sees a moment without one).
        if let expectation { releaseFill(expectation.id) }
        // From the send: the app-wide watcher waits for this order's own result rather than racing it (I5).
        if let expected { expectFill(id, input.market.id, input.side, expected, deadline.wallClock) }
        following.insert(id)
        let done = operation("Perpl order outcome") // not localized: the task's name
        Task { @MainActor [weak self] in
            defer { done() }
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.followEntry(id, t, deadline) }
                // Refused or unanswered triggers keep today's lines; accepted ones settle on their own.
                for (kind, sent) in [(PerplTriggerKind.takeProfit, t.takeProfit), (.stopLoss, t.stopLoss)] {
                    guard let sent, sent.ack.accepted, let rq = sent.rq ?? sent.ack.requestId else { continue }
                    group.addTask { await self.followChild(id, kind: kind, rq: rq, client: t.client, deadline: deadline) }
                }
            }
            await self.checkLeftTriggers(id, sentOn: t.client)
            self.following.remove(id)
        }
        return id
    }

    /// A task still follows order `id` (its own wait, its triggers', the re-read of triggers it left armed).
    func isFollowing(_ id: UUID) -> Bool { following.contains(id) || checkingLeft.contains(id) }

    /// The take-profit / stop-loss of order `id` that are still on Perpl's live list with no position to close (found by
    /// their request ids), for the sheet's "Cancel" of what the order left armed: those a check found still listed, and
    /// those no check could rule out yet (the entry executed nothing, they were armed, and no live list has been read
    /// without them) — only while the live list shows them.
    func liveTriggers(of id: UUID) -> [PerplOpenOrder] {
        guard ordersAreLive, let client, let order = orders.order(id) else { return [] }
        let executedNothing = order.entry?.executedNothing == true
        let rqs = Set(PerplTriggerKind.allCases.compactMap { kind -> Int? in
            guard let child = order.child(kind) else { return nil }
            let unverified = executedNothing && child.outcome == .armed && !child.checkedNotListed
            return child.armedWithoutPosition || unverified ? child.rq : nil
        })
        guard !rqs.isEmpty else { return [] }
        return openOrders.filter { listed in client.requestId(for: listed.id).map(rqs.contains) ?? false }
    }

    /// The entry, on the socket that sent it: settled the moment Perpl decides it; "not confirmed" at the deadline or
    /// when the socket closes, and then read from the other evidence for up to two minutes (`resolveUnconfirmed`).
    private func followEntry(_ id: UUID, _ t: PerplOrderTracking, _ deadline: PerplOutcomeDeadline) async {
        let outcome = await t.client.awaitOutcome(rq: t.entryRq, sent: t.entry, deadline: deadline)
        settle(id, outcome)
        if PerplTracker.isUnconfirmed(outcome) { startResolving(id) }
    }

    private func followChild(_ id: UUID, kind: PerplTriggerKind, rq: Int, client: PerplTradeClient, deadline: PerplOutcomeDeadline) async {
        guard let sent = client.sentRequest(rq: rq) else { return }
        let outcome = await client.awaitOutcome(rq: rq, sent: sent, deadline: deadline)
        settleChild(id, kind: kind, outcome, duringFollow: true)
    }

    /// An entry that executed nothing whose take-profit or stop-loss Perpl had armed: three seconds later a live list is
    /// read — the socket that sent them, else the current one — and each one is either still listed (marked: the sheet
    /// offers to cancel it, it would act on a later position) or, on a list that can tell it, gone (marked: it went with
    /// the entry, and only then does its echo go). A list that can't tell (none signed in with its snapshot, or one that
    /// lists a trigger of that kind on that side whose request it can't name) decides nothing: the sheet says it may
    /// still be armed, and the check runs again on the next snapshots. Runs when the follow ends, and again whenever an
    /// entry is decided as executing nothing after that.
    private func checkLeftTriggers(_ id: UUID, sentOn sender: PerplTradeClient?) async {
        guard let order = orders.order(id), order.entry?.executedNothing == true, Self.leftTriggersToCheck(order).isEmpty == false,
              checkingLeft.insert(id).inserted else { return }
        defer { checkingLeft.remove(id) }
        try? await Task.sleep(for: .seconds(3))
        let live: PerplTradeClient? = sender.flatMap { $0.signedIn && $0.hasOrdersSnapshot ? $0 : nil } ?? client
        guard let live, live.signedIn, live.hasOrdersSnapshot, !live.streamSuspect, var current = orders.order(id) else { return }
        var effects: [PerplTrackerEffect] = []
        var changed = false
        let now = Date()
        for kind in Self.leftTriggersToCheck(current) {
            guard let rq = current.child(kind)?.rq else { continue }
            let named = live.openOrders.filter { live.requestId(for: $0.id) == rq }
            if !named.isEmpty {
                PerplTracker.markArmedWithoutPosition(&current, kind: kind, now: now)
                changed = true
                continue
            }
            // A trigger of this kind on that side whose request this socket can't name could be this one: no conclusion.
            let unnamed = live.openOrders.contains { listed in
                listed.isTrigger && listed.marketId == current.marketId && listed.protectsLong == (current.side == .long)
                    && listed.isStopLoss == (kind == .stopLoss) && live.requestId(for: listed.id) == nil
            }
            guard !unnamed else { continue }
            effects += PerplTracker.markCheckedNotListed(&current, kind: kind, now: now)
            changed = true
        }
        guard changed else { return }
        orders.update(current)
        apply(effects, to: current)
    }

    /// The take-profit / stop-loss of an order whose entry executed nothing that Perpl had armed and no check has placed
    /// yet (neither found still listed nor found gone).
    private static func leftTriggersToCheck(_ order: PerplTrackedOrder) -> [PerplTriggerKind] {
        PerplTriggerKind.allCases.filter { kind in
            guard let child = order.child(kind) else { return false }
            return child.outcome == .armed && !child.armedWithoutPosition && !child.checkedNotListed
        }
    }

    /// Every order whose entry executed nothing with a take-profit / stop-loss not yet placed by a check, and no task on
    /// it: checked again on the current socket (after each reconnect's snapshots).
    private func recheckLeftTriggers() {
        guard let owner = boundOwner else { return }
        for order in orders.orders where order.owner == owner && order.entry?.executedNothing == true && !following.contains(order.id)
            && !checkingLeft.contains(order.id) && !Self.leftTriggersToCheck(order).isEmpty {
            let id = order.id
            Task { await self.checkLeftTriggers(id, sentOn: nil) }
        }
    }

    /// Applies an entry outcome to the tracked order and carries out its effects (once: an unchanged outcome does
    /// nothing). `notify` false: a reconcile, which posts no notice. An entry decided as executing nothing after its
    /// follow ended has its armed take-profit / stop-loss looked for again on the current socket.
    private func settle(_ id: UUID, _ outcome: PerplOrderOutcome, notify: Bool = true) {
        guard var order = orders.order(id) else { return }
        let effects = PerplTracker.settleEntry(&order, outcome, now: Date(), notify: notify && notifyFills(),
                                               appActive: UIApplication.shared.applicationState == .active,
                                               watcherAnnouncedSinceSent: watcherAnnounced(order.marketId, order.side, order.noticeSince))
        guard !effects.isEmpty else { return }
        orders.update(order)
        apply(effects, to: order)
        // A close from the position's Close sheet that Perpl refused because order forwarding is off (OrderForwardingNotAllowed,
        // sr 34): the trading route rests on the socket that sent it (A.2), as for Add Margin and Cancel Order.
        if order.purpose != nil, case .failed(let reason) = outcome, reason.reason == 34 { noteAPIRefusal(on: closeClients[id]?.client) }
        if outcome.executedNothing, !following.contains(id) {
            Task { await self.checkLeftTriggers(id, sentOn: nil) }
        }
    }

    private func settleChild(_ id: UUID, kind: PerplTriggerKind, _ outcome: PerplOrderOutcome, duringFollow: Bool = false) {
        guard var order = orders.order(id) else { return }
        let effects = PerplTracker.settleChild(&order, kind: kind, outcome, now: Date(), duringFollow: duringFollow)
        orders.update(order)
        apply(effects, to: order)
    }

    /// The effects the tracker doesn't carry out itself.
    private func apply(_ effects: [PerplTrackerEffect], to order: PerplTrackedOrder) {
        let id = order.id
        let ended = order.isClose ? positionEnded(of: order) : nil
        orders.apply(effects, order: order, boundOwner: boundOwner, positionEnded: ended) { effect in
            switch effect {
            case .noteAnnounced(let growth): fillAnnounced(id, growth)
            case .releaseExpectation: releaseFill(id)
            // Only a FINAL no-execution gives the passkey charge back (MERA-PLAN §3), once.
            case .refund: mera?.refund(charges.removeValue(forKey: id))
            // The app-wide watcher's note belongs to the account signed in.
            case .voidUserClose: if order.owner == boundOwner { userCloseVoided(order.marketId) }
            case .reload: streamRevision &+= 1
            case .wakeWatcher: wakeWatcher()
            case .announce, .recordActivity, .removeTriggerEcho: break
            }
        }
    }

    /// A late report on `client` (an update, a fill, a position): every tracked order of its account that is still
    /// waiting shows a provisional failure, and one whose result can still change (not confirmed, a growth seen on the
    /// chain, resting) is decided again from it.
    private func reevaluate(using client: PerplTradeClient) {
        guard let accountId = client.accountId else { return }
        for order in orders.orders {
            guard case .api(let account, let rq) = order.source, account == accountId, let sent = order.sent else { continue }
            if order.entry == nil {
                let provisional = client.provisionalFailure(rq: rq, accountId: accountId)
                if provisional != order.provisional {
                    var waiting = order
                    waiting.provisional = provisional
                    orders.update(waiting)
                }
            } else if order.entry?.canStillChange == true, let outcome = client.outcome(rq: rq, sent: sent, final: false) {
                // A "not confirmed" from this socket never replaces a growth the chain showed.
                if !(PerplTracker.isUnconfirmed(outcome) && order.entry.map(PerplTracker.isUnconfirmed) == false) { settle(order.id, outcome) }
            }
            // Its take-profit / stop-loss, on the socket that wrote them, once their own wait is over.
            for kind in PerplTriggerKind.allCases {
                guard let child = order.child(kind), child.outcome != nil, let childRq = child.rq, let childSent = client.sentRequest(rq: childRq),
                      let outcome = client.outcome(rq: childRq, sent: childSent, final: false), outcome != child.outcome else { continue }
                settleChild(order.id, kind: kind, outcome)
            }
        }
        // Margin sent from here whose result wasn't confirmed (or was refused a moment ago): its socket's late word.
        recheckMargins(on: client)
    }

    /// An order not confirmed at its deadline: read again at once, then after each report on the account (at most every
    /// three seconds) for two minutes. Still not confirmed ten minutes after the send, the reconcile writes its row.
    private func startResolving(_ id: UUID) {
        guard resolving.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var seen: Int?
            let start = Date()
            while Date().timeIntervalSince(start) < Self.resolveWindow {
                guard let order = self.orders.order(id), Self.needsResolving(order) else { break }
                if seen != self.accountActivity {
                    seen = self.accountActivity
                    await self.resolveOnce(id, notify: true)
                }
                try? await Task.sleep(for: .seconds(3))
            }
            self.resolving.remove(id)
            guard let order = self.orders.order(id), Self.needsResolving(order) else { return }
            let wait = order.sentAt.addingTimeInterval(Self.unconfirmedRowAfter + 1).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await self.reconcileLoadedOrders()
        }
    }

    static let resolveWindow: TimeInterval = 120
    /// How long an unconfirmed order waits for its result before its row says so (no volume) and the store lets it go.
    static let unconfirmedRowAfter: TimeInterval = 600

    /// Its result isn't Perpl's yet: waiting (after a relaunch), not confirmed, or only a growth seen on the chain.
    private static func needsResolving(_ order: PerplTrackedOrder) -> Bool {
        guard let entry = order.entry else { return true }
        if PerplTracker.isUnconfirmed(entry) { return true }
        if case .observed = entry { return true }
        return false
    }

    /// One pass over the evidence for an order whose result the stream didn't give in time: (a) the live socket's
    /// reports, (b) once, the signed order history (a key account, or a passkey account while its session is open),
    /// (c) the position on the chain, compared with the one read before the order (`PerplPositionEvidence`). Nothing is
    /// ever resent.
    private func resolveOnce(_ id: UUID, notify: Bool) async {
        guard let order = orders.order(id), case .api(let accountId, let rq) = order.source, let sent = order.sent else { return }
        // (a) The snapshots and updates carry the request id of an order still open.
        if let client, client.accountId == accountId, let outcome = client.outcome(rq: rq, sent: sent, final: false), !PerplTracker.isUnconfirmed(outcome) {
            settle(id, outcome, notify: notify)
            if !Self.needsResolving(orders.order(id) ?? order) { return }
        }
        // (b) After the fact: the history is final.
        if !historyRead.contains(id), let key, let orderHistory, order.owner == boundOwner {
            historyRead.insert(id)
            if let events = try? await orderHistory(key) {
                // Decided by the stream while the history was read: its fresher word stands (a lagging or incomplete
                // history never overwrites a fill, never refunds one).
                guard let latest = orders.order(id), Self.needsResolving(latest) else { return }
                var ledger = PerplOrderLedger(account: accountId)
                let now = Date()
                for event in events.reversed() where event.requestId == rq && (event.accountId ?? accountId) == accountId {
                    _ = ledger.apply(event, at: now)
                }
                if let outcome = ledger.outcome(rq: rq, sent: sent, final: true), !PerplTracker.isUnconfirmed(outcome) {
                    settle(id, outcome, notify: notify)
                    return
                }
            }
        }
        // (c) The chain: only while nothing better is known, only for an order that can grow its side, only against a
        // position read before it, only while its own result could still be arriving (up to the resolve window past its
        // deadline), and never for an order read back from the store: the orders sent before a relaunch aren't in memory,
        // so a later growth (another order, the Perpl web app) could be pinned on it.
        guard let latest = orders.order(id), latest.entry == nil || latest.entry.map(PerplTracker.isUnconfirmed) == true,
              PerplTracker.mayReadChainGrowth(latest, now: Date(), loadedFromDisk: orders.loadedFromDisk.contains(id), window: Self.resolveWindow),
              let expected = latest.expectedGrowth, let beforeReadAt = latest.beforeReadAt, let owner = latest.owner, owner == boundOwner,
              let read = readPositions, !markets.isEmpty else { return }
        guard let positions = try? await read(owner, Array(markets.values)) else { return }
        guard let current = orders.order(id), current.entry == nil || current.entry.map(PerplTracker.isUnconfirmed) == true else { return }
        let after = positions.first { $0.perpId == current.marketId }
        let others = orders.orders.contains { $0.id != id && $0.owner == owner && $0.marketId == current.marketId && $0.side == current.side && $0.sentAt > beforeReadAt }
        let attributable = PerplPositionEvidence.isAttributable(beforeAge: current.sentAt.timeIntervalSince(beforeReadAt), otherTrackedOrders: others,
                                                                restingOnSide: current.restingOnSide)
        if let growth = PerplPositionEvidence.growth(side: current.side, before: current.before, after: after, expected: expected,
                                                     lot: pow(10, -Double(current.lotDecimals)), attributable: attributable) {
            settle(id, .observed(growth), notify: notify)
        }
    }

    /// Orders no live task follows — read back from the store (the app was closed or killed while they waited), or
    /// followed here until their own window ended — read once more per call, with no notice: the stream, the history,
    /// the chain. One still not confirmed ten minutes after it was sent gets its row (no volume) and leaves the store; a
    /// resting one is followed for a day. Runs on each return to the app and after each reconnect's snapshots.
    func reconcileLoadedOrders() async {
        guard !reconciling, let owner = boundOwner else { return }
        reconciling = true
        defer { reconciling = false }
        // A wallet-signed order is read from its receipt (`redecodeOnChainOrders`), never from the stream or the history.
        for order in orders.orders where order.owner == owner && !order.isOnChain && !following.contains(order.id) && !resolving.contains(order.id) && !reconciled.contains(order.id) {
            let id = order.id
            guard order.entry == nil || order.entry?.canStillChange == true else { finishReconciling(id); continue }
            let age = Date().timeIntervalSince(order.sentAt)
            if let entry = order.entry, PerplTracker.isResting(entry) {
                if age > PerplPendingOrderStore.restingRetention { finishReconciling(id); continue }
            }
            await resolveOnce(id, notify: false)
            guard boundOwner == owner, var latest = orders.order(id) else { continue }
            if latest.entry == nil {
                // Its answer was lost with the app or the socket: not confirmed.
                settle(id, .unconfirmed(.connectionLost), notify: false)
                latest = orders.order(id) ?? latest
            }
            guard let entry = latest.entry else { continue }
            if Self.needsResolving(latest) {
                guard age > Self.unconfirmedRowAfter else { continue }
                // Its row, so the feed stays complete: no volume (only a fill, or a growth only it explains, has one).
                if PerplTracker.isUnconfirmed(entry) {
                    PerplOrderTracker.record(entry, latest, kindName: PerplOrderTracker.kindName(latest), hash: nil, id: latest.id, owner: latest.owner)
                }
                finishReconciling(id)
            } else if !entry.canStillChange {
                finishReconciling(id)
            }
        }
        // Margin sent from here whose result wasn't confirmed: the chain, once per pending request.
        await recheckMarginsOnChain(owner: owner)
    }

    /// The reconcile is done with `id`: out of the store, and never read by it again in this process.
    private func finishReconciling(_ id: UUID) {
        reconciled.insert(id)
        orders.forget(id)
    }

    // MARK: Wallet-signed orders (real-time spec, Phase 3)

    /// Reads a mined transaction's Perpl requests from its receipt (`PerplService.receiptRequests`: up to three reads
    /// 300 ms apart while it reads back null); set by AppEnvironment.
    @ObservationIgnored var receiptRequests: ((Data) async throws -> [PerplReceipt.Request]?)?
    /// Wallet-signed orders whose receipt is being read now (one read at a time each), and when each was last read again
    /// on a return to the app.
    @ObservationIgnored private var decodingOnChain: Set<UUID> = []
    @ObservationIgnored private var redecodedAt: [UUID: Date] = [:]
    /// When the watcher started waiting for each wallet-signed order (`expectOnChainOrder`), until `trackOnChain` stores it
    /// on the order: its notice window and the watcher's notices count from then, not from the receipt.
    @ObservationIgnored private var onChainExpectedSince: [UUID: Date] = [:]
    /// How long the app-wide watcher waits for a wallet-signed order's own result before it announces a growth itself.
    static let onChainExpectation: TimeInterval = 90
    /// A stored wallet-signed order is read again on a return to the app at most this often.
    static let redecodeSpacing: TimeInterval = 60

    /// A wallet-signed order is about to be signed and sent (its sheet's `onStarted`, after App Lock and any approval):
    /// the app-wide watcher waits for the order's own result rather than racing it (I5), for 90 s at most. Returns the
    /// order's id, which `trackOnChain` follows it under.
    func expectOnChainOrder(_ input: OrderInput, held: (side: PositionSide, size: Double)?) -> UUID {
        let id = UUID()
        let now = Date()
        onChainExpectedSince[id] = now
        if let growth = PerplPositionEvidence.expectedGrowth(orderSide: input.side, size: input.size, reduceOnly: input.reduceOnly, held: held) {
            expectFill(id, input.market.id, input.side, growth, now.addingTimeInterval(Self.onChainExpectation))
        }
        return id
    }

    /// The order's sheet closed. One whose transaction never confirmed (refused, reverted, never sent) expects no fill
    /// any more; one that did shows on the trade screen's status row from now on until its result is seen.
    func onChainSheetClosed(_ id: UUID) {
        onChainExpectedSince[id] = nil
        if orders.order(id) == nil { releaseFill(id) } else { orders.setPresented(id, false) }
    }

    /// A wallet-signed order's transaction confirmed (its sheet's `onCompleted`, GL-3): its Activity row says it was sent
    /// and that its result isn't read yet (no volume, no notice), and it is followed — in the store until its receipt is
    /// read (a kill before the read still upgrades the row on the next return), and on the trade screen's status row once
    /// its sheet closes.
    func trackOnChain(id: UUID, hash: Data, input: OrderInput, closes: PositionSide?, held: (side: PositionSide, size: Double)?,
                      accountId: Int?, descId: UInt64?, owner: Address?) {
        let sentAt = Date()
        // The watcher has waited since the order was about to be signed (`expectOnChainOrder`): the order's window is the
        // same one, and a fill the watcher announced since then is never announced again by the order.
        let expectedSince = onChainExpectedSince.removeValue(forKey: id)
        var order = PerplTrackedOrder(
            id: id, source: .onChain(hash: hash), owner: owner, sent: nil, marketId: input.market.id, asset: input.market.asset,
            priceDecimals: input.market.priceDecimals, lotDecimals: input.market.lotDecimals, side: input.side, isMarket: input.kind == .market,
            requestedSize: input.size, limitPrice: input.kind == .limit ? input.price : nil, reduceOnly: input.reduceOnly, closes: closes,
            slippageBps: input.slippageBps,
            expectedGrowth: PerplPositionEvidence.expectedGrowth(orderSide: input.side, size: input.size, reduceOnly: input.reduceOnly, held: held),
            acknowledged: false, sentAt: sentAt,
            deadline: PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: expectedSince ?? sentAt, cap: Self.onChainExpectation),
            before: nil, beforeReadAt: nil, restingOnSide: false,
            receiptKey: accountId.map { PerplTrackedOrder.ReceiptKey(accountId: $0, descId: descId) })
        order.expectedSince = expectedSince
        order.presentedInSheet = true
        orders.add(order)
        PerplOrderTracker.recordOnChainSent(order, hash: hash)
    }

    /// What a wallet-signed order's transaction did, read from its receipt the moment it confirmed (its sheet's
    /// `settle`). A fill, a partial fill or a resting order replaces the row (with the volume that filled, at the price it
    /// filled at) and posts the order's own notice; nothing filled says so on the row and in a notice, and a close noted
    /// for it is voided; a receipt that can't be read, or doesn't add up, keeps the row it was sent with, says so plainly,
    /// and is read again on the next return to the app. Never a guess (I3, I33).
    func settleOnChainOrder(_ id: UUID) async -> SettledLine? {
        await decodeOnChain(id, notify: true)
        guard let order = orders.order(id) else { return nil }
        if let entry = order.entry, !PerplTracker.isUnconfirmed(entry) {
            return SettledLine(text: PerplOutcomeText.order(entry, order.textContext), link: nil)
        }
        return SettledLine(text: PerplOutcomeText(headline: PerpOnChainCopy.unreadable, detail: nil, tone: .warning), link: nil)
    }

    /// Wallet-signed orders whose receipt wasn't read (its reads failed, or the app was closed or killed first): read again
    /// on each return to the app, at most once a minute each, for a day, with no notice.
    func redecodeOnChainOrders() async {
        guard let owner = boundOwner else { return }
        let now = Date()
        // Never one whose sheet is still open: that sheet reads it now, with its notice (a Face ID prompt makes a return).
        for order in orders.orders where order.owner == owner && order.isOnChain && !order.presentedInSheet && PerplOrderTracker.keepsRecord(order, now: now) {
            if let last = redecodedAt[order.id], now.timeIntervalSince(last) < Self.redecodeSpacing { continue }
            redecodedAt[order.id] = now
            await decodeOnChain(order.id, notify: false)
        }
    }

    /// Reads order `id`'s receipt once and settles it: its decoded outcome, or — when the receipt can't be read or its
    /// events don't add up — "not confirmed" (its row stays as sent; the follow-up stays stored). Nil: not read.
    @discardableResult
    private func decodeOnChain(_ id: UUID, notify: Bool) async -> PerplOrderOutcome? {
        guard let order = orders.order(id), case .onChain(let hash) = order.source, decodingOnChain.insert(id).inserted else { return nil }
        defer { decodingOnChain.remove(id) }
        let requests = try? await receiptRequests?(hash)
        guard let key = order.receiptKey,
              let outcome = PerplReceipt.orderOutcome(requests, accountId: key.accountId, descId: key.descId.map { BigUInt($0) }) else {
            if orders.order(id)?.entry == nil { settle(id, .unconfirmed(.timedOut), notify: false) }
            return nil
        }
        settle(id, outcome, notify: notify)
        if outcome.executedNothing, let latest = orders.order(id) { PerplOrderTracker.recordOnChainNotFilled(latest, hash: hash) }
        return outcome
    }

    // MARK: The scripted demo (DEBUG + Simulator only)

    #if DEBUG && targetEnvironment(simulator)
    /// The scripted Perps demo's session (`PerpsDemo`, p4 spec D): a client that never connects (`debugScripted()`) is
    /// adopted by an instance of its own — never the app's, never bound to a wallet or a passkey, with no key — and wired as
    /// a live socket would be. Its request ids are never written to the device's store.
    func debugAdopt(_ client: PerplTradeClient) {
        precondition(client.isDebugScripted && key == nil && boundAddress == nil, "only a scripted client, on an instance bound to no one")
        wire(client)
        client.onRequestIdIssued = nil
        self.client = client
        orders.debugNotice = { [weak self] title, body in self?.debugNotices.append((title, body)) }
        syncStatus()
    }

    /// Lets the demo's client go: its counts never reach the owner's census, and nothing is flushed.
    func debugRelease() {
        _ = client?.drainCensus()
        client?.disconnect()
        client = nil
        openOrders = []
    }

    /// This instance is the scripted demo's.
    var isDemo: Bool { client?.isDebugScripted == true }
    /// The fixed address the demo's position reads use (its stub reads nothing else): never an account.
    var demoReadOwner: Address? { isDemo ? PerpsDemo.readAddress : nil }
    private var demoSession: Bool { isDemo }
    /// The title and body of every notice the demo's orders and margin would post, posted nowhere.
    @ObservationIgnored private(set) var debugNotices: [(title: String, body: String)] = []
    /// A margin sheet of the demo's shows its request's result now (its request was written): the demo may close it.
    var debugMarginPresented: Bool { !marginPresented.isEmpty }
    #else
    /// Nil outside the DEBUG demo.
    var demoReadOwner: Address? { nil }
    private var demoSession: Bool { false }
    #endif

    // MARK: Stream census (counts only)

    private static let log = Logger(subsystem: "fun.dyorhq.app", category: "perpl") // not localized: a log category

    /// Every 60 s while the app runs: the sockets' census merged into the stored one, and logged when it changed.
    private func startCensusLog() {
        guard censusTask == nil else { return }
        censusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.flushCensus(self.client, self.draining)
            }
        }
    }

    /// Merges what `sockets` counted since the last flush into the stored census, and writes its one-line summary to the
    /// device log (subsystem fun.dyorhq.app, category perpl) at most once a minute when it changed — in every build: it
    /// holds counts only, never an id, an amount, a key or a frame.
    private func flushCensus(_ sockets: PerplTradeClient?...) {
        var delta = PerplStreamCensus()
        for socket in sockets.compactMap({ $0 }) { delta.merge(socket.drainCensus()) }
        var total = censusStore.load()
        if delta != PerplStreamCensus() {
            total.merge(delta)
            censusStore.save(total)
        }
        guard total != censusLogged, Date().timeIntervalSince(censusLoggedAt) >= 60 else { return }
        censusLogged = total
        censusLoggedAt = Date()
        Self.log.notice("\(total.summary, privacy: .public)")
    }

    func forget(address: Address) {
        stopKeepAlive()
        PerplKeychain.delete(address: address.checksummed)
        disconnect()
        key = nil
        storedToken = nil
        keyRejected = false
        forwardingGrantedOnChain = false
        resetProtection()
        resetRetry()
        status = .notEnrolled
    }
}

/// Whether the last trading socket of a Perpl account reported one-click trading (order forwarding) on: a public flag,
/// never a key, in UserDefaults ("perpl.forwarding.v1.<chain>.<account>"). Written from what the socket reports, never from
/// the on-chain grant. A passkey account whose session is locked sends Close / Add Margin over the trading connection after
/// its step-up only when it was on (`PerplTrading.apiActionsAfterUnlock`).
enum PerplForwardingMemory {
    static func key(chainId: Int, accountId: Int) -> String { "perpl.forwarding.v1.\(chainId).\(accountId)" } // not localized: a storage key

    /// Nil when no socket of the account was ever signed in on this device.
    static func lastKnown(chainId: Int, accountId: Int, defaults: UserDefaults = .standard) -> Bool? {
        let key = key(chainId: chainId, accountId: accountId)
        return defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    static func record(_ forwarding: Bool, chainId: Int, accountId: Int, defaults: UserDefaults = .standard) {
        defaults.set(forwarding, forKey: key(chainId: chainId, accountId: accountId))
    }
}

/// The owner's two Perps kill switches (`RemoteFlags.perpsLiveOutcome`, `.perpsApiActions`) as the last check that read
/// `app_config` 'ios' found them: two Bools in UserDefaults ("perps.switches.v1"), never a secret. Saved each time a
/// check reads the row (`AppEnvironment.apply`); a failed check saves nothing and changes nothing (`UpdateGate` fails
/// open). Read once, when `PerplTrading` starts: before the first check of a launch the app uses the last values read,
/// so an OFF the owner engaged holds across a relaunch and an offline start until a check reads otherwise. Nothing
/// stored: both on (`RemoteFlags.on`).
enum PerpsSwitchStore {
    struct Switches: Equatable {
        let perpsLiveOutcome: Bool
        let perpsApiActions: Bool
    }

    static let key = "perps.switches.v1" // not localized: a storage key
    private static let liveOutcomeKey = "perpsLiveOutcome" // not localized: a storage key
    private static let apiActionsKey = "perpsApiActions" // not localized: a storage key

    /// The last values read on this device; nil before the first check that read the row (or for a value that isn't
    /// the two Bools).
    static var last: Switches? { read(from: .standard) }

    static func read(from defaults: UserDefaults) -> Switches? {
        guard let stored = defaults.dictionary(forKey: key), let live = stored[liveOutcomeKey] as? Bool,
              let api = stored[apiActionsKey] as? Bool else { return nil }
        return Switches(perpsLiveOutcome: live, perpsApiActions: api)
    }

    static func save(_ flags: RemoteFlags, defaults: UserDefaults = .standard) {
        defaults.set([liveOutcomeKey: flags.perpsLiveOutcome, apiActionsKey: flags.perpsApiActions], forKey: key)
    }
}

extension PerplTradeError {
    /// Refused on the device (the frame wouldn't do what the sheet says): never a reason to stop using the connection.
    var isInvalidOrder: Bool { if case .invalidOrder = self { return true }; return false }
}

/// The trading stream's census (`PerplStreamCensus`), merged across sockets and launches, in UserDefaults: counts only,
/// nothing secret and nothing that names an order or an account. The owner reads it from a TestFlight device's log to
/// judge the Perps kill switches (live outcome, API actions) on data, and turn either off.
struct PerplCensusStore {
    private static let key = "perpl.census.v1" // not localized: a storage key
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PerplStreamCensus {
        guard let data = defaults.data(forKey: Self.key), let census = try? JSONDecoder().decode(PerplStreamCensus.self, from: data) else { return PerplStreamCensus() }
        return census
    }

    func save(_ census: PerplStreamCensus) {
        guard let data = try? JSONEncoder().encode(census) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// What a passkey (Mera) account stores of its Perpl API key: the token, and the nonce of the enrolment that issued it
/// (`Mera.Purpose.perplTrading(nonce:)`). Neither can sign in to the trading socket without the Ed25519 secret, which
/// the passkey re-derives at every unlock and is never stored.
struct PerplToken: Codable, Equatable {
    let token: String
    let address: String
    let scopeMask: Int
    /// Hex; nil for a token enrolled before enrolments carried a nonce (its key is the purpose's own).
    let keyNonce: String?

    init(_ key: PerplApiKey, keyNonce: Data?) {
        token = key.token
        address = key.address
        scopeMask = key.scopeMask
        self.keyNonce = keyNonce?.hexString
    }

    var keyNonceData: Data? { keyNonce.flatMap { Data(hex: $0) } }
}

/// Keychain storage for the Perpl API key (opaque token + 32-byte Ed25519 secret), one per wallet address — or, for a
/// passkey account, its token only (`saveToken`).
enum PerplKeychain {
    private static let service = "fun.dyorhq.perpl"

    static func save(_ key: PerplApiKey, address: String) {
        guard let data = try? JSONEncoder().encode(key) else { return }
        write(data, address: address)
    }

    static func load(address: String) -> PerplApiKey? {
        read(address: address).flatMap { try? JSONDecoder().decode(PerplApiKey.self, from: $0) }
    }

    /// A passkey account's token. Replaces whatever was stored for the address.
    static func saveToken(_ token: PerplToken, address: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        write(data, address: address)
    }

    /// A passkey account's token. An earlier build stored such an account's whole key; the secret in it is dropped here
    /// (the token is kept with no nonce, and the passkey re-derives the pre-nonce secret).
    static func loadToken(address: String) -> PerplToken? {
        guard let data = read(address: address), let token = try? JSONDecoder().decode(PerplToken.self, from: data) else { return nil }
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["secret"] != nil { saveToken(token, address: address) }
        return token
    }

    private static func write(_ data: Data, address: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false // explicit: keep the Perpl API secret off iCloud Keychain
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(address: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    static func delete(address: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
        SecItemDelete(query as CFDictionary)
    }
}

/// The background time iOS grants an app that leaves the foreground (about 30 s), held while frames are on their way to
/// Perpl or their answers are awaited (security audit 2026-09-26, GL-1): a suspended app freezes its socket, which could
/// leave an entry live with its stop-loss unsent, or an old stop cancelled with the new one unsent. Always handed back:
/// by `end` when the work is done, or when the time runs out.
@MainActor
private final class PerplBackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            MainActor.assumeIsolated { self.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
