// A Stellar account (G…) or contract (C…) address, checked (docs/DESIGN-stellar-parity.md §3.10 rule 1). Internal builds
// only (STELLAR_LITE).
#if STELLAR_LITE
import DyorLite
import StellarKit
import UIKit

/// A Stellar address whose StrKey checksum was checked: an account (G…) or a contract (C…), never a secret seed (S…) or a
/// muxed account (M…). It is the only thing the Stellar screens put on the pasteboard, always as `checksummed`, so a copy
/// can never carry a typo, a formatted figure or a key. Token ids, memos and amounts are never copied: they are shown as
/// selectable text.
struct StellarAccountID: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A G… account.
        case account
        /// A C… contract: a launch's coin, the Moments collection, a pool.
        case contract
    }

    let kind: Kind
    /// The canonical StrKey: the decoded key encoded again, upper case, with its checksum.
    let checksummed: String

    /// `text` with blanks around it trimmed, when it is a G… or C… StrKey whose checksum holds; nil otherwise.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let key = try? StrKey.decode(.accountID, trimmed) {
            kind = .account
            checksummed = StrKey.encode(.accountID, key)
        } else if let hash = try? StrKey.decode(.contract, trimmed) {
            kind = .contract
            checksummed = StrKey.encode(.contract, hash)
        } else {
            return nil
        }
    }

    /// "GBQ4…7ZKD": its first and last four characters, as Profile shows a Stellar address (`stellarShort`).
    var short: String { checksummed.stellarShort }

    /// The address's page on StellarExpert, for the build's pinned network (`StellarExplorer`).
    func explorerURL(network: StellarNetwork = LiteGate.pinned.network) -> URL? {
        switch kind {
        case .account: StellarExplorer.account(checksummed, network: network)
        case .contract: StellarExplorer.contract(checksummed, network: network)
        }
    }

    /// Puts the address on the pasteboard, as its checksummed StrKey.
    @MainActor
    func copy() {
        let address = self
        UIPasteboard.general.string = address.checksummed
        Haptics.success()
    }
}
#endif
