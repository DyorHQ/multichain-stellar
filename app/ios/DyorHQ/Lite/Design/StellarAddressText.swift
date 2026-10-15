// A Stellar address as a review or a row shows it (docs/DESIGN-stellar-parity.md §3.10, §5.2). Internal builds only
// (STELLAR_LITE).
#if STELLAR_LITE
import SwiftUI

/// A checked Stellar address, short ("GBQ4…7ZKD") or whole, in the monospaced style Monad's addresses use. VoiceOver reads
/// it character by character, always whole. A review shows the bound address the transaction pays (`intent.to`), never a
/// display string; the whole address is selectable, so it can be checked against what the user meant.
struct StellarAddressText: View {
    let address: StellarAccountID
    /// The whole address, on as many lines as it takes, instead of its short form.
    var whole = false

    init(_ address: StellarAccountID, whole: Bool = false) {
        self.address = address
        self.whole = whole
    }

    var body: some View {
        Text(verbatim: whole ? address.checksummed : address.short)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel(Text(verbatim: address.checksummed))
            .speechSpellsOutCharacters()
    }
}
#endif
