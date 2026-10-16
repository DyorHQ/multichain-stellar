// How to see a Stellar Moment edition in Freighter (docs/DESIGN-stellar-parity.md §8.11.6). Internal builds only
// (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// An edition as Freighter adds it: the NFT contract that holds it and its token id. A v2 Moment is a contract of its
/// own, whose token ids are its edition numbers from 1; a retired v1 edition is a token of the v1 Moments contract.
struct StellarFreighterEdition: Identifiable, Hashable {
    let contract: StellarAccountID
    let tokenId: Int
    /// The Moment's name, for the sheet's header; nil when it isn't known.
    let name: String?
    /// The photo, or a video's cover frame.
    let image: String?
    let isVideo: Bool

    var id: String { "\(contract.checksummed)#\(tokenId)" }

    /// The edition's token id as Freighter takes it: digits only, never grouped.
    var tokenText: String { String(tokenId) }
}

/// Freighter, the Stellar wallet, shows an edition once the user adds it by its contract and token id: the steps, the
/// contract with a Copy button (its checksummed address, the only thing the Stellar screens copy), and the token id as
/// selectable text. No Freighter link opens it: no URL scheme of Freighter's was verified.
struct StellarFreighterSheet: View {
    let edition: StellarFreighterEdition
    @Environment(\.dismiss) private var dismiss
    @State private var showsFreighter = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Text("View in Freighter", tableName: "StellarMoments", comment: "Title of the sheet that explains how to see a Moment edition in Freighter, the Stellar wallet. Freighter is never translated"),
                        onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Paragraph(LocalizedStringResource("Freighter, the Stellar wallet, can show this edition once you add it. You'll need the contract address and the token ID.", table: "StellarMoments", comment: "The Freighter sheet's introduction. Freighter and Stellar are never translated"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    steps
                    contractRow
                    tokenRow
                    footers
                    Button {
                        Haptics.tap()
                        showsFreighter = true
                    } label: {
                        Label {
                            Text("Get Freighter", tableName: "StellarMoments", comment: "Button in the Freighter sheet: opens Freighter's website to install the wallet. Freighter is never translated")
                        } icon: {
                            Image(systemName: "safari")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sheet(isPresented: $showsFreighter) {
            SafariView(url: Self.freighterSite).ignoresSafeArea()
        }
    }

    /// Freighter's own site.
    static let freighterSite = URL(string: "https://freighter.app")!

    private var header: some View {
        HStack(spacing: 12) {
            StellarMomentArtwork(image: edition.image, name: edition.name ?? edition.contract.short)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: edition.name ?? edition.contract.short).font(.headline).lineLimit(2)
                Text("Edition #\(edition.tokenText)", tableName: "StellarMoments", comment: "Under a Moment's name: which edition of it this is. The value is its number (12)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            if AppNetwork.stellar.isTestnet {
                step(1, Text("Open Freighter and switch to the test network.", tableName: "StellarMoments", comment: "A step in the Freighter sheet, on testnet: the wallet must show the Stellar test network. Freighter is never translated"))
            }
            let first = AppNetwork.stellar.isTestnet ? 2 : 1
            step(first, Text("Open Collectibles and choose Add manually.", tableName: "StellarMoments", comment: "A step in the Freighter sheet: where in Freighter an NFT is added by hand. 'Collectibles' and 'Add manually' are Freighter's own English labels"))
            step(first + 1, Text("Paste the contract address, then type the token ID.", tableName: "StellarMoments", comment: "A step in the Freighter sheet: what to enter in Freighter to add the edition"))
        }
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.brand.opacity(0.14)))
                .foregroundStyle(Color.brand)
            text.font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var contractRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Contract address", tableName: "StellarMoments", comment: "Label in the Freighter sheet: the address of the NFT contract that holds the edition")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(verbatim: edition.contract.checksummed)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(verbatim: edition.contract.checksummed))
                    .speechSpellsOutCharacters()
                Spacer(minLength: 0)
                Button {
                    edition.contract.copy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// The token id, large, selectable and never copied by a button (§3.10): the user types it into Freighter.
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token ID", tableName: "StellarMoments", comment: "Label in the Freighter sheet: the edition's token number, which the user types into Freighter")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: edition.tokenText)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .accessibilityLabel(Text(verbatim: edition.tokenText))
        }
    }

    private var footers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Paragraph(LocalizedStringResource("Needs Freighter 5.37 or later.", table: "StellarMoments", comment: "A note in the Freighter sheet: the oldest Freighter version that can add a Stellar NFT. Freighter is never translated"))
            if edition.isVideo {
                Paragraph(LocalizedStringResource("Freighter shows the cover image; the video plays in DyorHQ.", table: "StellarMoments", comment: "A note in the Freighter sheet, for a video Moment: the wallet shows its still image only. Freighter and DyorHQ are never translated"))
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
#endif
