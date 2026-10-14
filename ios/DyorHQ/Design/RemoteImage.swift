import DyorKit
import SwiftUI

/// The app's one image pipeline (`ImagePipeline`, security audit 2026-09-26, RI-5) for every image from a host it
/// doesn't control: coin logos, launch and Moment artwork, avatars, NFT art, news thumbnails, chain badges. Each fetch is
/// capped (`RemoteMedia.fetch`) — tighter for a logo-sized image (`RemoteMedia.caps(forThumbnail:)`) — and only a
/// thumbnail at the size bucket the view shows is decoded (`ImageSizeBucket`), never the full image. What it accepted is
/// kept in memory and in Caches (`ImageDiskCache`, about 200 MB), so a picture seen once paints from the phone on the
/// next launch; a picture that can't change (DyorHQ's write-once bucket, an IPFS CID) isn't asked about again for a
/// week, any other for an hour, and past that the kept copy still shows at once while it is asked again. An image with
/// several sources (a coin's picture: DyorHQ's mirror, then the IPFS gateways, `ImageSourcePolicy`) tries them best
/// first under the same caps; one whose bytes must hash to a known value (`RemoteImageSource.keccak`) counts only when
/// they do. A list-sized thumbnail of an unchecked picture in DyorHQ's write-once bucket (a launch logo) comes from
/// Storage's resized copy at its size, the original after it (`ImageSourcePolicy.renderURL`); a new avatar is drawn from
/// the bytes just uploaded (`ImagePipeline.seed`); the boards warm their next rows (`BoardPrefetch`). Its disk index is
/// read as the app starts (`ImagePipeline.prepare`, from the app delegate). Deleting the account or forgetting this device
/// empties it (`Session.eraseLocalData`).
enum RemoteImageLoader {
    @MainActor static let shared = ImagePipeline(policy: .app, directory: ImageDiskCache.defaultDirectory)
}

/// A remote image through `RemoteImageLoader`, sized for a view whose longer side is `pointSize` points (decoded at the
/// size bucket that covers it, `ImageSizeBucket`), or `placeholder` while it loads (`true`) and when it can't be shown
/// (`false`). Its `sources` are tried best first and the first that is accepted shows; none is the placeholder. `caps`
/// overrides the caps the size would give (Moment art keeps the full caps at every size, `MomentArtwork`).
///
/// A view with letters to stand in for the image passes a `grace` (`RemoteImageWait.grace`): the loading placeholder
/// shows only that long, then the letters while the image keeps loading, and the letters at once for an image that
/// failed lately. Without one, the loading placeholder stays until the answer (`ImageLoadingSpinner`: a plain fill, and
/// a spinner only once the load takes a moment).
///
/// What it shows first, with no frame of placeholder for a picture the app already has in memory: the image in memory,
/// read in `init` and whenever the view is given another picture (at this size or larger; a smaller one while this size
/// loads); then the copy kept on the phone; then the network. A kept copy past its lifetime shows while the network is
/// asked behind it, and stays when that fails — unless every source says the picture is gone. A picture that failed
/// lately shows the stand-in, and is asked once more when its miss runs out (`ImagePipeline.retryAfter`) while the view
/// is still there.
struct RemoteImage<Placeholder: View>: View {
    let sources: [RemoteImageSource]
    let pointSize: CGFloat
    var contentMode: ContentMode
    var grace: Duration?
    let placeholder: (_ loading: Bool) -> Placeholder
    /// The picture's key (`ImagePipeline.key`), the bucket it is shown at, and the caps it loads under.
    private let key: String
    private let bucket: Int
    private let caps: RemoteMedia.Caps
    @State private var image: CGImage?
    /// The key `image` belongs to: a view given another picture never shows the last one's, even for a frame.
    @State private var imageKey: String?
    /// The key of the picture this view gave up on: its stand-in shows for that picture, never for the next.
    @State private var failedKey: String?
    @State private var graceOver = false
    /// The image `graceOver` was counted for: a row scrolled back on screen keeps its letters rather than showing the
    /// disc again for another grace.
    @State private var graceKey: String?

    init(sources: [RemoteImageSource], pointSize: CGFloat, contentMode: ContentMode = .fill, grace: Duration? = nil, caps: RemoteMedia.Caps? = nil,
         @ViewBuilder placeholder: @escaping (_ loading: Bool) -> Placeholder) {
        self.sources = sources
        self.pointSize = pointSize
        self.contentMode = contentMode
        self.grace = grace
        self.placeholder = placeholder
        let key = ImagePipeline.key(sources)
        let bucket = ImageSizeBucket.bucket(points: pointSize)
        let caps = caps ?? RemoteMedia.caps(forThumbnail: bucket)
        self.key = key
        self.bucket = bucket
        self.caps = caps
        // Read here rather than in `load`, which runs after the first frame: a picture already in memory never shows its
        // placeholder for a frame (and one that failed lately never shows the disc, `isFailed`).
        let shown = RemoteImageLoader.shared.memoryImage(sources, bucket: bucket)
        _image = State(initialValue: shown?.image)
        _imageKey = State(initialValue: shown == nil ? nil : key)
    }

    /// The image at `url` alone; none for nil.
    init(url: URL?, pointSize: CGFloat, contentMode: ContentMode = .fill, grace: Duration? = nil,
         @ViewBuilder placeholder: @escaping (_ loading: Bool) -> Placeholder) {
        self.init(sources: url.map { [RemoteImageSource(url: $0)] } ?? [], pointSize: pointSize, contentMode: contentMode, grace: grace, placeholder: placeholder)
    }

    /// The image to draw: this picture's, from state — or, in a view just given another picture whose load hasn't run
    /// yet, that picture's from memory, whatever the view held before — never the last picture's.
    private var shown: CGImage? {
        RemoteImageWait.drawn(held: image, heldKey: imageKey, key: key) { RemoteImageLoader.shared.memoryImage(sources, bucket: bucket)?.image }
    }

    /// Whether the placeholder is the stand-in rather than the loading one: for this picture, never the last one's.
    private var isFailed: Bool {
        RemoteImageWait.failed(failedKey: failedKey, key: key, hasURL: !sources.isEmpty) { RemoteImageLoader.shared.failedLately(sources, caps: caps) }
    }

    var body: some View {
        Group {
            if let shown {
                Image(decorative: shown, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder(RemoteImageWait.shown(hasImage: false, hasURL: !sources.isEmpty, failed: isFailed, graceOver: graceOver) == .loading)
            }
        }
        .task(id: "\(bucket)|\(key)") { await load() }
        .task(id: key) {
            if graceKey != key { graceOver = false; graceKey = key }
            guard !graceOver, let grace, shown == nil, await RemoteImageWait.graceElapses(grace) else { return }
            graceOver = true
        }
    }

    private func show(_ picture: CGImage) {
        image = picture
        imageKey = key
        failedKey = nil
    }

    /// This picture can't be shown now: its stand-in, unless the view already shows a copy of it.
    private func giveUp() {
        failedKey = imageKey == key ? nil : key
    }

    private func load() async {
        guard !sources.isEmpty else { image = nil; imageKey = nil; failedKey = key; return }
        let loader = RemoteImageLoader.shared
        // Memory: this size (or larger) and fresh is all there is to do; a smaller or older one shows meanwhile.
        if let memory = loader.memoryImage(sources, bucket: bucket) {
            show(memory.image)
            if memory.exact, memory.fresh { return }
        } else if imageKey != key {
            // Another picture than the one shown: its own state, not the last one's.
            image = nil
            imageKey = nil
        }
        // The phone, with no network.
        if let kept = await loader.stored(sources, bucket: bucket, caps: caps) {
            guard !Task.isCancelled else { return }
            show(kept.image)
            if kept.exact, kept.fresh { return }
        }
        // The network: not again for a picture that failed a moment ago — once more when that runs out, if the view is
        // still here, and no more.
        var waited = false
        while !Task.isCancelled {
            if let wait = loader.retryAfter(sources, caps: caps) {
                giveUp()
                guard !waited, await RemoteImageWait.graceElapses(.seconds(wait)) else { return }
                waited = true
                continue
            }
            switch await loader.fetch(sources, bucket: bucket, caps: caps) {
            case .image(let fresh):
                guard !Task.isCancelled else { return }
                show(fresh)
                return
            case .gone:
                guard !Task.isCancelled else { return }
                image = nil
                imageKey = nil
                failedKey = key
                return
            case .failed:
                guard !Task.isCancelled else { return }
                giveUp()
                // A miss is waited out once (above); a failure that left none (a picture that didn't decode) isn't asked again.
                guard !waited, loader.retryAfter(sources, caps: caps) != nil else { return }
            }
        }
    }
}

/// What a picture with no letters to stand in for it (a Moment's art, a launch's, an avatar, an NFT) shows while it
/// loads: nothing over the view's own fill at first, and a spinner only once the load has taken
/// `RemoteImageWait.spinnerDelay` — a picture kept on the phone arrives within that, so it never flashes a spinner (after
/// a relaunch, memory is empty and the phone answers a moment after the first frame).
struct ImageLoadingSpinner: View {
    @State private var spinning = false

    var body: some View {
        Color.clear
            .overlay { if spinning { ProgressView().controlSize(.small) } }
            .task { if await RemoteImageWait.graceElapses(RemoteImageWait.spinnerDelay) { spinning = true } }
    }
}
