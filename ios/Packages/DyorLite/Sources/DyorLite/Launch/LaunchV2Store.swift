import Foundation
import Observation
import StellarKit

/// Launchpad v2 for the Launch screens (docs/DESIGN-stellar-contracts-v2.md §20.2–§21, DESIGN-stellar-parity.md §8.10):
/// the terms new launches bind, a launch's live state and quotes, and the plan of every v2 action. Reads that only show
/// figures need no session (`economics` is public, `state(_:)` a viewer read). Every plan is built once a session is held
/// (a passkey account in the public view signs in once: the user started the action), priced on the phone and ready
/// for the review sheet and `LiteStore.run`, which verifies it against the build's pins before it signs.
///
/// New launches are v2's. A launch launchpad v2 doesn't know is a retired v1 launch (`state(_:)` answers nil): it keeps
/// v1's sell and creator-fee claim through `LiteStore` (`launchQuote`, `launchTradePlan`, `claimPlan`) and nothing new.
/// Every id (the launchpad, the venues, the XLM contract, the quote assets) comes from the API, never from here.
///
/// The API, in full:
/// - reads: `refreshEconomics()` (→ `economics`), `state(_:)`, `preview(_:)`, `quote(token:side:amount:)`;
/// - plans: `createPlan`, `tradePlan` (buy, sell, refund), `graduatePlan` (and its fallback), `markStuckPlan`,
///   `rescuePlan`, `claimPlan` (creator fees), `claimOwedPlan`, `claimRewardsPlan`, `recipientPlan` (transfer, veto,
///   apply, with the harvest backlog);
/// - the first buy's figures on the phone: `firstBuy(_:terms:creatorFeeBps:)`.
@MainActor
@Observable
public final class LaunchV2Store {
    public let store: LiteStore
    /// The v2 launchpad's terms (`GET /v1/economics`, read live); nil until read, and when this network has no v2
    /// launchpad (`economicsStatus` is then `.read`).
    public private(set) var economics: StellarLaunchpadEconomicsV2?
    /// How the last read of `economics` went (`.unread`, `.read` or `.failed`).
    public private(set) var economicsStatus: LiteReadStatus = .unread
    /// Why that read failed, in the current language; nil once one goes through.
    public private(set) var economicsError: String?

    public init(store: LiteStore) {
        self.store = store
    }

    private var pinned: PinnedContracts { store.env.pinned }

    /// Whether this build pins launchpad v2 (its contract and durations): the phone verifies every v2 transaction against
    /// them, so without them no v2 action can be signed here.
    public var isPinned: Bool { !pinned.contracts("launchpadV2").isEmpty && pinned.durations != nil }

    // MARK: - Reads

    /// The v2 launchpad's terms, read again. What was read stays until a read replaces it.
    public func refreshEconomics() async {
        do {
            economics = try await store.api.economicsV2().launchpad
            economicsStatus = .read
            economicsError = nil
        } catch {
            economicsStatus = .failed
            economicsError = LiteErrorText.describe(error)
        }
    }

    /// A launch's live v2 state: its phase and every time that gates an action, its venue, refunds, the fee recipient and
    /// a pending takeover, the curve fees booked, holder rewards and the viewer's owed fees. A viewer read (`you` is the
    /// account's, with or without a session). Nil for a launch launchpad v2 doesn't know (a retired v1 launch), and on a
    /// network with no v2 launchpad.
    public func state(_ token: String) async throws -> StellarLaunchStateV2? {
        do {
            return try await store.api.launchStateV2(token)
        } catch LiteAPIError.server(let status, let code, _, _) where status == 404 || code == "not_deployed" {
            return nil
        }
    }

    /// What `form` would bind now: the terms (venue and durations included), the launch fee, Max for the first buy
    /// (`maxInitialBuy`: what the launch leaves of the account's XLM for an XLM quote, the quote's balance otherwise) and
    /// the XLM missing before any buy (`shortfall`).
    public func preview(_ form: LaunchV2Form) async throws -> StellarLaunchPreviewV2 {
        try await store.ensureSession()
        return try await store.api.launchPreviewV2(form.request)
    }

    /// A curve buy (`amount` of the quote), a sale (`amount` coins) or a rescued launch's refund (`amount` coins), priced
    /// now, with its minimum at the fixed 1% slippage.
    public func quote(token: String, side: StellarTradeQuoteV2.Side, amount: Int64) async throws -> LaunchV2Quote {
        try await store.ensureSession()
        return LaunchV2Quote(side: side, amount: amount, quote: try await store.api.quoteTradeV2(token: token, side: side, amount: amount))
    }

    // MARK: - Plans

    /// A new coin on `terms` (the preview's, which the screen showed): its image uploaded and its metadata written
    /// first, then the launch with its 10 XLM fee and the developer buy. A ticker the contracts refuse, terms this build
    /// can't sign and terms that changed since they were shown are refused before anything is signed.
    public func createPlan(_ form: LaunchV2Form, terms: StellarLaunchTermsV2, image: Data?) async throws -> PreparedAction {
        guard let ticker = StellarTickerV2.normalized(form.symbol) else { throw StellarTickerV2.refusal }
        try check(terms)
        try await store.ensureSession()
        var imageUrl: String?
        if let image { imageUrl = try await store.upload(image, contentType: "image/jpeg") }
        let uri = try await store.api.launchMetadata(name: form.name, symbol: ticker, description: form.description, imageUrl: imageUrl,
                                                     website: form.website, x: form.x, telegram: form.telegram)
        var request = form.request
        request.symbol = ticker
        request.uri = uri
        let built = try await store.api.buildLaunchV2(request)
        if let bound = built.terms, bound != terms { throw Self.termsChanged }
        // What the user chose, as the create binds it: the server can't change the form either (verify.ts and
        // TxVerifier bind these fields to the transaction).
        if !Self.formChanges(built.plan, form: form, user: store.address).isEmpty { throw Self.formChanged }
        return try store.prepare(built.plan, limits: Self.createLimits(terms: terms, developerBuy: form.developerBuy),
                                 bindings: Self.createBindings(form, user: store.address), title: tr("Launch a coin"),
                                 titles: Self.titles(built.plan, main: tr("Launch \(ticker)"), symbol: ticker), section: .launch, reference: nil,
                                 summary: .launchCreate(symbol: ticker, name: form.name))
    }

    /// The trade `quote` priced: a buy spends at most its amount of `asset` (the launch's quote), a sale and a refund
    /// their coins, each bringing at least the quote's minimum.
    public func tradePlan(_ quote: LaunchV2Quote, token: String, symbol: String, asset: StellarLaunchStateV2.Quote) async throws -> PreparedAction {
        try requirePinned()
        try await store.ensureSession()
        let action: LiteAPI.LaunchRequestV2.Action
        let title: String
        let summary: LiteActionSummary
        switch quote.side {
        case .buy:
            (action, title, summary) = (.buy, tr("Buy"), .launchTrade(buy: true, symbol: symbol, amount: quote.amount, quoteCode: asset.code))
        case .sell:
            (action, title, summary) = (.sell, tr("Sell"), .launchTrade(buy: false, symbol: symbol, amount: quote.amount, quoteCode: asset.code))
        case .refund:
            (action, title, summary) = (.refund, words("Refund"),
                                        .launchV2(kind: "launch_refund", title: words("Refunded \(symbol)"), body: "\(Self.written(quote.amount)) \(symbol)"))
        }
        var request = LiteAPI.LaunchRequestV2(action: action, token: token, amount: String(quote.amount))
        if quote.side != .refund { request.minOut = String(quote.minOut) }
        let built = try await store.api.buildLaunchV2(request)
        let main = quote.side == .refund ? words("Refund \(Self.written(quote.amount)) \(symbol)") : title
        // A buy brings at least the quote's minimum of coins, a sale at least its minimum of the quote. A refund's rate is
        // fixed on chain and its intent names no minimum.
        let bindings = switch quote.side {
        case .buy: PlanBindings(minimums: [token: quote.minOut])
        case .sell: PlanBindings(minimums: [asset.contract: quote.minOut])
        case .refund: PlanBindings.none
        }
        return try store.prepare(built.plan, limits: [quote.side == .buy ? asset.contract : token: quote.amount], bindings: bindings, title: title,
                                 titles: Self.titles(built.plan, main: main, symbol: symbol), section: .launch,
                                 reference: "stellar:launch/\(token)", summary: summary)
    }

    /// Graduates a full curve on its own venue, or, once the fallback opens, on the fallback venue (Soroswap). Anyone
    /// may; the user pays only the network fee.
    public func graduatePlan(token: String, symbol: String, fallback: Bool = false) async throws -> PreparedAction {
        try await plan(.init(action: fallback ? .graduateFallback : .graduate, token: token), title: tr("Graduate"),
                       main: tr("Move this launch to Soroswap"), symbol: symbol, summary: .launchGraduate(symbol: symbol), token: token)
    }

    /// Marks a full curve's graduation delayed once its grace has passed (anyone may): the fallback and rescue clocks
    /// start.
    public func markStuckPlan(token: String, symbol: String) async throws -> PreparedAction {
        let title = words("Mark \(symbol)'s graduation delayed")
        return try await plan(.init(action: .markStuck, token: token), title: title, main: title, symbol: symbol,
                              summary: .launchV2(kind: "launch_mark_stuck", title: words("\(symbol)'s graduation marked delayed"), body: ""), token: token)
    }

    /// Opens refunds for a launch stuck past its rescue date (anyone may, from `rescuePublicAt`).
    public func rescuePlan(token: String, symbol: String) async throws -> PreparedAction {
        let title = words("Open refunds for \(symbol)")
        return try await plan(.init(action: .rescue, token: token), title: title, main: title, symbol: symbol,
                              summary: .launchV2(kind: "launch_rescue", title: words("Refunds opened for \(symbol)"), body: ""), token: token)
    }

    /// Pays the launch's booked curve fees to its current fee recipient (anyone may).
    public func claimPlan(token: String, symbol: String) async throws -> PreparedAction {
        try await plan(.init(action: .claim, token: token), title: tr("Claim"), main: tr("Claim your creator fees"), symbol: symbol,
                       summary: .launchClaim(symbol: symbol), token: token)
    }

    /// Pays the account the curve fees it earned before a fee recipient change (L14), `amount` of `asset`. Owed fees are
    /// per asset, not per launch.
    public func claimOwedPlan(asset: StellarLaunchStateV2.Quote, amount: Int64) async throws -> PreparedAction {
        let title = words("Claim creator fees owed to you")
        var request = LiteAPI.LaunchRequestV2(action: .claimOwed)
        request.asset = asset.contract
        return try await plan(request, title: title, main: title, symbol: asset.code,
                              summary: .launchV2(kind: "launch_claim_owed", title: words("Collected creator fees owed to you"),
                                                 body: "\(Self.written(amount)) \(asset.code)"), token: nil)
    }

    /// The account's holder rewards in the launch, in both its quote and the coin itself.
    public func claimRewardsPlan(token: String, symbol: String) async throws -> PreparedAction {
        let title = words("Claim your \(symbol) holder rewards")
        return try await plan(.init(action: .claimRewards, token: token), title: title, main: title, symbol: symbol,
                              summary: .launchV2(kind: "launch_claim_rewards", title: words("Claimed \(symbol) holder rewards"), body: ""), token: token)
    }

    /// A change of the launch's creator fee recipient: the current recipient's transfer, its veto of a pending takeover,
    /// or a takeover applied inside its window (anyone may). On a graduated launch without holder sharing, a transfer
    /// and an apply first collect the pool fees, and `backlog` is what one collection can't take before the change: the
    /// review offers to wait for the hourly collections instead (V7).
    public func recipientPlan(token: String, symbol: String, change: LaunchV2RecipientChange) async throws -> LaunchV2RecipientPlan {
        try requirePinned()
        try await store.ensureSession()
        var request: LiteAPI.LaunchRequestV2
        let main: String
        let summary: LiteActionSummary
        let bindings: PlanBindings
        switch change {
        case .transfer(let to):
            // The fees go to the address the user typed, exactly.
            bindings = PlanBindings(destination: .confirmed(to: to, memo: nil))
            request = .init(action: .recipientTransfer, token: token)
            request.to = to
            main = words("Change \(symbol)'s fee recipient")
            summary = .launchV2(kind: "launch_recipient_transfer", title: words("Changed \(symbol)'s fee recipient"), body: LiteFormat.short(to))
        case .cancel:
            bindings = .none
            request = .init(action: .recipientCancel, token: token)
            main = words("Veto the change of \(symbol)'s fee recipient")
            summary = .launchV2(kind: "launch_recipient_cancel", title: words("Vetoed the change of \(symbol)'s fee recipient"), body: "")
        case .execute:
            // The new recipient is the one the contract already holds for the pending change; the call names none.
            bindings = PlanBindings(destination: .unchecked)
            request = .init(action: .recipientExecute, token: token)
            main = words("Apply the change of \(symbol)'s fee recipient")
            summary = .launchV2(kind: "launch_recipient_execute", title: words("Changed \(symbol)'s fee recipient"), body: "")
        }
        let built = try await store.api.buildLaunchV2(request)
        let action = try store.prepare(built.plan, limits: [:], bindings: bindings, title: main, titles: Self.titles(built.plan, main: main, symbol: symbol),
                                       section: .launch, reference: "stellar:launch/\(token)", summary: summary)
        return LaunchV2RecipientPlan(action: action, backlog: built.harvestBacklog)
    }

    // MARK: - The first buy, on the phone

    /// What a developer buy of `amount` (base units of the quote) brings when the launch is made with `terms`: launchpad
    /// v2's own buy on a new curve (curve.rs `quote_buy`), with the creator exempt from the early-buy tax and a buy that
    /// would pass the threshold clamped to it. Nil for no buy, or terms that can't be read.
    public nonisolated static func firstBuy(_ amount: Int64, terms: StellarLaunchTermsV2, creatorFeeBps: Int) -> LaunchV2FirstBuy? {
        guard amount > 0, let supply = UInt64(terms.supply), let phantom = UInt64(terms.phantom), let threshold = UInt64(terms.threshold),
              threshold > 0, phantom > 0, terms.feeBps >= 0, creatorFeeBps >= 0 else { return nil }
        let total = UInt64(min(terms.feeBps + creatorFeeBps, maxTotalBps))
        var used = UInt64(amount)
        var net = used - mulDiv(used, total, bps)
        if net > threshold {
            used = min(mulDivUp(threshold, bps, bps - total), UInt64(amount))
            net = min(used - mulDiv(used, total, bps), threshold)
        }
        let tokens = net > 0 ? mulDiv(net, supply, phantom + net) : 0
        guard tokens > 0, let tokensOut = Int64(exactly: tokens), let taken = Int64(exactly: used) else { return nil }
        return LaunchV2FirstBuy(used: taken, fees: taken - Int64(net), tokensOut: tokensOut, minOut: StellarLaunchMath.minOut(tokensOut))
    }

    /// curve.rs: a buy's fees never take more than this.
    nonisolated static let maxTotalBps = 9_900
    private nonisolated static let bps: UInt64 = 10_000

    /// a · b / c, rounded down, through 128 bits (the product of a supply and an amount passes 64).
    nonisolated static func mulDiv(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64 {
        let product = a.multipliedFullWidth(by: b)
        guard product.high < c else { return .max }
        return c.dividingFullWidth(product).quotient
    }

    /// a · b / c, rounded up.
    nonisolated static func mulDivUp(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64 {
        let product = a.multipliedFullWidth(by: b)
        guard product.high < c else { return .max }
        let (quotient, remainder) = c.dividingFullWidth(product)
        return remainder > 0 ? quotient + 1 : quotient
    }

    // MARK: - Inside

    /// The most a create confirms spending: the launch fee in XLM, and the developer buy in the quote (both in XLM for an
    /// XLM quote).
    nonisolated static func createLimits(terms: StellarLaunchTermsV2, developerBuy: Int64) -> [String: Int64] {
        var limits = [terms.feeAsset: Int64(terms.launchFee) ?? 0]
        if developerBuy > 0 { limits[terms.quote, default: 0] += developerBuy }
        return limits
    }

    /// What a create binds besides its spends: the developer buy's minimum (for the new coin, whose contract exists only
    /// once launched), and where the creator fees go: the recipient the user typed, or the user.
    nonisolated static func createBindings(_ form: LaunchV2Form, user: String) -> PlanBindings {
        let minimums = form.developerBuy > 0 ? [PlanBindings.anyAsset: form.minOut] : [:]
        guard let recipient = form.recipient, recipient != user else { return PlanBindings(minimums: minimums) }
        return PlanBindings(minimums: minimums, destination: .confirmed(to: recipient, memo: nil))
    }

    /// The fields of `form` the plan's create binds differently, or doesn't state, by name; empty when it binds them as
    /// the form has them. Fails closed: a create not built yet, or one that doesn't state a field, differs. The creator
    /// fee recipient is `intent.to` (absent, or the user, for the user) and `display.recipient` (the recipient, or the
    /// user); the others are the create's display fields `snipeExempt` (the addresses comma-separated, in the form's
    /// order, "" for none), `creatorFeeBps` and `holderSharing`. Both verifiers bind each of them to the call.
    nonisolated static func formChanges(_ plan: PlanView, form: LaunchV2Form, user: String) -> [String] {
        guard let intent = plan.steps.lazy.compactMap(\.intent).first(where: { $0.kind == "launch_create" }) else { return ["create"] }
        var changes: [String] = []
        let wanted = form.recipient.flatMap { $0 == user ? nil : $0 }
        let bound = intent.to.flatMap { $0 == user ? nil : $0 }
        let shown = BoundDisplay(intent.display)
        if bound != wanted || shown.text("recipient") != (form.recipient ?? user) { changes.append("recipient") }
        if shown.strings("snipeExempt") != form.exempt { changes.append("snipeExempt") }
        if shown.whole("creatorFeeBps") != form.creatorFeeBps { changes.append("creatorFeeBps") }
        if shown.flag("holderSharing") != form.holderSharing { changes.append("holderSharing") }
        return changes
    }

    /// A permissionless or zero-spend action: built, then priced.
    private func plan(_ request: LiteAPI.LaunchRequestV2, title: String, main: String, symbol: String, summary: LiteActionSummary,
                      token: String?) async throws -> PreparedAction {
        try requirePinned()
        try await store.ensureSession()
        let built = try await store.api.buildLaunchV2(request)
        return try store.prepare(built.plan, limits: [:], title: title, titles: Self.titles(built.plan, main: main, symbol: symbol),
                                 section: .launch, reference: token.map { "stellar:launch/\($0)" }, summary: summary)
    }

    /// Terms this build can sign: launchpad v2 pinned, its fee within the pinned bound, its durations the pinned ones.
    private func check(_ terms: StellarLaunchTermsV2) throws {
        try requirePinned()
        guard let fee = Int64(terms.launchFee), fee >= 0, fee <= pinned.maxLaunchFeeStroops, let durations = pinned.durations?.launch,
              terms.durations.matches(durations) else { throw Self.termsRefused }
    }

    private func requirePinned() throws {
        guard isPinned else { throw Self.notPinned }
    }

    /// The phone's title for each step `LiteTitles` doesn't name (v2's own kinds, and steps the server hasn't built yet),
    /// so the review, the passkey prompt and the progress rows never show the server's English: a recipient change's
    /// pool-fee collection by its own words, every other step by the action's.
    nonisolated static func titles(_ plan: PlanView, main: String, symbol: String) -> [String: String] {
        var titles: [String: String] = [:]
        for step in plan.steps {
            if let intent = step.intent, LiteTitles.intent(kind: intent.kind, display: intent.display) != nil { continue }
            let kind = step.intent?.kind ?? step.stepKind
            titles[step.id] = kind == "launch_harvest" || kind == "launch_v2_harvest" ? words("Collect \(symbol)'s pool fees first") : main
        }
        return titles
    }

    /// An amount in base units as notifications write it (at most 4 decimals).
    nonisolated static func written(_ units: Int64) -> String { StellarAmount.format(units, maxFraction: 4) }

    nonisolated static var notPinned: LiteAPIError {
        .server(status: 409, code: "launchpad_v2_unpinned",
                message: words("This version of DyorHQ can't sign on Stellar's new launchpad yet. Update DyorHQ to continue."))
    }

    nonisolated static var termsRefused: LiteAPIError {
        .server(status: 409, code: "launch_terms_unpinned",
                message: words("The launchpad's terms aren't the ones this version of DyorHQ signs. Update DyorHQ to launch."))
    }

    nonisolated static var formChanged: LiteAPIError {
        .server(status: 409, code: "launch_form_changed", message: words("The launch doesn't match what you chose. Nothing was signed. Review your launch again."))
    }

    nonisolated static var termsChanged: LiteAPIError {
        .server(status: 409, code: "launch_terms_changed", message: words("The launchpad's terms changed. Review your launch again."))
    }
}

/// A new coin, as Create fills it in (`LaunchV2Store.createPlan`, `preview`).
public struct LaunchV2Form: Equatable, Sendable {
    public var name: String
    /// 2–10 ASCII letters or digits (`StellarTickerV2`): refused before anything is sent otherwise.
    public var symbol: String
    public var description: String?
    /// https links only (the server refuses the rest).
    public var website: String?
    public var x: String?
    public var telegram: String?
    /// The quote asset: "XLM", "USDC" or its contract.
    public var quote: String
    /// The graduation venue's id; nil for the quote's default.
    public var venue: Int?
    public var creatorFeeBps: Int
    /// Share fees with holders (Create's default).
    public var holderSharing: Bool
    /// Who receives the creator fees (G… or C…); nil for the creator.
    public var recipient: String?
    /// Buyers who pay no early-buy tax besides the creator and the recipient (at most 32).
    public var exempt: [String]
    /// The developer buy in the same transaction, base units of the quote; 0 for none.
    public var developerBuy: Int64
    /// The fewest coins it may bring (`LaunchV2FirstBuy.minOut`); 0 with no developer buy.
    public var minOut: Int64

    public init(name: String, symbol: String, description: String? = nil, website: String? = nil, x: String? = nil, telegram: String? = nil,
                quote: String, venue: Int? = nil, creatorFeeBps: Int, holderSharing: Bool = true, recipient: String? = nil, exempt: [String] = [],
                developerBuy: Int64 = 0, minOut: Int64 = 0) {
        self.name = name
        self.symbol = symbol
        self.description = description
        self.website = website
        self.x = x
        self.telegram = telegram
        self.quote = quote
        self.venue = venue
        self.creatorFeeBps = creatorFeeBps
        self.holderSharing = holderSharing
        self.recipient = recipient
        self.exempt = exempt
        self.developerBuy = developerBuy
        self.minOut = minOut
    }

    /// The create request (and the preview's) for these fields.
    var request: LiteAPI.LaunchRequestV2 {
        LiteAPI.LaunchRequestV2(action: .create, quote: quote, venue: venue, name: name, symbol: symbol, creatorFeeBps: creatorFeeBps,
                                holderSharing: holderSharing, recipient: recipient, exempt: exempt.isEmpty ? nil : exempt,
                                amount: developerBuy > 0 ? String(developerBuy) : nil, minOut: developerBuy > 0 ? String(minOut) : nil)
    }
}

/// A curve trade's or a refund's price (`LaunchV2Store.quote`): what it brings, at least what it must bring, and every
/// fee apart.
public struct LaunchV2Quote: Equatable, Sendable {
    public let side: StellarTradeQuoteV2.Side
    /// The quote a buy spends, or the coins a sale or a refund gives, in base units.
    public let amount: Int64
    /// The coins a buy brings, or the quote a sale or a refund brings, in base units.
    public let out: Int64
    /// `out` less 1% (the fixed slippage, R11); a refund's own figure, which its fixed rate can't move.
    public let minOut: Int64
    /// The server's answer: `used`, `baseFee`, `creatorFee`, `snipeFee`, `refund`, a refund's `rate`.
    public let quote: StellarTradeQuoteV2

    init(side: StellarTradeQuoteV2.Side, amount: Int64, quote: StellarTradeQuoteV2) {
        self.side = side
        self.amount = amount
        self.quote = quote
        out = Int64((side == .buy ? quote.tokensOut : quote.quoteOut) ?? "0") ?? 0
        minOut = side == .refund ? out : StellarLaunchMath.minOut(out)
    }

    /// A fee or an amount of the answer in base units; 0 when it says none.
    public static func units(_ text: String?) -> Int64 { text.flatMap { Int64($0) } ?? 0 }
}

/// What a developer buy brings on a new curve (`LaunchV2Store.firstBuy`).
public struct LaunchV2FirstBuy: Equatable, Sendable {
    /// What the curve takes of the buy: all of it, unless it fills the curve.
    public let used: Int64
    /// The curve fee and the creator fee in it.
    public let fees: Int64
    public let tokensOut: Int64
    /// `tokensOut` less 1%.
    public let minOut: Int64
}

/// A change of a launch's creator fee recipient (`LaunchV2Store.recipientPlan`).
public enum LaunchV2RecipientChange: Equatable, Sendable {
    /// The current recipient hands the creator fees to `to` (G… or C…).
    case transfer(to: String)
    /// The current recipient vetoes the admin's pending takeover.
    case cancel
    /// A pending takeover applied inside its window (anyone may).
    case execute
}

/// A recipient change ready for the review, and the pool fees it hands over that the hourly collections haven't taken yet.
public struct LaunchV2RecipientPlan: Equatable {
    public let action: PreparedAction
    public let backlog: StellarHarvestBacklogV2?
}

/// Launchpad v2's words, from the package's own table (Resources/LaunchV2.xcstrings), in the current language.
private func words(_ value: String.LocalizationValue) -> String {
    LiteL10n.string(LocalizedStringResource(value, table: "LaunchV2", bundle: LiteL10n.lite))
}
