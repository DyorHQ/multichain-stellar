// Stellar copy of ios/DyorHQ/Design/Components.swift TokenBadgeView (42cd8c7 sha256:04b1f4838562)
// Stellar copy of ios/DyorHQ/Home/HomeView.swift NewBadge (42cd8c7 sha256:9515837220e5)
// What a Stellar asset's row says about where it came from (docs/DESIGN-stellar-parity.md §3.5, §8.2.6, §8.3). Internal
// builds only (STELLAR_LITE).
#if STELLAR_LITE
import SwiftUI

/// What a Stellar asset's row says about it, from the server's `badges` and `verified` (§6.5): "DyorHQ Launch" in the
/// brand colour, or a warning in the attention colour — a look-alike's "Not the real USDC", or "Unverified" for an asset
/// DyorHQ doesn't list — or "Blend test" in grey for Blend's test USDC, and nothing for XLM and the listed assets. `.new`
/// is the "New" capsule that stands in for a coin's 24h change while it has none, in the change's place and size.
struct StellarTokenBadge: View {
    enum Kind: Hashable {
        /// A DyorHQ launch's coin.
        case launch
        /// An asset DyorHQ doesn't list (a classic trustline outside the registry, or a contract found by its id).
        case unverified
        /// A look-alike: its code reads as a listed asset's without being it. The value is that code.
        case imitation(String)
        /// Blend's test USDC: not Circle's, and with no market.
        case testAsset
        /// A coin under a day old, which has no 24h change yet.
        case new
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// The badge a holdings or search row shows, from the server's words about it; nil for none. A look-alike is said
    /// first, whatever else it is.
    static func kind(badges: [String], verified: Bool, code: String) -> Kind? {
        if badges.contains("lookAlike") { return .imitation(code) }
        if badges.contains("testAsset") { return .testAsset }
        if badges.contains("launch") { return .launch }
        if badges.contains("unverified") || !verified { return .unverified }
        return nil
    }

    var body: some View {
        switch kind {
        case .new:
            Text("New")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.brand.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.brand)
        default:
            label
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8) // shrinks a little before it truncates: the label's point is its whole name
                .foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tint.opacity(0.14), in: Capsule())
                .layoutPriority(-1)
        }
    }

    @ViewBuilder private var label: some View {
        switch kind {
        case .launch:
            Text("DyorHQ Launch", tableName: "StellarCommon", comment: "[tight] A Stellar coin's badge: launched on the DyorHQ launchpad. DyorHQ is never translated")
        case .unverified:
            Text("Unverified")
        case .imitation(let code):
            Text("Not the real \(code)", tableName: "StellarCommon", comment: "[tight] A warning badge on a Stellar look-alike token: the value is the code it imitates (USDC), never translated")
        case .testAsset:
            Text("Blend test", tableName: "StellarCommon", comment: "[tight] A badge on Blend's test USDC: a test token only the Blend lending protocol's testnet pool uses, not Circle's USDC. Blend is never translated")
        case .new:
            EmptyView()
        }
    }

    private var tint: Color {
        switch kind {
        case .launch, .new: return .brand
        case .unverified, .imitation: return .attention
        case .testAsset: return .secondary
        }
    }
}
#endif
