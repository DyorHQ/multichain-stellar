import PhotosUI
import StellarKit
import SwiftUI
import UniformTypeIdentifiers

/// Lite Moments: collectible editions of a photo or video, in one SEP-50 collection. 95% of every collect goes to
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
                Picker("", selection: $showMine) {
                    Text("Discover").tag(false)
                    Text("My collection").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                if showMine {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.owned) { e in
                            MomentTile(title: e.title ?? "Moment #\(e.momentId)", mediaUrl: e.mediaUrl, caption: "Edition #\(e.tokenId)")
                        }
                    }
                    .padding(16)
                    if store.owned.isEmpty { ContentUnavailableView("Nothing collected yet", systemImage: "camera.aperture") }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.moments) { m in
                            Button { selected = m } label: {
                                MomentTile(title: m.title ?? "Moment #\(m.id)", mediaUrl: m.mediaUrl, caption: "\(Amount.format(m.price)) \(store.asset(m.quote)?.code ?? "") · \(m.minted)\(m.maxEditions > 0 ? "/\(m.maxEditions)" : "") collected")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    if store.moments.isEmpty { ContentUnavailableView("No Moments yet", systemImage: "camera.aperture", description: Text("Tap + to publish the first one.")) }
                }
            }
            .background(LiteTheme.canvas)
            .navigationTitle("Moments")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { publishing = true } label: { Image(systemName: "plus") }.accessibilityLabel("Publish a Moment")
                }
            }
            .refreshable { await store.refreshMoments() }
            .sheet(item: $selected) { MomentSheet(moment: $0) }
            .sheet(isPresented: $publishing) { PublishMomentSheet() }
        }
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
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MomentTile(title: moment.title ?? "Moment #\(moment.id)", mediaUrl: moment.mediaUrl, caption: "by \(shortAddress(moment.creator))")
                    LiteCard {
                        LabeledContent("Price", value: "\(Amount.format(moment.price)) \(store.asset(moment.quote)?.code ?? "")")
                        LabeledContent("Collected", value: moment.maxEditions > 0 ? "\(moment.minted) of \(moment.maxEditions)" : "\(moment.minted) (open edition)")
                        LabeledContent("Closes", value: String(moment.deadline.prefix(16)).replacingOccurrences(of: "T", with: " "))
                        Text("95% goes to the creator. Your edition carries a 5% creator royalty for future sales.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if moment.open {
                        Stepper("Editions: \(quantity)", value: $quantity, in: 1...20)
                        if let error { Text(error).foregroundStyle(LiteTheme.negative) }
                        LitePrimaryButton(title: "Collect for \(Amount.format((Int64(moment.price) ?? 0) * Int64(quantity))) \(store.asset(moment.quote)?.code ?? "")", busy: busy) {
                            Task {
                                busy = true
                                defer { busy = false }
                                do { prepared = try await store.collectPlan(moment, quantity: quantity) } catch { self.error = describe(error) }
                            }
                        }
                    } else {
                        Text("This Moment is closed.").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Moment")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await store.refreshMoments() }; dismiss() } }
        }
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
                        Label(media == nil ? "Choose a photo or video" : (isVideo ? "Video ready" : "Photo ready"), systemImage: "photo.on.rectangle")
                    }
                    TextField("Title", text: $title)
                    TextField("Say something (optional)", text: $description, axis: .vertical)
                }
                Section {
                    AmountInput(label: "Price", text: $price, code: quote)
                    Picker("Priced in", selection: $quote) {
                        Text("USDC").tag("USDC")
                        Text("XLM").tag("XLM")
                    }
                    Stepper("Editions: \(editions == 0 ? "open" : String(editions))", value: $editions, in: 0...10_000, step: 10)
                    VStack(alignment: .leading) {
                        Text("Open for \(Int(hours)) hours")
                        Slider(value: $hours, in: 1...720, step: 1)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(LiteTheme.negative) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: "Review", busy: busy, enabled: media != nil && !title.isEmpty && Amount.parse(price) != nil) { Task { await review() } }.padding()
            }
            .navigationTitle("Publish a Moment")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: item) { _, newItem in
                Task {
                    isVideo = newItem?.supportedContentTypes.contains { $0.conforms(to: .movie) } ?? false
                    media = try? await newItem?.loadTransferable(type: Data.self)
                }
            }
            .sheet(item: $prepared) { action in ConfirmSheet(action: action) { _ in Task { await store.refreshMoments() }; dismiss() } }
        }
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
