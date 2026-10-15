// Stellar copy of ios/DyorHQ/Design/Components.swift AddressRow (42cd8c7 sha256:6746f410615e)
// A copyable Stellar address row (docs/DESIGN-stellar-parity.md §3.5, §3.10). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import SwiftUI

/// Copyable Stellar address row. Its title is a catalog key when written in the code, a resource that names its Stellar
/// table, or a `String` shown as it is. The copy is the address's checksummed StrKey (`StellarAccountID.copy`), the only
/// thing the Stellar screens put on the pasteboard.
struct StellarAddressRow: View {
    private let title: Text
    let address: StellarAccountID

    init(title: LocalizedStringKey, address: StellarAccountID) {
        self.title = Text(title)
        self.address = address
    }

    /// A title that names its Stellar table: `LocalizedStringResource("…", table: "Stellar…", comment: "…")`.
    init(resource: LocalizedStringResource, address: StellarAccountID) {
        self.title = Text(resource)
        self.address = address
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, address: StellarAccountID) {
        self.title = Text(verbatim: String(title))
        self.address = address
    }

    var body: some View {
        LabeledContent {
            StellarAddressText(address)
                .foregroundStyle(.secondary)
        } label: {
            title
        }
        .contextMenu {
            Button("Copy Address", systemImage: "doc.on.doc") { address.copy() }
            if let page = address.explorerURL() {
                Link(destination: page) {
                    Label {
                        Text("View on StellarExpert", tableName: "StellarCommon", comment: "A menu item and a link: opens this address, contract or transaction on StellarExpert, a Stellar block explorer. StellarExpert is never translated")
                    } icon: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
    }
}
#endif
