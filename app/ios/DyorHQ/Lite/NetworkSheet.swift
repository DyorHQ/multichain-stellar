// The network sheet: Select, Confirm, Setup (docs/DESIGN-network-switch.md §3.6). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Observation
import SwiftUI

/// What opens the network sheet: where from, which decides what happens once a switch is chosen (§2.5), and the step it
/// opens at: Select from the chip and Profile's Network row; Setup from Stellar Home's locked card when its inline unlock
/// paused or failed, where the run is already under way.
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
/// follows `state`, `steps` and `isSending` as they change.
///
/// One unlock per run (open question 2): the key `run` unlocks signs the sign-in, the sign-in again with an invite and the
/// account setup, with no other prompt. It lives in memory only, until the run ends, `cancel()`, the app goes to the
/// background, or 120 s idle while waiting on the user; after that the next step unlocks again.
@MainActor
protocol NetworkSetupSession: AnyObject, Observable {
    associatedtype StepRow: NetworkSetupStepRow
    var state: NetworkSetup.State { get }
    /// The steps listed, in order, with their status.
    var steps: [StepRow] { get }
    /// The account setup is being sent: it can't be called back, so ✕ and the swipe are off.
    var isSending: Bool { get }
    /// What a switch to Stellar needs now. Local: no network, no prompt.
    func plan() -> NetworkSetup.Plan
    /// Check → [unlock] → [sign in] → [set up], from the first unfinished step. Returns once it is ready, waits for the
    /// user (`waiting(.invite)`, `waiting(.setUp)`) or fails; it never prompts before the silent check has passed.
    func run() async
    /// Signs in again with `code`, with the key unlocked for this run, then goes on.
    func join(invite code: String) async
    /// Sends the account setup (its tap is the confirmation of that write), then goes on.
    func setUp() async
    /// The failed step again, unlocking first if the key was dropped.
    func retry() async
    /// Stops between steps and drops the key; what finished is kept (the Stellar address, a saved session).
    func cancel()
}

extension LiteSession.StepRow: NetworkSetupStepRow {}
extension LiteSession: NetworkSetupSession {}

extension NetworkSetupSession {
    /// The steps as the sheet draws them.
    var rows: [NetworkSheetContent.Row] { steps.map { NetworkSheetContent.Row(step: $0.step, status: $0.status) } }
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
            return liteTr(LocalizedStringResource("Unlock was cancelled.", table: "Lite", comment: "The network sheet's Setup: the passkey or Face ID prompt that unlocks the Stellar key was cancelled"))
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
    /// The account's sign-in method, for the key-not-on-this-iPhone copy.
    let method: Session.Method?
    /// Confirm was already shown to this account on this iPhone (`AppNetwork.stellarIntroSeen`).
    let introSeen: Bool
    let setup: (any NetworkSetupSession)?
    let markIntroSeen: () -> Void
    /// A switch is decided: the presenter closes the sheet and commits it.
    let choose: (AppNetwork) -> Void
    let close: () -> Void
    /// Opened at Setup with the run under way (Stellar Home's locked card): the run isn't started again.
    private let resumesRun: Bool

    @State private var step: Step
    @State private var selection: AppNetwork
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var inviteCode = ""
    @FocusState private var inviteFocused: Bool
    @AccessibilityFocusState private var inviteSpoken: Bool
    @AccessibilityFocusState private var spokenRow: NetworkSetup.Step?
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
        // Closed by ✕ or a swipe in the middle of Setup: the run stops and the key is dropped, and what finished is kept.
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

    /// Confirm comes first on the first switch to Stellar on this iPhone, when the switch needs work (§2.3).
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
            // Monad, or a Stellar session that is ready: the swap is at once (Stellar Home restores it as it appears).
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

    // MARK: Setup (§3.6.3, §4)

    private var state: NetworkSetup.State { setup?.state ?? .idle }
    private var rows: [Row] { setup?.rows ?? [] }
    private var isDone: Bool { state == .ready }

    /// The account setup is being sent: ✕ and the swipe are off, since it can't be called back.
    private var isSending: Bool { setup?.isSending ?? false }

    private var setupStep: some View {
        VStack(spacing: 0) {
            // Monad to Stellar, also when the run resumes from Stellar Home's locked card.
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
                ForEach(Self.displayRows(steps: rows, state: state)) { setupRow($0) }
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

    /// A row as the sheet draws it: a step of the session's, or the invite step drawn in sign-in's place.
    struct Row: Identifiable, Equatable {
        let step: NetworkSetup.Step
        let status: NetworkSetup.StepStatus
        var id: NetworkSetup.Step { step }
    }

    /// The rows as drawn: the session's, with the invite step in sign-in's place while it is asked for (sign-in "expands"
    /// into it), and otherwise left out.
    static func displayRows(steps: [Row], state: NetworkSetup.State) -> [Row] {
        let invite = steps.first { $0.step == .invite }
        let inviting: Bool = {
            switch state {
            case .waiting(.invite), .failed(.invite?, _), .failed(_, .inviteRejected): return true
            default: return invite.map { $0.status != .pending && $0.status != .done } ?? false
            }
        }()
        var shown: [Row] = []
        for row in steps {
            switch row.step {
            case .invite:
                // Drawn in sign-in's place below, or not at all; at its own place only if the session lists no sign-in.
                if inviting, !steps.contains(where: { $0.step == .signIn }) { shown.append(inviteRow(invite, state: state)) }
            case .signIn where inviting:
                shown.append(inviteRow(invite, state: state))
            default:
                shown.append(row)
            }
        }
        return shown
    }

    private static func inviteRow(_ row: Row?, state: NetworkSetup.State) -> Row {
        if let row, row.status != .pending { return row }
        if case .failed(_, let failure) = state { return Row(step: .invite, status: .failed(failure)) }
        return Row(step: .invite, status: .needsYou)
    }

    /// The key was unlocked earlier in the run and dropped since (120 s idle): the unlock row is pending again while a later
    /// step waits, and the next action unlocks first.
    private var unlockDropped: Bool {
        guard let unlock = rows.first(where: { $0.step == .unlock }), unlock.status == .pending else { return false }
        return rows.contains { $0.step != .unlock && $0.status != .pending }
    }

    private func setupRow(_ row: Row) -> some View {
        let detail = detail(for: row)
        let rejected = row.step == .invite && row.status == .failed(.inviteRejected)
        // On testnet the account setup also brings test XLM (Friendbot), said under what the setup does.
        let testXLM = row.step == .setUp && row.status == .needsYou && AppNetwork.stellar.isTestnet
            ? liteTr(LocalizedStringResource("On testnet you also get \(NumberStyle.number(10_000)) test XLM.", table: "Lite", comment: "The network sheet's account setup step, on Stellar's test network. %@ is a number, formatted by the app (10,000)"))
            : nil
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            statusIcon(rejected ? .needsYou : row.status)
                .frame(width: statusColumn)
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title(row.step))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.status == .pending ? .tertiary : .primary)
                    if let detail {
                        Paragraph(verbatim: detail.text)
                            .font(.footnote)
                            .foregroundStyle(detail.isError ? Color.attention : Color.secondary)
                    }
                    if let testXLM {
                        Paragraph(verbatim: testXLM).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spoken(row, detail: WordWrap.sentences([detail?.text, testXLM].compactMap { $0 }))))
                .accessibilityFocused($spokenRow, equals: row.step)
                if row.step == .invite, row.status != .done {
                    inviteField(rejected: rejected).padding(.top, 8)
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

    private func title(_ step: NetworkSetup.Step) -> String {
        switch step {
        case .unlock:
            return liteTr(LocalizedStringResource("Unlock your Stellar key", table: "Lite", comment: "A step of the network sheet's Setup, and the reason the passkey or Face ID prompt gives: unlock the account's key on the Stellar network"))
        case .signIn:
            return liteTr(LocalizedStringResource("networkSetup.signIn", defaultValue: "Sign in", table: "Lite", comment: "[tight] A step of the network sheet's Setup: DyorHQ checks this account owns its Stellar key"))
        case .invite:
            return liteTr(LocalizedStringResource("Enter your invite code", table: "Lite", comment: "A step of the network sheet's Setup: DyorHQ on Stellar asks testers for an invite code once"))
        case .setUp:
            return liteTr(LocalizedStringResource("Set up your Stellar account", table: "Lite", comment: "A step of the network sheet's Setup: create the account on the Stellar network"))
        }
    }

    /// The line under a row's title: what it is doing, what it needs, what it did, or why it stopped (`isError`).
    private func detail(for row: Row) -> (text: String, isError: Bool)? {
        switch (row.step, row.status) {
        case (.invite, .failed(.inviteRejected)), (.invite, .needsYou), (.invite, .running):
            // A refused code is said under the field instead.
            return (liteTr(LocalizedStringResource("DyorHQ on Stellar is invite-only while we test it.", table: "Lite", comment: "The network sheet's invite step: why it asks for a code")), false)
        case (_, .failed(let failure)):
            return (failure.message(method: method), true)
        case (.unlock, .running):
            return (tr("Confirm with \(BiometricGate.promptName)"), false)
        case (.unlock, .done):
            return (liteTr(LocalizedStringResource("Unlocked", table: "Lite", comment: "[tight] The network sheet's unlock step is done: the Stellar key is unlocked")), false)
        case (.unlock, .pending), (.unlock, .needsYou):
            guard unlockDropped || row.status == .needsYou else { return nil }
            return (liteTr(LocalizedStringResource("Unlock again to continue.", table: "Lite", comment: "The network sheet's unlock step, after the unlocked key was dropped for being idle: the next step asks for it again")), false)
        case (.signIn, .running):
            return (liteTr(LocalizedStringResource("Checking your access…", table: "Lite", comment: "The network sheet's sign-in step while it runs")), false)
        case (.signIn, .done):
            return (tr("Signed in"), false)
        case (.setUp, .needsYou):
            return (liteTr(LocalizedStringResource("Creates your account and adds USDC. DyorHQ pays the network fees and the reserve, so you spend nothing.", table: "Lite", comment: "The network sheet's account setup step, before its tap. “Reserve”: the XLM every Stellar account must hold, which DyorHQ pays")), false)
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
        case .failed(.inviteRejected) where row.step == .invite:
            status = liteTr(LocalizedStringResource("networkSetup.status.needsYou", defaultValue: "Needs you", table: "Lite", comment: "VoiceOver: a step of the network sheet's Setup waits for the user (a code, a tap)"))
        case .failed: status = liteTr(LocalizedStringResource("networkSetup.status.failed", defaultValue: "Failed", table: "Lite", comment: "VoiceOver: a step of the network sheet's Setup failed"))
        }
        return [title(row.step), status, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    // MARK: The invite code

    private func inviteField(rejected: Bool) -> some View {
        let joining = state == .running
        return VStack(alignment: .leading, spacing: 6) {
            Text("Invite code", tableName: "Lite", comment: "The label over the network sheet's invite code field")
                .font(.footnote.weight(.semibold))
            HStack(spacing: 8) {
                TextField("" as String, text: $inviteCode)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .onSubmit { if canJoin { join() } }
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
            .disabled(joining)
            if rejected {
                InlineError(message: NetworkSetup.Failure.inviteRejected.message(method: method))
            } else {
                Paragraph(LocalizedStringResource("You need it only once.", table: "Lite", comment: "The network sheet, under the invite code field"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: inviteCode) { _, typed in
            let code = Self.code(typed)
            if code != typed { inviteCode = code }
        }
        .onAppear {
            inviteFocused = true
            inviteSpoken = true
        }
    }

    /// The code as it is sent: spaces and line breaks taken out.
    private static func code(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    private var canJoin: Bool { inviteCode.count >= 8 && state != .running }

    private func join() {
        tapped = .join
        let code = inviteCode
        Task { await setup?.join(invite: code) }
    }

    // MARK: Setup's button

    private enum SetupAction { case join, setUp, retry, close }

    /// Join while the invite code is asked for (or was refused), Set up while the account setup waits for its tap, Try
    /// again after a failure retrying can help, Close after one it can't; while a run is under way, the button that started
    /// it, busy. None while the first run goes, nor once done.
    private var setupAction: SetupAction? {
        switch state {
        case .waiting(.invite): return .join
        case .waiting(.setUp): return .setUp
        case .waiting: return nil
        case .failed(_, .inviteRejected): return .join
        case .failed(_, let failure): return failure.canRetry ? .retry : .close
        case .unavailable: return .close
        case .running: return tapped
        case .idle, .ready, .locked: return nil
        }
    }

    @ViewBuilder private func setupButton(_ action: SetupAction) -> some View {
        let busy = state == .running
        switch action {
        case .join:
            PrimaryButton(title: Text(verbatim: liteTr(LocalizedStringResource("networkSetup.join", defaultValue: "Join", table: "Lite", comment: "[tight] The network sheet's button: join the test of DyorHQ on Stellar with the invite code (a verb)"))),
                          isBusy: busy, isDisabled: !busy && inviteCode.count < 8) { join() }
        case .setUp:
            PrimaryButton(title: Text(verbatim: liteTr(LocalizedStringResource("networkSetup.setUp", defaultValue: "Set up", table: "Lite", comment: "[tight] The network sheet's button: create the Stellar account (a verb)"))),
                          isBusy: busy) {
                tapped = .setUp
                Task { await setup?.setUp() }
            }
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
            if failure == .inviteRejected {
                inviteSpoken = true // the code and the focus stay
            } else {
                spokenRow = step
            }
        case .unavailable:
            Haptics.error()
        default:
            break
        }
    }

    /// A step that just finished is said: "Unlocked", "Signed in".
    private func announceFinishedSteps(old: [Row], new: [Row]) {
        for row in new where row.status == .done && old.first(where: { $0.step == row.step })?.status != .done {
            if let text = detail(for: row)?.text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}

// MARK: Previews

#if DEBUG
/// A scripted Stellar session for the network sheet's previews: each step takes a second, sign-in asks for an invite code
/// (K7Q2XM9P) once, and the account setup waits for its tap. Never used by the app.
@MainActor
@Observable
final class PreviewSetupSession: NetworkSetupSession {
    enum Script { case firstTime, offlineOnce, paused }

    struct StepRow: NetworkSetupStepRow {
        let step: NetworkSetup.Step
        let status: NetworkSetup.StepStatus
    }

    private(set) var state: NetworkSetup.State
    private(set) var steps: [StepRow]
    private(set) var isSending = false
    private let script: Script
    private var invited = false
    private var wentOffline = false
    private var cancelled = false

    init(_ script: Script = .firstTime, state: NetworkSetup.State = .idle, steps: [StepRow]? = nil) {
        self.script = script
        self.state = state
        self.steps = steps ?? [.init(step: .unlock, status: .pending), .init(step: .signIn, status: .pending), .init(step: .setUp, status: .pending)]
    }

    func plan() -> NetworkSetup.Plan { .setup([.unlock, .signIn, .setUp]) }

    func run() async {
        cancelled = false
        state = .running
        guard await pause() else { return }
        if script == .paused {
            // As DyorLite's silent check: the service is paused, before any prompt.
            state = .unavailable(.paused)
            return
        }
        guard await advance(.unlock), await signIn() else { return }
        waitForSetUp()
    }

    func join(invite code: String) async {
        state = .running
        set(.invite, .running)
        guard await pause() else { return }
        guard code.uppercased() == "K7Q2XM9P" else {
            set(.invite, .failed(.inviteRejected))
            state = .failed(.invite, .inviteRejected)
            return
        }
        invited = true
        replace(.invite, with: .signIn)
        guard await signIn() else { return }
        waitForSetUp()
    }

    func setUp() async {
        state = .running
        isSending = true
        defer { isSending = false }
        guard await advance(.setUp) else { return }
        state = .ready
    }

    func retry() async {
        switch state {
        case .failed(.invite?, _):
            set(.invite, .needsYou)
            state = .waiting(.invite)
        case .failed(.signIn?, _):
            state = .running
            guard await signIn() else { return }
            waitForSetUp()
        default:
            await run()
        }
    }

    func cancel() {
        cancelled = true
        steps = steps.map { $0.status == .running ? .init(step: $0.step, status: .pending) : $0 }
        if state == .running { state = .idle }
    }

    /// As DyorLite's session: the first sign-in finds the account isn't invited yet, and the invite step takes sign-in's
    /// place until the code is sent.
    private func signIn() async -> Bool {
        set(.signIn, .running)
        guard await pause() else { return false }
        if script == .offlineOnce, !wentOffline {
            wentOffline = true
            set(.signIn, .failed(.offline))
            state = .failed(.signIn, .offline)
            return false
        }
        guard invited else {
            replace(.signIn, with: .invite)
            set(.invite, .needsYou)
            state = .waiting(.invite)
            return false
        }
        set(.signIn, .done)
        return true
    }

    private func waitForSetUp() {
        set(.setUp, .needsYou)
        state = .waiting(.setUp)
    }

    private func advance(_ step: NetworkSetup.Step) async -> Bool {
        set(step, .running)
        guard await pause() else { return false }
        set(step, .done)
        return true
    }

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
    var introSeen = false
    let setup: (any NetworkSetupSession)?

    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                NetworkSheetContent(startAt: startAt, current: current, availability: availability, method: .meraPasskey,
                                    introSeen: introSeen, setup: setup, markIntroSeen: {}, choose: { _ in }, close: {})
            }
    }
}

#Preview("Select") { NetworkSheetPreview(setup: PreviewSetupSession()) }
#Preview("Select · on Stellar") { NetworkSheetPreview(current: .stellar, setup: PreviewSetupSession()) }
#Preview("Select · unavailable") { NetworkSheetPreview(availability: .unavailable(.signInMethod(.apple)), setup: PreviewSetupSession()) }
#Preview("Confirm, then Setup (code K7Q2XM9P)") { NetworkSheetPreview(setup: PreviewSetupSession()) }
#Preview("Setup · offline once") { NetworkSheetPreview(introSeen: true, setup: PreviewSetupSession(.offlineOnce)) }
#Preview("Setup · paused") { NetworkSheetPreview(introSeen: true, setup: PreviewSetupSession(.paused)) }
#Preview("Setup · invite") {
    NetworkSheetPreview(startAt: .setup, setup: PreviewSetupSession(state: .waiting(.invite), steps: [
        .init(step: .unlock, status: .done), .init(step: .invite, status: .needsYou), .init(step: .setUp, status: .pending),
    ]))
}
#Preview("Setup · set up waits") {
    NetworkSheetPreview(startAt: .setup, setup: PreviewSetupSession(state: .waiting(.setUp), steps: [
        .init(step: .unlock, status: .done), .init(step: .signIn, status: .done), .init(step: .setUp, status: .needsYou),
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
