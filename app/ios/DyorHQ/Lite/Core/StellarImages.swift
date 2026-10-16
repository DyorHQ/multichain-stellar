// Stellar media through the app's one image pipeline (docs/DESIGN-stellar-parity.md §3.8). Internal builds only
// (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// What `RemoteImage` loads for a Stellar picture: DyorHQ's own uploads under the build's pinned media base and nothing
/// else (`LiteMediaPolicy`), best first — Storage's render at the size bucket the view is drawn at (Release; never for a
/// gif or above 768 px), then the original. A link anywhere else, a server's saved snapshot included, gives no source,
/// and the view shows its letters or placeholder art. `AsyncImage` is never used.
enum StellarImages {
    /// The sources for the picture at `uri`, drawn `pointSize` points across.
    static func sources(_ uri: String?, pointSize: CGFloat, mediaBase: URL = LiteGate.mediaBase,
                        renderBase: URL? = LiteGate.renderBase) -> [RemoteImageSource] {
        guard let uri, !uri.isEmpty else { return [] }
        let pixels = ImageSizeBucket.bucket(points: pointSize)
        return LiteMediaPolicy.imageSources(uri, base: mediaBase, renderBase: renderBase, pixels: pixels)
            .map { RemoteImageSource(url: $0) }
    }

    /// The video at `uri` (mp4 or mov), when it is an upload under the media base.
    static func video(_ uri: String?, mediaBase: URL = LiteGate.mediaBase) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        return LiteMediaPolicy.videoURL(uri, base: mediaBase)
    }
}
#endif
