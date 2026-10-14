import DyorKit
import SwiftUI

/// The page a Moment link opens: it finds the Moment the link names — by name through `MomentDirectory`, or by
/// (factory, id) — reads it from the live service or the retired cohort that factory belongs to, then shows the ordinary
/// detail page (which itself turns claim-only for a retired cohort). A link only navigates: nothing here signs, and
/// collecting still takes the usual review.
struct MomentLinkView: View {
    let link: MomentLink
    var onChanged: () -> Void = {}
    @Environment(AppEnvironment.self) private var env
    @State private var info: MomentInfo?
    @State private var missing = false
    @State private var error: String?

    var body: some View {
        if let info {
            MomentDetailView(info: info, onChanged: onChanged)
        } else {
            Group {
                if missing {
                    ContentUnavailableView {
                        Label("No Moment at this link", systemImage: "camera.aperture")
                    } description: {
                        Paragraph("Nothing has been published under this link yet. It may be mistyped.")
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't open this Moment", systemImage: "wifi.exclamationmark")
                    } description: {
                        Paragraph(error)
                    } actions: {
                        Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Opening Moment…")
                }
            }
            .navigationTitle(tr("Moment"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: link) { await load() }
        }
    }

    private func load() async {
        error = nil
        missing = false
        do {
            let key: MomentKey?
            switch link.target {
            case .key(let known): key = known
            case .name(let slug): key = try await env.momentDirectory.key(for: slug)
            }
            guard let key else { missing = true; return }
            let loaded: MomentInfo?
            if let cohort = env.retiredMoments(for: key.factory) {
                loaded = try await cohort.info(id: key.id)
            } else if key.factory == env.config.moments.factory {
                loaded = try await env.moments.info(id: key.id)
            } else {
                loaded = nil // a cohort this build doesn't read
            }
            // Only ever the same Moment (factory, id) back, never the live cohort's Moment of the same id.
            if let loaded, loaded.key == key { info = loaded } else { missing = true }
        } catch {
            self.error = describe(error)
        }
    }
}

/// The Share button of a Moment page: the Moment's link (`dyorhq.fun/moments/<name>`), with its artwork (when the page
/// has it) as the share sheet's preview on the sender's phone. Until the name is looked up, or if the lookup fails, it
/// shares the id form of the same link (`dyorhq.fun/moments/[cN/]<id>`, the NFT's own external_url), which opens the
/// same Moment. Recipients without the app get the website's Moments page and its generic preview card.
///
/// The name is looked up once the page's own reads have answered (`ready`): a first lookup reads every cohort's names
/// (`MomentDirectory`), and until build 23 it ran beside the page's reads on the same endpoint, holding them up.
struct MomentShareButton: View {
    let info: MomentInfo
    /// The page's reads have answered: the name may be looked up.
    var ready = true
    @Environment(AppEnvironment.self) private var env
    @State private var named: MomentLink?

    var body: some View {
        if let link = named ?? MomentLink(key: info.key) {
            ShareLink(item: link.url, subject: Text(info.name), preview: SharePreview(info.name, image: artwork)) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share this Moment")
            .task(id: "\(info.key.description)-\(ready)") {
                guard ready else { return }
                named = try? await env.momentDirectory.link(for: info.key)
            }
        }
    }

    /// The artwork the page shows, from memory (the largest size kept, the page header's), or the wordmark.
    private var artwork: Image {
        let sources = MomentArtwork.imageSources(provenance: info.provenance, creator: info.moment.creator)
        if let shown = RemoteImageLoader.shared.memoryImage(sources, bucket: ImageSizeBucket.largest) {
            return Image(uiImage: UIImage(cgImage: shown.image))
        }
        return Image(.wordmark)
    }
}
