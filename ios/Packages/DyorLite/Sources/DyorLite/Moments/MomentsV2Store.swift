import Foundation
import StellarKit

// Moments v2 for the screens (docs/DESIGN-stellar-contracts-v2.md §9, §20.2–20.3, §21): one Moment is one NFT contract,
// and its address is the Moment's id. Collectors pay USDC; the collect that reaches the threshold completes the Moment,
// the keeper (or anyone) graduates it into its coin and a Soroswap pool, and the coins promised to collectors and the
// creator vest from then. Everything goes through StellarKit's LiteClient (MomentsV2.swift): no contract is called from
// the phone, and no contract id is written here (the API names them).

/// A new v2 Moment, as Publish fills it in (`MomentsV2Store.publishPlan`).
public struct StellarMomentFormV2: Equatable, Sendable {
    /// The NFT's and its coin's name: 1 to 32 bytes.
    public var name: String
    /// The coin's ticker: 2 to 10 ASCII letters or digits (`StellarTickerV2`).
    public var symbol: String
    public var description: String?
    /// Where it happened: at most 64 bytes.
    public var place: String?
    /// The day it happened, "2026-10-14".
    public var takenOn: String?
    /// Per edition, in USDC base units (7 decimals).
    public var price: Int64
    /// The creator's coins: 0 to the policy's maximum, in 1% steps (100 bps).
    public var allocationBps: Int
    /// How long collecting stays open, within the terms' `minWindow`…`maxWindow`.
    public var windowSecs: Int

    public init(name: String, symbol: String, description: String? = nil, place: String? = nil, takenOn: String? = nil, price: Int64,
                allocationBps: Int, windowSecs: Int) {
        self.name = name
        self.symbol = symbol
        self.description = description
        self.place = place
        self.takenOn = takenOn
        self.price = price
        self.allocationBps = allocationBps
        self.windowSecs = windowSecs
    }
}

/// A Moment's media once uploaded to DyorHQ's storage (`MomentsV2Store.upload`): the photo, or the video and its cover
/// frame, which is the NFT's image.
public struct StellarMomentUploadV2: Equatable, Sendable {
    public let mediaUrl: String
    /// A video's cover frame; nil for a photo.
    public let posterUrl: String?

    public init(mediaUrl: String, posterUrl: String?) {
        self.mediaUrl = mediaUrl
        self.posterUrl = posterUrl
    }

    public var isVideo: Bool { posterUrl != nil }
    /// The NFT's image: the photo, or the video's cover frame.
    public var imageUrl: String { posterUrl ?? mediaUrl }
}

/// What a screen knows of a v2 Moment besides its state (`StellarMomentStatusV2`): its name, ticker, media and
/// provenance. Publish knows it from its own form, and a board from its feed; with only the address (a link, a
/// notification) every field but `nft` is nil.
public struct StellarMomentListingV2: Hashable, Sendable, Identifiable {
    /// The Moment's NFT contract: its id.
    public let nft: String
    public var name: String?
    public var symbol: String?
    /// The photo, or a video's cover frame.
    public var image: String?
    /// The video, for a video Moment.
    public var video: String?
    public var place: String?
    /// "2026-10-14".
    public var takenOn: String?

    public var id: String { nft }

    public init(nft: String, name: String? = nil, symbol: String? = nil, image: String? = nil, video: String? = nil, place: String? = nil,
                takenOn: String? = nil) {
        self.nft = nft
        self.name = name
        self.symbol = symbol
        self.image = image
        self.video = video
        self.place = place
        self.takenOn = takenOn
    }
}

/// Where a v2 Moment is at an instant: the contract's state, with the deadline and a recorded failure read in, so a page
/// moves on the moment its window closes whatever the server said when it was read.
public enum StellarMomentPhaseV2: String, Equatable, Sendable {
    /// Taking collects until its deadline.
    case collecting
    /// Its deadline passed short of the threshold: anyone can expire it.
    case windowClosed
    /// It reached the threshold; the keeper usually graduates it within a minute, and anyone may.
    case graduating
    /// A graduation attempt failed and was recorded; it can still graduate, or expire later (`expiresAt`).
    case graduationFailed
    /// Its coin and Soroswap pool exist; the coins vest.
    case graduated
    /// It ended without graduating: its reserve went 70/30 to the creator and the treasury.
    case expired

    public init(_ status: StellarMomentStatusV2, now: Date) {
        switch status.state {
        case "graduated": self = .graduated
        case "expired": self = .expired
        case "graduation_pending": self = status.failure?.recorded == true || status.stuckSince != nil ? .graduationFailed : .graduating
        case "collecting":
            let deadline = status.deadline.liteDate ?? .distantPast
            self = now < deadline ? .collecting : .windowClosed
        default:
            // A state a later contract adds: nothing is offered on it.
            self = .windowClosed
        }
    }

    public var isCollecting: Bool { self == .collecting }
}

/// What a collect plan binds, from its intent (`MomentsV2Store.collect(in:)`): for the review.
public struct StellarCollectV2: Equatable, Sendable {
    /// The editions it mints: fewer than asked when it completes the Moment.
    public let editions: Int
    /// The most it pulls, in USDC base units (`max_total`).
    public let total: Int64
    /// The coins it promises, in coin base units (7 decimals).
    public let entitlement: String
    /// It completes the Moment: it takes only what the reserve still needs.
    public let terminal: Bool
}

/// v2 Moments: reads and plans keyed by the Moment's NFT address. A thin layer over `LiteStore` (made where it is used,
/// `MomentsV2Store(store:)`): reads never prompt (the status is public, the vesting a viewer read), and each plan is built
/// once a session is held, then priced and verified on the phone like any other (`LiteStore.prepare`). `title` is the
/// review's own title, in the app's language: what a passkey prompt names.
@MainActor
public struct MomentsV2Store {
    public let store: LiteStore

    public init(store: LiteStore) {
        self.store = store
    }

    /// The largest video a Moment can be (the API's upload limit).
    public static let maxVideoBytes = 25 * 1024 * 1024
    /// How long a completed Moment usually waits for the keeper: past this, the page says graduation is slow.
    public static let usualGraduation: TimeInterval = 60 * 60

    // MARK: - Reads

    /// The Moments terms a publish binds now, read live (public, kept 5 minutes by the API); nil where the network has
    /// no v2 Moments.
    public func economics() async throws -> StellarMomentsEconomicsV2? {
        try await store.api.economicsV2().moments
    }

    /// A Moment's state, read live from its contract (public).
    public func status(_ nft: String) async throws -> StellarMomentStatusV2 {
        try await store.api.momentStatusV2(nft)
    }

    /// The account's coins in a Moment: as a collector and, for its creator, the allocation (a viewer read).
    public func vesting(_ nft: String) async throws -> StellarMomentVestingV2 {
        try await store.api.momentVestingV2(nft)
    }

    /// The account's USDC, in base units, as last read.
    public var usdcBalance: Int64 { store.balance("USDC") }

    // MARK: - Publish

    /// Uploads a Moment's photo, or its video and cover frame (the NFT's image), to DyorHQ's storage. A video doesn't go
    /// without its cover frame; the screen keeps it within `maxVideoBytes`.
    public func upload(_ media: StellarMedia) async throws -> StellarMomentUploadV2 {
        if media.isVideo, media.poster == nil {
            throw LiteAPIError.server(status: 400, code: "bad_media", message: tr("A video needs its cover frame."))
        }
        // The API refuses a larger file at its upload ticket, in its own words; the screen says so before reading it.
        try await store.ensureSession()
        let mediaUrl = try await store.upload(media.data, contentType: media.contentType)
        var posterUrl: String?
        if media.isVideo, let poster = media.poster { posterUrl = try await store.upload(poster, contentType: "image/jpeg") }
        return StellarMomentUploadV2(mediaUrl: mediaUrl, posterUrl: posterUrl)
    }

    /// A new Moment: its metadata written, then the publish, which binds the terms as they stand by value and the
    /// account's USDC trustline first when it has none (a creator withdraws its proceeds in USDC). The ticker is refused
    /// here, before anything is sent, unless the contracts would take it (`StellarTickerV2`).
    public func publishPlan(_ form: StellarMomentFormV2, media: StellarMomentUploadV2, title: String) async throws -> PreparedAction {
        guard let symbol = StellarTickerV2.normalized(form.symbol) else { throw StellarTickerV2.refusal }
        try await store.ensureSession()
        let metadata = try await store.api.momentMetadata(title: form.name, description: form.description, mediaUrl: media.mediaUrl,
                                                          mediaType: media.isVideo ? "video" : "image", posterUrl: media.posterUrl,
                                                          place: form.place, takenOn: form.takenOn)
        let plan = try await store.api.buildMomentV2(.init(action: .publish, uri: metadata.uri, name: form.name, symbol: symbol,
                                                           price: String(form.price), allocationBps: form.allocationBps, windowSecs: form.windowSecs))
        let main = LiteTitles.intent(kind: "moment_publish", display: ["price": .string(String(form.price)), "quote": .string("USDC")])
        return try store.prepare(plan, limits: [:], title: title,
                                 titles: LiteStore.unbuilt(plan, main: main, before: LiteTitles.intent(kind: "trust", display: ["asset": .string("USDC")])),
                                 section: .moments, reference: Self.publishing(plan).map(Self.reference), summary: .publish(title: form.name))
    }

    // MARK: - Collect, claim, withdraw, graduate, expire

    /// `quantity` editions of the Moment `nft` (1 to the economics' `maxPerCollect`), at its `price` (USDC base units).
    /// The user confirms what the plan pulls (`max_total`), which is never more than `price × quantity`: the collect that
    /// completes the Moment pulls only what its reserve still needs.
    public func collectPlan(nft: String, quantity: Int, price: Int64, name: String, title: String) async throws -> PreparedAction {
        guard quantity > 0, price > 0, let usdc = store.asset("USDC")?.contract else { throw LiteAPIError.decoding("the collect") }
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .collect, nft: nft, quantity: quantity))
        let (ceiling, overflow) = price.multipliedReportingOverflow(by: Int64(quantity))
        let collect = Self.collect(in: plan)
        // A built collect states what it pulls; one the server builds later (after a restore) may pull up to the ceiling.
        let total = collect?.total ?? ceiling
        guard !overflow, total > 0, total <= ceiling, collect == nil || Self.spends(plan, only: usdc, total: total) else {
            throw LiteAPIError.decoding("the collect")
        }
        let main = LiteTitles.intent(kind: "moment_collect", display: ["quantity": .number(Double(quantity)), "total": .string(String(total)),
                                                                       "quote": .string("USDC")])
        return try store.prepare(plan, limits: [usdc: total], title: title, titles: LiteStore.unbuilt(plan, main: main, before: nil),
                                 section: .moments, reference: Self.reference(nft),
                                 summary: .collect(title: name, quantity: collect?.editions ?? quantity, total: total, quoteCode: "USDC"))
    }

    /// The coins of the Moment `nft` the account can claim now: as a collector and, for its creator, the allocation.
    public func claimPlan(nft: String, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .claim, nft: nft))
        return try store.prepare(plan, limits: [:], title: title, section: .moments, reference: Self.reference(nft), summary: Self.unannounced)
    }

    /// The coins of up to `maxClaimIds` (20) Moments in one transaction; the API leaves out those with nothing due.
    public func claimAllPlan(nfts: [String], maxClaimIds: Int, title: String) async throws -> PreparedAction {
        var unique: [String] = []
        for nft in nfts where !unique.contains(nft) { unique.append(nft) }
        // The API's own refusal, before anything is sent: the screens never ask for more.
        guard (1...max(1, maxClaimIds)).contains(unique.count) else {
            throw LiteAPIError.server(status: 400, code: "bad_arg", message: "nfts: the Moments to claim from, 1 to \(maxClaimIds) at a time.",
                                      detail: ["max": String(maxClaimIds)])
        }
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .claimAll, nfts: unique))
        return try store.prepare(plan, limits: [:], title: title, section: .moments, reference: "stellar:moment", summary: Self.unannounced)
    }

    /// The creator's proceeds of the Moment `nft` (its share of every collect, and of an expired reserve), in USDC, to
    /// the account: with its USDC trustline first when it has none.
    public func withdrawPlan(nft: String, symbol: String, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .withdraw, nft: nft))
        return try store.prepare(plan, limits: [:], title: title, titles: LiteStore.unbuilt(plan, main: nil, before: LiteTitles.intent(kind: "trust", display: ["asset": .string("USDC")])),
                                 section: .moments, reference: Self.reference(nft), summary: .launchClaim(symbol: symbol))
    }

    /// Graduates the completed Moment `nft` into its coin and Soroswap pool: anyone may, paying only the network fee. The
    /// API offers it only when it would graduate, or record the first failure (which starts the clock to expiry).
    public func graduatePlan(nft: String, symbol: String, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .graduate, nft: nft))
        return try store.prepare(plan, limits: [:], title: title, section: .moments, reference: Self.reference(nft), summary: .launchGraduate(symbol: symbol))
    }

    /// Ends the Moment `nft` without graduating, once it may (`StellarMomentStatusV2.expirable`): its reserve goes to the
    /// creator and the treasury (`expiryCreatorBps`), and collectors keep their editions. Anyone may.
    public func expirePlan(nft: String, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .expire, nft: nft))
        return try store.prepare(plan, limits: [:], title: title, section: .moments, reference: Self.reference(nft), summary: Self.unannounced)
    }

    // MARK: - Reading plans and results

    /// What a collect plan binds, from its built collect step; nil before the server built it.
    public nonisolated static func collect(in plan: PlanView) -> StellarCollectV2? {
        guard let intent = plan.steps.lazy.compactMap(\.intent).first(where: { $0.kind == "moment_collect" }), let d = intent.display,
              let editions = d["editions"].flatMap(whole), let total = d["total"].flatMap(whole).map(Int64.init) else { return nil }
        return StellarCollectV2(editions: editions, total: total, entitlement: d["entitlement"]?.text ?? "0",
                                terminal: d["terminal"] == .bool(true))
    }

    /// The terms a publish plan binds that differ from `terms`, the ones its review showed, and from the form's own
    /// values, by name; empty when it binds them exactly. A field the publish doesn't state counts as differing (the
    /// guard fails closed). Nil while the publish isn't built yet (behind the account's USDC trustline): the server
    /// builds it once that step confirmed, with the terms as they stand then.
    public nonisolated static func termsChanges(_ plan: PlanView, terms: StellarMomentsTermsV2, form: StellarMomentFormV2) -> [String]? {
        guard let step = plan.steps.first(where: { ($0.stepKind ?? $0.intent?.kind) == "moment_publish" }) else { return ["publish"] }
        guard let intent = step.intent else { return step.xdr == nil ? nil : ["publish"] }
        guard intent.kind == "moment_publish" else { return ["publish"] }
        let shown = intent.display ?? [:]
        let p = terms.policy
        let d = terms.durations
        let expected: [(String, String)] = [
            ("threshold", p.threshold), ("minPrice", p.minPrice), ("creatorBps", String(p.creatorBps)), ("platformBps", String(p.platformBps)),
            ("reserveBps", String(p.reserveBps)), ("maxCreatorAllocBps", String(p.maxCreatorAllocBps)),
            ("expiryCreatorBps", String(p.expiryCreatorBps)), ("royaltyBps", String(p.royaltyBps)), ("platform", p.platform),
            ("treasury", p.treasury), ("externalBase", terms.externalBase), ("nftWasmHash", terms.nftWasmHash),
            ("coinWasmHash", terms.coinWasmHash), ("graduator", terms.graduator), ("executor", terms.executor), ("locker", terms.locker),
            ("vestPeriod", String(d.vestPeriod)), ("stuckExpiry", String(d.stuckExpiry)), ("pendingBackstop", String(d.pendingBackstop)),
            ("timelock", String(d.timelock)), ("timelockWindow", String(d.timelockWindow)), ("minWindow", String(d.minWindow)),
            ("maxWindow", String(d.maxWindow)), ("harvestInterval", String(d.harvestInterval)), ("harvestBps", String(terms.harvestBps)),
            ("harvestCreatorBps", String(terms.harvestCreatorBps)),
            ("price", String(form.price)), ("allocationBps", String(form.allocationBps)), ("windowSecs", String(form.windowSecs)),
            ("symbol", StellarTickerV2.normalized(form.symbol) ?? form.symbol),
        ]
        return expected.filter { name, value in shown[name]?.text != value }.map(\.0)
    }

    /// The new Moment's NFT address, as a publish plan predicts it (the address follows from the creator and the nonce).
    public nonisolated static func publishing(_ plan: PlanView) -> String? {
        plan.steps.lazy.compactMap(\.intent).first { $0.kind == "moment_publish" }?.display?["nft"].map(\.text).flatMap(contract)
    }

    /// The NFT address a settled publish returned: the new Moment's id.
    public nonisolated static func publishedNFT(_ results: [TxStatus]) -> String? {
        guard case .string(let nft)? = results.last?.returnValue else { return nil }
        return contract(nft)
    }

    /// The edition numbers a settled collect minted (its `first_rank` and `editions`), each a token id of the Moment's
    /// NFT contract.
    public nonisolated static func collectedEditions(_ results: [TxStatus]) -> ClosedRange<Int>? {
        guard case .object(let r)? = results.last?.returnValue,
              let first = r["first_rank"].flatMap(whole), let count = r["editions"].flatMap(whole), first >= 1, count >= 1,
              first <= Int.max - count else { return nil }
        return first...(first + count - 1)
    }

    /// "stellar:moment/<C…>": where a v2 Moment's notification leads.
    public nonisolated static func reference(_ nft: String) -> String { "stellar:moment/\(nft)" }

    // MARK: - Private

    /// The plan's steps spend nothing but `total` of `usdc`, the one asset a collect pulls.
    private nonisolated static func spends(_ plan: PlanView, only usdc: String, total: Int64) -> Bool {
        let spends = plan.steps.compactMap(\.intent).flatMap(\.spend).filter { (Int64($0.value) ?? 1) != 0 }
        return spends.allSatisfy { $0.key == usdc && Int64($0.value) == total }
    }

    /// A claim's or an expiry's summary: `LiteActionSummary` has no case for either yet, so they settle without a
    /// notification (a trust step's kind posts none) rather than with another action's words.
    private static var unannounced: LiteActionSummary { .enable(code: "") }

    private nonisolated static func contract(_ text: String) -> String? {
        StrKey.isValid(.contract, text) ? text : nil
    }

    private nonisolated static func whole(_ value: StellarJSON) -> Int? {
        switch value {
        case .number(let n) where n >= 0 && n == n.rounded() && n < 1e15: Int(n)
        case .string(let s): Int(s).flatMap { $0 >= 0 ? $0 : nil }
        default: nil
        }
    }

    private nonisolated static func whole(_ value: AnyJSON) -> Int? {
        switch value {
        case .number(let n) where n >= 0 && n == n.rounded() && n < 1e15: Int(n)
        case .string(let s): Int(s).flatMap { $0 >= 0 ? $0 : nil }
        default: nil
        }
    }
}
