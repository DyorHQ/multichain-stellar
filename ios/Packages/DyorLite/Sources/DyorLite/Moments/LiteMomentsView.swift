import PhotosUI
import StellarKit
import SwiftUI
import UniformTypeIdentifiers

/// Moments on Stellar: collectible editions of a photo or video, in one SEP-50 collection. 95% of every collect goes to
/// the creator. Collected and shown in-app (no Stellar NFT marketplace indexes Soroban NFTs yet).
struct LiteMomentsView: View {
    @Environment(LiteStore.self) private var store
    @State private var showMine = false
    @State private var publishing = false
    @State private var selected: Moment?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker(String(), selection: $showMine) {
                    Text(tr("Discover")).tag(false)
                    Text(tr("My collection")).tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                if showMine {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.owned) { e in
                            MomentTile(title: e.title ?? tr("Moment #\(e.momentId)"), mediaUrl: e.mediaUrl, caption: tr("Edition #\(e.tokenId)"))
                        }
                    }
                    .padding(16)
                    if store.owned.isEmpty && store.loaded.contains(.moments) {
                        ContentUnavailableView(tr("Nothing collected yet"), systemImage: "camera.aperture")
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.moments) { m in
                            Button { selected = m } label: {
                                MomentTile(title: m.title ?? tr("Moment #\(m.id)"), mediaUrl: m.mediaUrl, caption: caption(m))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    if store.moments.isEmpty && store.loaded.contains(.moments) {
                        ContentUnavailableView(tr("No Moments yet"), systemImage: "camera.aperture", description: Text(tr("Tap + to publish the first one.")))
                    }
                }
                if store.failed.contains(.moments) {
                    LiteInlineError(message: store.lastError ?? tr("No connection. Check your network and try again.")).padding(.horizontal, 16)
                }
            }
            .background(Color.liteCanvas)
            .navigationTitle(tr("Moments"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { publishing = true } label: { Image(systemName: "plus") }.accessibilityLabel(tr("Publish a Moment"))
                }
            }
            .refreshable { await store.refreshMoments() }
            .sheet(item: $selected) { MomentSheet(moment: $0) }
            .sheet(isPresented: $publishing) { PublishMomentSheet() }
        }
    }

    /// "1.5 USDC · 3/100 collected", or "· 3 collected" for an open edition.
    private func caption(_ m: Moment) -> String {
        let price = "\(Amount.format(m.price)) \(store.asset(m.quote)?.code ?? "")"
        return m.maxEditions > 0 ? tr("\(price) · \(m.minted)/\(m.maxEditions) collected") : tr("\(price) · \(m.minted) collected")
    }
}

struct MomentTile: View {
    let title: String
    let mediaUrl: String?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: mediaUrl.flatMap(URL.init(string:))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } }
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(verbatim: title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(verbatim: caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct MomentSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let moment: Moment
    @State private var quantity = 1
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    private var code: String { store.asset(moment.quote)?.code ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MomentTile(title: moment.title ?? tr("Moment #\(moment.id)"), mediaUrl: moment.mediaUrl, caption: tr("by \(shortAddress(moment.creator))"))
                    LiteCard {
                        LabeledContent(tr("Price"), value: "\(Amount.format(moment.price)) \(code)")
                        LabeledContent(tr("Collected"), value: moment.maxEditions > 0 ? tr("\(moment.minted) of \(moment.maxEditions)") : tr("\(moment.minted) (open edition)"))
                        LabeledContent(tr("Closes"), value: closes)
                        LiteParagraph(tr("95% goes to the creator. Your edition carries a 5% creator royalty for future sales."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if moment.open {
                        Stepper(tr("Editions: \(quantity)"), value: $quantity, in: 1...20)
                        if let error { LiteInlineError(message: error) }
                        LitePrimaryButton(title: tr("Collect for \(Amount.format((Int64(moment.price) ?? 0) * Int64(quantity))) \(code)"), busy: busy) {
                            Task {
                                busy = true
                                defer { busy = false }
                                do { prepared = try await store.collectPlan(moment, quantity: quantity) } catch { self.error = describe(error) }
                            }
                        }
                    } else {
                        Text(tr("This Moment is closed.")).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(Color.liteCanvas)
            .navigationTitle(tr("Moment"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await store.refreshMoments() }; dismiss() } }
        }
    }

    private var closes: String {
        guard let date = moment.deadline.liteDate else { return String(moment.deadline.prefix(16)).replacingOccurrences(of: "T", with: " ") }
        return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(LiteL10n.locale))
    }
}

struct PublishMomentSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var media: Data?
    @State private var isVideo = false
    @State private var title = ""
    @State private var description = ""
    @State private var price = "1"
    @State private var quote = "USDC"
    @State private var editions = 100
    @State private var hours = 24.0
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                        Label(media == nil ? tr("Choose a photo or video") : (isVideo ? tr("Video ready") : tr("Photo ready")), systemImage: "photo.on.rectangle")
                    }
                    TextField(tr("Title"), text: $title)
                    TextField(tr("Say something (optional)"), text: $description, axis: .vertical)
                }
                Section {
                    AmountInput(label: tr("Price"), text: $price, code: quote)
                    Picker(tr("Priced in"), selection: $quote) {
                        Text(verbatim: "USDC").tag("USDC")
                        Text(verbatim: "XLM").tag("XLM")
                    }
                    Stepper(editions == 0 ? tr("Editions: open") : tr("Editions: \(editions)"), value: $editions, in: 0...10_000, step: 10)
                    VStack(alignment: .leading) {
                        Text(tr("Open for \(Int(hours)) hours"))
                        Slider(value: $hours, in: 1...720, step: 1)
                    }
                }
                if let error { Section { LiteInlineError(message: error) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: tr("Review"), busy: busy, enabled: media != nil && !title.isEmpty && Amount.parse(price) != nil) { Task { await review() } }.padding()
            }
            .navigationTitle(tr("Publish a Moment"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .onChange(of: item) { _, newItem in
                Task {
                    isVideo = newItem?.supportedContentTypes.contains { $0.conforms(to: .movie) } ?? false
                    media = try? await newItem?.loadTransferable(type: Data.self)
                }
            }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await store.refreshMoments() }; dismiss() } }
        }
        .liteFormSheet()
    }

    private func review() async {
        guard let media else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            let (data, type) = isVideo ? (media, "video/mp4") : (jpeg(media), "image/jpeg")
            prepared = try await store.publishPlan(media: data, contentType: type, title: title, description: description, price: Amount.parse(price) ?? 0, quote: quote, editions: editions, windowSecs: Int(hours) * 3600)
        } catch {
            self.error = describe(error)
        }
    }
}

/// Re-encodes a picked image as JPEG (Photos hands over HEIC on most iPhones).
func jpeg(_ data: Data) -> Data {
    #if canImport(UIKit)
    if let img = UIImage(data: data), let out = img.jpegData(compressionQuality: 0.85) { return out }
    #endif
    return data
}
