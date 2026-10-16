// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift LaunchArtwork (42cd8c7 sha256:d81d37e88d1c)
// A Stellar launch's artwork (docs/DESIGN-stellar-parity.md §3.5, §3.8). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import SwiftUI

/// A Stellar coin's artwork: its uploaded image, or a monogram on a tinted ground when it has none. The image is whatever
/// the launch's metadata names, so it is loaded only from DyorHQ's own media under the build's pinned base
/// (`StellarImages`, `LiteMediaPolicy`), never a host the launcher chose, through the capped loader (RemoteImage).
struct StellarArtwork: View {
    let symbol: String
    /// The launch's image, as its metadata names it; nil for none.
    let image: String?
    /// How wide the artwork is drawn, in points: the thumbnail is decoded for this size.
    var pointSize: CGFloat = StellarArtwork.cardPointSize

    /// The size a board's card draws it at, and what its next rows are warmed at (`prefetch`).
    static let cardPointSize: CGFloat = 240

    /// Warms the picture a board's card for `image` will ask for — the same sources, size bucket and caps as `body` at
    /// `cardPointSize` — ahead of the board's scroll (`BoardPrefetch`, `ImagePipeline.prefetch`).
    @MainActor static func prefetch(image: String?) {
        let bucket = ImageSizeBucket.bucket(points: cardPointSize)
        RemoteImageLoader.shared.prefetch(StellarImages.sources(image, pointSize: cardPointSize), bucket: bucket,
                                          caps: RemoteMedia.caps(forThumbnail: bucket))
    }

    var body: some View {
        Group {
            let sources = StellarImages.sources(image, pointSize: pointSize)
            if !sources.isEmpty {
                RemoteImage(sources: sources, pointSize: pointSize) { loading in
                    if loading { ZStack { Color(.tertiarySystemFill); ImageLoadingSpinner() } } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .accessibilityIgnoresInvertColors()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.brand.opacity(0.30), Color.brand.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Sized to the frame: a fixed 40 pt shows only "…" in the 34–44 pt rows. Cards and headers keep 40. The letters
            // skip the isolate around right-to-left text (`ChainText.leading`).
            GeometryReader { frame in
                Text(verbatim: ChainText.leading(symbol, 2).uppercased())
                    .font(.system(size: min(40, frame.size.width * 0.4), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
#endif
