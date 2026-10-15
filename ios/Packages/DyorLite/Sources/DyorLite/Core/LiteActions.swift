import Foundation
import StellarKit

/// A plan plus the limits the user is confirming, ready for the review sheet: verified and priced on the phone.
public struct PreparedAction: Identifiable, Equatable {
    public let plan: PlanView
    /// The most the user confirms spending, per asset contract id (base units). An asset not listed may not be spent.
    public let limits: [String: Int64]
    public let title: String
    /// The phone's titles for the steps the server hasn't built yet, by step id: they come with an English label only.
    public let titles: [String: String]
    public let section: LiteSection
    /// Where the settled action's notification leads ("stellar:<tab>[/<id>]", §3.7); nil when only its result can say
    /// (a new Moment's or coin's id), which the settled action then carries.
    public let reference: String?
    /// The plan's network fees, worked out on the phone from each step's own transaction (§4.4): what the review shows,
    /// and what the run holds every step to.
    public let fees: PlanFees
    /// Whether DyorHQ pays a step, as the phone checked it (§4.3): only then may the review say that DyorHQ pays.
    public let sponsorVerified: Bool
    /// What the action does, for its notification once it settles.
    let summary: LiteActionSummary
    public var id: String { plan.planId }

    init(plan: PlanView, limits: [String: Int64], title: String, titles: [String: String], section: LiteSection, reference: String?,
         fees: PlanFees, summary: LiteActionSummary) {
        self.plan = plan
        self.limits = limits
        self.title = title
        self.titles = titles
        self.section = section
        self.reference = reference
        self.fees = fees
        sponsorVerified = fees.sponsorVerified
        self.summary = summary
    }

    /// A step's title, the same one Activity gives the transaction once it is sent: from its intent; for a step the
    /// server hasn't built yet, the phone's own; the server's label only when neither knows what it is.
    public func title(of step: PlanStep) -> String {
        step.intent.flatMap { LiteTitles.intent(kind: $0.kind, display: $0.display) } ?? titles[step.id] ?? step.label
    }
}

/// Where an action belongs (§6.11's sections): Portfolio's sections, and what kind of notification it posts.
public enum LiteSection: String, CaseIterable, Sendable {
    case spot, earn, launch, moments, bridge, cash, account
}

/// A plan the store saw through to the end (`LiteSession.onSettled`): once per plan, whether or not a sheet still shows
/// it.
public struct LiteSettledAction: Equatable, Sendable {
    public let planId: String
    /// What the action was: its main step's kind ("swap", "payment", "earn_deposit", "launch_buy", "moment_collect",
    /// "trust", …).
    public let kind: String
    /// The notification's title and body, in the current language (§8.15); the body has no network suffix.
    public let title: String
    public let body: String
    public let section: LiteSection
    /// "stellar:<tab>[/<id>]" (§3.7).
    public let reference: String?
    /// Every step's transaction hash, in order.
    public let hashes: [String]
    public let at: Date
}

/// A part of the account's figures a screen shows on its own (§7.2): the four holdings parts, and DyorHQ's history.
public enum LitePart: String, CaseIterable, Hashable, Sendable {
    case spot, earn, launch, moments, activity, portfolio, myLaunchpad, myMoments
}

/// How a part's last read went.
public enum LiteReadStatus: Equatable, Sendable {
    /// Not read yet.
    case unread
    /// Read: its figures are the last answer's.
    case read
    /// The last read failed (`LiteStore.lastError` says why); what was read before stays.
    case failed
    /// DyorHQ's history with no session: a passkey account reading in the public view. The screen offers "Sign in with
    /// your passkey" (`LiteSession.signIn()`); nothing asks until it is tapped.
    case needsSignIn
}

/// A new coin, as Create fills it in (`LiteStore.launchCreatePlan`).
public struct StellarLaunchForm: Equatable, Sendable {
    public var name: String
    /// A–Z and 0–9, 2 to 10 characters.
    public var symbol: String
    public var description: String?
    /// https links only (the server refuses the rest).
    public var website: String?
    public var x: String?
    public var telegram: String?
    /// The quote asset's id ("XLM", "USDC").
    public var quote: String
    public var creatorFeeBps: Int
    /// The developer buy in the same transaction, in base units of the quote; 0 for none.
    public var developerBuy: Int64
    /// The fewest coins the developer buy may bring (1% under its quote); 0 with no developer buy.
    public var minOut: Int64

    public init(name: String, symbol: String, description: String? = nil, website: String? = nil, x: String? = nil, telegram: String? = nil,
                quote: String, creatorFeeBps: Int, developerBuy: Int64 = 0, minOut: Int64 = 0) {
        self.name = name
        self.symbol = symbol
        self.description = description
        self.website = website
        self.x = x
        self.telegram = telegram
        self.quote = quote
        self.creatorFeeBps = creatorFeeBps
        self.developerBuy = developerBuy
        self.minOut = minOut
    }
}

/// A new Moment, as Publish fills it in (`LiteStore.publishPlan`).
public struct StellarMomentForm: Equatable, Sendable {
    public var title: String
    public var description: String?
    public var place: String?
    /// The day it was taken, "2026-10-14".
    public var takenOn: String?
    /// Per edition, in base units of the quote.
    public var price: Int64
    /// The quote asset's id ("XLM", "USDC").
    public var quote: String
    /// 0 for an open edition.
    public var maxEditions: Int
    public var windowSecs: Int

    public init(title: String, description: String? = nil, place: String? = nil, takenOn: String? = nil, price: Int64, quote: String,
                maxEditions: Int, windowSecs: Int) {
        self.title = title
        self.description = description
        self.place = place
        self.takenOn = takenOn
        self.price = price
        self.quote = quote
        self.maxEditions = maxEditions
        self.windowSecs = windowSecs
    }
}

/// A Moment's photo, or its video with the cover frame that becomes the NFT's image (§6.9: a video needs a poster).
public struct StellarMedia: Equatable, Sendable {
    public let data: Data
    /// "image/jpeg", "video/mp4", "video/quicktime", …: the real type, as the upload sends it.
    public let contentType: String
    /// The video's cover frame, a JPEG; nil for a photo.
    public let poster: Data?

    public var isVideo: Bool { contentType.hasPrefix("video/") }

    public static func photo(_ jpeg: Data) -> StellarMedia {
        StellarMedia(data: jpeg, contentType: "image/jpeg", poster: nil)
    }

    public static func video(_ data: Data, contentType: String = "video/mp4", poster jpeg: Data) -> StellarMedia {
        StellarMedia(data: data, contentType: contentType, poster: jpeg)
    }
}

/// A curve trade's price (`LiteStore.launchQuote`): what it brings, at least what it must bring (fixed 1% slippage,
/// R11), and its fees apart.
public struct StellarLaunchQuote: Equatable, Sendable {
    public let buy: Bool
    /// What the user pays (a buy, in the quote asset) or sells (coins), in base units.
    public let amount: Int64
    /// The coins a buy brings, or the quote asset a sale brings, in base units.
    public let out: Int64
    /// `out` less 1%: the trade's minimum.
    public let minOut: Int64
    /// The server's answer, with the fees apart (`baseFee`, `creatorFee`, `snipeFee`, `used`, `refund`).
    public let quote: TradeQuote

    init(buy: Bool, amount: Int64, quote: TradeQuote) {
        self.buy = buy
        self.amount = amount
        self.quote = quote
        out = Int64((buy ? quote.tokensOut : quote.quoteOut) ?? "0") ?? 0
        minOut = StellarLaunchMath.minOut(out)
    }
}

/// A cash transfer started with an anchor (`LiteStore.startCash`): its page to open, and what follows it. The anchor's
/// session token stays inside: it is the anchor's sign-in, not a key, and no view reads it.
public struct LiteCashFlow: Identifiable, Sendable {
    /// The anchor's id for the transfer.
    public let id: String
    /// The anchor's own page (SEP-24), https.
    public let url: URL
    /// The anchor's domain and name.
    public let anchor: String
    public let name: String
    public let deposit: Bool
    /// "XLM" or "USDC".
    public let asset: String
    let client: AnchorClient
    let toml: AnchorClient.Toml
    let token: String
}

/// What an action does, for its notification once it settles (`LiteTitles.settled`).
enum LiteActionSummary: Equatable, Sendable {
    case swap(amountIn: Int64, sell: String, buy: String, quotedOut: Int64)
    case earn(deposit: Bool, amount: Int64, code: String)
    case send(amount: Int64, code: String, to: String)
    case enable(code: String)
    case launchCreate(symbol: String, name: String)
    case launchTrade(buy: Bool, symbol: String, amount: Int64, quoteCode: String)
    case launchGraduate(symbol: String)
    case launchClaim(symbol: String)
    case publish(title: String)
    case collect(title: String, quantity: Int, total: Int64, quoteCode: String)
    case bridgeOut(amount: Int64)
    case cashOut(amount: Int64, code: String, anchor: String)

    /// The main step's kind, as the server names it.
    var kind: String {
        switch self {
        case .swap: "swap"
        case .earn(let deposit, _, _): deposit ? "earn_deposit" : "earn_withdraw"
        case .send, .cashOut: "payment"
        case .enable: "trust"
        case .launchCreate: "launch_create"
        case .launchTrade(let buy, _, _, _): buy ? "launch_buy" : "launch_sell"
        case .launchGraduate: "launch_graduate"
        case .launchClaim: "launch_claim"
        case .publish: "moment_publish"
        case .collect: "moment_collect"
        case .bridgeOut: "bridge_out"
        }
    }
}
