import DyorKit
import SwiftUI

// Chain + token iconography for the Bridge. Real brand logos come from Trust Wallet's asset repo on
// raw.githubusercontent.com — the same trusted host the app already uses for Monad's token list — and every glyph
// degrades to a coloured monogram when the network image is missing, so a row is never a blank placeholder.

private enum BridgeLogo {
    static let base = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains"

    /// Aurora `blockchain` id → Trust Wallet chain slug. Chains Trust Wallet doesn't publish (Berachain, Monad) map to
    /// nil, so their glyphs fall back to a brand-coloured monogram instead of a dead request.
    static let slug: [String: String] = [
        "eth": "ethereum", "base": "base", "arb": "arbitrum", "op": "optimism", "pol": "polygon",
        "bsc": "smartchain", "avax": "avalanchec", "gnosis": "xdai", "scroll": "scroll",
    ]

    /// Native-asset symbol → the coin's own logo slug (so native ETH shows the ETH mark, not the L2's chain mark).
    static let nativeSlug: [String: String] = [
        "ETH": "ethereum", "POL": "polygon", "MATIC": "polygon", "BNB": "smartchain",
        "AVAX": "avalanchec", "XDAI": "xdai",
    ]

    static func chain(_ auroraId: String) -> URL? { slug[auroraId].flatMap { URL(string: "\(base)/\($0)/info/logo.png") } }
    static func native(_ symbol: String) -> URL? { nativeSlug[symbol.uppercased()].flatMap { URL(string: "\(base)/\($0)/info/logo.png") } }
    static func erc20(_ auroraId: String, _ checksummed: String) -> URL? {
        slug[auroraId].flatMap { URL(string: "\(base)/\($0)/assets/\(checksummed)/logo.png") }
    }
}

extension EVMChain {
    /// The chain's own brand logo (Ethereum diamond, Base circle, Arbitrum, …). `nil` for chains without a Trust Wallet
    /// entry, which then render the monogram.
    var logoURL: URL? { BridgeLogo.chain(auroraId) }

    /// Brand colour, used for the monogram fallback fill and small chain accents.
    var brandColor: Color {
        switch auroraId {
        case "eth": return Color(hex: 0x627EEA)
        case "base": return Color(hex: 0x0052FF)
        case "arb": return Color(hex: 0x12AAFF)
        case "op": return Color(hex: 0xFF0420)
        case "pol": return Color(hex: 0x8247E5)
        case "bsc": return Color(hex: 0xF0B90B)
        case "avax": return Color(hex: 0xE84142)
        case "gnosis": return Color(hex: 0x3E6957)
        case "scroll": return Color(hex: 0xE9A24A)
        case "bera": return Color(hex: 0xD2691E)
        case "monad": return .brand
        default: return .brand
        }
    }

    /// One/two-letter monogram for the fallback badge.
    var monogram: String {
        switch auroraId {
        case "eth": return "E"; case "base": return "B"; case "arb": return "AR"; case "op": return "OP"
        case "pol": return "PO"; case "bsc": return "BN"; case "avax": return "AV"; case "gnosis": return "GN"
        case "scroll": return "SC"; case "bera": return "BE"; case "monad": return "M"
        default: return String(name.prefix(1))
        }
    }
}

extension AuroraToken {
    /// Real logo for this asset: the ERC-20's Trust Wallet image (keyed by checksummed address), or — for a native
    /// asset — the coin's own mark. `nil` where unavailable, which `MarketLogo` turns into a monogram.
    var logoURL: URL? {
        if isNative { return BridgeLogo.native(symbol) }
        guard let contract = contractAddress, let checksummed = Address(contract)?.checksummed else { return nil }
        return BridgeLogo.erc20(blockchain, checksummed)
    }
}

/// A small circular chain badge: the chain's real logo when Trust Wallet has it, otherwise a brand-coloured monogram.
/// Like `TokenLogo`, it shows its plain tinted disc for a moment while the logo loads, so the letters don't flash
/// first, then the letters until it comes (`RemoteImageWait`).
struct ChainBadge: View {
    let chain: EVMChain
    var size: CGFloat = 20

    var body: some View {
        Group {
            RemoteImage(url: chain.logoURL, pointSize: size, contentMode: .fit, grace: RemoteImageWait.grace) { loading in
                if loading { Color.clear } else { monogram }
            }
        }
        .frame(width: size, height: size)
        .background(chain.brandColor.opacity(0.18))
        .clipShape(Circle())
        .accessibilityIgnoresInvertColors() // the logo; its ring inverts with the card, like TokenLogo's
        .overlay(Circle().strokeBorder(Color.logoRing, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        ZStack {
            chain.brandColor
            Text(chain.monogram)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// A network-free brand-coloured chain monogram — used as the corner badge on `AssetGlyph` in long lists, where a
/// second remote image per row would flicker and burst requests. The chain name still appears as row text.
struct ChainDot: View {
    let chain: EVMChain
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            chain.brandColor
            Text(chain.monogram)
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .padding(1)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityIgnoresInvertColors() // like the MarketLogo it sits on in AssetGlyph
        .accessibilityHidden(true)
    }
}

/// A token logo with the chain badge tucked into its corner — the "which asset, on which chain" glyph used in the
/// cross-chain asset list, exactly the pattern Monday Trade uses.
struct AssetGlyph: View {
    let token: AuroraToken
    let chain: EVMChain
    var size: CGFloat = 34

    var body: some View {
        MarketLogo(symbol: token.symbol, url: token.logoURL, size: size)
            .overlay(alignment: .bottomTrailing) {
                ChainDot(chain: chain, size: size * 0.5)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
    }
}

extension Color {
    /// 0xRRGGBB literal → Color. Used only for the fixed set of chain brand hues.
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
