// A history part with no session (docs/DESIGN-stellar-parity.md §8, decision 6). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorLite
import SwiftUI

/// What a part of DyorHQ's own history (Total Volume, Portfolio, Recent Activity, My Launchpad, My Moments, Swap History)
/// shows in place of its figures for a passkey account whose session is gone (its refresh token revoked, signed out, or
/// unused for 30 days, §6.18): it says why, and offers the passkey. Nothing prompts until the button is tapped; seed
/// accounts never see it, since they sign in again silently. Figures from the chain fill in with no session at all.
struct StellarSignInRow: View {
    @Environment(\.stellarActions) private var actions
    @State private var signingIn = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Paragraph(LocalizedStringResource("Sign in again to see your Stellar history.", table: "StellarCommon", comment: "In place of the account's Stellar history (volume, portfolio, activity) when its session has ended: the history needs a sign-in. Stellar is never translated"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Haptics.tap()
                Task { await signIn() }
            } label: {
                HStack(spacing: 8) {
                    if signingIn { ProgressView().controlSize(.small) }
                    Text("Sign in with your passkey", tableName: "StellarCommon", comment: "Button: sign in to DyorHQ on Stellar with the account's passkey (one passkey prompt), to see its history")
                }
            }
            .buttonStyle(.bordered)
            .disabled(signingIn)
            if let failure { InlineError(message: failure) }
        }
        .padding(.vertical, 4)
    }

    private func signIn() async {
        signingIn = true
        failure = nil
        defer { signingIn = false }
        do {
            try await actions.signIn()
        } catch {
            // A dismissed passkey prompt is the user's choice: nothing to say. Anything else, as the screens say it.
            if (error as? LiteSession.Failure) != .cancelled { failure = LiteErrorText.describe(error) }
        }
    }
}
#endif
