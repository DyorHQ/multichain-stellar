import DyorKit
import SwiftUI
import UIKit

/// Export for a passkey (Mera) account (MERA-PLAN §7): the 24-word recovery phrase, which restores the wallet in any
/// BIP-39 wallet without the passkey. Reached from Export Wallet (`WalletExportView`) only, never from onboarding.
///
/// - Every reveal is a fresh passkey prompt pinned to this account, even while a session is live, and the words must
///   derive the address on screen (`MeraSession.revealPhrase`).
/// - The words are blanked while the screen is recorded, mirrored or AirPlayed, and dropped when the app leaves the
///   foreground (PrivacyCover covers the snapshot). They hide themselves after a minute — "Keep Showing" gives another,
///   and VoiceOver hears twenty seconds' notice first — are never stored, and have no Copy: the phrase belongs on paper.
/// - "Done" needs three random words confirmed (`Mera.RecoveryPhrase.Quiz`). A wrong answer means revealing again,
///   so the choices can't be guessed through.
struct RecoveryPhraseView: View {
    /// Called once the words are confirmed.
    var onConfirmed: (() -> Void)? = nil

    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        /// Nothing revealed.
        case start
        /// The words on screen until `hidesAt`, and the quiz drawn from them.
        case shown(words: [String], quiz: Mera.RecoveryPhrase.Quiz, hidesAt: Date)
        /// The words are gone; only the quiz's three are kept.
        case confirming(Mera.RecoveryPhrase.Quiz)
    }

    @State private var stage: Stage = .start
    /// Question number → the word picked.
    @State private var picks: [Int: String] = [:]
    /// Whether the screen is being captured. Nil until the observer reports, and nil counts as captured, so the words
    /// never flash up before the first report.
    @State private var captured: Bool?
    @State private var screenshotTaken = false
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?

    private var hidesAt: Date? { if case .shown(_, _, let date) = stage { return date } else { return nil } }
    /// How long before the words hide VoiceOver is told, time enough to choose Keep Showing.
    private static let warning: TimeInterval = 20

    var body: some View {
        List {
            switch stage {
            case .start: startSections
            case .shown(let words, _, let hidesAt): shownSections(words, hidesAt: hidesAt)
            case .confirming(let quiz): confirmSections(quiz)
            }
            warningSection
        }
        .navigationTitle(tr("Recovery Phrase"))
        .navigationBarTitleDisplayMode(.inline)
        .background { ScreenCaptureObserver { captured = $0 } }
        // The words hide themselves a minute after the reveal (or the last Keep Showing), with a spoken warning twenty
        // seconds before for VoiceOver, and a spoken note when they go (AI-11).
        .task(id: hidesAt) {
            guard let hidesAt else { return }
            let warnAt = hidesAt.addingTimeInterval(-Self.warning)
            if warnAt.timeIntervalSinceNow > 0 { try? await Task.sleep(for: .seconds(warnAt.timeIntervalSinceNow)) }
            guard !Task.isCancelled, self.hidesAt == hidesAt else { return }
            UIAccessibility.post(notification: .announcement, argument: tr("Your recovery phrase hides in \(Int(Self.warning)) seconds. Choose Keep Showing for more time."))
            try? await Task.sleep(for: .seconds(max(0, hidesAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, self.hidesAt == hidesAt else { return }
            hide(notice: tr("Hidden when its time ran out. Show it again if you haven't finished writing it down."))
            UIAccessibility.post(notification: .announcement, argument: tr("Recovery phrase hidden."))
        }
        // Leaving the foreground drops the words; PrivacyCover covers the snapshot meanwhile. A passkey prompt makes the
        // scene inactive too, and that isn't leaving.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && !session.mera.isPrompting) { hide(notice: nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if case .shown = stage { screenshotTaken = true; Haptics.warning() }
        }
        .onDisappear { stage = .start; picks = [:] }
    }

    // MARK: Start

    @ViewBuilder private var startSections: some View {
        Section {
            Button { reveal() } label: {
                HStack {
                    Label("Show Recovery Phrase", systemImage: "key.horizontal")
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                }
            }
            .disabled(working || !session.isPasskeyAccount)
        } header: {
            Text("Recovery Phrase")
        } footer: {
            if let error { InlineError(message: error) }
            else { Paragraph("Your passkey is this wallet's key. These 24 words are a second way in: they restore the same wallet in MetaMask, Rabby or any wallet that takes a recovery phrase, even without your passkey. Showing them always asks for \(BiometricGate.promptName), and they hide after a minute unless you keep them showing.") }
        }
    }

    // MARK: Shown

    @ViewBuilder private func shownSections(_ words: [String], hidesAt: Date) -> some View {
        Section {
            if captured ?? true {
                Label("Hidden while the screen is being recorded, mirrored or shared.", systemImage: "eye.slash")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                PhraseGrid(words: words)
            }
        } header: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    Text("Your 24 words")
                    Spacer()
                    Text("Hides in \(Self.seconds(max(0, Int(hidesAt.timeIntervalSince(context.date).rounded(.up)))))").monospacedDigit()
                }
            }
        } footer: {
            if screenshotTaken {
                InlineError(message: "You took a screenshot of your recovery phrase. Delete it from Photos, and from Recently Deleted: anyone who sees it can take your funds.")
            } else {
                Paragraph("Write them on paper, in order. Don't screenshot, copy or save them anywhere online.")
            }
        }

        Section {
            Button("I've Written It Down", systemImage: "checkmark") { Haptics.tap(); hide(notice: nil) }
            Button("Keep Showing", systemImage: "clock.arrow.circlepath") { Haptics.tap(); keepShowing() }
        } footer: {
            Paragraph("Keep Showing gives you another minute. Nothing else is asked.")
        }
    }

    // MARK: Confirm

    @ViewBuilder private func confirmSections(_ quiz: Mera.RecoveryPhrase.Quiz) -> some View {
        Section {
            ForEach(quiz.questions) { question in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Word #\(question.number)").font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(question.choices, id: \.self) { word in
                            choice(word, selected: picks[question.number] == word) {
                                Haptics.selection()
                                picks[question.number] = word
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Confirm your backup")
        } footer: {
            if let notice { Text(verbatim: notice) }
            else { Paragraph("Pick each word from the copy you wrote down.") }
        }

        Section {
            Button("Done", systemImage: "checkmark.seal") { finish(quiz) }
                .disabled(quiz.questions.contains { picks[$0.number] == nil })
            Button { reveal() } label: {
                HStack {
                    Label("Show the Phrase Again", systemImage: "eye")
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                }
            }
            .disabled(working)
        } footer: {
            if let error { InlineError(message: error) }
            else { Text("Showing it again asks for \(BiometricGate.promptName).") }
        }
    }

    private func choice(_ word: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(word)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.brand : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        // Each choice its own tap target, not the whole row.
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Shared

    private var warningSection: some View {
        Section {
            Label("Anyone with these words has full control of your funds, on Monad and on every other chain. Never share them — DyorHQ support will never ask for them.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Color.attention)
            Label("Only enter them into a wallet you trust (MetaMask, Rabby, OKX…). A hardware wallet is safest.", systemImage: "hand.raised.fill")
                .font(.footnote).foregroundStyle(.secondary)
        } footer: {
            if let short = session.address?.short {
                Paragraph("This is the phrase for \(short). DyorHQ never stores it.")
            } else {
                Paragraph("This is the phrase for your wallet. DyorHQ never stores it.")
            }
        }
    }

    // MARK: Actions

    private func reveal() {
        guard session.isPasskeyAccount, let address = session.address else { return }
        working = true
        error = nil
        notice = nil
        Task {
            defer { working = false }
            do {
                let words = try await session.mera.revealPhrase(expecting: address)
                // The app left the foreground while the prompt was up: the words aren't shown.
                guard UIApplication.shared.applicationState != .background else { return }
                guard let quiz = Mera.RecoveryPhrase.Quiz(words: words) else { throw MeraSession.Failure.phraseUnavailable }
                picks = [:]
                screenshotTaken = false
                stage = .shown(words: words, quiz: quiz, hidesAt: Date().addingTimeInterval(Mera.RecoveryPhrase.visibleFor))
                Haptics.warning()
            } catch where isUserCancellation(error) {
            } catch {
                self.error = describe(error)
            }
        }
    }

    /// Another full minute on screen from now, for anyone still writing (AI-11).
    private func keepShowing() {
        guard case .shown(let words, let quiz, _) = stage else { return }
        stage = .shown(words: words, quiz: quiz, hidesAt: Date().addingTimeInterval(Mera.RecoveryPhrase.visibleFor))
    }

    /// "12s": a countdown in seconds, in the app's language's own short unit.
    static func seconds(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow).locale(L10n.locale))
    }

    /// Drops the words from the screen and memory, keeping only the quiz's three. `notice` is in the app's language.
    private func hide(notice: String?) {
        guard case .shown(_, let quiz, _) = stage else { return }
        stage = .confirming(quiz)
        picks = [:]
        self.notice = notice
    }

    private func finish(_ quiz: Mera.RecoveryPhrase.Quiz) {
        let passed = quiz.passes(picks)
        stage = .start
        picks = [:]
        notice = nil
        guard passed else {
            Haptics.error()
            error = tr("That doesn't match your recovery phrase. Show it again and check what you wrote down.")
            return
        }
        Haptics.success()
        onConfirmed?()
        dismiss()
    }
}

/// The 24 words, numbered, in reading order. Not selectable: the system's Copy has no expiry and syncs to other devices.
private struct PhraseGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 8) {
                    Text(verbatim: "\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(word).font(.body.monospaced())
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Word \(index + 1), \(word)")
            }
        }
        .privacySensitive()
        .padding(.vertical, 4)
    }
}

/// Reports whether the screen is being recorded, mirrored or AirPlayed: the scene's `sceneCaptureState` trait, with
/// `UIScreen.isCaptured` and its change notification as a second source. Either one blanks the words.
private struct ScreenCaptureObserver: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> ObserverView { ObserverView(onChange: onChange) }
    func updateUIView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: UIView {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            _ = registerForTraitChanges([UITraitSceneCaptureState.self]) { (view: ObserverView, _: UITraitCollection) in view.report() }
            NotificationCenter.default.addObserver(self, selector: #selector(report), name: UIScreen.capturedDidChangeNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { report() }
        }

        @objc private func report() {
            let captured = traitCollection.sceneCaptureState == .active || (window?.windowScene?.screen.isCaptured ?? false)
            // Outside SwiftUI's update pass, which may be the one that moved this view into its window.
            DispatchQueue.main.async { [onChange] in onChange(captured) }
        }
    }
}
