// Stellar copy of ios/DyorHQ/Design/Components.swift TokenLogo (42cd8c7 sha256:ddb682e47093)
// Stellar copy of ios/DyorHQ/Design/Components.swift LogoDisc (42cd8c7 sha256:8e179eabdd6d)
// Stellar copy of ios/DyorHQ/Design/Components.swift LogoMonogram (42cd8c7 sha256:80b5af3213d5)
// A Stellar asset's logo (docs/DESIGN-stellar-parity.md §3.5). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import StellarKit
import SwiftUI

/// A Stellar asset's logo, decided by what the asset is, never by what it is called: XLM's mark for native XLM, Circle's
/// logo for Circle's own USDC (by its issuer), a DyorHQ launch's uploaded art (only from DyorHQ's media, `StellarImages`),
/// filled, and letters for everything else, or while nothing can be loaded. A coin named "USDC" never wears Circle's
/// logo. Always circular, on the plate and with the faint ring that suits the appearance (`StellarLogoDisc`), as
/// `TokenLogo` draws Monad's.
struct StellarTokenLogo: View {
    /// The asset's code or the coin's symbol: its letters.
    private let symbol: String
    /// A bundled logo's image name, for an asset the build itself recognises.
    private let bundled: String?
    /// A launch's uploaded art.
    private let image: String?
    var size: CGFloat = 36

    /// `symbol`'s logo: the bundled one when `classic` ("native", "USDC:G…") is an asset this build knows by its issuer
    /// on `network`, else `image` (a launch's art, from DyorHQ's media only), else its letters.
    init(symbol: String, classic: String? = nil, image: String? = nil, size: CGFloat = 36,
         network: StellarNetwork = LiteGate.pinned.network) {
        self.symbol = symbol
        bundled = classic.flatMap { Self.bundledLogo(classic: $0, network: network) }
        self.image = image
        self.size = size
    }

    /// The bundled logo of a classic asset ("native", or "CODE:ISSUER"), by its issuer and never by its code alone: XLM's
    /// mark (the network's own, `logo-XLM`, Internal/Resources) and Circle's USDC. Nil for every other asset.
    static func bundledLogo(classic: String, network: StellarNetwork) -> String? {
        if classic == "native" { return "logo-XLM" }
        return circleUSDC[network.name] == classic ? "logo-USDC" : nil
    }

    /// Circle's USDC on each network, as "USDC:<Circle's issuing account>".
    static let circleUSDC = [
        StellarNetwork.testnet.name: "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5",
        StellarNetwork.mainnet.name: "USDC:GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
    ]

    var body: some View {
        StellarLogoDisc(size: size) {
            let sources = StellarImages.sources(image, pointSize: size)
            if let bundled, let shipped = UIImage(named: bundled) {
                Image(uiImage: shipped).resizable().scaledToFit()
            } else if !sources.isEmpty {
                // Capped and downsampled (RemoteImage): a neutral disc for a moment while it loads, then the monogram until
                // it comes; the monogram at once when it failed lately (RemoteImageWait).
                RemoteImage(sources: sources, pointSize: size, contentMode: .fill, grace: RemoteImageWait.grace) { loading in
                    if loading { Color.clear } else { monogram }
                }
            } else {
                monogram
            }
        }
    }

    private var monogram: some View { StellarLogoMonogram(symbol: symbol, size: size) }
}

/// The circle every Stellar logo sits in: a neutral plate under the picture, clipped round, with a faint ring that suits
/// the appearance (`Color.logoRing`). Smart Invert leaves the logo as it is but inverts the ring with the card, so the ring
/// still edges the logo on the inverted card.
struct StellarLogoDisc<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill))
            .clipShape(Circle())
            .accessibilityIgnoresInvertColors()
            .overlay(Circle().strokeBorder(Color.logoRing, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// An asset with no image gets a filled monogram in a colour derived from its symbol, so it reads as a real avatar (and
/// each asset keeps a consistent, distinct colour) rather than a grey placeholder.
struct StellarLogoMonogram: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        let seed = symbol.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(seed % 360) / 360
        let tint = Color(hue: hue, saturation: 0.5, brightness: 0.62)
        let letters = ChainText.leading(symbol, 2)
        ZStack {
            LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // One line, shrunk rather than wrapped, inset from the sides so wide letters fit the circle. "?" for an asset
            // with no symbol that draws.
            Text(verbatim: letters.isEmpty ? "?" : letters.uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.12)
                .foregroundStyle(.white)
        }
    }
}
#endif
