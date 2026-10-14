import DyorKit
import SwiftUI

/// The confirmation sheet's line for a passkey (Mera) account: "No Face ID needed" when the live session signs this
/// plan on its own, or "Face ID required: <reason>" (MERA-PLAN §3 "On screen").
struct SessionScopeBadge: View {
    let assessment: MeraSession.Assessment

    var body: some View {
        Label(assessment.badge, systemImage: assessment.isRefused ? "xmark.shield.fill" : (assessment.needsFaceID ? BiometricGate.promptSymbol : "checkmark.shield.fill"))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(assessment.isRefused ? Color.negative : (assessment.needsFaceID ? Color.primary : Color.positive))
            .accessibilityLabel(assessment.badge)
    }
}

/// Home's session pill for a passkey account: "Active · 12m" while a session is live, amber in its last minute, and
/// "Locked" once it ends. Tapping it shows what the session signs on its own. Expiry only changes the pill.
struct SessionPill: View {
    @Environment(Session.self) private var session
    @State private var showScope = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = SessionPillState(expiresAt: session.mera.expiresAt, now: context.date)
            Button { Haptics.tap(); showScope = true } label: {
                Label(state.title, systemImage: state.isActive ? "lock.open.fill" : "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(state.isEnding ? Color.attention : (state.isActive ? Color.positive : Color.secondary))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isActive ? "Passkey session \(state.title)" : "Passkey session locked")
            .accessibilityHint("Shows what signs without \(BiometricGate.promptName)")
        }
        .sheet(isPresented: $showScope) { SessionScopeSheet() }
    }
}

/// The pill's text for a session ending at `expiresAt` (nil while locked), as of `now`, in the app's language: the time
/// left in its short units ("12m", "45s").
struct SessionPillState: Equatable {
    let isActive: Bool
    /// The last minute: the pill turns amber.
    let isEnding: Bool
    let title: String

    init(expiresAt: Date?, now: Date) {
        guard let expiresAt, expiresAt > now else {
            isActive = false; isEnding = false
            title = tr(LocalizedStringResource("Locked", comment: "The passkey session is locked or has ended: the next signature asks for the passkey [tight]"))
            return
        }
        let left = expiresAt.timeIntervalSince(now)
        isActive = true
        isEnding = left <= 60
        let time = isEnding ? Duration.seconds(Int(left.rounded(.up))).formatted(.units(allowed: [.seconds], width: .narrow).locale(L10n.locale))
            : Duration.seconds(Int((left / 60).rounded(.up)) * 60).formatted(.units(allowed: [.minutes], width: .narrow).locale(L10n.locale))
        title = tr(LocalizedStringResource("Active · \(time)", comment: "A live passkey session and the time it has left: “Active · 12m”. [tight]"))
    }
}

/// What a passkey session signs on its own and what always asks (MERA-PLAN §3), with the live session's time and
/// spending left, Lock now, and Unlock.
struct SessionScopeSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var unlocking = false
    @State private var error: String?

    var body: some View {
        let mera = session.mera
        NavigationStack {
            List {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let state = SessionPillState(expiresAt: mera.expiresAt, now: context.date)
                        LabeledContent("Session") {
                            Text(verbatim: state.title)
                                .monospacedDigit()
                                .foregroundStyle(state.isEnding ? Color.attention : (state.isActive ? Color.positive : Color.secondary))
                        }
                    }
                    if let expiresAt = mera.expiresAt {
                        LabeledContent("Ends", value: expiresAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))
                    }
                    if let spent = mera.spentUSD, let left = mera.remainingUSD {
                        LabeledContent("Signed this session", value: PriceFormat.usdValue(spent))
                        LabeledContent("Left before \(BiometricGate.promptName)", value: PriceFormat.usdValue(left))
                    }
                    if mera.isUnlocked {
                        Button("Lock now", systemImage: "lock") { Haptics.tap(); mera.end() }
                    } else {
                        Button { unlock() } label: {
                            HStack {
                                Label("Unlock with \(BiometricGate.promptName)", systemImage: BiometricGate.promptSymbol)
                                if unlocking { Spacer(); ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(unlocking)
                    }
                } footer: {
                    if let error { InlineError(message: error) }
                    else { Paragraph("A session lasts \(Self.length(mera.sessionLength)) from the \(BiometricGate.promptName) that opens it, and ends when you leave the app. Change the length in Settings.") }
                }

                Section {
                    row("arrow.left.arrow.right", "Swaps on Uniswap, Monday Trade and Kuru Flow")
                    row("arrow.triangle.2.circlepath", "Wrapping and unwrapping MON")
                    row("chart.line.uptrend.xyaxis", "Launchpad buys and sells")
                    row("photo.stack", "Moments: collect, claim, withdraw to you")
                    row("chart.xyaxis.line", "Perpl: deposit, withdraw to you, orders and brackets")
                } header: {
                    Text("No \(BiometricGate.promptName) needed while active")
                } footer: {
                    Paragraph("Up to \(Self.dollars(Mera.SpendingCaps.perActionUSD)) per action and \(Self.dollars(Mera.SpendingCaps.perSessionUSD)) per session, and only when DyorHQ can price it. Every transaction is also checked on its own: the right chain and contract, approvals for exactly the amount shown, and the output coming back to you.")
                }

                Section {
                    row("paperplane", "Sending or transferring tokens")
                    row("point.3.connected.trianglepath.dotted", "Bridging to another chain")
                    row("sparkles", "Launching a coin or creating a Moment")
                    row("arrow.up.forward.square", "Withdrawing to another address")
                    row("xmark.circle", "Cancelling orders and closing positions")
                    row("key", "Showing your recovery phrase")
                    row("trash", "Deleting your account")
                    row("timer", "Making sessions longer")
                    row("signature", "Signing any message other than DyorHQ sign-in")
                } header: {
                    Text("Always asks for \(BiometricGate.promptName)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Passkey Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: symbol).font(.subheadline)
    }

    private func unlock() {
        unlocking = true; error = nil
        Task {
            do { try await session.mera.unlock() }
            catch where isUserCancellation(error) {}
            catch { self.error = describe(error) }
            unlocking = false
        }
    }

    /// A session's length in the app's language: "15 minutes", or "1 hour" for an hour or more.
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = seconds >= 3600 ? 60 : Int(seconds / 60)
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(L10n.locale))
    }

    /// A spending cap in whole dollars, "$50", in the app's one number style.
    static func dollars(_ value: Double) -> String { "$\(Int(value))" }
}
