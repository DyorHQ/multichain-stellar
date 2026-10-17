// Stellar copy of ios/DyorHQ/Wallet/TransactionRun.swift ConfirmationSheet (42cd8c7 sha256:102b8f61ad33)
// The Stellar review sheet (docs/DESIGN-stellar-parity.md §8.7, §4.6). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// The confirm → progress → done sheet of every Stellar write, as Monad's `ConfirmationSheet` is of every Monad one. The
/// plan is built by an async closure (`LiteStore`'s `…Plan` calls: verified and priced on the phone), so the sheet shows
/// "Preparing transaction" first, then the review, the Confirm button, and live progress.
///
/// The review shows what the transaction is bound to, from the plan itself (§5.2): every amount the user pays ("You pay",
/// or "You pay at most" where the contract may take less), the minimum it must bring back ("Minimum"), the account it
/// pays (`intent.to`, unless the plan may pay only the user's own) and its memo. The caller's `details` add what the
/// plan can't say (a route, a rate); Swap's review puts them in Monad's order instead (`receives`). Then each asset the
/// plan enables and its reserve, any archived data it restores, the most its network fees can come to (or, when the
/// phone checked it, that DyorHQ pays), and whether the account's XLM covers it all.
///
/// Signing follows Monad's Confirm (decision 6): Confirm runs the plan (`LiteStore.run`), whose key provider asks for Face
/// ID or the passcode once, only while App Lock applies, for a seed account, and for the passkey once per signed step for
/// a passkey account. The sheet adds no prompt of its own. A cancelled prompt leaves the sheet as it was: nothing was sent.
/// Notifications come from the store as the plan settles (`LiteSession.onSettled`), never from the sheet.
struct StellarConfirmationSheet<Details: View>: View {
    let title: LocalizedStringResource
    let confirmTitle: LocalizedStringResource
    var build: () async throws -> PreparedAction
    /// The caller's cleanup (clear the form, reload) once the plan settled: on Done, or when the settled sheet is swiped
    /// away.
    let onDone: () -> Void
    /// Fired once with the plan's transactions the moment it settles, not on Done, so a swipe-dismiss or an OS kill on the
    /// Done screen can't lose it (GL-3).
    var onCompleted: (([TxStatus]) -> Void)? = nil
    /// When set, a step's "View" calls this with the transaction's hash instead of opening StellarExpert.
    var onView: ((String) -> Void)? = nil
    /// The caller's own guard on the built plan (a Moment's terms that changed since the form was filled, §8.11.4): its
    /// message, and Confirm stays off; nil when the plan may go.
    var check: ((PreparedAction) -> LocalizedStringResource?)? = nil
    /// Swap's review (§8.6.1): what the quote brings, shown in Monad's swap order. The plan's spends ("You pay"), then
    /// "You receive" with this amount, then the plan's minimum as "Minimum received", then `details`. Nil for every other
    /// review: `details`, then the plan's rows.
    var receives: String? = nil
    @ViewBuilder var details: Details

    init(title: LocalizedStringResource, confirmTitle: LocalizedStringResource, build: @escaping () async throws -> PreparedAction,
         onDone: @escaping () -> Void, onCompleted: (([TxStatus]) -> Void)? = nil, onView: ((String) -> Void)? = nil,
         check: ((PreparedAction) -> LocalizedStringResource?)? = nil, receives: String? = nil, @ViewBuilder details: () -> Details) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.build = build
        self.onDone = onDone
        self.onCompleted = onCompleted
        self.onView = onView
        self.check = check
        self.receives = receives
        self.details = details()
    }

    @Environment(Session.self) private var session
    @Environment(\.stellarSession) private var stellar
    @Environment(\.stellarActions) private var actions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var run = StellarReviewRun()
    @State private var action: PreparedAction?
    @State private var buildError: String?
    @State private var preparing = true
    /// Where the sheet's own read of the account stands: the preflight, and Confirm, wait for one that went through.
    @State private var accountCheck = AccountCheck.reading
    /// Counts the sheet's reads of the account: when two overlap, the later one decides.
    @State private var accountReads = 0
    /// `onCompleted` fired / `onDone` ran: each once per sheet.
    @State private var completed = false
    @State private var cleanedUp = false

    /// The sheet's read of the account's XLM (§4.6): on appear, and again on return to the app.
    private enum AccountCheck { case reading, read, failed }

    private var store: LiteStore? { stellar?.store }
    private var isPasskey: Bool { session.isPasskeyAccount }

    /// The caller's guard, on the plan built.
    private var checkFailure: LocalizedStringResource? { action.flatMap { check?($0) } }

    /// What the account's XLM can't cover (§4.6), once the sheet's own read of the account went through; nil when it covers
    /// the plan, and until then (Confirm stays off meanwhile).
    private var shortage: StellarXLMShortage? {
        guard accountCheck == .read, let action, let store, let position = store.account?.xlm.flatMap({ XLMReserve($0) }) else { return nil }
        return StellarXLMShortage.of(fees: action.fees, limits: action.limits, position: position, estimates: store.fees,
                                     isXLM: { Self.isXLM($0, store: store) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let receives {
                        // Monad's swap rows, in Monad's order.
                        if let action { StellarBoundRows(action: action, store: store, parts: [.spends]) }
                        DetailRow("You receive", verbatim: receives)
                        if let action { StellarBoundRows(action: action, store: store, parts: [.minimums], minimumReceived: true) }
                        details
                        if let action { StellarBoundRows(action: action, store: store, parts: [.destination]) }
                    } else {
                        details
                        if let action { StellarBoundRows(action: action, store: store) }
                    }
                } header: {
                    if AppNetwork.stellar.isTestnet { StellarNetworkLine() }
                } footer: {
                    if action != nil, !run.isDone {
                        Paragraph(LocalizedStringResource("Your phone checks every transaction against this review before it signs, and refuses anything else.", table: "StellarReview", comment: "The Stellar review sheet, under what the transaction does: the phone signs only what this review shows"))
                    }
                }
                if let action, !run.isDone {
                    enableSection(action)
                    restoreSection(action)
                    feeSection(action)
                }
                if let shortage, !run.isRunning, !run.isDone {
                    shortageSection(shortage)
                }
                if action != nil, !run.isRunning, !run.isDone {
                    accountCheckSection
                }
                if let checkFailure, !run.isDone {
                    Section { InlineError(message: checkFailure) }.listRowBackground(Color.clear)
                }
                if preparing {
                    Section {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing transaction").foregroundStyle(.secondary) }
                    }
                }
                if let buildError {
                    Section { InlineError(message: buildError) }.listRowBackground(Color.clear)
                }
                if !run.progress.isEmpty {
                    Section("Progress") { StellarTransactionProgress(steps: run.progress.steps, onView: onView) }
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
                        .disabled(run.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                    } else if case .failed = run.phase, run.progress.reachedNetwork {
                        // Something already reached the network: no Confirm again from this sheet (it would start the plan
                        // over). Check the sent step with View, then start again from the form.
                        Text(TransactionRun.alreadySent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    } else if stellar?.canSign == false {
                        Paragraph(SessionError.readOnly.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        if isPasskey, let steps = action?.plan.steps.count, steps > 1, !run.isRunning {
                            // Seed accounts get no such line: one Confirm covers every step, as on Monad.
                            Text("\(steps) steps · each asks for your passkey", tableName: "StellarReview", comment: "The Stellar review, above Confirm, on a passkey account: how many transactions the action signs, each with its own passkey prompt")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        PrimaryButton(title: Text(verbatim: tr(confirmTitle)), isBusy: run.isRunning,
                                      isDisabled: preparing || action == nil || buildError != nil || checkFailure != nil
                                          || accountCheck != .read || shortage != nil) {
                            Task { await confirm() }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            // Only while running. A settled sheet may be swiped away: `onCompleted` ran when it settled, and `onDisappear`
            // runs the cleanup Done would have.
            .interactiveDismissDisabled(run.isRunning)
        }
        .onDisappear { cleanUp() }
        // A Moment link never tears a review down, running or not (RootView's link gate).
        .holdsMomentLinks()
        .presentationDetents([.medium, .large])
        // Opaque on purpose: the list fades under the footer, and a translucent sheet would show the presenting screen's
        // dark primary button through that fade.
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: run.isDone) { _, done in done }
        .sensoryFeedback(.error, trigger: run.failures)
        .task {
            do { action = try await build() } catch { buildError = LiteErrorText.describe(error) }
            preparing = false
        }
        // A fresh read of the account's XLM for the preflight, alongside the plan's build: the review never decides from a
        // stale balance, or from none.
        .task { await readAccount() }
        // Back from Deposit, or from anywhere else: the account is read again, and the preflight with it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !run.isRunning, !run.isDone else { return }
            Task { await readAccount() }
        }
    }

    /// Reads the account again for the preflight. The store keeps its last figures when a read fails, and says that one
    /// went through only by moving `LiteStore.updatedAt` (which a holdings read landing meanwhile moves too): Confirm waits
    /// for that, and a read that failed says so, with Try Again.
    private func readAccount() async {
        accountReads += 1
        let read = accountReads
        accountCheck = .reading
        guard let store else {
            accountCheck = .failed
            return
        }
        let started = Date()
        await store.refreshAccount()
        guard read == accountReads else { return }
        accountCheck = store.updatedAt.map { $0 >= started } == true ? .read : .failed
    }

    // MARK: Sections

    /// Each asset the plan enables (a trustline), before the action, with what it holds of the account's XLM, or, for the
    /// account's setup as the phone checked it (§4.3), that DyorHQ pays it.
    @ViewBuilder private func enableSection(_ action: PreparedAction) -> some View {
        let enables = action.plan.steps.filter(Self.enables)
        if !enables.isEmpty {
            let reserve = baseReserve.map { StellarFormat.units($0) }
            Section {
                ForEach(enables) { step in
                    let code = Self.code(of: step)
                    DetailRow(Text("Enable", tableName: "StellarReview", comment: "The Stellar review: a row for an asset this transaction enables (a Stellar trustline), so the account can hold it. The value is the asset's code (USDC)"),
                              Text(verbatim: code))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(reserve.map { Text("Enable \(code). Holds \($0) XLM while enabled.", tableName: "StellarReview", comment: "VoiceOver: the review's row for an asset this transaction enables. The first value is its code (USDC), the second an amount of XLM (0.5)") }
                            ?? Text(verbatim: code))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(enables) { step in
                        // The setup's reserve is the sponsor's, never the account's balance.
                        if case .dyorHQ(.setup)? = action.fees.step(step.id)?.payer {
                            Paragraph(LocalizedStringResource("DyorHQ pays this reserve.", table: "StellarReview", comment: "The Stellar review on mainnet, under the asset the account's setup enables: DyorHQ pays the XLM Stellar holds for it. DyorHQ is never translated"))
                        } else if let reserve {
                            Paragraph(LocalizedStringResource("Stellar holds \(reserve) XLM of your balance while \(Self.code(of: step)) is enabled. It's returned if you remove it.", table: "StellarReview", comment: "The Stellar review, under an asset this transaction enables: the minimum balance Stellar keeps for it. The first value is an amount of XLM (0.5), the second the asset's code (USDC)"))
                        }
                    }
                }
            }
        }
    }

    /// Each archived entry the plan brings back first, paid by the user like any other step (§4.9).
    @ViewBuilder private func restoreSection(_ action: PreparedAction) -> some View {
        let restores = action.plan.steps.filter { Self.kind(of: $0) == "restore" }
        if !restores.isEmpty {
            Section {
                ForEach(restores) { step in
                    Text("Restore archived data for \(Self.restored(step))", tableName: "StellarReview", comment: "The Stellar review: a step that first brings back data the Stellar network archived. The value is what it belongs to (a coin's symbol, an asset's code)")
                }
            }
        }
    }

    /// The most the plan's network fees can come to, or that DyorHQ pays, as the phone checked it (§4.3, §4.6).
    @ViewBuilder private func feeSection(_ action: PreparedAction) -> some View {
        let summary = StellarFeeSummary(action.fees)
        Section {
            DetailRow(Text("Max network fee"), Text(verbatim: StellarFormat.feeSummary(summary)))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if summary.value != .paidByDyorHQ {
                    Paragraph("The most the network can charge. Each transaction's fee is checked again before it's signed, and refused if it's unusually high.")
                }
                switch summary.sponsorReason {
                case .setup?:
                    Paragraph(LocalizedStringResource("DyorHQ pays this one: your account's setup.", table: "StellarReview", comment: "The Stellar review, under the network fee DyorHQ pays: it pays the fee of the account's setup only. DyorHQ is never translated"))
                case .starterSwap?:
                    Paragraph(LocalizedStringResource("DyorHQ pays this one: your first swap into XLM. After it, you pay each network fee in XLM.", table: "StellarReview", comment: "The Stellar review, under the network fee DyorHQ pays for an account's first swap into XLM (it holds none yet): after it the user pays their own fees. DyorHQ and XLM are never translated"))
                case nil:
                    EmptyView()
                }
            }
        }
    }

    /// The account's XLM doesn't cover the plan: Monad's "Not enough MON to pay for gas.", with the way to add some. Confirm
    /// stays off until a read of the account says it does.
    @ViewBuilder private func shortageSection(_ shortage: StellarXLMShortage) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if shortage.fee {
                    InlineError(message: LocalizedStringResource("Not enough XLM for the network fee.", table: "StellarReview", comment: "The Stellar review: the account's XLM can't pay this transaction's network fee (and what it spends). XLM is never translated"))
                } else {
                    InlineError(message: LocalizedStringResource("Not enough XLM for Stellar's minimum balance.", table: "StellarReview", comment: "The Stellar review: the account's XLM pays the fee, but not the minimum balance Stellar keeps for what this transaction adds. Stellar and XLM are never translated"))
                }
                Paragraph(LocalizedStringResource("You need about \(StellarFormat.units(shortage.need)) XLM and can spend \(StellarFormat.units(shortage.spendable)) XLM. Your account keeps \(StellarFormat.units(shortage.minBalance)) XLM to stay open.", table: "StellarReview", comment: "The Stellar review, when the account's XLM is short. The values are amounts of XLM: what the transaction needs, what the account can spend, and the minimum balance Stellar keeps in it"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Haptics.tap()
                    actions.addFunds()
                } label: {
                    Text("Add XLM", tableName: "StellarReview", comment: "Button in the Stellar review when the account's XLM is short: opens Deposit to add XLM. XLM is never translated")
                }
                .buttonStyle(.bordered)
            }
        }
        .listRowBackground(Color.clear)
    }

    /// The sheet's read of the account, while it is under way or when it failed: Confirm waits for it either way.
    @ViewBuilder private var accountCheckSection: some View {
        switch accountCheck {
        case .reading:
            Section {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your balances…").foregroundStyle(.secondary) }
            }
        case .failed:
            Section {
                InlineError(message: "Couldn’t check your wallet’s balance. Check your connection and try again.")
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await readAccount() } }
            }
        case .read:
            EmptyView()
        }
    }

    // MARK: Running

    /// The plan, through the store's own task (it goes on if the sheet closes, and settles once): the key provider asks
    /// what Monad's Confirm would (App Lock once when it applies, or the passkey per step), with the confirm title as the
    /// prompt's reason.
    private func confirm() async {
        guard let action, let store, !run.isRunning else { return }
        let reason = tr("Confirm \(tr(confirmTitle))")
        let results = await run.start(action, store: store, reason: reason, passkey: isPasskey)
        guard let results, !completed else { return }
        completed = true
        onCompleted?(results)
    }

    /// Dismiss and, when the plan settled, run the caller's cleanup. `onCompleted` already ran at settlement, before this on
    /// purpose: callers clear their input in `onDone`, and `onCompleted` may read that live input to record the action.
    private func finish() {
        dismiss()
        cleanUp()
    }

    private func cleanUp() {
        guard run.isDone, !cleanedUp else { return }
        cleanedUp = true
        onDone()
    }

    // MARK: Reading the plan

    /// The ledger's base reserve, in stroops, from the last read of the fees or the account.
    private var baseReserve: Int64? {
        store?.fees.flatMap { Int64($0.baseReserve) } ?? store?.account?.xlm.flatMap { Int64($0.baseReserve) }
    }

    /// What a step does: its fee kind, or its intent's kind.
    static func kind(of step: PlanStep) -> String? { step.stepKind ?? step.intent?.kind }

    /// Whether a step enables an asset: a trust step, or the account's setup, which enables USDC with the account
    /// (`activate`, mainnet).
    static func enables(_ step: PlanStep) -> Bool {
        switch kind(of: step) {
        case "trust": true
        case "activate": !(step.intent?.trust ?? []).isEmpty
        default: false
        }
    }

    /// The code of the asset a trust step enables.
    static func code(of step: PlanStep) -> String {
        if case .string(let asset)? = step.intent?.display?["asset"], !asset.isEmpty { return asset }
        if let trust = step.intent?.trust?.first {
            return trust == "native" ? "XLM" : String(trust.split(separator: ":").first ?? Substring(trust))
        }
        return step.label
    }

    /// What a restore step brings back, as its intent names it.
    static func restored(_ step: PlanStep) -> String {
        for key in ["symbol", "asset", "name"] {
            if case .string(let name)? = step.intent?.display?[key], !name.isEmpty { return name }
        }
        return step.label
    }

    /// Whether `id` (a limit's asset: a registry id or its contract) is XLM.
    static func isXLM(_ id: String, store: LiteStore) -> Bool {
        id == "XLM" || id == "native" || store.asset("XLM")?.contract == id
    }
}

extension StellarFormat {
    /// The Max network fee row's value when the phone checked that DyorHQ pays every step of the plan (§4.3): written
    /// only here, with the review's sponsored rows.
    static var sponsoredFee: String {
        liteTr(LocalizedStringResource("Paid by DyorHQ", table: "StellarReview", comment: "The review's Max network fee row, when DyorHQ pays this transaction's network fee (a new account's setup, or a first swap into XLM). DyorHQ is never translated"))
    }
}

/// Where the review's run stands: Monad's `TransactionRun`, for a Stellar plan.
@Observable
@MainActor
final class StellarReviewRun {
    enum Phase: Equatable { case idle, running, done, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var progress = StellarPlanProgress()
    /// Counts failures, for the error haptic.
    private(set) var failures = 0

    var isRunning: Bool { phase == .running }
    var isDone: Bool { phase == .done }

    /// Runs `action` and returns its transactions once it settles; nil when it didn't. A plan that sent something is never
    /// started again from the same sheet (`TransactionRun.alreadySent`): a call that already landed would land twice.
    func start(_ action: PreparedAction, store: LiteStore, reason: String, passkey: Bool) async -> [TxStatus]? {
        guard !isRunning else { return nil }
        guard !progress.reachedNetwork else {
            fail(TransactionRun.alreadySent)
            return nil
        }
        phase = .running
        progress = StellarPlanProgress()
        // A lock or an app switch mid-plan suspends it: the time iOS grants lets the step in flight still be sent and seen
        // (GL-2).
        let background = BackgroundTime("Transaction") // not localized: the background task's name, never shown
        defer { background.end() }
        do {
            let results = try await store.run(action, reason: reason) { event in
                Task { @MainActor in self.record(event, action: action, passkey: passkey) }
            }
            phase = .done
            return results
        } catch where Self.isCancellation(error) {
            // A prompt the person dismissed: say plainly what did and didn't happen.
            fail(progress.reachedNetwork ? tr("Stopped at \(BiometricGate.promptName). Only the steps above were sent.") : TransactionRun.notSent)
        } catch {
            fail(LiteErrorText.describe(error, for: action))
        }
        return nil
    }

    private func record(_ event: PlanRunner.Event, action: PreparedAction, passkey: Bool) {
        let id: String
        switch event {
        case .building(let step, _), .signing(let step, _), .submitted(let step, _), .confirmed(let step, _): id = step
        }
        let title = action.plan.steps.first { $0.id == id }.map(action.title(of:)) ?? action.title
        progress.apply(event, title: title, passkey: passkey)
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        failures += 1
    }

    /// A Face ID, passcode or passkey prompt the person dismissed: nothing was signed by it.
    static func isCancellation(_ error: Error) -> Bool {
        (error as? LiteSession.Failure) == .cancelled || error is CancellationError
    }
}

/// What the account's XLM can't cover in a plan, before anything is signed (§4.6): the counterpart of Monad's "Not enough
/// MON to pay for gas."
struct StellarXLMShortage: Equatable {
    /// The network fee (with the XLM the plan spends) can't be paid; false when only the reserves it adds can't be held.
    let fee: Bool
    /// About what the plan needs, in stroops: the user's fees, the XLM it spends and the reserves it adds.
    let need: Int64
    let spendable: Int64
    /// What the account keeps to stay open.
    let minBalance: Int64

    /// Nil when `position` covers a plan's `fees` and the XLM among its `limits` (`PreparedAction`'s): a built step counts
    /// its own fee, an unbuilt one its estimate (`estimates`, or the shipped defaults), and DyorHQ's verified steps nothing.
    static func of(fees plan: PlanFees, limits: [String: Int64], position: XLMReserve, estimates: StellarFees?,
                   isXLM: (String) -> Bool) -> StellarXLMShortage? {
        var fees: Int64 = 0
        for step in plan.steps where step.payer == .user {
            let estimate = step.stepKind.flatMap { estimates?.estimate($0) ?? StellarFeeDefaults.estimate($0) }
            fees = sum(fees, step.built ? step.maxFee : estimate ?? step.maxFee)
        }
        let spent = limits.filter { isXLM($0.key) }.values.reduce(Int64(0)) { sum($0, max(0, $1)) }
        let payable = sum(fees, spent)
        let need = sum(payable, position.reserves(plan.newReserves))
        guard position.spendable < need else { return nil }
        return StellarXLMShortage(fee: position.spendable < payable, need: need, spendable: position.spendable, minBalance: position.minBalance)
    }

    private static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }
}

/// The review's rows that come from the plan itself, as the phone checks it before signing (§5.2): what the user pays,
/// the least it must bring back, the account it pays and its memo. Never a display string the server chose.
struct StellarBoundRows: View {
    /// The plan's rows, in the order they show.
    enum Part { case spends, minimums, destination }

    let action: PreparedAction
    let store: LiteStore?
    /// The rows shown: every one, unless a review places them among its own (Swap's, in Monad's order).
    var parts: Set<Part> = [.spends, .minimums, .destination]
    /// The minimum's label: Monad's swap says "Minimum received"; every other review "Minimum".
    var minimumReceived = false

    var body: some View {
        if parts.contains(.spends) {
            ForEach(spends, id: \.asset) { spend in
                DetailRow(spend.atMost
                          ? Text("You pay at most", tableName: "StellarReview", comment: "The Stellar review: the most this transaction may spend of an asset (the contract may take less)")
                          : Text("You pay"),
                          Text(verbatim: StellarFormat.amount(spend.units, code: code(spend.asset))))
            }
        }
        if parts.contains(.minimums) {
            ForEach(minimums, id: \.asset) { minimum in
                DetailRow(minimumReceived ? Text("Minimum received") : Text("Minimum"), Text(verbatim: StellarFormat.amount(minimum.units, code: code(minimum.asset))))
            }
        }
        if parts.contains(.destination) { destination }
    }

    /// The account the plan pays and its memo. No "To" for a plan the run holds to the user's own account (`.own`, as a
    /// swap's): every step may pay only the user, so there is no other address to check.
    @ViewBuilder private var destination: some View {
        if let to = Self.recipient(action.bindings, intents: intents) {
            // The whole address the transaction pays, never a short form: a look-alike address can share its first and
            // last characters, so the user checks every one (§5.2). Monospaced, selectable, read out character by character.
            LabeledContent {
                if let address = StellarAccountID(to) {
                    StellarAddressText(address, whole: true).foregroundStyle(.secondary)
                } else {
                    // A Monad address (a bridge's): shown as it is, whole.
                    Text(verbatim: to)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(verbatim: to))
                        .speechSpellsOutCharacters()
                }
            } label: {
                Text("To")
            }
            .font(.subheadline)
        }
        if let memo = intents.lazy.compactMap(\.memo).first {
            DetailRow(Text("Memo", tableName: "StellarReview", comment: "The Stellar review: the memo this transaction carries, as the recipient (an exchange, a cash provider) asked for it"),
                      Text(verbatim: memo.value))
                .textSelection(.enabled)
        }
    }

    /// The address the review shows as "To": the first a step's intent names, unless the plan is bound to the user's own
    /// account (`PlanBindings.Destination.own`), under which the run refuses any other address.
    static func recipient(_ bindings: PlanBindings, intents: [Intent]) -> String? {
        guard bindings.destination != .own else { return nil }
        return intents.lazy.compactMap(\.to).first
    }

    private var intents: [Intent] { action.plan.steps.compactMap(\.intent) }

    private struct Line: Equatable {
        let asset: String
        let units: Int64
        var atMost = false
    }

    /// Every limit the user confirms (`PreparedAction.limits`): exact, unless a step that spends it may take less (a
    /// curve buy refunds what the curve didn't use; a launch's developer buy likewise).
    private var spends: [Line] {
        action.limits.sorted { $0.key < $1.key }.map { asset, units in
            let atMost = action.plan.steps.contains { step in
                guard let intent = step.intent, intent.spend[asset] != nil else { return false }
                return ["launch_buy", "launch_create"].contains(intent.kind)
            }
            return Line(asset: asset, units: units, atMost: atMost)
        }
    }

    /// The least each asset must bring back, from the last step that names it (`intent.receive`).
    private var minimums: [Line] {
        var found: [String: Int64] = [:]
        for intent in intents {
            for (asset, text) in intent.receive ?? [:] { if let units = Int64(text), units > 0 { found[asset] = units } }
        }
        return found.sorted { $0.key < $1.key }.map { Line(asset: $0.key, units: $0.value) }
    }

    /// An asset's code: the registry's, else what a step's intent calls it, else its short contract id.
    private func code(_ asset: String) -> String {
        if let known = store?.asset(asset)?.code { return known }
        for intent in intents {
            let display = intent.display ?? [:]
            if case .string(let token)? = display["token"], token == asset, case .string(let symbol)? = display["symbol"] { return symbol }
        }
        if asset == "native" { return "XLM" }
        return StellarAccountID(asset)?.short ?? asset
    }
}
#endif
