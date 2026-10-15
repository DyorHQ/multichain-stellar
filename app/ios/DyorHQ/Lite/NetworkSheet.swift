// The network sheet: Select, Confirm, Setup (docs/DESIGN-network-switch.md §3.6; Setup's steps, copy and fees,
// docs/DESIGN-stellar-parity.md §8.14). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Observation
import StellarKit
import SwiftUI

/// What opens the network sheet: where from, which decides what happens once a switch is chosen (§2.5), and the step it
/// opens at: Select from the chip and Profile's Network row; Setup where its run is already under way, which the sheet
/// then doesn't start again.
struct NetworkSheetRequest: Identifiable, Equatable {
    enum Origin: Equatable { case home, profile }
    enum Start: Equatable { case select, setup }

    let id = UUID()
    let origin: Origin
    var startAt: Start = .select
}

// MARK: The Stellar session Setup drives

/// The Setup step's vocabulary: DyorLite's `LiteSession` types (§8.3), case for case.
enum NetworkSetup {
    typealias Step = LiteSession.Step
    typealias StepStatus = LiteSession.StepStatus
    typealias Failure = LiteSession.Failure
    typealias Plan = LiteSession.Plan
    typealias State = LiteSession.State
}

/// One step as a session lists it, with its status (`LiteSession.StepRow`).
protocol NetworkSetupStepRow {
    var step: NetworkSetup.Step { get }
    var status: NetworkSetup.StepStatus { get }
}

/// The signed-in account's Stellar session, as the network sheet's Setup step drives it (§3.6.3): DyorLite's
/// `LiteSession`, which `NetworkRoot` keeps per account and hands the sheet through the environment. Observable: the sheet
/// follows `state`, `steps`, `isSending` and the setup's price as they change.
///
/// Nothing unlocks (docs/DESIGN-stellar-parity.md §1.1 decision 6, §8.14). A seed account (an imported phrase or key,
/// email & password) signs in with no prompt, and its Set Up tap asks for Face ID or the passcode once, only when App
/// Lock applies, as a Monad Confirm. A passkey account taps Set Up first, then confirms with its passkey once: that one
/// ceremony signs the sign-in and the account's setup, and its signer goes with the run. Going to the background ends
/// a passkey run ("Not finished. Try again.").
@MainActor
protocol NetworkSetupSession: AnyObject, Observable {
    associatedtype StepRow: NetworkSetupStepRow
    var state: NetworkSetup.State { get }
    /// The steps listed, in order, with their status.
    var steps: [StepRow] { get }
    /// The account setup is being sent: it can't be called back, so ✕ and the swipe are off.
    var isSending: Bool { get }
    /// Stellar's testnet: the account step is Friendbot's one claim of test XLM (decision 7).
    var isTestnet: Bool { get }
    /// Whether a first sign-in needs an invite code, as `/v1/config` says: false on testnet, where Setup has no invite
    /// step at all.
    var inviteRequired: Bool { get }
    /// The Enable USDC step's price: `/v1/fees`' estimate before the Set Up tap, its own transaction's fee once built
    /// (never above the one shown). Nil until the fees are read.
    var setupFee: PlanFees? { get }
    /// The ledger's base reserve in stroops, from `/v1/fees`; nil until read.
    var baseReserve: Int64? { get }
    /// What Friendbot gives a new testnet account, in XLM, as the server's config says it (`faucet.amount`); nil off
    /// testnet and until the config is read.
    var friendbotAmount: String? { get }
    /// What a switch to Stellar needs now. Local: no network, no prompt.
    func plan() -> NetworkSetup.Plan
    /// Check → [sign in] → [set up], from the first unfinished step. Returns once it is ready, waits for the user
    /// (`waiting(.invite)`, `waiting(.setUp)`) or fails; it never prompts before the silent check has passed, and a seed
    /// account's sign-in never prompts at all.
    func run() async
    /// Signs in again with `code` (a passkey account with a new ceremony: the run kept nothing while it waited), then
    /// goes on.
    func join(invite code: String) async
    /// The Set Up tap, which is the confirmation of that write: App Lock when it applies (seed accounts), or the one
    /// passkey ceremony with `code` when a first sign-in on this iPhone needs one (passkey accounts); then the account
    /// and Enable USDC.
    func setUp(invite code: String?) async
    /// The failed step again.
    func retry() async
    /// Stops between steps; what finished is kept (the Stellar address, a saved session).
    func cancel()
}

extension LiteSession.StepRow: NetworkSetupStepRow {}

extension LiteSession: NetworkSetupSession {
    /// Friendbot's amount from the server's config, as the account's store holds it.
    var friendbotAmount: String? { store?.config?.faucet?.amount }
}

extension NetworkSetupSession {
    /// The steps as the session lists them, as rows. Only Sign in, the invite code and the account's setup are listed:
    /// nothing unlocks any more.
    var rows: [NetworkSheetContent.Row] {
        steps.compactMap { row in NetworkSheetContent.RowKind(row.step).map { NetworkSheetContent.Row(kind: $0, status: row.status) } }
    }
}

extension EnvironmentValues {
    /// The signed-in account's Stellar session, for the network sheet's Setup step: `NetworkRoot` sets it, above the
    /// covers, so the sheet has it from Home and from Profile alike. Nil where the account can't use Stellar.
    @Entry var networkSetupSession: (any NetworkSetupSession)? = nil
}

extension NetworkSetup.Failure {
    /// What the sheet says, in the app's language. A key not on this iPhone is said for the account's sign-in method.
    func message(method: Session.Method?) -> String {
        switch self {
        case .offline:
            return tr(LocalizedStringResource("No connection. Check your network and try again.", comment: "An error message: the device is offline, or its connection dropped during the request"))
        case .cancelled:
            return liteTr(LocalizedStringResource("Not finished. Try again.", table: "StellarSetup", comment: "The network sheet's Setup: the passkey, Face ID or passcode prompt was cancelled, or the app went to the background during a passkey run; nothing was sent"))
        case .otherAccountsKey:
            return liteTr(LocalizedStringResource("That passkey is for a different account. Use this account's passkey.", table: "Lite", comment: "The network sheet's Setup: the passkey chosen belongs to another DyorHQ account"))
        case .keyNotOnDevice:
            return (method == .imported ? NetworkAvailability.Reason.importAgain : .signInAgain).message
        case .paused:
            return liteTr(LocalizedStringResource("DyorHQ on Stellar is paused for maintenance. Monad is unaffected.", table: "Lite", comment: "The network sheet's Setup and Stellar Home: DyorHQ's service on the Stellar network is paused; Monad works as usual"))
        case .updateRequired:
            return liteTr(LocalizedStringResource("Update DyorHQ to use Stellar.", table: "Lite", comment: "The network sheet's Setup and Stellar Home: this version of the app is too old for the Stellar service"))
        case .inviteRejected:
            return liteTr(LocalizedStringResource("That code isn't valid, has expired or was already used.", table: "Lite", comment: "The network sheet's invite step, under the field: the invite code was refused"))
        case .accessRevoked:
            return liteTr(LocalizedStringResource("Access to Stellar was turned off for this account.", table: "Lite", comment: "The network sheet's Setup: DyorHQ turned off this account's access to its Stellar service"))
        case .rateLimited:
            return liteTr(LocalizedStringResource("Too many tries. Wait a moment and try again.", table: "Lite", comment: "The network sheet's Setup: the server refused more attempts for now"))
        case .setUpFailed:
            return liteTr(LocalizedStringResource("Couldn't set up your Stellar account. Nothing was spent.", table: "Lite", comment: "The network sheet's Setup: the account setup transaction failed, and it cost the user nothing"))
        case .server(let text):
            return text
        }
    }
}

// MARK: Presenting

extension View {
    /// Presents the network sheet while `request` is set (§3.6). Once a switch is chosen the sheet closes, and `commit` runs
    /// with the network after it has slid down (`onDismiss`): a swap never runs under the sheet (§2.5).
    func networkSheet(_ request: Binding<NetworkSheetRequest?>, commit: @escaping (AppNetwork) -> Void) -> some View {
        modifier(NetworkSheetPresenter(request: request, commit: commit))
    }
}

private struct NetworkSheetPresenter: ViewModifier {
    @Binding var request: NetworkSheetRequest?
    let commit: (AppNetwork) -> Void
    /// The network chosen in the sheet on screen, committed once the sheet has closed.
    @State private var chosen: AppNetwork?

    func body(content: Content) -> some View {
        content.sheet(item: $request, onDismiss: {
            guard let network = chosen else { return }
            chosen = nil
            commit(network)
        }) { request in
            NetworkSheet(request: request) { network in
                chosen = network
                self.request = nil
            }
        }
    }
}

/// The sheet as the app presents it: what it needs, read from the app's environment.
struct NetworkSheet: View {
    let request: NetworkSheetRequest
    let choose: (AppNetwork) -> Void
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @Environment(\.networkSetupSession) private var setup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NetworkSheetContent(
            startAt: request.startAt,
            current: router.network,
            // The control can go while the sheet is up (the owner's switch turned off): the root then closes the sheet.
            availability: LiteGate.availability(session: session) ?? .offered,
            method: session.account?.method,
            introSeen: AppNetwork.stellarIntroSeen(for: session.address),
            setup: setup,
            markIntroSeen: { [address = session.address] in AppNetwork.markStellarIntroSeen(for: address) },
            choose: choose,
            close: { dismiss() }
        )
        // A Moment link or a notification's screen waits until the sheet is gone: a link never tears a setup down.
        .holdsMomentLinks()
    }
}

// MARK: The sheet

/// One sheet whose content moves between Select, Confirm and Setup in place (§3.6), sized to its content: a fitted height
/// up to 85% of the screen, then `.large` with the content scrolling. The header and the primary button stay put.
struct NetworkSheetContent: View {
    enum Step: Hashable { case select, confirm, setup }

    let current: AppNetwork
    let availability: NetworkAvailability
    /// The account's sign-in method: the key-not-on-this-iPhone copy, and a passkey account's own Setup (§8.14).
    let method: Session.Method?
    /// Confirm was already shown to this account on this iPhone (`AppNetwork.stellarIntroSeen`).
    let introSeen: Bool
    let setup: (any NetworkSetupSession)?
    let markIntroSeen: () -> Void
    /// A switch is decided: the presenter closes the sheet and commits it.
    let choose: (AppNetwork) -> Void
    let close: () -> Void
    /// Opened at Setup with the run under way: the run isn't started again.
    private let resumesRun: Bool

    @State private var step: Step
    @State private var selection: AppNetwork
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// The invite code: the invite step's, or the optional one under a passkey account's account step.
    @State private var inviteCode = ""
    @FocusState private var inviteFocused: Bool
    @AccessibilityFocusState private var inviteSpoken: Bool
    @AccessibilityFocusState private var spokenRow: RowKind?
    /// The action tapped last in Setup: its button stays, busy, while the run it started goes on.
    @State private var tapped: SetupAction?
    /// The switch was handed over (or Setup finished): closing the sheet then cancels nothing.
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The status column of Setup's rows, grown with the text.
    @ScaledMetric(relativeTo: .subheadline) private var statusColumn: CGFloat = 24
    /// The symbol column of Confirm's lines.
    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 24
    /// The marks of Select's rows: 36 at the default size, up to 52.
    @ScaledMetric(relativeTo: .body) private var rowMark: CGFloat = 36

    init(startAt: NetworkSheetRequest.Start = .select, current: AppNetwork, availability: NetworkAvailability, method: Session.Method?,
         introSeen: Bool, setup: (any NetworkSetupSession)?, markIntroSeen: @escaping () -> Void,
         choose: @escaping (AppNetwork) -> Void, close: @escaping () -> Void) {
        self.current = current
        self.availability = availability
        self.method = method
        self.introSeen = introSeen
        self.setup = setup
        self.markIntroSeen = markIntroSeen
        self.choose = choose
        self.close = close
        let opensSetup = startAt == .setup && setup != nil
        resumesRun = opensSetup
        _step = State(initialValue: opensSetup ? .setup : .select)
        _selection = State(initialValue: opensSetup ? .stellar : current)
    }

    var body: some View {
        ScrollView {
            stepContent
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) {
            header.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .presentationDetents(usesLarge ? [.large] : [.height(fittedHeight)])
        .presentationDragIndicator(.visible)
        // Opaque: the sheet holds an input, and iOS 26 sheets are translucent otherwise.
        .presentationBackground(Color(.systemBackground))
        .interactiveDismissDisabled(isSending)
        .onChange(of: setup?.state) { old, new in
            guard step == .setup, let new else { return }
            stateChanged(from: old, to: new)
        }
        .onChange(of: rows) { old, new in
            guard step == .setup else { return }
            announceFinishedSteps(old: old, new: new)
        }
        // Closed by ✕ or a swipe in the middle of Setup: the run stops, and what finished is kept.
        .onDisappear { if step == .setup, !finished { setup?.cancel() } }
    }

    // MARK: Layout

    /// The content's measured height, header and button included; about 350 until it is measured.
    private var fittedHeight: CGFloat {
        let measured = headerHeight + contentHeight + footerHeight
        return measured > 0 ? measured : 350
    }

    /// `.large` once the content outgrows 85% of the screen, and while the invite code is typed (the keyboard is up).
    private var usesLarge: Bool {
        inviteFocused || fittedHeight > Self.screenHeight * 0.85
    }

    private static var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? 800
    }

    private func go(to next: Step) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { step = next }
    }

    @ViewBuilder private var header: some View {
        switch step {
        case .select:
            SheetHeader(title: Text("Select network", tableName: "Lite", comment: "The network sheet's title: choose Monad or Stellar"), onClose: close)
        case .confirm:
            SheetHeader(onBack: { go(to: .select) }, onClose: close)
        case .setup:
            SheetHeader(onClose: closeSetup)
                // Not while the account setup is being sent: it can't be called back.
                .disabled(isSending)
        }
    }

    @ViewBuilder private var stepContent: some View {
        Group {
            switch step {
            case .select: selectStep
            case .confirm: confirmStep
            case .setup: setupStep
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder private var footer: some View {
        Group {
            switch step {
            case .select: selectButton
            case .confirm:
                PrimaryButton(title: switchTitle(.stellar)) { confirm() }
            case .setup:
                if let action = setupAction { setupButton(action) }
            }
        }
        .padding(.top, 24).padding(.horizontal, 20).padding(.bottom, 16)
        .background(Color(.systemBackground))
    }

    // MARK: Select (§3.6.1)

    private var selectStep: some View {
        VStack(spacing: 12) {
            ForEach(AppNetwork.allCases) { networkRow($0) }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private func networkRow(_ network: AppNetwork) -> some View {
        let reason = network == .stellar ? availability.reason : nil
        let selected = selection == network
        return Button {
            guard selection != network else { return }
            Haptics.selection()
            selection = network
        } label: {
            HStack(spacing: 14) {
                NetworkMark(network: network, size: min(rowMark, 52))
                    .opacity(reason == nil ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: network.name).font(.body.weight(.semibold))
                        if network.isTestnet { TestnetBadge() }
                    }
                    .opacity(reason == nil ? 1 : 0.5)
                    Paragraph(verbatim: reason?.message ?? network.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if reason != nil {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                } else if selected {
                    Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand)
                }
            }
            .padding(14)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? Color.brand : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        // A Stellar row this account can't use can never be selected; it says why instead.
        .disabled(reason != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenRow(network, reason: reason)))
        .accessibilityValue(network == current ? Text("Current network", tableName: "Lite", comment: "VoiceOver: the value of the network sheet's row for the network on screen now") : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Stellar, test network. Earn, swap, launch and collect": the row's name, badge and line, as one.
    private func spokenRow(_ network: AppNetwork, reason: NetworkAvailability.Reason?) -> String {
        let name = network.isTestnet ? "\(network.name), \(TestnetBadge.spoken)" : network.name
        return "\(name). \(reason?.message ?? network.summary)"
    }

    /// What a switch to Stellar needs; nil without the account's Stellar session, when it can't be made.
    private var stellarPlan: NetworkSetup.Plan? { setup?.plan() }

    /// Confirm comes first on the first switch to Stellar on this iPhone, when the switch needs work (§2.3). An account set
    /// up on this iPhone switches at once (`.instant`), with no Confirm and no Setup.
    private var showsConfirm: Bool { (stellarPlan.map { $0 != .instant } ?? false) && !introSeen }

    private func switchTitle(_ network: AppNetwork) -> Text {
        Text("Switch to \(network.name)", tableName: "Lite", comment: "A button of the network sheet: change the app to that network. %@ is a network's name (Monad, Stellar), not translated")
    }

    @ViewBuilder private var selectButton: some View {
        if selection == current || (selection == .stellar && setup == nil) {
            PrimaryButton(title: Text("Switch network", tableName: "Lite", comment: "The network sheet's button before another network is chosen (unavailable until then)"), isDisabled: true) {}
        } else if selection == .stellar, showsConfirm {
            PrimaryButton(title: Text("Next", tableName: "Lite", comment: "The network sheet's button: on to what changes with the switch to Stellar")) { go(to: .confirm) }
        } else {
            PrimaryButton(title: switchTitle(selection)) { switchFromSelect() }
        }
    }

    private func switchFromSelect() {
        guard selection == .stellar, let plan = stellarPlan, plan != .instant else {
            // Monad, or an account set up on this iPhone: the swap is at once (Stellar Home restores it as it appears).
            hand(selection)
            return
        }
        go(to: .setup)
    }

    // MARK: Confirm (§3.6.2)

    private var confirmStep: some View {
        VStack(spacing: 0) {
            NetworkRoute(from: current, to: .stellar).padding(.top, 4)
            Paragraph(LocalizedStringResource("You're switching networks", table: "Lite", comment: "The title of the network sheet's step that explains the first switch to Stellar"))
                .font(.title2.bold()).multilineTextAlignment(.center)
                .padding(.top, 16).padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 14) {
                confirmLine("square.split.2x1", LocalizedStringResource("Stellar has its own balance and activity. Your Monad funds stay on Monad.", table: "Lite", comment: "The network sheet, before the first switch to Stellar: balances aren't shared between the networks"))
                confirmLine("key", LocalizedStringResource("Same account: your Stellar key comes from the secret you already use.", table: "Lite", comment: "The network sheet, before the first switch to Stellar. “Secret”: the passkey, recovery phrase or password the account uses"))
                confirmLine("fuelpump", LocalizedStringResource("You pay Stellar's network fees in XLM, as you pay MON on Monad.", table: "StellarSetup", comment: "The network sheet, before the first switch to Stellar: every Stellar transaction's network fee is paid by the user in XLM, Stellar's coin, as Monad's are paid in MON, Monad's coin. Stellar, Monad, XLM and MON are never translated"))
                if AppNetwork.stellar.isTestnet {
                    confirmLine("testtube.2", LocalizedStringResource("This is Stellar's testnet. Balances there have no value.", table: "Lite", comment: "The network sheet, before the first switch to Stellar: it runs on Stellar's test network"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 20)
            Paragraph(LocalizedStringResource("You can switch back anytime.", table: "Lite", comment: "The network sheet, before the first switch to Stellar: Monad is one tap away"))
                // Secondary, not tertiary: tertiary footnote text on the sheet's white is under 4.5:1.
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 20).padding(.horizontal, 24)
        }
    }

    private func confirmLine(_ symbol: String, _ text: LocalizedStringResource) -> some View {
        Label {
            Paragraph(text)
        } icon: {
            Image(systemName: symbol).font(.body).frame(width: symbolColumn)
        }
        .modifier(ParagraphLabel())
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// "Switch to Stellar" on Confirm: the intro is seen, and the Setup run that follows is the consent (no third tap).
    private func confirm() {
        markIntroSeen()
        go(to: .setup)
    }

    private func hand(_ network: AppNetwork) {
        finished = true
        choose(network)
    }

    // MARK: Setup (§3.6.3, docs/DESIGN-stellar-parity.md §8.14)

    private var state: NetworkSetup.State { setup?.state ?? .idle }
    private var rows: [Row] { setup?.rows ?? [] }
    private var isDone: Bool { state == .ready }

    /// The account setup is being sent: ✕ and the swipe are off, since it can't be called back.
    private var isSending: Bool { setup?.isSending ?? false }

    /// A passkey account: Set Up first, then its one passkey prompt for the sign-in and the setup together.
    private var passkey: Bool { method == .meraPasskey }

    /// Whether codes are asked for at all (mainnet); older servers always ask.
    private var inviteRequired: Bool { setup?.inviteRequired ?? true }

    private var shownRows: [Row] {
        Self.displayRows(steps: rows, state: state, inviteRequired: inviteRequired)
    }

    private var accountStep: AccountStep {
        Self.accountStep(testnet: setup?.isTestnet ?? AppNetwork.stellar.isTestnet, friendbotAmount: setup?.friendbotAmount)
    }

    /// The optional invite field under a passkey account's account step.
    private var asksInviteAtSetUp: Bool {
        Self.asksInviteAtSetUp(steps: rows, state: state, passkey: passkey, inviteRequired: inviteRequired)
    }

    private var setupStep: some View {
        VStack(spacing: 0) {
            NetworkRoute(from: .monad, to: .stellar, done: isDone).padding(.top, 4)
            Paragraph(isDone
                      ? LocalizedStringResource("You're on \(AppNetwork.stellar.name)", table: "Lite", comment: "The network sheet's title once the switch is done. %@ is a network's name, not translated")
                      : LocalizedStringResource("Switching to \(AppNetwork.stellar.name)", table: "Lite", comment: "The network sheet's title while the switch runs its steps. %@ is a network's name, not translated"))
                .font(.title2.bold()).multilineTextAlignment(.center)
                .padding(.top, 16).padding(.horizontal, 24)
            if let failure = checkFailure {
                // The silent first check isn't listed: it shows only when it fails, before any prompt.
                InlineError(message: failure.message(method: method))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 16)
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(shownRows) { setupRow($0) }
            }
            .padding(.horizontal, 24).padding(.top, 20)
        }
        .task {
            // The run starts on entry, at its first unfinished step (Confirm is never shown again after it).
            guard !resumesRun, let setup else { return }
            await setup.run()
        }
    }

    /// The silent first check's failure: the server is paused, this build is too old, or it can't be reached.
    private var checkFailure: NetworkSetup.Failure? {
        switch state {
        case .failed(nil, let failure), .unavailable(let failure): return failure
        default: return nil
        }
    }

    /// What a row of the checklist is: a step of the session's, or Enable USDC, which the account step sends right after
    /// the account, in the same run. There is no unlock row (decision 6).
    enum RowKind: Hashable {
        case signIn, invite, setUp, enableUSDC

        /// The row of a step the session lists; nil for one it never lists any more (nothing unlocks).
        init?(_ step: NetworkSetup.Step) {
            switch step {
            case .signIn: self = .signIn
            case .invite: self = .invite
            case .setUp: self = .setUp
            default: return nil
            }
        }
    }

    /// A row as the sheet draws it, with its status.
    struct Row: Identifiable, Equatable {
        let kind: RowKind
        let status: NetworkSetup.StepStatus
        var id: RowKind { kind }
    }

    /// The checklist as drawn (§8.14): Sign in, the account step, then Enable USDC. The invite step takes sign-in's place
    /// while the server asks for a code, and only where codes are asked for at all (`inviteRequired`): on testnet there is
    /// never an invite step. The account step needs the user only while the run waits for its tap: a passkey account's
    /// tap signs in first, and a code asked for comes before it.
    static func displayRows(steps: [Row], state: NetworkSetup.State, inviteRequired: Bool) -> [Row] {
        let invite = steps.first { $0.kind == .invite }
        let inviting: Bool = inviteRequired && {
            switch state {
            case .waiting(.invite), .failed(.invite?, _), .failed(_, .inviteRejected): return true
            default: return invite.map { $0.status != .pending && $0.status != .done } ?? false
            }
        }()
        var shown: [Row] = []
        for row in steps {
            switch row.kind {
            case .invite:
                if !inviteRequired {
                    // No code is asked for here: the step stays Sign in, whatever the session calls it.
                    shown.append(Row(kind: .signIn, status: row.status == .needsYou ? .pending : row.status))
                } else if inviting, !steps.contains(where: { $0.kind == .signIn }) {
                    // Drawn in sign-in's place below, or not at all; at its own place only if the session lists no sign-in.
                    shown.append(inviteRow(invite, state: state))
                }
            case .signIn where inviting:
                shown.append(inviteRow(invite, state: state))
            case .setUp:
                let status: NetworkSetup.StepStatus = row.status == .needsYou && state != .waiting(.setUp) ? .pending : row.status
                shown.append(Row(kind: .setUp, status: status))
                shown.append(Row(kind: .enableUSDC, status: enableStatus(status)))
            default:
                shown.append(row)
            }
        }
        return shown
    }

    private static func inviteRow(_ row: Row?, state: NetworkSetup.State) -> Row {
        if let row, row.status != .pending { return row }
        if case .failed(_, let failure) = state { return Row(kind: .invite, status: .failed(failure)) }
        return Row(kind: .invite, status: .needsYou)
    }

    /// Enable USDC goes with the account step: it runs and finishes with it, and waits otherwise (a failure is the
    /// account step's to say).
    private static func enableStatus(_ account: NetworkSetup.StepStatus) -> NetworkSetup.StepStatus {
        switch account {
        case .running, .done: return account
        default: return .pending
        }
    }

    /// Whether a passkey account's account step carries the optional invite field (§8.14): its first sign-in on this
    /// iPhone, while the run waits for the Set Up tap that starts its one ceremony, where codes are asked for at all.
    /// Seed accounts get the invite step instead, only when the server asks.
    static func asksInviteAtSetUp(steps: [Row], state: NetworkSetup.State, passkey: Bool, inviteRequired: Bool) -> Bool {
        guard passkey, inviteRequired, state == .waiting(.setUp) else { return false }
        return steps.first { $0.kind == .setUp }?.status == .needsYou && steps.first { $0.kind == .signIn }?.status == .pending
    }

    /// The account step's line before its tap, and its button (§8.14, decision 7).
    struct AccountStep: Equatable {
        let line: String
        let button: String
    }

    /// On testnet the account step is Friendbot's one claim of test XLM, in the amount the server's config gives
    /// (`faucet.amount`, never a figure of the app's), and its button reads "Fund with Friendbot"; on mainnet DyorHQ pays
    /// the one-time setup, and the button reads "Set up". The user pays every other network fee in XLM.
    static func accountStep(testnet: Bool, friendbotAmount: String?) -> AccountStep {
        guard testnet else {
            return AccountStep(
                line: liteTr(LocalizedStringResource("Creates your Stellar account and enables USDC. DyorHQ pays this one-time setup. After it, you pay Stellar's network fees in XLM.", table: "StellarSetup", comment: "The network sheet's account step on Stellar's main network, before its tap: DyorHQ pays for creating the account and enabling USDC; every later network fee is paid by the user in XLM. Stellar, USDC, DyorHQ and XLM are never translated")),
                button: liteTr(LocalizedStringResource("networkSetup.setUp", defaultValue: "Set up", table: "Lite", comment: "[tight] The network sheet's button: create the Stellar account (a verb)")))
        }
        let button = liteTr(LocalizedStringResource("Fund with Friendbot", table: "StellarSetup", comment: "[tight] The network sheet's button on Stellar's test network: create the account with free test XLM from Friendbot, Stellar's testnet faucet (a verb). Friendbot is a name, never translated"))
        guard let amount = friendbotAmount.flatMap({ figure(xlm: $0) }) else {
            return AccountStep(line: liteTr(LocalizedStringResource("Get free test XLM from Stellar's Friendbot (one claim per account), then enable USDC. Enabling USDC holds 0.5 XLM and costs a small network fee, paid from your test XLM.", table: "StellarSetup", comment: "The network sheet's account step on Stellar's test network, before its tap, while the amount isn't known: Friendbot, Stellar's testnet faucet, gives the new account free test XLM once; enabling USDC keeps 0.5 XLM back and costs a small fee in that XLM. Friendbot, Stellar, XLM and USDC are never translated")),
                               button: button)
        }
        return AccountStep(line: liteTr(LocalizedStringResource("Get \(amount) free test XLM from Stellar's Friendbot (one claim per account), then enable USDC. Enabling USDC holds 0.5 XLM and costs a small network fee, paid from your test XLM.", table: "StellarSetup", comment: "The network sheet's account step on Stellar's test network, before its tap: Friendbot, Stellar's testnet faucet, gives the new account free test XLM once; enabling USDC keeps 0.5 XLM back and costs a small fee in that XLM. %@ is a number, formatted by the app (10,000). Friendbot, Stellar, XLM and USDC are never translated")),
                           button: button)
    }

    /// The Enable USDC row's line (§8.14): what its trustline holds back (`baseReserve` for each new reserve) and the most
    /// its network fee may be, from `setupFee`: `/v1/fees`' estimate before the Set Up tap, the step's own transaction's
    /// fee once built. Only the steps the user pays count: on testnet all of them; on mainnet DyorHQ pays the one-time
    /// setup, so only a built step the phone found the user's. Nil while the price or the reserve isn't read.
    static func enableLine(fee: PlanFees?, baseReserve: Int64?, testnet: Bool) -> String? {
        guard let fee, let baseReserve else { return nil }
        let mine = fee.steps.filter { $0.payer == .user && (testnet || $0.built) }
        guard !mine.isEmpty else { return nil }
        let held = figure(stroops: Int64(mine.reduce(0) { $0 + $1.reserveDelta }) * baseReserve)
        let most = figure(stroops: mine.reduce(Int64(0)) { $0 + $1.maxFee })
        return liteTr(LocalizedStringResource("Holds \(held) XLM · network fee up to \(most) XLM", table: "StellarSetup", comment: "The network sheet's Enable USDC step: the XLM the account must keep back for USDC (its reserve), then the most the step's network fee may be. Both values are numbers of XLM, formatted by the app (0.5, 0.001). XLM is never translated"))
    }

    /// An amount of XLM the server writes as a decimal ("10000"), in the app's number style ("10,000"); nil if it isn't one.
    private static func figure(xlm text: String) -> String? {
        guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
        return NumberStyle.number(value)
    }

    /// Stroops as a number of XLM in the app's number style: 5,000,000 is "0.5", 10,000 is "0.001".
    private static func figure(stroops: Int64) -> String {
        NumberStyle.number(StellarFeeSummary.xlm(stroops), maximumFractionDigits: 7)
    }

    private func setupRow(_ row: Row) -> some View {
        let detail = detail(for: row)
        let rejected = row.kind == .invite && row.status == .failed(.inviteRejected)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            statusIcon(rejected ? .needsYou : row.status)
                .frame(width: statusColumn)
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title(row.kind))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.status == .pending ? .tertiary : .primary)
                    if let detail {
                        Paragraph(verbatim: detail.text)
                            .font(.footnote)
                            .foregroundStyle(detail.isError ? Color.attention : Color.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spoken(row, detail: detail?.text)))
                .accessibilityFocused($spokenRow, equals: row.kind)
                if row.kind == .invite, row.status != .done {
                    inviteField(rejected: rejected,
                                hint: LocalizedStringResource("You need it only once.", table: "Lite", comment: "The network sheet, under the invite code field"),
                                focuses: true) { if canJoin { join() } }
                        .padding(.top, 8)
                } else if row.kind == .setUp, asksInviteAtSetUp {
                    inviteField(rejected: false,
                                hint: LocalizedStringResource("Needed the first time you use Stellar.", table: "StellarSetup", comment: "The network sheet, under the optional invite code field of a passkey account's first setup on this iPhone: a code is needed only the first time the account uses DyorHQ on Stellar. Stellar is never translated"),
                                focuses: false) { if canSetUp { tapSetUp() } }
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func statusIcon(_ status: NetworkSetup.StepStatus) -> some View {
        ZStack {
            // The baseline every status sits on, the spinner included, so each lines up with its row's title.
            Image(systemName: "circle").hidden()
            if status == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: Self.symbol(status))
                    .foregroundStyle(Self.tint(status))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .font(.body)
        .accessibilityHidden(true)
    }

    private static func symbol(_ status: NetworkSetup.StepStatus) -> String {
        switch status {
        case .pending, .running: return "circle"
        case .needsYou: return "circle.inset.filled"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private static func tint(_ status: NetworkSetup.StepStatus) -> AnyShapeStyle {
        switch status {
        case .pending, .running: return AnyShapeStyle(.tertiary)
        case .needsYou: return AnyShapeStyle(Color.brand)
        case .done: return AnyShapeStyle(Color.positive)
        case .failed: return AnyShapeStyle(Color.attention)
        }
    }

    private func title(_ kind: RowKind) -> String {
        switch kind {
        case .signIn:
            return liteTr(LocalizedStringResource("networkSetup.signIn", defaultValue: "Sign in", table: "Lite", comment: "[tight] A step of the network sheet's Setup: DyorHQ checks this account owns its Stellar key"))
        case .invite:
            return liteTr(LocalizedStringResource("Enter your invite code", table: "Lite", comment: "A step of the network sheet's Setup: DyorHQ on Stellar asks testers for an invite code once"))
        case .setUp:
            return liteTr(LocalizedStringResource("Set up your Stellar account", table: "Lite", comment: "A step of the network sheet's Setup: create the account on the Stellar network"))
        case .enableUSDC:
            return liteTr(LocalizedStringResource("Enable USDC", table: "StellarSetup", comment: "A step of the network sheet's Setup: let the new Stellar account hold USDC (a trustline), right after the account is created. USDC is never translated"))
        }
    }

    /// The line under a row's title: what it is doing, what it needs, what it costs, what it did, or why it stopped
    /// (`isError`).
    private func detail(for row: Row) -> (text: String, isError: Bool)? {
        switch (row.kind, row.status) {
        case (.invite, .failed(.inviteRejected)), (.invite, .needsYou), (.invite, .running):
            // A refused code is said under the field instead. A passkey account that left the optional field empty is
            // asked for it again; the next tap asks for the passkey again (the run kept nothing).
            if passkey {
                return (liteTr(LocalizedStringResource("Enter your invite code to continue.", table: "StellarSetup", comment: "The network sheet's invite step on a passkey account: the server needs an invite code for this account's first use of DyorHQ on Stellar; the next tap asks for the passkey again")), false)
            }
            return (liteTr(LocalizedStringResource("DyorHQ on Stellar is invite-only while we test it.", table: "Lite", comment: "The network sheet's invite step: why it asks for a code")), false)
        case (.enableUSDC, .done):
            return nil
        case (.enableUSDC, _):
            // Before the step signs: its reserve and the most its fee may be (the estimate, then the decoded fee).
            guard let line = Self.enableLine(fee: setup?.setupFee, baseReserve: setup?.baseReserve,
                                             testnet: setup?.isTestnet ?? AppNetwork.stellar.isTestnet) else { return nil }
            return (line, false)
        case (_, .failed(let failure)):
            return (failure.message(method: method), true)
        case (.signIn, .running):
            // A seed account's sign-in signs only the challenge, with no prompt; a passkey account's is its one ceremony.
            if passkey {
                return (liteTr(LocalizedStringResource("Confirm with your passkey", table: "StellarSetup", comment: "The network sheet's sign-in step on a passkey account while it runs: the passkey prompt is up, and that one prompt signs in and sets up the account")), false)
            }
            return (liteTr(LocalizedStringResource("Signing in…", table: "StellarSetup", comment: "The network sheet's sign-in step while it runs, with no prompt: DyorHQ checks this account owns its Stellar key")), false)
        case (.signIn, .done):
            return (tr("Signed in"), false)
        case (.setUp, .needsYou):
            return (accountStep.line, false)
        case (.setUp, .running):
            return (liteTr(LocalizedStringResource("Setting up… This can take a few seconds.", table: "Lite", comment: "The network sheet's account setup step while its transaction is sent")), false)
        case (.setUp, .done):
            return (liteTr(LocalizedStringResource("networkSetup.ready", defaultValue: "Ready", table: "Lite", comment: "[tight] The network sheet's account setup step is done: the Stellar account is ready")), false)
        default:
            return nil
        }
    }

    /// "{title}. {Done / In progress / Needs you / Failed}. {detail}", for VoiceOver.
    private func spoken(_ row: Row, detail: String?) -> String {
        let status: String?
        switch row.status {
        case .pending: status = nil
        case .running: status = liteTr(LocalizedStringResource("networkSetup.status.running", defaultValue: "In progress", table: "Lite", comment: "VoiceOver: a step of the network sheet's Setup is running"))
        case .needsYou: status = liteTr(LocalizedStringResource("networkSetup.status.needsYou", defaultValue: "Needs you", table: "Lite", comment: "VoiceOver: a step of the network sheet's Setup waits for the user (a code, a tap)"))
        case .done: status = liteTr(LocalizedStringResource("networkSetup.status.done", defaultValue: "Done", table: "Lite", comment: "VoiceOver: a step of the network sheet's Setup is done"))
        case .failed(.inviteRejected) where row.kind == .invite:
            status = liteTr(LocalizedStringResource("networkSetup.status.needsYou", defaultValue: "Needs you", table: "Lite", comment: "VoiceOver: a step of the network sheet's Setup waits for the user (a code, a tap)"))
        case .failed: status = liteTr(LocalizedStringResource("networkSetup.status.failed", defaultValue: "Failed", table: "Lite", comment: "VoiceOver: a step of the network sheet's Setup failed"))
        }
        return [title(row.kind), status, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    // MARK: The invite code

    /// The code field: the invite step's (focused as it appears), or the optional one under a passkey account's account
    /// step (not focused: the code may not be needed). `submit` runs on the keyboard's Join.
    private func inviteField(rejected: Bool, hint: LocalizedStringResource, focuses: Bool, submit: @escaping () -> Void) -> some View {
        let busy = state == .running
        return VStack(alignment: .leading, spacing: 6) {
            Text("Invite code", tableName: "Lite", comment: "The label over the network sheet's invite code field")
                .font(.footnote.weight(.semibold))
            HStack(spacing: 8) {
                TextField("" as String, text: $inviteCode)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .onSubmit(submit)
                    .focused($inviteFocused)
                    .accessibilityLabel(Text("Invite code", tableName: "Lite", comment: "The label over the network sheet's invite code field"))
                    .accessibilityFocused($inviteSpoken)
                // The system's own: no paste-permission prompt.
                PasteButton(payloadType: String.self) { pasted in
                    guard let text = pasted.first else { return }
                    Task { @MainActor in inviteCode = Self.code(text) }
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(minHeight: 48)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(busy)
            if rejected {
                InlineError(message: NetworkSetup.Failure.inviteRejected.message(method: method))
            } else {
                Paragraph(hint)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: inviteCode) { _, typed in
            let code = Self.code(typed)
            if code != typed { inviteCode = code }
        }
        .onAppear {
            guard focuses else { return }
            inviteFocused = true
            inviteSpoken = true
        }
    }

    /// The code as it is sent: spaces and line breaks taken out.
    private static func code(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    private var canJoin: Bool { inviteCode.count >= 8 && state != .running }

    /// The optional code goes with the Set Up tap: none, or a whole one (a code begun waits for the rest).
    private var setUpCodeReady: Bool { !asksInviteAtSetUp || inviteCode.isEmpty || inviteCode.count >= 8 }

    private var canSetUp: Bool { setUpCodeReady && state != .running }

    private func join() {
        tapped = .join
        let code = inviteCode
        Task { await setup?.join(invite: code) }
    }

    /// The Set Up tap: a seed account's App Lock when it applies, or a passkey account's one ceremony, with the optional
    /// code when its field shows.
    private func tapSetUp() {
        tapped = .setUp
        let code = asksInviteAtSetUp ? inviteCode : nil
        Task { await setup?.setUp(invite: code) }
    }

    // MARK: Setup's button

    private enum SetupAction { case join, setUp, retry, close }

    /// Join while the invite code is asked for (or was refused), the account step's button (Fund with Friendbot on
    /// testnet, Set up on mainnet) while it waits for its tap, Try again after a failure retrying can help, Close after one
    /// it can't; while a run is under way, the button that started it, busy. None while the first run goes, nor once done.
    private var setupAction: SetupAction? {
        switch state {
        case .waiting(.invite): return inviteRequired ? .join : .close
        case .waiting(.setUp): return .setUp
        case .waiting: return nil
        case .failed(_, .inviteRejected): return inviteRequired ? .join : .close
        case .failed(_, let failure): return failure.canRetry ? .retry : .close
        case .unavailable: return .close
        case .running: return tapped
        case .idle, .ready: return nil
        }
    }

    @ViewBuilder private func setupButton(_ action: SetupAction) -> some View {
        let busy = state == .running
        switch action {
        case .join:
            PrimaryButton(title: Text(verbatim: liteTr(LocalizedStringResource("networkSetup.join", defaultValue: "Join", table: "Lite", comment: "[tight] The network sheet's button: join the test of DyorHQ on Stellar with the invite code (a verb)"))),
                          isBusy: busy, isDisabled: !busy && inviteCode.count < 8) { join() }
        case .setUp:
            PrimaryButton(title: Text(verbatim: accountStep.button), isBusy: busy, isDisabled: !busy && !setUpCodeReady) { tapSetUp() }
        case .retry:
            PrimaryButton(title: "Try again", isBusy: busy) {
                tapped = .retry
                Task { await setup?.retry() }
            }
        case .close:
            PrimaryButton(title: Text("Close", comment: "Closes this screen or sheet (a verb)")) { close() }
        }
    }

    /// ✕ in Setup: closes, which stops the run (`onDisappear`). Once done it hands the switch over at once.
    private func closeSetup() {
        if isDone, !finished {
            hand(.stellar)
        } else {
            close()
        }
    }

    // MARK: What Setup says as it goes

    private func stateChanged(from old: NetworkSetup.State?, to new: NetworkSetup.State) {
        if new != .running { tapped = nil }
        switch new {
        case .ready:
            Haptics.success()
            AccessibilityNotification.Announcement(liteTr(LocalizedStringResource("You're on \(AppNetwork.stellar.name)", table: "Lite", comment: "The network sheet's title once the switch is done. %@ is a network's name, not translated"))).post()
            // A moment on the check, then the sheet closes and the swap runs.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                if !finished { hand(.stellar) }
            }
        case .failed(let step, let failure):
            Haptics.error()
            if failure == .inviteRejected, inviteRequired {
                inviteSpoken = true // the code and the focus stay
            } else {
                spokenRow = step.flatMap(RowKind.init)
            }
        case .unavailable:
            Haptics.error()
        default:
            break
        }
    }

    /// A step that just finished is said: "Signed in", "Ready".
    private func announceFinishedSteps(old: [Row], new: [Row]) {
        for row in new where row.status == .done && old.first(where: { $0.kind == row.kind })?.status != .done {
            if let text = detail(for: row)?.text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}

// MARK: Previews

#if DEBUG
/// A scripted Stellar session for the network sheet's previews, each step a second: a seed account signs in with no
/// prompt and waits for its Set Up tap; a passkey account waits for its tap first, then signs in and sets up with its one
/// passkey prompt. On mainnet the first sign-in asks for an invite code (K7Q2XM9P) once; on testnet none is asked. Never
/// used by the app.
@MainActor
@Observable
final class PreviewSetupSession: NetworkSetupSession {
    enum Script { case seed, passkey, offlineOnce, paused }

    struct StepRow: NetworkSetupStepRow {
        let step: NetworkSetup.Step
        let status: NetworkSetup.StepStatus
    }

    private(set) var state: NetworkSetup.State
    private(set) var steps: [StepRow]
    private(set) var isSending = false
    let isTestnet: Bool
    var inviteRequired: Bool { !isTestnet }
    private(set) var setupFee: PlanFees? = nil
    private(set) var baseReserve: Int64? = nil
    var friendbotAmount: String? { isTestnet ? "10000" : nil }
    private let script: Script
    private var invited = false
    private var wentOffline = false
    private var cancelled = false

    init(_ script: Script = .seed, testnet: Bool = true, state: NetworkSetup.State = .idle, steps: [StepRow]? = nil) {
        self.script = script
        self.isTestnet = testnet
        self.state = state
        self.steps = steps ?? [.init(step: .signIn, status: .pending), .init(step: .setUp, status: .pending)]
        if state != .idle { readFees() }
    }

    func plan() -> NetworkSetup.Plan { .setup([.signIn, .setUp]) }

    func run() async {
        cancelled = false
        state = .running
        guard await pause() else { return }
        if script == .paused {
            // As DyorLite's silent check: the service is paused, before any prompt.
            state = .unavailable(.paused)
            return
        }
        readFees()
        if script == .passkey {
            // A passkey account's tap comes first; nothing is held while it waits.
            waitForSetUp()
        } else if await signIn(invite: nil) {
            waitForSetUp()
        }
    }

    func join(invite code: String) async {
        state = .running
        guard await signIn(invite: code) else { return }
        if script == .passkey {
            await setUpAccount()
        } else {
            waitForSetUp()
        }
    }

    func setUp(invite code: String?) async {
        state = .running
        if script == .passkey {
            // The one ceremony: its signer signs the sign-in, then the setup.
            guard await signIn(invite: code) else { return }
        }
        await setUpAccount()
    }

    func retry() async {
        switch state {
        case .failed(.invite?, _):
            set(.invite, .needsYou)
            state = .waiting(.invite)
        case .failed(.signIn?, _):
            state = .running
            guard await signIn(invite: nil) else { return }
            if script == .passkey { await setUpAccount() } else { waitForSetUp() }
        default:
            await run()
        }
    }

    func cancel() {
        cancelled = true
        steps = steps.map { $0.status == .running ? .init(step: $0.step, status: .pending) : $0 }
        if state == .running { state = .idle }
    }

    /// As DyorLite's session: on mainnet a first sign-in without a code finds the account isn't invited yet, and the invite
    /// step takes sign-in's place until the code is sent.
    private func signIn(invite code: String?) async -> Bool {
        replace(.invite, with: .signIn)
        set(.signIn, .running)
        guard await pause() else { return false }
        if script == .offlineOnce, !wentOffline {
            wentOffline = true
            set(.signIn, .failed(.offline))
            state = .failed(.signIn, .offline)
            return false
        }
        if inviteRequired, !invited {
            guard let code, !code.isEmpty else {
                replace(.signIn, with: .invite)
                set(.invite, .needsYou)
                state = .waiting(.invite)
                return false
            }
            guard code.uppercased() == "K7Q2XM9P" else {
                replace(.signIn, with: .invite)
                set(.invite, .failed(.inviteRejected))
                state = .failed(.invite, .inviteRejected)
                return false
            }
            invited = true
        }
        set(.signIn, .done)
        return true
    }

    private func waitForSetUp() {
        set(.setUp, .needsYou)
        state = .waiting(.setUp)
    }

    private func setUpAccount() async {
        isSending = true
        defer { isSending = false }
        set(.setUp, .running)
        guard await pause() else { return }
        set(.setUp, .done)
        state = .ready
    }

    /// `/v1/fees` as the session reads it: a 0.5 XLM base reserve, and Enable USDC's estimate.
    private func readFees() {
        baseReserve = 5_000_000
        setupFee = Self.enableEstimate
    }

    /// One user-paid Enable USDC step at 0.001 XLM, holding one more base reserve.
    private static let enableEstimate: PlanFees? = {
        let json = #"{"planId":"setup","kind":"trust","expiresAt":"","steps":[{"id":"trust","label":"Enable USDC","status":"pending","stepKind":"trust","maxFee":"10000","feePayer":"user","reserveDelta":1}]}"#
        guard let plan = try? JSONDecoder().decode(PlanView.self, from: Data(json.utf8)) else { return nil }
        return try? PlanFees(plan: plan, pinned: .testnet)
    }()

    private func set(_ step: NetworkSetup.Step, _ status: NetworkSetup.StepStatus) {
        guard let index = steps.firstIndex(where: { $0.step == step }) else { return }
        steps[index] = .init(step: step, status: status)
    }

    private func replace(_ step: NetworkSetup.Step, with other: NetworkSetup.Step) {
        guard let index = steps.firstIndex(where: { $0.step == step }) else { return }
        steps[index] = .init(step: other, status: steps[index].status)
    }

    /// A second, as a network round-trip; false once cancelled.
    private func pause() async -> Bool {
        try? await Task.sleep(for: .seconds(1))
        return !cancelled
    }
}

/// The sheet presented over a plain ground, the way the app presents it.
private struct NetworkSheetPreview: View {
    var startAt: NetworkSheetRequest.Start = .select
    var current: AppNetwork = .monad
    var availability: NetworkAvailability = .offered
    var method: Session.Method = .emailPassword
    var introSeen = false
    let setup: (any NetworkSetupSession)?

    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                NetworkSheetContent(startAt: startAt, current: current, availability: availability, method: method,
                                    introSeen: introSeen, setup: setup, markIntroSeen: {}, choose: { _ in }, close: {})
            }
    }
}

#Preview("Select") { NetworkSheetPreview(setup: PreviewSetupSession()) }
#Preview("Select · on Stellar") { NetworkSheetPreview(current: .stellar, setup: PreviewSetupSession()) }
#Preview("Select · unavailable") { NetworkSheetPreview(availability: .unavailable(.signInMethod(.apple)), setup: PreviewSetupSession()) }
#Preview("Confirm, then Setup · seed") { NetworkSheetPreview(setup: PreviewSetupSession(.seed)) }
#Preview("Setup · passkey") { NetworkSheetPreview(method: .meraPasskey, introSeen: true, setup: PreviewSetupSession(.passkey)) }
#Preview("Setup · mainnet, code K7Q2XM9P") { NetworkSheetPreview(introSeen: true, setup: PreviewSetupSession(.seed, testnet: false)) }
#Preview("Setup · passkey on mainnet, code K7Q2XM9P") {
    NetworkSheetPreview(method: .meraPasskey, introSeen: true, setup: PreviewSetupSession(.passkey, testnet: false))
}
#Preview("Setup · offline once") { NetworkSheetPreview(introSeen: true, setup: PreviewSetupSession(.offlineOnce)) }
#Preview("Setup · paused") { NetworkSheetPreview(introSeen: true, setup: PreviewSetupSession(.paused)) }
#Preview("Setup · Fund with Friendbot waits") {
    NetworkSheetPreview(startAt: .setup, setup: PreviewSetupSession(state: .waiting(.setUp), steps: [
        .init(step: .signIn, status: .done), .init(step: .setUp, status: .needsYou),
    ]))
}
#Preview("Chips") {
    VStack(alignment: .leading, spacing: 16) {
        NetworkChipRow(network: .monad)
        NetworkChipRow(network: .stellar)
        NetworkRoute(from: .monad, to: .stellar, done: true)
    }
    .padding()
    .environment(Router.shared)
}
#endif
#endif
