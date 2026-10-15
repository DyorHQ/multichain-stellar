import Foundation
import StellarKit

/// How Recent Activity, Portfolio and My Launchpad word a Stellar activity item (docs/DESIGN-stellar-parity.md §8.12.3):
/// a symbol, a title and a subtitle, past tense, as keys with their arguments for the app's tables (most of them
/// Monad's own keys) rather than the server's English. An asset whose code isn't known is named by its short contract,
/// never by an old server's stand-in (`LiteFormat.standIns`).
public struct StellarActivityPresentation: Equatable, Sendable {
    /// An SF Symbol.
    public let symbol: String
    public let title: Title
    public let subtitle: Subtitle?
    /// The network fee the user paid, in stroops; nil when DyorHQ paid it or it isn't known.
    public let feeStroops: Int64?
    /// DyorHQ paid this transaction's fee (a sponsored setup or starter swap): "Fee paid by DyorHQ".
    public let paidByDyorHQ: Bool

    public enum Title: Equatable, Sendable {
        /// "Launched $%@" (key)
        case launched(symbol: String)
        /// "Bought %@" (key)
        case bought(symbol: String)
        /// "Sold %@" (key)
        case sold(symbol: String)
        /// "Collected %@ creator fees" (key)
        case collectedCreatorFees(symbol: String)
        /// "%@ graduated" (key)
        case graduated(symbol: String)
        /// "Published %@" (key)
        case published(title: String)
        /// "Collected %@" (key)
        case collected(title: String)
        /// "Swapped"
        case swapped
        /// "Sent %@"
        case sent(code: String)
        /// "Supplied %@"
        case supplied(code: String)
        /// "Withdrew %@"
        case withdrew(code: String)
        /// "Bridged %@"
        case bridged(code: String)
        /// "Enabled %@"
        case enabled(code: String)
        /// "Set up your account"
        case setUpAccount
        /// "Restored data"
        case restoredData
        /// "Got %@ test XLM"; nil when the amount isn't known.
        case gotTestXLM(amount: StellarActivityAmount?)
        /// "Cash added" / "Cash out" with an anchor.
        case cash(deposit: Bool)
        /// A kind this build has no words for: the server's own title, as it is.
        case other(String)
    }

    public enum Subtitle: Equatable, Sendable {
        /// A coin's name.
        case name(String)
        /// "%@ %@ for %@ %@" (key): what a curve trade brought, for what it cost.
        case trade(StellarActivityAmount, for: StellarActivityAmount)
        case amount(StellarActivityAmount)
        /// The venue a coin graduated to ("Soroswap").
        case venue(String)
        /// "%@ per edition"
        case perEdition(StellarActivityAmount)
        /// "%lld editions · %@" (key)
        case editions(Int, total: StellarActivityAmount?)
        /// "%@ → %@": what a swap spent and brought.
        case swap(StellarActivityAmount, to: StellarActivityAmount)
        /// A send's recipient (the whole address: the app shortens it) and amount.
        case to(address: String, amount: StellarActivityAmount?)
        /// "Blend · %@": the Earn pool.
        case pool(String)
        /// Networks: "Monad → Stellar".
        case route(from: String, to: String)
    }
}

/// An amount with its asset's code, in base units: the app formats it with its own number style.
public struct StellarActivityAmount: Equatable, Sendable {
    public let units: Int64
    public let decimals: Int
    public let code: String

    public init(units: Int64, decimals: Int = 7, code: String) {
        self.units = units
        self.decimals = decimals
        self.code = code
    }
}

public enum StellarActivityPresenter {
    public static func present(_ item: StellarActivityItem) -> StellarActivityPresentation {
        let words = wording(item)
        let fee = item.feeCharged.flatMap { Int64($0) }
        let sponsored = item.feePayer == "sponsor"
        return StellarActivityPresentation(symbol: words.symbol, title: words.title, subtitle: words.subtitle,
                                           feeStroops: sponsored ? nil : fee, paidByDyorHQ: sponsored)
    }

    private static func wording(_ item: StellarActivityItem) -> (symbol: String, title: StellarActivityPresentation.Title, subtitle: StellarActivityPresentation.Subtitle?) {
        let d = item.display ?? [:]
        switch item.type {
        case "bridge":
            let fromMonad = item.kind == "monad_to_stellar"
            return ("point.3.connected.trianglepath.dotted", .bridged(code: "USDC"),
                    fromMonad ? .route(from: "Monad", to: "Stellar") : .route(from: "Stellar", to: "Monad"))
        case "cash":
            let asset = text(d["asset"]).map { $0 == "native" ? "XLM" : $0 }
            let amount = written(item.amount.map(StellarJSON.string)).flatMap { units in asset.map { StellarActivityAmount(units: units, code: $0) } }
            return ("banknote", .cash(deposit: item.kind == "deposit"), amount.map { .amount($0) })
        default:
            break
        }
        let symbol = coin(item, d)
        switch item.kind {
        case "launch_create":
            return ("flame.fill", .launched(symbol: symbol), (clean(text(d["name"])) ?? clean(item.name)).map { .name($0) })
        case "launch_buy":
            let paid = amount(d["amount"], code: quote(item, d))
            let got = units(item.result?.amountOut.map(StellarJSON.string)).map { StellarActivityAmount(units: $0, code: symbol) }
            return ("arrow.down", .bought(symbol: symbol), trade(got, for: paid))
        case "launch_sell":
            let sold = amount(d["amount"], code: symbol)
            let got = units(item.result?.amountOut.map(StellarJSON.string)).map { StellarActivityAmount(units: $0, code: quote(item, d)) }
            return ("arrow.up", .sold(symbol: symbol), trade(sold, for: got))
        case "launch_claim":
            return ("dollarsign.circle.fill", .collectedCreatorFees(symbol: symbol), amount(d["amount"], code: quote(item, d)).map { .amount($0) })
        case "launch_graduate":
            return ("checkmark.seal.fill", .graduated(symbol: symbol), .venue("Soroswap"))
        case "moment_publish":
            let price = amount(d["price"], code: quote(item, d))
            return ("camera.aperture", .published(title: momentTitle(item, d)), price.map { .perEdition($0) })
        case "moment_collect":
            let quantity = count(d["quantity"]) ?? 1
            return ("camera.aperture", .collected(title: momentTitle(item, d)), .editions(quantity, total: amount(d["total"], code: quote(item, d))))
        case "swap":
            let sell = asset(d["sell"], item: item)
            let buy = asset(d["buy"], item: item)
            let spent = amount(d["amountIn"], code: sell)
            let got = units(item.result?.amountOut.map(StellarJSON.string)).map { StellarActivityAmount(units: $0, code: buy) }
                ?? amount(d["minOut"], code: buy)
            let subtitle: StellarActivityPresentation.Subtitle? = spent.flatMap { s in got.map { .swap(s, to: $0) } }
            return ("arrow.left.arrow.right", .swapped, subtitle)
        case "payment":
            let code = asset(d["asset"], item: item)
            let sent = written(d["amount"]).map { StellarActivityAmount(units: $0, code: code) }
            return ("arrow.up", .sent(code: code), text(d["to"]).map { .to(address: $0, amount: sent) } ?? sent.map { .amount($0) })
        case "earn_deposit", "earn_withdraw":
            let code = asset(d["asset"], item: item)
            let pool = text(d["pool"]).map(StellarActivityPresentation.Subtitle.pool)
            return ("leaf", item.kind == "earn_deposit" ? .supplied(code: code) : .withdrew(code: code), pool ?? amount(d["amount"], code: code).map { .amount($0) })
        case "bridge_out", "approve":
            return ("point.3.connected.trianglepath.dotted", .bridged(code: "USDC"), .route(from: "Stellar", to: "Monad"))
        case "trust":
            return ("checkmark.circle", .enabled(code: asset(d["asset"], item: item)), nil)
        case "activate":
            return ("checkmark.circle", .setUpAccount, nil)
        case "restore":
            return ("checkmark.circle", .restoredData, nil)
        case "faucet":
            let amount = (written(d["amount"]) ?? written(item.amount.map(StellarJSON.string))).map { StellarActivityAmount(units: $0, code: "XLM") }
            return ("checkmark.circle", .gotTestXLM(amount: amount), nil)
        default:
            return ("circle", .other(clean(item.title) ?? item.summary), clean(item.subtitle).map { .name($0) })
        }
    }

    // MARK: Names, never a stand-in

    /// The coin a launch item is about: its symbol from the item, else the server's resolved one, else its short
    /// contract.
    private static func coin(_ item: StellarActivityItem, _ d: [String: StellarJSON]) -> String {
        clean(text(d["symbol"])) ?? clean(item.symbol) ?? (item.ref?.token ?? text(d["token"])).map(LiteFormat.short) ?? ""
    }

    /// An asset field of the display ("XLM", "USDC", a coin's symbol, or an id), as a code.
    private static func asset(_ value: StellarJSON?, item: StellarActivityItem) -> String {
        guard let raw = clean(text(value)) else { return clean(item.symbol) ?? item.ref?.token.map(LiteFormat.short) ?? "" }
        if raw == "native" { return "XLM" }
        return StrKey.isValid(.contract, raw) ? clean(item.symbol) ?? LiteFormat.short(raw) : raw
    }

    private static func quote(_ item: StellarActivityItem, _ d: [String: StellarJSON]) -> String {
        asset(d["quote"] ?? d["quoteCode"], item: item)
    }

    private static func momentTitle(_ item: StellarActivityItem, _ d: [String: StellarJSON]) -> String {
        clean(text(d["title"])) ?? clean(item.name) ?? (count(d["momentId"]) ?? item.ref?.momentId).map { "#\($0)" } ?? ""
    }

    /// A name worth showing (`LiteFormat.name`).
    private static func clean(_ text: String?) -> String? { LiteFormat.name(text) }

    // MARK: Reading display fields

    private static func trade(_ got: StellarActivityAmount?, for paid: StellarActivityAmount?) -> StellarActivityPresentation.Subtitle? {
        guard let got, let paid else { return (got ?? paid).map { .amount($0) } }
        return .trade(got, for: paid)
    }

    private static func amount(_ value: StellarJSON?, code: String) -> StellarActivityAmount? {
        units(value).map { StellarActivityAmount(units: $0, code: code) }
    }

    private static func text(_ value: StellarJSON?) -> String? {
        switch value {
        case .string(let text)?: text.isEmpty ? nil : text
        case .number?: value?.text
        default: nil
        }
    }

    /// An amount in base units.
    private static func units(_ value: StellarJSON?) -> Int64? {
        switch value {
        case .string(let text)?: Int64(text).flatMap { $0 >= 0 ? $0 : nil }
        case .number(let number)? where number.isFinite && number >= 0 && number < 9e18: Int64(number)
        default: nil
        }
    }

    /// An amount the server or an anchor wrote out ("10.5"), in base units.
    private static func written(_ value: StellarJSON?) -> Int64? {
        text(value).flatMap { StellarAmount.parse($0) }
    }

    private static func count(_ value: StellarJSON?) -> Int? {
        switch value {
        case .number(let number)? where number >= 0 && number < 1_000_000_000 && number == number.rounded(): Int(number)
        case .string(let text)?: Int(text)
        default: nil
        }
    }
}
