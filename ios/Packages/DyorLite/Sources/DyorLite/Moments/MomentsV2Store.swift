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

    /// A Moment as the API's indexer recorded it (a feed's card, a page's header, an account's or a creator's Moment).
    public init(_ row: StellarMomentRowV2) {
        self.init(nft: row.nft, name: row.name, symbol: row.symbol, image: row.image, video: row.isVideo ? row.mediaUrl : nil, place: row.place,
                  takenOn: row.takenOn)
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

/// What a graduation plan's attempt does, as the API's simulation found it when it built the step
/// (`MomentsV2Store.graduation(in:)`): for the review and the notification.
public struct StellarGraduationAttemptV2: Equatable, Sendable {
    /// The attempt fails as things stand: it records the failure, which starts the clock to the Moment's expiry, and the
    /// Moment doesn't graduate.
    public let failed: Bool
    /// The failure: the contract error's name ("GraduationInvalid"), or its origin and code when the API's table doesn't
    /// name it; nil when it graduates.
    public let failure: String?
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

    /// A Moment's page as the API's indexer recorded it (a viewer read): its name, ticker, media, place and date, its
    /// collectors, the account's editions and coins (`you`), and the creator's earnings. A 404 until the indexer has seen
    /// its publish.
    public func detail(_ nft: String) async throws -> StellarMomentDetailV2 {
        try await store.api.momentV2(nft)
    }

    /// The account's USDC, in base units, as last read.
    public var usdcBalance: Int64 { store.balance("USDC") }

    // MARK: - Publish

    /// Whether the account must enable USDC before it publishes, read again now: a creator's proceeds are paid in USDC,
    /// and a publish the server queues behind the account's USDC trustline can't be checked against its review
    /// (`publishWaits`), so Publish enables USDC first (`enableUSDCPlan`). False when the account can't be read: the
    /// publish's own plan then says.
    public func needsUSDC() async -> Bool {
        await store.refreshAccount()
        guard let account = store.account, account.exists else { return false }
        return !(account.balances.first { $0.asset == "USDC" }?.enabled ?? false)
    }

    /// Enables USDC on the account (its trustline, one base reserve of the account's own XLM), before a publish.
    public func enableUSDCPlan() async throws -> PreparedAction {
        try await store.enablePlan(asset: "USDC")
    }

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

    /// A new Moment: its metadata written, then the publish, which binds the terms as they stand by value. The server puts
    /// the account's USDC trustline first when it has none (a creator withdraws its proceeds in USDC), and builds the
    /// publish only once that confirmed, too late for its review to check it (`publishWaits`): enable USDC first
    /// (`needsUSDC`). The ticker is refused here, before anything is sent, unless the contracts would take it
    /// (`StellarTickerV2`).
    public func publishPlan(_ form: StellarMomentFormV2, media: StellarMomentUploadV2, title: String) async throws -> PreparedAction {
        guard let symbol = StellarTickerV2.normalized(form.symbol) else { throw StellarTickerV2.refusal }
        try await store.ensureSession()
        let metadata = try await store.api.momentMetadata(title: form.name, description: form.description, mediaUrl: media.mediaUrl,
                                                          mediaType: media.isVideo ? "video" : "image", posterUrl: media.posterUrl,
                                                          place: form.place, takenOn: form.takenOn)
        let plan = try await store.api.buildMomentV2(.init(action: .publish, uri: metadata.uri, name: form.name, symbol: symbol,
                                                           price: String(form.price), allocationBps: form.allocationBps, windowSecs: form.windowSecs))
        // What the user chose, as the publish binds it (verify.ts and TxVerifier bind these to the transaction). A publish
        // queued behind the USDC trustline isn't built yet: its review doesn't go ahead (`publishWaits`).
        if !Self.publishWaits(plan), !Self.formChanges(plan, form: form).isEmpty { throw Self.formChanged }
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
    /// `name` and `symbol` name the Moment in the notification ("Claimed $DUSK").
    public func claimPlan(nft: String, name: String, symbol: String?, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .claim, nft: nft))
        let coins = Self.amount(plan, "moment_claim", "total")
        let summary = LiteActionSummary.momentV2(kind: "moment_claim", title: words("Claimed \(Self.label(name: name, symbol: symbol))"),
                                               body: coins.map { words("\(Self.written($0)) vested coins") } ?? "")
        return try store.prepare(plan, limits: [:], title: title, titles: Self.titles(plan, kind: "moment_claim", main: words("Claim your vested coins")),
                                 section: .moments, reference: Self.reference(nft), summary: summary)
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
        let count = plan.steps.lazy.compactMap(\.intent).first { $0.kind == "moment_claim_all" }?.display?["moments"].flatMap(Self.whole) ?? unique.count
        let summary = LiteActionSummary.momentV2(kind: "moment_claim_all", title: words("Claimed vested coins"), body: words("across \(count) Moments"))
        return try store.prepare(plan, limits: [:], title: title,
                                 titles: Self.titles(plan, kind: "moment_claim_all", main: words("Claim vested coins from \(count) Moments")),
                                 section: .moments, reference: "stellar:moment", summary: summary)
    }

    /// The creator's proceeds of the Moment `nft` (its share of every collect, and of an expired reserve), in USDC, to
    /// the account: with its USDC trustline first when it has none. `proceeds` (USDC base units, as the page read them)
    /// words the notification while the withdrawal waits behind that trustline; once built, it states its own amount.
    public func withdrawPlan(nft: String, name: String, symbol: String?, proceeds: Int64?, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .withdraw, nft: nft))
        let amount = Self.amount(plan, "moment_withdraw", "amount") ?? proceeds
        let summary = LiteActionSummary.momentV2(kind: "moment_withdraw", title: words("Collected \(Self.label(name: name, symbol: symbol)) proceeds"),
                                               body: amount.map { words("\(Self.written($0)) USDC creator proceeds") } ?? "")
        return try store.prepare(plan, limits: [:], title: title, titles: Self.titles(plan, kind: "moment_withdraw", main: words("Withdraw your proceeds")),
                                 section: .moments, reference: Self.reference(nft), summary: summary)
    }

    /// Graduates the completed Moment `nft` into its coin and Soroswap pool: anyone may, paying only the network fee. The
    /// API offers it only when it would graduate, or record the first failure (which starts the clock to expiry): the
    /// plan says which (`graduation(in:)`), and so do its review and its notification. `reserve` (USDC base units, as the
    /// page read it) words a graduation's notification.
    public func graduatePlan(nft: String, name: String, symbol: String?, reserve: Int64?, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .graduate, nft: nft))
        let label = Self.label(name: name, symbol: symbol)
        let summary: LiteActionSummary
        let main: String
        switch Self.graduation(in: plan) {
        case let attempt? where attempt.failed:
            summary = .momentV2(kind: "moment_graduate", title: words("Recorded a failed graduation of \(label)"), body: attempt.failure ?? "")
            main = words("Record a failed graduation attempt")
        case .some:
            summary = .momentV2(kind: "moment_graduate", title: words("Graduated \(label)"),
                                body: reserve.map { words("\(Self.written($0)) USDC reserve into a locked pool") } ?? "")
            main = words("Graduate this Moment")
        case nil:
            // Not built yet (behind a restore): what the attempt does is known only once it is.
            summary = .momentV2(kind: "moment_graduate", title: words("Tried to graduate \(label)"), body: "")
            main = words("Graduate this Moment")
        }
        return try store.prepare(plan, limits: [:], title: title, titles: Self.titles(plan, kind: "moment_graduate", main: main), section: .moments,
                                 reference: Self.reference(nft), summary: summary)
    }

    /// Ends the Moment `nft` without graduating, once it may (`StellarMomentStatusV2.expirable`): its reserve goes to the
    /// creator and the treasury (`expiryCreatorBps`), and collectors keep their editions. Anyone may. `name` names it in
    /// the notification ("Expired Harbour at dusk").
    public func expirePlan(nft: String, name: String, title: String) async throws -> PreparedAction {
        try await store.ensureSession()
        let plan = try await store.api.buildMomentV2(.init(action: .expire, nft: nft))
        let reserve = Self.amount(plan, "moment_expire", "reserve")
        let summary = LiteActionSummary.momentV2(kind: "moment_expire", title: words("Expired \(name)"),
                                               body: reserve.map { words("\(Self.written($0)) USDC reserve wound down") } ?? "")
        return try store.prepare(plan, limits: [:], title: title, titles: Self.titles(plan, kind: "moment_expire", main: words("Expire this Moment")),
                                 section: .moments, reference: Self.reference(nft), summary: summary)
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
    /// values, by name; empty when it binds them exactly. The guard fails closed: a field the publish doesn't state counts
    /// as differing, and a plan with no built publish (none at all, or one queued behind the account's USDC trustline,
    /// `publishWaits`, which the server would build later with the terms as they stand then) is "publish".
    public nonisolated static func termsChanges(_ plan: PlanView, terms: StellarMomentsTermsV2, form: StellarMomentFormV2) -> [String] {
        guard let intent = plan.steps.first(where: isPublish)?.intent, intent.kind == "moment_publish" else { return ["publish"] }
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

    /// The fields of `form` the plan's built publish binds differently, or doesn't state, by name; empty when it binds
    /// them as the form has them: `price` (USDC base units), `allocBps` (or `allocationBps`) and `windowSecs`. Fails
    /// closed: no built publish, or a field it doesn't state, differs.
    public nonisolated static func formChanges(_ plan: PlanView, form: StellarMomentFormV2) -> [String] {
        guard let intent = plan.steps.first(where: isPublish)?.intent, intent.kind == "moment_publish" else { return ["publish"] }
        let shown = BoundDisplay(intent.display)
        var changes: [String] = []
        if shown.text("price") != String(form.price) { changes.append("price") }
        if (shown.whole("allocBps") ?? shown.whole("allocationBps")) != form.allocationBps { changes.append("allocBps") }
        if shown.whole("windowSecs") != form.windowSecs { changes.append("windowSecs") }
        return changes
    }

    nonisolated static var formChanged: LiteAPIError {
        .server(status: 409, code: "moment_form_changed", message: words("The Moment doesn't match what you chose. Nothing was signed. Review it again."))
    }

    /// Whether a publish plan's publish waits, unbuilt, behind another step (the account's USDC trustline): it can't be
    /// compared with its review before it is built, so the review doesn't go ahead (`termsChanges`).
    public nonisolated static func publishWaits(_ plan: PlanView) -> Bool {
        plan.steps.first(where: isPublish).map { $0.intent == nil } ?? false
    }

    /// What a graduation plan's attempt does, from its built step's intent; nil before the server built it.
    public nonisolated static func graduation(in plan: PlanView) -> StellarGraduationAttemptV2? {
        guard let d = plan.steps.lazy.compactMap(\.intent).first(where: { $0.kind == "moment_graduate" })?.display,
              case .string(let outcome)? = d["outcome"] else { return nil }
        // Anything but a graduation reads as an attempt that doesn't graduate.
        guard outcome != "graduated" else { return StellarGraduationAttemptV2(failed: false, failure: nil) }
        let named: String? = if case .string(let name)? = d["failureName"], !name.isEmpty { name } else { nil }
        let coded = [d["failureOrigin"], d["failureCode"]].compactMap { $0.flatMap(whole).map(String.init) }
        return StellarGraduationAttemptV2(failed: true, failure: named ?? (coded.count == 2 ? coded.joined(separator: " · ") : nil))
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

    /// A publish step: built (its intent's kind) or not yet (the server's step kind, v1's or v2's builder).
    private nonisolated static func isPublish(_ step: PlanStep) -> Bool {
        step.intent?.kind == "moment_publish" || ["moment_publish", "moment_v2_publish"].contains(step.stepKind ?? "")
    }

    /// The phone's title for the action's own step (`kind`, built or not: v2's builder kind is "moment_v2_…"), so the
    /// review, the passkey prompt and the progress rows never show the server's English; a step `LiteTitles` names keeps
    /// its words.
    nonisolated static func titles(_ plan: PlanView, kind: String, main: String) -> [String: String] {
        let builder = "moment_v2_" + kind.dropFirst("moment_".count)
        var titles: [String: String] = [:]
        for step in plan.steps where [kind, builder].contains(step.intent?.kind ?? step.stepKind ?? "") {
            if let intent = step.intent, LiteTitles.intent(kind: intent.kind, display: intent.display) != nil { continue }
            titles[step.id] = main
        }
        return titles
    }

    /// An amount in base units that the plan's built `kind` step states in its display under `key`.
    private nonisolated static func amount(_ plan: PlanView, _ kind: String, _ key: String) -> Int64? {
        guard case .string(let text)? = plan.steps.lazy.compactMap(\.intent).first(where: { $0.kind == kind })?.display?[key],
              let units = Int64(text), units >= 0 else { return nil }
        return units
    }

    /// The Moment as a notification names it: its ticker ("$DUSK"), else its name.
    nonisolated static func label(name: String, symbol: String?) -> String { symbol.map { "$\($0)" } ?? name }

    /// An amount in base units as notifications write it (at most 4 decimals).
    nonisolated static func written(_ units: Int64) -> String { StellarAmount.format(units, maxFraction: 4) }

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

/// Moments v2's words, from the package's own table (Resources/MomentsV2.xcstrings), in the current language.
private func words(_ value: String.LocalizationValue) -> String {
    LiteL10n.string(LocalizedStringResource(value, table: "MomentsV2", bundle: LiteL10n.lite))
}
