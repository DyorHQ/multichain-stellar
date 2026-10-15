import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

// Launchpad v2 (docs/DESIGN-stellar-contracts-v2.md §5, §20.2–20.3; the API's _shared/launchpad_v2.ts): the launchpad
// block of /v1/economics, a launch's live state, the launch preview with its XLM check and Max, trade and refund
// quotes, and the plans of every v2 launch action. Launches are keyed by their token's address. Amounts are base units
// as decimal strings, durations seconds, times ISO 8601. v1's models (Models+Launch.swift) stay for the retired
// generation.
//
// The routes, as the API serves them for v2 (CT-18 wires them):
//   GET  /v1/economics                  public    both blocks; v2's carry generation 2 (StellarEconomicsV2)
//   POST /v1/launches/preview           session   the terms a launch binds now, its fee, Max and the shortfall
//   GET  /v1/launches/:token/state      viewer    status, recipient, takeover, creator fees, rewards, owed fees
//   POST /v1/launches/:token/quote      session   buy, sell, and a rescued launch's refund
//   POST /v1/launches/build             session   every v2 action (LaunchRequestV2); a recipient change answers its
//                                                 harvest backlog beside the plan

/// A graduation venue (launchpad-v2 VenueInfo), named as every label names it.
public struct StellarLaunchVenueV2: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    /// "Soroswap", "Aquarius", "HoldOnly", or "QaFail" (testnet-qa's failing venue, never pinned in the app).
    public let kind: String
    /// What the app shows: "Soroswap", "Aquarius 0.3%", …: the launch's own venue, never another's.
    public let name: String
    public let executor: String
    public let enabled: Bool
    /// Aquarius's fee tier in bps (30 = 0.3%); 0 for every other venue.
    public let feeFraction: Int
}

/// launchpad-v2's durations, in seconds (dyor_common::LaunchDurations). Every launch binds them.
public struct StellarLaunchDurationsV2: Codable, Equatable, Sendable {
    /// After completion, how long graduation may take before anyone can mark the launch delayed (stuck).
    public let grace: Int
    /// After `stuck_since`, how long only the creator's venue is retried before the fallback opens (F14).
    public let fallbackDelay: Int
    public let rescueAdmin: Int
    /// After `stuck_since`, when anyone may open refunds (O2).
    public let rescuePublic: Int
    /// A venue-locked launch's fallback opens this long after `stuck_since` (or when the admin allows it).
    public let lockedFallback: Int
    public let takeoverDelay: Int
    public let takeoverWindow: Int
    public let timelock: Int
    public let timelockWindow: Int
    /// The LP locker's harvest interval: pool fees are collected at most this often (F6).
    public let harvestInterval: Int

    /// Whether these are the durations the app pins (`PinnedContracts.durations`): the verifier refuses a launch that
    /// binds others, so a screen can tell before the review.
    public func matches(_ pinned: PinnedDurations.Launch) -> Bool {
        [grace, fallbackDelay, rescueAdmin, rescuePublic, lockedFallback, takeoverDelay, takeoverWindow, timelock, timelockWindow, harvestInterval]
            .map(UInt64.init(clamping:)) == [
                pinned.grace, pinned.fallbackDelay, pinned.rescueAdmin, pinned.rescuePublic, pinned.lockedFallback, pinned.takeoverDelay,
                pinned.takeoverWindow, pinned.timelock, pinned.timelockWindow, pinned.harvestInterval,
            ]
    }
}

/// Everything a launch binds (launchpad-v2 LaunchTerms, read with preview_launch_terms): a launch passes them back by
/// value, and the phone's verifier holds the venue's executors, the locker, the token's WASM and the durations to its
/// pins, and the fee to its bound.
public struct StellarLaunchTermsV2: Codable, Equatable, Sendable {
    public let supply: String
    public let feeBps: Int
    /// The protocol's share of the curve fee, and of both sides of every harvest after graduation (O1, V1).
    public let protocolShareBps: Int
    public let maxCreatorFeeBps: Int
    /// The early-buy tax in bps, one step per `snipeStepSecs` after the launch (index 0 is the launch's own ledger).
    public let snipeSchedule: [Int]
    public let snipeStepSecs: Int
    /// In stroops, paid in XLM to the launchpad whatever the quote (10 XLM, O6).
    public let launchFee: String
    /// The XLM Stellar Asset Contract.
    public let feeAsset: String
    public let quote: String
    public let phantom: String
    public let threshold: String
    public let venue: StellarLaunchVenueV2
    /// Always a Soroswap venue.
    public let fallback: StellarLaunchVenueV2
    /// The quote's allowlist leaves the fallback out: it opens only after `lockedFallback`, or when the admin allows it.
    public let venueLocked: Bool
    public let locker: String
    /// Hex.
    public let tokenWasmHash: String
    public let durations: StellarLaunchDurationsV2
}

/// The launchpad block of `GET /v1/economics` for v2 (§20.2), read live from the contracts. The admin is never served.
public struct StellarLaunchpadEconomicsV2: Codable, Equatable, Sendable {
    /// Booked on the launch and swept to the treasury by anyone (O6).
    public struct LaunchFee: Codable, Equatable, Sendable {
        /// "XLM".
        public let asset: String
        public let contract: String
        public let amount: String
        public let booked: Bool
    }

    /// A quote asset launches may be priced in, and the venues open to it.
    public struct Quote: Codable, Equatable, Sendable {
        /// "XLM", "USDC" (testnet-qa: "QA").
        public let asset: String
        public let code: String
        public let contract: String
        public let phantom: String
        public let threshold: String
        public let enabled: Bool
        /// The venue ids a launch in this quote may choose; empty: every enabled venue.
        public let venuesAllowed: [Int]
        public let fallbackVenue: Int
        /// The allowlist leaves the fallback out (the Create screen forces the venue).
        public let venueLocked: Bool
        /// The venue create picks when none is asked for; nil when none is open.
        public let defaultVenue: Int?
        /// What a launch on `defaultVenue` binds now; nil while the quote is off.
        public let terms: StellarLaunchTermsV2?
    }

    /// After graduation (§8.2, §14.4): every interval, at most `roundCapBps` of the locked position; all of the growth,
    /// both sides split by the launch's own pinned protocol share; holders paid in the quote and the coin (F1); the
    /// treasury holds the launch tokens it receives (V2).
    public struct Harvest: Codable, Equatable, Sendable {
        public struct Split: Codable, Equatable, Sendable {
            public let protocolBps: Int
            public let creatorOrHoldersBps: Int
        }

        public let intervalSecs: Int
        public let roundCapBps: Int
        public let harvestBps: Int
        /// What new launches pin; each launch keeps the split it was launched with.
        public let split: Split
        public let splitPinnedPerLaunch: Bool
        /// ["quote", "token"].
        public let sides: [String]
        public let holdersPaidIn: [String]
        /// "held".
        public let treasuryLaunchTokens: String
    }

    /// exclude_pool's floor (F2): a DEX pool of a launch token is excluded from holder rewards only above it.
    public struct ExclusionFloor: Codable, Equatable, Sendable {
        public let minPoolTokens: String
        public let minPendingQuote: String
        public let minPendingTokens: String
    }

    /// exec-aquarius's float (F11), where the deployment has the Aquarius venue; Aquarius is off everywhere today (O7).
    public struct AquariusFloat: Codable, Equatable, Sendable {
        public let asset: String
        public let amount: String
        public let poolPayment: String
        public let target: String
        public let alertBelow: String
    }

    public let contract: String
    /// 2.
    public let generation: Int
    public let launchesEnabled: Bool
    public let whitelistEnabled: Bool
    public let supply: String
    public let feeBps: Int
    public let protocolShareBps: Int
    public let maxCreatorFeeBps: Int
    public let snipeSchedule: [Int]
    public let snipeStepSecs: Int
    public let launchFee: LaunchFee
    public let treasury: String
    public let locker: String
    /// The venues this deployment offers (Aquarius only where it is enabled).
    public let venues: [StellarLaunchVenueV2]
    public let quotes: [Quote]
    public let durations: StellarLaunchDurationsV2
    public let harvest: Harvest
    public let exclusionFloor: ExclusionFloor
    public let aquariusFloat: AquariusFloat?
}

/// `GET /v1/economics` as v2 reads it: each block when it is v2's (generation 2), nil for v1's block or none, so a v1
/// server's answer reads as "not deployed".
public struct StellarEconomicsV2: Codable, Equatable, Sendable {
    public let launchpad: StellarLaunchpadEconomicsV2?
    public let moments: StellarMomentsEconomicsV2?

    public init(launchpad: StellarLaunchpadEconomicsV2?, moments: StellarMomentsEconomicsV2?) {
        self.launchpad = launchpad
        self.moments = moments
    }

    private enum CodingKeys: String, CodingKey { case launchpad, moments }
    private struct Generation: Decodable { let generation: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchpad = try Self.v2(c, .launchpad)
        moments = try Self.v2(c, .moments)
    }

    /// The block under `key` when it says generation 2. A v2 block that doesn't decode is an error, never nil.
    private static func v2<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> T? {
        guard let block = try c.decodeIfPresent(Generation.self, forKey: key), block.generation == 2 else { return nil }
        return try c.decode(T.self, forKey: key)
    }
}

/// Why a launch's graduation is delayed (V10): the failure the indexer recorded, or what graduate fails with in a
/// simulation now. `origin` is the contract's tag (0 for a contract outside DyorHQ, 99 for the host), `code` its
/// namespaced error code.
public struct StellarGraduationFailureV2: Codable, Equatable, Sendable {
    public let origin: Int
    public let code: Int
    /// The error's name ("LiquidityTooLow"); nil for a pair the API's table doesn't know.
    public let name: String?
    /// The contract that raised it ("exec-soroswap"); nil with `name`.
    public let contract: String?
    /// "recorded" or "simulated".
    public let source: String

    public var recorded: Bool { source == "recorded" }
}

/// A launch's status (launchpad-v2 `status`, §5.3): its phase, every time that gates an action, the venues, a rescued
/// launch's refund rate and a delayed graduation's failure.
public struct StellarLaunchStatusV2: Codable, Equatable, Sendable {
    /// Refund mode (Rescued): one fixed rate for every holder, in any order, with no fees (O2).
    public struct Refund: Codable, Equatable, Sendable {
        /// The quote set aside for refunds, and the supply it pays out over.
        public let quote: String
        public let supply: String
        public let refunded: String
        /// Quote per whole token, human units ("0.000000048050614666").
        public let rate: String
    }

    /// What a plan may do now; the time-gated ones open at the times above.
    public struct Actions: Codable, Equatable, Sendable {
        public let buy: Bool
        public let sell: Bool
        public let graduate: Bool
        public let graduateFallback: Bool
        public let markStuck: Bool
        public let rescue: Bool
        public let refund: Bool
    }

    public let token: String
    /// "curve", "completed", "graduated" or "rescued".
    public let phase: String
    public let completedAt: String?
    /// Completed, and graduation delayed: marked stuck after a failed attempt or the grace.
    public let stuck: Bool
    public let stuckSince: String?
    /// When mark_stuck opens: completion + grace.
    public let markStuckAt: String?
    /// When graduate_fallback opens: `stuckSince` + fallbackDelay, later for a venue-locked launch (F14).
    public let fallbackAt: String?
    public let rescueAdminAt: String?
    /// When anyone may open refunds.
    public let rescuePublicAt: String?
    public let venue: StellarLaunchVenueV2
    public let fallback: StellarLaunchVenueV2
    public let venueLocked: Bool
    /// The admin allowed a venue-locked launch's fallback early.
    public let fallbackAllowed: Bool
    public let pool: String?
    public let graduatedVenue: StellarLaunchVenueV2?
    public let refund: Refund?
    /// A stuck launch's failure; nil otherwise, and when nothing can say (RPC down, an attempt that would graduate).
    public let failure: StellarGraduationFailureV2?
    public let actions: Actions
}

/// A launch's page (§20.2–20.3): its status, who receives its creator fees, a pending takeover, the curve fees booked,
/// holder rewards in both assets, and the viewer's owed fees. A viewer read.
public struct StellarLaunchStateV2: Codable, Equatable, Sendable {
    public struct Quote: Codable, Equatable, Sendable {
        /// "XLM", "USDC", or the contract itself for an asset the API doesn't list.
        public let id: String
        public let code: String
        public let contract: String
    }

    /// The admin's takeover of the fee recipient (§5.4): the current recipient may veto it while it waits.
    public struct Takeover: Codable, Equatable, Sendable {
        public let new: String
        public let effectiveAt: String
        public let expiresAt: String
        /// "waiting" (vetoable, not yet executable), "open" (inside its window) or "lapsed", when the API answered.
        public let state: String

        /// The state at `now`, as the API words it: a takeover held on screen past `expiresAt` reads as lapsed.
        public func state(at now: Date) -> String {
            LiteWindow(from: effectiveAt, to: expiresAt).map { $0.state(at: now, before: "waiting", inside: "open") } ?? state
        }
    }

    /// Holder rewards (L13, F1): in the quote, and in the launch token itself after graduation.
    public struct Rewards: Codable, Equatable, Sendable {
        /// The launch shares fees with its holders.
        public let sharing: Bool
        /// The supply that earns rewards; nil without sharing.
        public let eligible: String?
        public let queuedQuote: String
        public let queuedToken: String
        /// Queued rewards become claimable from this ledger; nil with nothing queued.
        public let releasableFromLedger: Int?
        /// The viewer's, claimable now; nil without a viewer.
        public let pendingQuote: String?
        public let pendingToken: String?
    }

    /// The viewer's side.
    public struct You: Codable, Equatable, Sendable {
        public let isRecipient: Bool
        /// Curve fees owed from before a recipient change (L14), in the quote: claim_owed pays them.
        public let creatorOwed: String
    }

    public let status: StellarLaunchStatusV2
    public let quote: Quote
    /// Who the creator fees, and the creator side of harvests without sharing, go to now.
    public let recipient: String
    public let pendingTakeover: Takeover?
    /// Curve fees booked for the current recipient, in the quote.
    public let creatorFees: String
    public let rewards: Rewards
    /// Nil without a viewer.
    public let you: You?
}

/// What a launch leaves an account in XLM (§20.3, F18, V12), in stroops.
public struct StellarLaunchXLMV2: Codable, Equatable, Sendable {
    public let balance: String
    /// (2 + subentries + sponsoring − sponsored) × the base reserve.
    public let minBalance: String
    /// XLM the account's open DEX offers sell: the network won't spend it.
    public let sellingLiabilities: String
    public let launchFee: String
    /// The launch's own network fee, simulated.
    public let fees: String
    public let buffer: String
    /// balance − minBalance − sellingLiabilities − launchFee − fees − buffer: what an XLM first buy may take. Negative
    /// when even a launch without one doesn't fit.
    public let spendable: String
}

/// `POST /v1/launches/preview`: the terms a launch would bind now, its fee, and the Create screen's Max (§20.3).
public struct StellarLaunchPreviewV2: Codable, Equatable, Sendable {
    public struct LaunchFee: Codable, Equatable, Sendable {
        public let asset: String
        public let amount: String
        public let booked: Bool
        /// The launchpad: the fee goes nowhere else (the verifier checks it).
        public let to: String
    }

    public let quote: StellarLaunchStateV2.Quote
    public let venue: StellarLaunchVenueV2
    public let terms: StellarLaunchTermsV2
    public let launchFee: LaunchFee
    public let xlm: StellarLaunchXLMV2
    public let quoteBalance: String
    /// Max for the first buy: what the launch leaves for an XLM quote (never below 0), the balance for any other.
    public let maxInitialBuy: String
    /// XLM missing before any buy; nil when a launch fits.
    public let shortfall: String?
}

/// `POST /v1/launches/:token/quote` on a v2 launch: every fee apart, none on a refund.
public struct StellarTradeQuoteV2: Codable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable {
        case buy, sell
        /// A rescued launch's refund, at its fixed rate.
        case refund
    }

    public let side: Side
    /// Buy: the quote the curve takes (a full curve takes less), and the tokens out.
    public let used: String?
    public let tokensOut: String?
    /// Sell and refund: the quote out.
    public let quoteOut: String?
    public let fees: String
    public let baseFee: String?
    public let creatorFee: String?
    public let snipeFee: String?
    /// What a full curve leaves of a buy.
    public let refund: String?
    /// Refund: quote per whole token.
    public let rate: String?
}

/// The pool fees a recipient change hands to the new recipient (V7): on a graduated launch without holder sharing,
/// what one harvest round can't take before the change. Pool fees not yet collected go to the new recipient; with this
/// backlog the review offers to wait for the hourly collections.
public struct StellarHarvestBacklogV2: Codable, Equatable, Sendable {
    /// The new recipient's part, after the treasury's pinned share, in the quote and the launch token.
    public let residualQuote: String
    public let residualToken: String
    /// The whole growth not yet harvested, the treasury's part included.
    public let growthQuote: String
    public let growthToken: String
    /// Harvests it takes with no further volume: one per interval.
    public let roundsToDrain: Int
    public let nextHarvestAt: String
    /// When the last of them can run.
    public let drainedBy: String
}

/// `POST /v1/launches/build` for v2: the plan, and what v2 adds to it. `plan` is what the review shows and `PlanRunner`
/// runs; each built step's intent keeps the fields every verifier reads, and its v2 fields are in `intents`.
public struct StellarLaunchPlanV2: Decodable, Equatable, Sendable {
    /// A built step's v2 intent fields.
    public struct IntentV2: Decodable, Equatable, Sendable {
        /// Create: the terms the launch binds by value, the durations included.
        public let terms: StellarLaunchTermsV2?
        /// A recipient change's own step: the backlog that crosses it.
        public let harvestBacklog: StellarHarvestBacklogV2?
    }

    public let plan: PlanView
    /// A recipient change: what crosses it after the plan's harvest step, nil when one round takes all the growth or
    /// when no pool fees move (holder sharing on, or before graduation).
    public let harvestBacklog: StellarHarvestBacklogV2?
    /// By step id, for the steps built so far.
    public let intents: [String: IntentV2]

    private enum CodingKeys: String, CodingKey { case steps, harvestBacklog }
    private struct Step: Decodable {
        let id: String
        let intent: IntentV2?
    }

    public init(from decoder: Decoder) throws {
        plan = try PlanView(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        harvestBacklog = try c.decodeIfPresent(StellarHarvestBacklogV2.self, forKey: .harvestBacklog)
        let steps = try c.decode([Step].self, forKey: .steps)
        intents = Dictionary(steps.compactMap { step in step.intent.map { (step.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The terms the plan's create step binds.
    public var terms: StellarLaunchTermsV2? { plan.steps.lazy.compactMap { self.intents[$0.id]?.terms }.first }
}

/// v2 tickers (owner decision, CT-08 review): 2–10 ASCII letters or digits, because Soroswap's pair reads each token's
/// symbol as UTF-8 and the contracts refuse any other. A launch's and a Moment's ticker are refused here, exactly as
/// the API refuses them, before anything is sent.
public enum StellarTickerV2 {
    /// The ticker as the contracts take it: `typed` without surrounding spaces, upper-cased; nil unless it is 2–10
    /// ASCII letters or digits.
    public static func normalized(_ typed: String) -> String? {
        let ticker = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...10).contains(ticker.utf8.count), ticker.utf8.allSatisfy(isAlphanumeric) else { return nil }
        return ticker.uppercased()
    }

    /// The API's refusal of a ticker (400 bad_symbol), word for word.
    public static var refusal: LiteAPIError {
        .server(status: 400, code: "bad_symbol", message: "Ticker: 2–10 letters (A–Z) or digits, without accents, spaces or symbols.")
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): return true
        default: return false
        }
    }
}

/// A window of time two ISO times bound (a takeover's, a pending policy's): before it, inside it (both ends included) or
/// after it, to the second, as the contracts compare ledger times.
struct LiteWindow {
    let start: Date
    let end: Date

    init?(from start: String, to end: String) {
        guard let s = Self.date(start), let e = Self.date(end) else { return nil }
        self.start = s
        self.end = e
    }

    func state(at now: Date, before: String, inside: String) -> String {
        let t = now.timeIntervalSince1970.rounded(.down)
        return t < start.timeIntervalSince1970 ? before : t <= end.timeIntervalSince1970 ? inside : "lapsed"
    }

    private static func date(_ text: String) -> Date? { ISO8601DateFormatter.lite.date(from: text) ?? ISO8601DateFormatter().date(from: text) }
}

extension LiteAPI {
    /// A v2 launch action (`POST /v1/launches/build`); the preview takes create's fields. Amounts are base units.
    public struct LaunchRequestV2: Encodable, Sendable {
        public enum Action: String, Encodable, Sendable {
            case create, buy, sell, refund, graduate
            case graduateFallback = "graduate_fallback"
            case markStuck = "mark_stuck"
            case rescue
            /// Pays the booked curve fees to the current recipient (anyone may).
            case claim
            case claimOwed = "claim_owed"
            /// The user's holder rewards, in both assets.
            case claimRewards = "claim_rewards"
            case recipientTransfer = "recipient_transfer"
            /// The current recipient's veto of a takeover.
            case recipientCancel = "recipient_cancel"
            case recipientExecute = "recipient_execute"
        }

        public let action: Action
        /// Every action but create and claim_owed: the launch token.
        public var token: String?
        /// Create: "XLM", "USDC" or the asset's contract.
        public var quote: String?
        /// Create: the venue id (the quote's default when nil).
        public var venue: Int?
        public var name: String?
        /// Create: refused here unless `StellarTickerV2` takes it.
        public var symbol: String?
        public var uri: String?
        public var creatorFeeBps: Int?
        /// Create: share fees with holders (on unless false).
        public var holderSharing: Bool?
        /// Create: who receives the creator fees (the creator when nil).
        public var recipient: String?
        /// Create: buyers who pay no snipe tax, besides the creator and the recipient (at most 32).
        public var exempt: [String]?
        /// Create: the first buy; buy, sell and refund: the amount.
        public var amount: String?
        public var minOut: String?
        /// claim_owed: the asset owed ("XLM", "USDC" or its contract); the launch's quote when nil.
        public var asset: String?
        /// recipient_transfer: the new recipient.
        public var to: String?

        public init(
            action: Action, token: String? = nil, quote: String? = nil, venue: Int? = nil, name: String? = nil, symbol: String? = nil,
            uri: String? = nil, creatorFeeBps: Int? = nil, holderSharing: Bool? = nil, recipient: String? = nil, exempt: [String]? = nil,
            amount: String? = nil, minOut: String? = nil, asset: String? = nil, to: String? = nil
        ) {
            self.action = action
            self.token = token
            self.quote = quote
            self.venue = venue
            self.name = name
            self.symbol = symbol
            self.uri = uri
            self.creatorFeeBps = creatorFeeBps
            self.holderSharing = holderSharing
            self.recipient = recipient
            self.exempt = exempt
            self.amount = amount
            self.minOut = minOut
            self.asset = asset
            self.to = to
        }
    }

    /// The launchpad's and the Moments contract's v2 terms, read live. Public, like `economics`.
    public func economicsV2() async throws -> StellarEconomicsV2 { try await request("GET", "economics", access: .publicPending) }

    /// What a launch with `r`'s create fields would bind now: the terms, the 10 XLM fee, Max for the first buy and any
    /// XLM shortfall. The ticker may still be empty, or not yet one the contracts take: it is left out then, and the
    /// API prices the longest ticker instead (create refuses it).
    public func launchPreviewV2(_ r: LaunchRequestV2) async throws -> StellarLaunchPreviewV2 {
        var r = r
        r.symbol = r.symbol.flatMap(StellarTickerV2.normalized)
        return try await request("POST", "launches/preview", body: r)
    }

    /// A v2 launch's page. A viewer read: `you` is the session's account, or the viewer's; nil without either.
    public func launchStateV2(_ token: String) async throws -> StellarLaunchStateV2 {
        try await request("GET", "launches/\(Self.segment(token))/state", access: .viewer(aboutAccount: false))
    }

    public func quoteTradeV2(token: String, side: StellarTradeQuoteV2.Side, amount: Int64) async throws -> StellarTradeQuoteV2 {
        try await request("POST", "launches/\(Self.segment(token))/quote", body: ["side": side.rawValue, "amount": String(amount)])
    }

    /// A v2 launch action's plan. Create's ticker is refused here as the API refuses it (`StellarTickerV2.refusal`),
    /// before anything is sent, and goes out upper-cased.
    public func buildLaunchV2(_ r: LaunchRequestV2) async throws -> StellarLaunchPlanV2 {
        var r = r
        if r.action == .create {
            guard let ticker = r.symbol.flatMap(StellarTickerV2.normalized) else { throw StellarTickerV2.refusal }
            r.symbol = ticker
        }
        return try await request("POST", "launches/build", body: r)
    }
}
