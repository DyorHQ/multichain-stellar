import BigInt
import DyorKit
import Foundation
import Observation
import SwiftUI

/// Drives one transaction plan from a confirmation sheet: runs the steps, records progress, surfaces errors.
@Observable
@MainActor
final class TransactionRun {
    enum Phase: Equatable { case idle, running, done(Data), failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var events: [TransactionEvent] = []
    /// The step this run last saw confirmed: superseded once the next one is sent (`record`).
    @ObservationIgnored private var lastConfirmed: Data?

    var isRunning: Bool { phase == .running }
    /// Whether any step of this run reached the network. `start` replays a plan from its first step, so a run that
    /// sent something is never started again from the same sheet: a call that already landed (a swap, a send, a buy)
    /// would be signed with the next nonce and land twice (security audit 2026-09-26).
    var sentSomething: Bool { events.contains { if case .sent = $0 { return true } else { return false } } }
    var isDone: Bool { if case .done = phase { return true } else { return false } }
    /// The settled transaction hash once the plan's final step confirms, for callers that record or route on it.
    var doneHash: Data? { if case .done(let hash) = phase { return hash } else { return nil } }

    /// `action`: the sheet's declared intent for a passkey (Mera) account, so its session's scope check sees the whole
    /// plan (`Session.wallet(for:)`); nil for every other account, which signs exactly as before.
    func start(_ steps: [TransactionStep], session: Session, sender: TransactionSender, action: MeraSession.Action? = nil) {
        guard !isRunning else { return }
        if sentSomething {
            phase = .failed(Self.alreadySent)
            return
        }
        guard let wallet = session.wallet(for: action) else {
            phase = .failed(SessionError.readOnly.localizedDescription)
            return
        }
        let passkey = session.isPasskeyAccount
        let owner = session.address
        let mera = session.mera
        phase = .running
        events = []
        lastConfirmed = nil
        // An approved plan keeps a passkey account's session until its last step, even if the app leaves the
        // foreground meanwhile (GL-1): its later steps never ask for the passkey again.
        mera.beginAction()
        Task {
            // A lock or an app switch mid-plan suspends it: ask for the time iOS grants so the step in flight can still
            // broadcast and see its receipt (GL-2).
            let background = BackgroundTime("Transaction") // not localized: the background task's name, never shown
            defer { background.end(); mera.endAction() }
            do {
                let hash = try await sender.run(steps, from: wallet) { event in
                    Task { @MainActor in self.record(event, owner: owner) }
                }
                phase = .done(hash)
            } catch where passkey && isUserCancellation(error) {
                // A passkey prompt the person dismissed: say plainly what did and didn't happen.
                phase = .failed(sentSomething ? tr("Stopped at \(BiometricGate.promptName). Only the steps above were sent.") : Self.notSent)
            } catch {
                if let failure = error as? TransactionError, case .reverted(let hash) = failure { PendingActivity.reverted(hash, owner: owner) }
                // A step sent but not seen confirmed keeps its hash (the View link above, and a pending row in Recent
                // Activity that the next foreground re-checks): "Sent — confirmation not seen yet".
                phase = .failed(describe(error))
            }
        }
    }

    /// Each sent step is a pending Activity row (`PendingActivity`), so a plan that fails or is killed after a broadcast
    /// never loses the transaction. Seen confirmed, the row says so and stays: an earlier step's goes when the next step is
    /// sent, and the last one's is replaced by the caller's own record of the action (same hash) — or stays, when the
    /// sheet is gone before it records (GL-2).
    private func record(_ event: TransactionEvent, owner: Address?) {
        events.append(event)
        switch event {
        case .sent(let label, let hash):
            if let previous = lastConfirmed { PendingActivity.superseded(previous, owner: owner) }
            lastConfirmed = nil
            PendingActivity.sent(hash, label: label, owner: owner)
        case .confirmed(_, let hash):
            PendingActivity.confirmed(hash, owner: owner)
            lastConfirmed = hash
        case .preparing: break
        }
    }

    /// A step-up the person cancelled before anything was signed, in the app's language.
    static var notSent: String { tr("Not sent. Nothing left your account.") }
    /// Why a run that already broadcast something is not started again, in the app's language.
    static var alreadySent: String {
        tr("Part of this was already sent. Check it with View above before trying again — confirming again here could send it twice.")
    }

    /// Shows a failure that happened before the plan started (a cancelled step-up).
    func fail(_ message: String) {
        guard !isRunning else { return }
        phase = .failed(message)
    }

    func reset() {
        phase = .idle
        events = []
        lastConfirmed = nil
    }
}

/// The background time iOS grants an app that leaves the foreground (about 30 s), held while a plan runs. Ends when
/// the run does, or when the time is up — after `onExpire`, when given.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String, onExpire: (@MainActor () -> Void)? = nil) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                let held = self // `onExpire` may drop the last other reference; the task must still be handed back
                onExpire?()
                held?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

extension TransactionSender.FeePreview {
    /// "Up to 0.061 MON", plus any steps that can only be priced once an earlier one lands (a swap after its approval),
    /// in the app's language. The step count is a plural.
    var summary: String {
        let fee = "\(NumberStyle.units(maxFee, decimals: 18)) \(NetworkFeeLimits.nativeSymbol(chainId: chainId))"
        if unestimated == 0 { return tr("Up to \(fee)") }
        if maxFee == 0 { return tr("Priced as each step is signed") }
        return tr("Up to \(fee) + \(unestimated) more steps")
    }
}

/// What a confirmed transaction did, when its caller can tell (a Perpl order's receipt, decoded): the sheet's bottom bar
/// and a section under Progress say it, and its tone sets the haptic.
struct SettledLine: Equatable {
    let text: PerplOutcomeText
    /// A link to more about it, when there is one.
    let link: URL?
}

/// The standard confirm → progress → done sheet used by every write in the app. The step plan is built by an
/// async closure (some builders read the chain or an actor-isolated service), so the sheet shows a brief
/// "Preparing" state, then the confirm button, then live progress.
///
/// The title and the confirm button's title are localizable resources written in the code ("Buy \(symbol)"): the
/// confirm title is also the App Lock prompt's reason, which iOS takes as a `String`, so both resolve through `tr()`.
struct ConfirmationSheet<Details: View>: View {
    let title: LocalizedStringResource
    let confirmTitle: LocalizedStringResource
    var build: () async throws -> [TransactionStep]
    /// The caller's cleanup (clear the form, reload) once the plan settled: on Done, or when the settled sheet is
    /// swiped away.
    let onDone: () -> Void
    /// Fired once with the settled transaction hash the moment the plan settles, for callers that log the action or
    /// record it — not on Done, so a swipe-dismiss or an OS kill on the Done screen can't lose it (GL-3).
    var onCompleted: ((Data) -> Void)? = nil
    /// When set, the confirmed step's "View" control calls this with the tx hash instead of opening the block
    /// explorer — the launch flow uses it to route to the in-app coin page.
    var onView: ((Data) -> Void)? = nil
    /// What the plan does, for a passkey account's session scope (MERA-PLAN §3). A sheet that declares nothing asks
    /// for Face ID every time; other accounts ignore it.
    var intent: Mera.Intent = .ask
    /// Called right before the plan starts, once App Lock and any passkey approval passed: what the caller expects of it
    /// can be noted from here (a Perps order's fill, so the app-wide watcher waits for the order's own result).
    var onStarted: (() -> Void)? = nil
    /// Reads what the settled transaction did, when the caller can tell (a Perpl order's receipt). With it, "done" waits for
    /// the result: the bottom bar says the result is being read (Done held for up to 2 s, then offered), then shows it;
    /// the confirmed step reads as a plain confirmation on Monad (the result carries the tone), and the haptic follows the
    /// result's tone instead of a plain success. It runs in a task of its own that outlives the sheet (GL-3).
    var settle: ((Data) async -> SettledLine?)? = nil
    @ViewBuilder var details: Details

    init(title: LocalizedStringResource, confirmTitle: LocalizedStringResource, build: @escaping () async throws -> [TransactionStep],
         onDone: @escaping () -> Void, onCompleted: ((Data) -> Void)? = nil, onView: ((Data) -> Void)? = nil, intent: Mera.Intent = .ask,
         onStarted: (() -> Void)? = nil, settle: ((Data) async -> SettledLine?)? = nil, @ViewBuilder details: () -> Details) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.build = build
        self.onDone = onDone
        self.onCompleted = onCompleted
        self.onView = onView
        self.intent = intent
        self.onStarted = onStarted
        self.settle = settle
        self.details = details()
    }

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var steps: [TransactionStep] = []
    @State private var buildError: String?
    @State private var preparing = true
    /// A passkey account's badge: prompt-free in the live session, or Face ID and why. Re-read when the session opens
    /// or ends, so expiry changes the badge and the button in place — no pop-up, and nothing typed is lost.
    @State private var assessment: MeraSession.Assessment?
    @State private var approving = false
    /// `onCompleted` fired / `onDone` ran: each once per sheet.
    @State private var completed = false
    @State private var cleanedUp = false
    /// The most the plan's network fees can come to at today's fees, read once the plan is built (IOST-1).
    @State private var fee: TransactionSender.FeePreview?
    /// Who the plan's exact approvals take a standing unlimited allowance away from, read once the plan is built (IOST-14).
    @State private var replacedUnlimited: [String] = []
    /// What the settled transaction did (`settle`), once read; nil while it is read, or without `settle`.
    @State private var settled: SettledLine?
    /// The receipt is being read now, and Done is held for the first moments of it (`ReceiptResultBar.doneHold`): the
    /// result usually shows first.
    @State private var reading = false
    @State private var holdingDone = false

    private var confirmLabel: Text {
        session.isPasskeyAccount && assessment?.needsFaceID == true ? Text("Confirm with \(BiometricGate.promptName)") : Text(verbatim: tr(confirmTitle))
    }

    var body: some View {
        NavigationStack {
            List {
                Section { details }
                if !unlimitedApprovals.isEmpty, !run.isDone {
                    Section {
                        ForEach(unlimitedApprovals, id: \.self) { DetailRow("Approval", "Unlimited approval to \($0)", tint: .attention) }
                    }
                }
                if !replacedUnlimited.isEmpty, !run.isDone {
                    Section {
                        ForEach(replacedUnlimited, id: \.self) { DetailRow("Approval", "Replaces your unlimited approval to \($0)") }
                    } footer: {
                        Paragraph("An earlier approval lets it spend any amount. This plan approves exactly what it needs instead.")
                    }
                }
                if let fee, !run.isDone {
                    Section {
                        DetailRow("Max network fee", fee.summary)
                    } footer: {
                        Paragraph("The most the network can charge. Each transaction's fee is checked again before it's signed, and refused if it's unusually high.")
                    }
                }
                if session.isPasskeyAccount, !preparing, buildError == nil, !run.isRunning, !run.isDone, let assessment {
                    Section { SessionScopeBadge(assessment: assessment) }
                }
                if preparing {
                    Section {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing transaction").foregroundStyle(.secondary) }
                    }
                }
                if let buildError {
                    Section { InlineError(message: buildError) }.listRowBackground(Color.clear)
                }
                if !run.events.isEmpty {
                    Section("Progress") { TransactionProgress(events: run.events, onView: onView, neutralConfirmation: settle != nil) }
                }
                if let settled {
                    PerpOrderOutcomeSection(text: settled.text, link: settled.link)
                }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(run.isDone ? "Done" : "Cancel") { finish() }
                    .disabled(run.isRunning || holdingDone)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isDone, settle != nil {
                        // The result is read from the receipt: "done" says what the transaction did, not only that it ran.
                        ReceiptResultBar(settled: settled?.text, reading: reading, holdingDone: holdingDone) { finish() }
                    } else if run.isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                    } else if case .failed = run.phase, run.sentSomething {
                        // Something already reached the network: no re-confirm from this sheet (it would replay the
                        // plan from its first step). Check the sent step with View, then start again from the form.
                        Text(TransactionRun.alreadySent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    } else if !session.canSign {
                        Paragraph(SessionError.readOnly.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        PrimaryButton(title: confirmLabel, isBusy: run.isRunning || approving, isDisabled: preparing || steps.isEmpty || buildError != nil || assessment?.isRefused == true) {
                            Task { await confirm() }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            // Only while running (and while Done is held for the result). A settled sheet may be swiped away: the action
            // was recorded when it settled, and `onDisappear` runs the cleanup Done would have.
            .interactiveDismissDisabled(run.isRunning || holdingDone)
        }
        .onChange(of: run.doneHash) { _, hash in
            guard let hash, !completed else { return }
            completed = true
            // The plan changed what is on chain (a buy, a sell, a launch, a collect, a claim, a swap): every read the
            // screens share is read again (`AppEnvironment.invalidateChainReads`), before the caller records or reloads.
            env.invalidateChainReads()
            onCompleted?(hash)
            guard let settle else { return }
            reading = true
            holdingDone = true
            Task { @MainActor in
                try? await Task.sleep(for: ReceiptResultBar.doneHold)
                holdingDone = false
            }
            // Its own task, with its own background time: a dismissed sheet or a phone locked now still reads the result
            // and upgrades what `onCompleted` recorded (GL-3).
            Task { @MainActor in
                let background = BackgroundTime("Perpl result") // not localized: the background task's name, never shown
                defer { background.end() }
                let line = await settle(hash)
                settled = line
                reading = false
                holdingDone = false
                if let line { AccessibilityNotification.Announcement(line.text.headline).post() }
            }
        }
        .onDisappear { cleanUp() }
        // A Moment link never tears a review down, running or not (RootView's link gate).
        .holdsMomentLinks()
        .presentationDetents([.medium, .large])
        // Opaque on purpose: the list fades under the footer, and a translucent sheet would show the presenting
        // screen's dark primary button through that fade.
        .presentationBackground(Color(.systemGroupedBackground))
        // A plain success only when there is no result to read; otherwise the result's tone, once read.
        .sensoryFeedback(trigger: run.isDone) { _, done in done && settle == nil ? .success : nil }
        .sensoryFeedback(trigger: settled?.text.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        .task {
            do { steps = try await build() } catch { buildError = describe(error) }
            preparing = false
            if buildError == nil, let address = session.address {
                fee = await env.sender.feePreview(steps, from: address)
                replacedUnlimited = await env.sender.unlimitedAllowancesReplaced(by: steps, owner: address).map(Self.spenderName)
            }
        }
        .task(id: scopeKey) { await reassess() }
    }

    /// Who the plan approves for an effectively unlimited amount (IOST-14). The app's own plans approve exact amounts;
    /// this keeps one that doesn't from being signed unseen.
    private var unlimitedApprovals: [String] {
        steps.compactMap { step in
            switch step.kind {
            case .approve(_, let spender, let amount), .permit2Approve(_, let spender, let amount, _):
                return amount >= TransactionSender.unlimitedAllowance ? Self.spenderName(spender) : nil
            case .call:
                return nil
            }
        }
    }

    /// The spender's name in "Unlimited approval to …": the contracts' own names are never translated, and the two
    /// that read with "the" are in the app's language.
    static func spenderName(_ spender: Address) -> String {
        switch spender {
        case Uniswap.permit2: return "Permit2" // not localized: a contract's name
        case Uniswap.universalRouter:
            return tr(LocalizedStringResource("the Uniswap Universal Router", comment: "Completes “Unlimited approval to %@” and “Replaces your unlimited approval to %@”."))
        case Uniswap.swapRouter02: return "Uniswap SwapRouter02" // not localized: a contract's name
        case MondayTrade.swapRouter: return "Monday Trade" // not localized: a venue's name
        case Kuru.entrypoint: return "Kuru Flow" // not localized: a venue's name
        case Perpl.exchange:
            return tr(LocalizedStringResource("the Perpl Exchange", comment: "Completes “Unlimited approval to %@” and “Replaces your unlimited approval to %@”."))
        default: return spender.short
        }
    }

    /// Changes whenever the badge could: the plan arrives, or the passkey session opens, ends or is replaced.
    private var scopeKey: String {
        "\(preparing)-\(session.mera.isUnlocked)-\(session.mera.expiresAt?.timeIntervalSince1970 ?? 0)"
    }

    private func reassess() async {
        guard session.isPasskeyAccount, !preparing, buildError == nil else { assessment = nil; return }
        assessment = await session.mera.assess(steps, intent: intent, chainId: env.sender.chainId)
    }

    /// App Lock (never for a passkey account), then — when the badge says Face ID — the passkey prompt straight from
    /// the tap, approving this plan; then the plan. A passkey account whose badge said "No Face ID needed" signs in its
    /// session, and the wallet still checks every transaction: one that fails asks for Face ID right there.
    private func confirm() async {
        if settings.appLockApplies(to: session.account) {
            // App Lock fails closed. Without a device passcode nothing can confirm the owner: say so, not a dead button.
            guard BiometricGate.canAuthenticateOwner else { run.fail(tr("App Lock needs a device passcode. Set one in iOS Settings, then try again.")); return }
            guard await BiometricGate.authenticate(reason: "Confirm \(tr(confirmTitle))") else { return }
        }
        guard session.isPasskeyAccount else {
            onStarted?()
            run.start(steps, session: session, sender: env.sender)
            return
        }
        let action = MeraSession.Action(intent)
        if assessment?.needsFaceID == true {
            approving = true
            defer { approving = false }
            do {
                try await session.mera.approve(action)
            } catch where isUserCancellation(error) {
                run.fail(TransactionRun.notSent)
                return
            } catch {
                run.fail(describe(error))
                return
            }
        }
        onStarted?()
        run.start(steps, session: session, sender: env.sender, action: action)
    }

    /// Dismiss and, when the plan settled, run the caller's cleanup. `onCompleted` already ran at settlement, before
    /// this on purpose: callers clear their input in `onDone`, and `onCompleted` reads that live input to record the
    /// action, so it must see the amount before it is cleared.
    private func finish() {
        dismiss()
        cleanUp()
    }

    private func cleanUp() {
        guard run.isDone, !cleanedUp else { return }
        cleanedUp = true
        onDone()
    }
}
