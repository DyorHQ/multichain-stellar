// Profile's Stellar pieces (docs/DESIGN-network-switch.md §3.5). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Profile › Network › Stellar account: the account's short Stellar address, pushing DyorLite's account screen inside
/// Profile's stack (the address to copy, Secured by, Network, Reserves paid by DyorHQ, the secret key, test XLM, Sign out of
/// Stellar). Nothing while the account's Stellar address isn't known on this iPhone.
struct StellarAccountRow: View {
    /// The account's Monad address, which its Stellar one is filed under.
    let owner: Address
    @Environment(\.stellarSession) private var stellar

    var body: some View {
        if let address = DyorHQLiteKeys.stellarAddress(for: owner) {
            if let stellar {
                NavigationLink {
                    LiteAccountView(session: stellar).environment(\.liteStyle, .dyorHQ)
                } label: {
                    row(address)
                }
            } else {
                row(address)
            }
        }
    }

    private func row(_ address: String) -> some View {
        LabeledContent {
            Text(verbatim: address.stellarShort)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .speechSpellsOutCharacters()
        } label: {
            SettingsRow(liteTr(LocalizedStringResource("Stellar account", table: "Lite", comment: "Profile › Network, when Stellar is the network: the row of the account's Stellar address, which opens its Stellar account details")),
                        symbol: "person.text.rectangle", tint: .accent)
        }
    }
}

/// Profile › Wallet's Receive and Send while Stellar is the network: DyorLite's deposit and withdraw sheets, each with its
/// own close button.
enum StellarWalletSheet: String, Identifiable {
    case deposit, withdraw
    var id: String { rawValue }
}

extension View {
    /// Presents Stellar's deposit or withdraw sheet while `sheet` is set, for the account's Stellar session.
    func stellarWalletSheet(_ sheet: Binding<StellarWalletSheet?>) -> some View {
        modifier(StellarWalletSheetPresenter(sheet: sheet))
    }
}

private struct StellarWalletSheetPresenter: ViewModifier {
    @Binding var sheet: StellarWalletSheet?
    @Environment(\.stellarSession) private var stellar

    func body(content: Content) -> some View {
        content.sheet(item: $sheet) { sheet in
            if let stellar {
                Group {
                    switch sheet {
                    case .deposit: LiteDepositSheet(session: stellar)
                    case .withdraw: LiteWithdrawSheet(session: stellar)
                    }
                }
                .environment(\.liteStyle, .dyorHQ)
            }
        }
    }
}
#endif
