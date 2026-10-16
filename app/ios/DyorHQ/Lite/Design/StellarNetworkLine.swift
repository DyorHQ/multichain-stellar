// "◉ Stellar [Testnet]": the network a review or a page is about (docs/DESIGN-stellar-parity.md §8.1). Internal builds
// only (STELLAR_LITE).
#if STELLAR_LITE
import SwiftUI

/// Stellar's mark and name, with the Testnet badge on a test network: the review sheet's first section header, so every
/// Stellar transaction says which network it is on. The badge hangs off `AppNetwork.stellar.isTestnet`, so a mainnet
/// build shows the name alone.
struct StellarNetworkLine: View {
    /// The mark grows with the name's text.
    @ScaledMetric(relativeTo: .footnote) private var markSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            NetworkMark(network: .stellar, size: markSize)
            Text(verbatim: AppNetwork.stellar.name)
            if AppNetwork.stellar.isTestnet { TestnetBadge() }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
