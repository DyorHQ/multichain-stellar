// Stellar copy of ios/DyorHQ/Moments/MomentsUI.swift MomentArtwork (42cd8c7 sha256:93793d250ec4)
// A Stellar Moment's picture (docs/DESIGN-stellar-parity.md §3.5, §3.8). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import SwiftUI

/// A Stellar Moment's media: its image (a video Moment's poster), or a monogram on the brand tint when there is none or it
/// fails to load. It loads through the app's one image pipeline (`RemoteImage`), decoded at the size bucket that covers
/// the frame it is drawn in (measured here, so a 44 pt row decodes a thumbnail and only a Moment's page header the
/// largest), and only from DyorHQ's own media under the build's pinned base (`StellarImages`): a link anywhere else
/// shows the monogram.
struct StellarMomentArtwork: View {
    /// The Moment's image or a video's poster, as its metadata names it; nil for none.
    let image: String?
    /// The Moment's name, for its letters.
    let name: String

    /// Moment art keeps the full caps at every size, as on Monad: where no rendered copy is served (a Debug build, which
    /// loads originals only, and a gif), a row's thumbnail is decoded from the creator's original, up to the 5 MB
    /// `lite-media` takes, rather than refused by the logo-sized caps.
    static let caps = RemoteMedia.caps(forThumbnail: ImageSizeBucket.largest)

    /// Warms the picture a card `side` points across will ask for — the same sources, size bucket and caps as `body` —
    /// ahead of the board's scroll (`BoardPrefetch`, `ImagePipeline.prefetch`).
    @MainActor static func prefetch(image: String?, side: CGFloat) {
        RemoteImageLoader.shared.prefetch(StellarImages.sources(image, pointSize: side), bucket: ImageSizeBucket.bucket(points: side), caps: caps)
    }

    var body: some View {
        GeometryReader { frame in
            let side = max(frame.size.width, frame.size.height)
            Group {
                if side > 0 {
                    RemoteImage(sources: StellarImages.sources(image, pointSize: side), pointSize: side, caps: Self.caps) { loading in
                        if loading { ZStack { Color(.tertiarySystemFill); ImageLoadingSpinner() } } else { placeholder }
                    }
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: frame.size.width, height: frame.size.height)
        }
        .accessibilityIgnoresInvertColors()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.allocationMoments.opacity(0.35), Color.brand.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Sized to the frame: a fixed 36 pt shows only "…" in the 34–44 pt rows. Cards and headers keep 36. The letters
            // skip the isolate around right-to-left text (`ChainText.leading`).
            GeometryReader { frame in
                Text(verbatim: ChainText.leading(name, 2).uppercased())
                    .font(.system(size: min(36, frame.size.width * 0.4), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
#endif
