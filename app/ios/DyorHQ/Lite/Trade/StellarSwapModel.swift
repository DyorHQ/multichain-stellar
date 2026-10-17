// Stellar copy of ios/DyorHQ/Swap/SwapView.swift SwapModel (42cd8c7 sha256:29ea9d24e0c7)
// Stellar copy of ios/DyorHQ/Swap/SwapView.swift SwapReview (42cd8c7 sha256:d62f3f8e7fbd)
// What Stellar's Swap shows and does (docs/DESIGN-stellar-parity.md §8.6.1, §8.6.2, §4.5). Internal builds only
// (STELLAR_LITE).
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import Foundation
import StellarKit

/// What Swap reads from the account's store and asks of it: the account's figures, Max, the quote, the plan for the venue
/// picked, and Swap History (a read of its own, never the shared `LiteStore.activity`). `LiteStore` in the app; a
/// stand-in in tests.
@MainActor
protocol StellarSwapSource: AnyObject {
    /// The account's Stellar address (G…).
    var address: String { get }
    var config: LiteConfig? { get }
    var account: AccountView? { get }
    var holdings: StellarHoldings? { get }
    var fees: StellarFees? { get }
    func maxAmount(asset: String, stepKind: String, newReserves: Int) -> Int64
    func swapQuote(sell: String, buy: String, amount: Int64, slippageBps: Int) async throws -> SwapQuote
    func swapPlan(_ quote: SwapQuote, venue: String?) async throws -> PreparedAction
    func readActivity(section: String?, kind: String?, period: VolumePeriodKey?) async -> (items: [StellarActivityItem], status: LiteReadStatus)
}

extension LiteStore: StellarSwapSource {}

/// A side of the swap: what the API calls it (a registry id such as "XLM", a coin's contract, or CODE:ISSUER) and how its
/// row shows it, from the best of what the phone has read about it (Top Tokens, the holdings, the account, the registry).
struct StellarSwapToken: Equatable {
    let id: String
    /// The asset's code or the coin's symbol: never translated.
    let code: String
    let name: String?
    let decimals: Int
    /// "native" or "CODE:ISSUER" for a classic asset: what picks a bundled logo (`StellarTokenLogo`), and what says the
    /// asset is held through a trustline. Nil for a token that lives only on Soroban (a DyorHQ coin).
    let classic: String?
    let contract: String?
    /// A DyorHQ coin's uploaded art.
    let image: String?
    /// The server's words about the asset (`StellarTokenBadge.kind`).
    let badges: [String]
    let verified: Bool
    /// A DyorHQ coin's phase ("curve", "completed", "graduated"); nil for any other asset, and while unknown.
    let phase: String?
    /// The reference USD price; nil while unknown.
    let priceUsd: Double?
}

/// One venue's answer for what is on screen: its output, and the least it may bring, which is exactly what the review
/// binds (`LiteStore.swapPlan`): the route's own minimum, never below the quoted amount less the quote's slippage.
struct StellarSwapRoute: Equatable, Identifiable {
    /// "sdex", "soroswap" or "aquarius".
    let venue: String
    let amountOut: Int64
    let minimum: Int64
    let priceImpactBps: Int?
    /// The assets it goes through: classic assets ("native", "CODE:ISSUER") on the Stellar DEX, contracts on Soroban.
    let path: [String]
    let best: Bool
    var id: String { venue }

    /// A venue's name: proper names, never translated.
    static func name(_ venue: String) -> String {
        switch venue.lowercased() {
        case "sdex": "Stellar DEX" // not localized: the network's exchange, by name
        case "soroswap": "Soroswap"
        case "aquarius": "Aquarius"
        default: venue.prefix(1).uppercased() + venue.dropFirst()
        }
    }
}

/// The venue selected, and whether the person picked it, as Monad's `VenueSelection`: until a venue row is tapped it
/// follows the best route; a pick is kept through each refresh that still quotes it, and given back to the best only by
/// an answer that doesn't.
struct StellarVenueSelection: Equatable {
    var venue: String?
    var picked = false

    func following(_ routes: [StellarSwapRoute]) -> StellarVenueSelection {
        if picked, let venue, routes.contains(where: { $0.venue == venue }) { return self }
        return StellarVenueSelection(venue: (routes.first(where: \.best) ?? routes.first)?.venue)
    }
}

/// What the review sheet shows and builds, frozen when Review is tapped: the quote, the venue picked and its route, and
/// the request it answers (the amount typed, the two sides and the slippage, which the quote was checked to echo).
/// Quotes refresh every 15 s and a Max can land late, but the sheet builds its plan once, so everything it shows and
/// binds comes from here, never from the live form.
struct StellarSwapReview: Identifiable {
    let id = UUID()
    let quote: SwapQuote
    let route: StellarSwapRoute
    let sell: StellarSwapToken
    let buy: StellarSwapToken
    let amountIn: Int64
    let slippageBps: Int
}

/// Stellar's spot swaps, as Monad's `SwapModel`: every venue quotes at once, the best preselected; the person can pick
/// another, and the review builds the one picked. A quote is asked for what is on screen (400 ms after the last edit),
/// then again every 15 seconds, or when it expires if that is sooner. The whole state reads the account's store
/// (`StellarSwapSource`) and Top Tokens, so it shows the figures the rest of the section shows.
@Observable
@MainActor
final class StellarSwapModel {
    enum Side: Identifiable { case pay, receive; var id: Self { self } }

    /// Slippage until the person picks another, in basis points (§8.6.1).
    static let defaultSlippageBps = 100
    /// The slippage a Stellar swap takes, in basis points: 0.01% to 10%. The quote refuses any other (/v1/swap/quote),
    /// so the slippage sheet caps a custom value to it and a value saved outside it is never used.
    static let slippageRange = 1...1_000
    /// How often a quote is asked for again while it is on screen.
    static let refreshInterval: Duration = .seconds(15)
    /// The venues Swap offers: the Stellar DEX and Soroswap. Aquarius is off for now (decision O7: Soroswap only, so
    /// Aquarius isn't tested), so no Aquarius route, or its price impact, shows whatever a server quotes.
    static let venues: Set<String> = ["sdex", "soroswap"]
    /// The step kinds a swap is priced at, by venue. Max keeps back the costliest: the quote may route through any of
    /// them, and the venue picked can change once Max has filled the field.
    static let swapStepKinds = ["swap_sdex", "swap_soroswap"]

    var sell = "XLM"
    var buy = "USDC"
    var amountText = ""
    var slippageBps = StellarSwapModel.defaultSlippageBps
    /// Top Tokens (`LitePublicReads.markets`): the sides' names, logos, prices and a coin's phase.
    var markets: [StellarMarketRow] = []

    /// The account's store; set by the view (`attach`).
    @ObservationIgnored private(set) weak var source: (any StellarSwapSource)?
    /// A token's row by its id (`LitePublicReads.market`), for a side Top Tokens doesn't list.
    @ObservationIgnored private var lookUp: ((String) async throws -> StellarMarketRow)?
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    /// The contracts this build signs calls to (`LiteGate.pinned`): the tokens a route may go through.
    @ObservationIgnored private let listed: Set<String>
    /// The network the build signs for, which names a classic asset's contract (`assetContract`).
    @ObservationIgnored private let network: StellarNetwork
    /// The account the quotes are asked for: part of `quoteKey`, so no quote made for another account stays reviewable.
    private(set) var account: String?
    /// Rows looked up for sides Top Tokens doesn't list.
    private(set) var found: [String: StellarMarketRow] = [:]
    private(set) var selection = StellarVenueSelection()
    private(set) var result: SwapQuote?
    /// The `quoteKey` that `result` and `error` answer: until a re-quote for an edit lands, the old answer stays out of
    /// sight and can't be reviewed.
    private(set) var resultKey: String?
    private(set) var quoting = false
    private(set) var error: String?
    /// The starter swap (§8.6.2) asked to fill the whole balance: done once the balance is read.
    private(set) var fillsMaxWhenRead = false
    /// Swap History for the range last read, newest first.
    private(set) var history: [StellarSwapHistoryItem] = []
    /// The range `history` answers.
    private(set) var historyRange: SwapHistoryService.Window?
    private(set) var historyStatus: LiteReadStatus = .unread
    private(set) var loadingHistory = false

    init(defaults: UserDefaults = .standard, pinned: PinnedContracts = LiteGate.pinned) {
        self.defaults = defaults
        listed = pinned.allContracts
        network = pinned.network
    }

    /// Reads and acts through `source` from now on: a new account starts afresh, with its own slippage.
    func attach(_ source: any StellarSwapSource, lookUp: ((String) async throws -> StellarMarketRow)? = nil) {
        self.lookUp = lookUp
        guard self.source !== source else { return }
        self.source = source
        account = source.address
        slippageBps = Self.storedSlippage(for: source.address, defaults: defaults)
        result = nil
        resultKey = nil
        error = nil
        selection = StellarVenueSelection()
        history = []
        historyRange = nil
        historyStatus = .unread
    }

    // MARK: Slippage

    /// Where the account's slippage is kept: per address, as every Stellar default, under "lite." (§3.10 rule 9).
    static func slippageKey(_ address: String) -> String { "lite.slippage.\(address)" }

    /// The slippage kept for `address`; the default when none is, or when the one kept is outside what a swap takes (an
    /// earlier build saved any custom value, and the quote refuses those).
    static func storedSlippage(for address: String, defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: slippageKey(address))
        return slippageRange.contains(stored) ? stored : defaultSlippageBps
    }

    /// Keeps the slippage picked for the account.
    func saveSlippage() {
        guard let account else { return }
        defaults.set(slippageBps, forKey: Self.slippageKey(account))
    }

    // MARK: The sides

    var tokenIn: StellarSwapToken { token(sell) }
    var tokenOut: StellarSwapToken { token(buy) }

    /// `id`'s row: Top Tokens' (or one looked up), else the holdings', the account's or the registry's; its short id and
    /// no badge of trust while nothing is known about it.
    func token(_ id: String) -> StellarSwapToken {
        let config = source?.config
        let registry = config?.asset(id)
        let contract = registry?.contract ?? (StrKey.isValid(.contract, id) ? id : nil)
        func matches(_ rowID: String, _ rowContract: String, _ rowClassic: String?) -> Bool {
            rowID == id || rowContract == id || rowClassic == id || (contract != nil && rowContract == contract)
        }
        if let row = markets.first(where: { matches($0.id, $0.contract, $0.classic) }) ?? found[id] {
            return StellarSwapToken(id: id, code: row.code, name: row.name, decimals: row.decimals, classic: row.classic, contract: row.contract,
                                    image: row.image, badges: row.badges, verified: row.verified, phase: row.launch?.phase, priceUsd: row.priceUsd)
        }
        if let spot = source?.holdings?.spot.first(where: { matches($0.id, $0.contract, $0.classic) }) {
            return StellarSwapToken(id: id, code: spot.code, name: spot.name, decimals: spot.decimals, classic: spot.classic, contract: spot.contract,
                                    image: nil, badges: spot.badges, verified: spot.verified, phase: nil, priceUsd: spot.priceUsd)
        }
        if let coin = source?.holdings?.launch.first(where: { matches($0.token, $0.token, nil) }) {
            return StellarSwapToken(id: id, code: coin.symbol, name: coin.name, decimals: StellarFormat.decimals, classic: nil, contract: coin.token,
                                    image: coin.image, badges: ["launch"], verified: true, phase: coin.phase, priceUsd: coin.priceUsd)
        }
        if let row = source?.account?.balances.first(where: { matches($0.asset, $0.contract, $0.classic) }) {
            return StellarSwapToken(id: id, code: row.code, name: row.name, decimals: row.decimals, classic: row.classic, contract: row.contract,
                                    image: nil, badges: row.kind == "launch" ? ["launch"] : [], verified: row.verified ?? (row.kind != "classic"),
                                    phase: nil, priceUsd: nil)
        }
        if let registry {
            return StellarSwapToken(id: id, code: registry.code, name: registry.name, decimals: registry.decimals, classic: registry.classic,
                                    contract: registry.contract, image: nil, badges: registry.listed == false ? ["testAsset"] : [], verified: true,
                                    phase: nil, priceUsd: nil)
        }
        return StellarSwapToken(id: id, code: Self.shortCode(id), name: nil, decimals: StellarFormat.decimals, classic: nil, contract: contract,
                                image: nil, badges: [], verified: false, phase: nil, priceUsd: nil)
    }

    /// What an asset nothing else names is called: XLM for "native", the code of a CODE:ISSUER, else its short id.
    static func shortCode(_ id: String) -> String {
        if id == "native" { return "XLM" }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, (1...12).contains(parts[0].count) { return String(parts[0]) }
        return StellarAccountID(id)?.short ?? id
    }

    /// A side a coin's row says is still on its launchpad (on its curve, or full and waiting to graduate): no venue routes
    /// it, so Swap says where it trades instead of asking for a quote.
    var curveToken: StellarSwapToken? {
        [tokenOut, tokenIn].first { coin in coin.phase.map { $0 != "graduated" } ?? false }
    }

    /// Looks up each side that nothing read so far names (a coin or an asset pasted into the search), once: its code,
    /// logo and price, and for a coin whether it still trades on its launchpad.
    func learnSides() async {
        guard let lookUp else { return }
        for id in [sell, buy] where !asked.contains(id) && isUnknown(id) {
            asked.insert(id)
            if let row = try? await lookUp(id) { found[id] = row }
        }
    }

    /// Reads again the rows looked up for the sides (`found`), as Top Tokens is read again: a coin's price follows its
    /// pool, and a coin that graduates while Swap is on screen is quoted from then on.
    func refreshFound() async {
        guard let lookUp else { return }
        for id in Set([sell, buy]) where found[id] != nil {
            if let row = try? await lookUp(id) { found[id] = row }
        }
    }

    private func isUnknown(_ id: String) -> Bool {
        let known = token(id)
        return known.name == nil && known.code == Self.shortCode(id) && (StrKey.isValid(.contract, id) || id.contains(":"))
    }

    func isXLM(_ id: String) -> Bool {
        id == "XLM" || id == "native" || source?.config?.asset("XLM")?.contract == id
    }

    // MARK: Balances, Max and the amount

    /// The account's balance of `id`, in base units; nil until the account or its holdings are read.
    func balance(_ id: String) -> Int64? {
        guard let source, source.account != nil || source.holdings != nil else { return nil }
        let contract = source.config?.asset(id)?.contract
        func matches(_ rowID: String, _ rowContract: String, _ rowClassic: String?) -> Bool {
            rowID == id || rowContract == id || rowClassic == id || (contract != nil && rowContract == contract)
        }
        if let row = source.account?.balances.first(where: { matches($0.asset, $0.contract, $0.classic) }) { return row.units }
        if let spot = source.holdings?.spot.first(where: { matches($0.id, $0.contract, $0.classic) }) { return spot.units }
        if let coin = source.holdings?.launch.first(where: { matches($0.token, $0.token, nil) }) { return Int64(coin.balance) ?? 0 }
        return 0
    }

    /// The account's XLM and what it must keep (§4.5), from its own figures.
    var xlmReserve: XLMReserve? {
        (source?.account?.xlm ?? source?.holdings?.xlm).flatMap { XLMReserve($0) }
    }

    /// The XLM Stellar keeps in the account (its minimum balance and what its offers hold): the part of the balance that
    /// can't be swapped.
    var lockedXLM: Int64? {
        xlmReserve.map { max(0, $0.balance - $0.spendable) }
    }

    /// The bought asset must be enabled (a trustline) first, in the same review: as the quote says, or, before one, a
    /// classic asset the account hasn't enabled.
    var needsEnable: Bool {
        if let quote = currentResult { return !(quote.needsEnable ?? []).isEmpty }
        guard !isXLM(buy), let account = source?.account else { return false }
        let out = tokenOut
        guard let classic = out.classic, classic != "native" else { return false }
        return !account.balances.contains { ($0.asset == buy || $0.contract == out.contract || $0.classic == classic) && $0.enabled }
    }

    /// The ledger's base reserve, in stroops: what enabling an asset holds back.
    var baseReserve: Int64? {
        (source?.fees?.baseReserve ?? source?.account?.xlm?.baseReserve).flatMap { Int64($0) }
    }

    /// Max (§4.5). XLM: what the account can swap and still pay the swap's network fee (the costliest venue's estimate,
    /// kept with a quarter more), a trustline's fee when the bought asset needs one, and the reserves the swap adds,
    /// from its own figures (`LiteStore.maxAmount`). Any other asset: the whole balance; its XLM fee is checked at review.
    /// Nil until the figures are read.
    var maxIn: Int64? {
        guard let source else { return nil }
        guard isXLM(sell) else { return balance(sell) }
        guard xlmReserve != nil else { return nil }
        let reserves = needsEnable ? 1 : 0
        let swap = Self.swapStepKinds.map { source.maxAmount(asset: sell, stepKind: $0, newReserves: reserves) }.min() ?? 0
        guard reserves > 0 else { return swap }
        let trust = source.fees?.estimate("trust") ?? StellarFeeDefaults.estimate("trust") ?? 0
        return max(0, swap - trust * 5 / 4)
    }

    var amountIn: Int64 { Amount.parse(amountText, decimals: tokenIn.decimals).flatMap { Int64(exactly: $0) } ?? 0 }

    /// The amount is more than can be swapped: more than the balance, or for XLM more than Max (it must pay its fee and
    /// keep the minimum balance). A balance that couldn't be read doesn't count.
    var insufficient: Bool {
        guard amountIn > 0 else { return false }
        let limit = isXLM(sell) ? maxIn : balance(sell)
        return limit.map { amountIn > $0 } ?? false
    }

    var actionTitle: String {
        if amountIn == 0 { return tr("Enter an Amount") }
        if insufficient { return tr("Insufficient \(tokenIn.code)") }
        return tr("Review Swap")
    }

    /// Sets the pay amount to `pct`% of what can be swapped: of the spendable XLM for XLM, of the balance for any other
    /// asset, rounded down to six significant digits (`Amount.roundedDown`). 100% is Max.
    func applyPercent(_ pct: Int) {
        guard pct < 100 else { applyMax(); return }
        let base = isXLM(sell) ? xlmReserve?.spendable : balance(sell)
        guard let base, base > 0 else { return }
        let share = Amount.roundedDown(BigUInt(base) * BigUInt(pct) / 100, decimals: tokenIn.decimals)
        amountText = StellarFormat.plain(units: Int64(share), decimals: tokenIn.decimals)
    }

    /// Max (`maxIn`). XLM's is rounded down to six significant digits: a sliver more stays back with the fee, and the
    /// field reads "9998.43", not seven decimals. Any other asset's stays exact, so all of it can be swapped.
    func applyMax() {
        guard let max = maxIn else { return }
        let amount = isXLM(sell) ? Int64(Amount.roundedDown(BigUInt(max), decimals: tokenIn.decimals)) : max
        amountText = StellarFormat.plain(units: amount, decimals: tokenIn.decimals)
    }

    /// The starter swap's whole balance (§8.6.2), once the balance is read: the add-funds card offers to swap all of it.
    func fillMaxIfRead() {
        guard fillsMaxWhenRead, let max = maxIn else { return }
        fillsMaxWhenRead = false
        if max > 0 { applyMax() }
    }

    // MARK: Picking

    /// A Swap entry's pair (`Router.openStellarSwap`): either side may be left as it is. The starter swap fills the whole
    /// balance of what it sells.
    func apply(_ request: StellarSwapRequest) {
        if let sell = request.sell { select(sell, for: .pay) }
        if let buy = request.buy { select(buy, for: .receive) }
        fillsMaxWhenRead = request.starter
        if request.starter {
            amountText = ""
            fillMaxIfRead()
        }
    }

    func select(_ id: String, for side: Side) {
        let before = (sell, buy)
        switch side {
        case .pay:
            if id == buy { buy = sell }
            sell = id
        case .receive:
            if id == sell { sell = buy }
            buy = id
        }
        // Picking the same asset again changes nothing: its quote stays.
        guard (sell, buy) != before else { return }
        result = nil
        selection.picked = false
    }

    func flip() {
        // The quote's output becomes the new input: read it before the swap makes it answer another pair.
        let carried = shownRoute
        swap(&sell, &buy)
        if let carried {
            let amount = Amount.roundedDown(BigUInt(max(0, carried.amountOut)), decimals: tokenIn.decimals)
            amountText = StellarFormat.plain(units: Int64(amount), decimals: tokenIn.decimals)
        }
        result = nil
        selection.picked = false
    }

    /// The person picked `venue` (a venue row tapped): it stays selected until an answer doesn't quote it.
    func pick(_ venue: String) {
        selection = StellarVenueSelection(venue: venue, picked: true)
    }

    // MARK: Quotes

    var quoteKey: String { "\(sell)|\(buy)|\(amountIn)|\(slippageBps)|\(account ?? "")" }

    /// `result`, when it answers what is on screen now.
    var currentResult: SwapQuote? { resultKey == quoteKey ? result : nil }
    /// `error`, when it answers what is on screen now.
    var currentError: String? { resultKey == quoteKey ? error : nil }

    /// A quote for what is on screen is on its way: the request, or the pause before it after an edit.
    var awaitingQuote: Bool { amountIn > 0 && sell != buy && curveToken == nil && (quoting || resultKey != quoteKey) }

    /// Every venue's route for what is on screen now that the phone would sign, the best first.
    var routes: [StellarSwapRoute] {
        guard amountIn > 0, let quote = currentResult else { return [] }
        return Self.routes(quote, listed: listed)
    }

    /// The route the screen shows and Review takes: the selected venue's, else the best.
    var shownRoute: StellarSwapRoute? {
        let routes = self.routes
        return routes.first { $0.venue == selection.venue } ?? routes.first(where: \.best) ?? routes.first
    }

    /// What the review sheet shows and builds, frozen when Review is tapped (nil without a quote for what is on screen,
    /// or while the amount can't be swapped).
    var review: StellarSwapReview? {
        guard let quote = currentResult, let route = shownRoute, !insufficient, curveToken == nil else { return nil }
        return StellarSwapReview(quote: quote, route: route, sell: tokenIn, buy: tokenOut, amountIn: amountIn, slippageBps: slippageBps)
    }

    /// The plan for `review`, through the venue it shows: the store binds the quote's amount as the spend and that route's
    /// minimum (`LiteStore.swapPlan`), so the quote must be the one for the request reviewed (`answers`).
    func plan(for review: StellarSwapReview) async throws -> PreparedAction {
        guard let source else { throw LiteAPIError.notSignedIn }
        guard answers(review.quote, sell: review.sell.id, buy: review.buy.id, amount: review.amountIn, slippageBps: review.slippageBps) else {
            throw PlanRunner.Failure.refused(step: tr("Swap"), reason: "the quote isn't for the amount you typed")
        }
        return try await source.swapPlan(review.quote, venue: review.route.venue)
    }

    var payUSD: Double? { tokenIn.priceUsd.map { Self.units(amountIn, decimals: tokenIn.decimals) * $0 } }

    var receiveUSD: Double? {
        guard let route = shownRoute, let price = tokenOut.priceUsd else { return nil }
        return Self.units(route.amountOut, decimals: tokenOut.decimals) * price
    }

    /// Asks for a quote for what is on screen, 400 ms after the last edit (the caller's `.task(id: quoteKey)` restarts it
    /// on every keystroke), then again every 15 seconds, or when the quote expires if that is sooner. A refresh keeps the
    /// last answer on screen until its own lands, so Review never goes dark for it. A side still on its launchpad is
    /// never quoted: no venue routes it (`curveToken`). `sleep` and `now` are the clock (tests pass their own).
    func quote(sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, now: () -> Date = Date.init) async {
        guard source != nil, amountIn > 0, sell != buy, curveToken == nil else {
            result = nil
            resultKey = nil
            error = nil
            // A request cancelled mid-flight (the amount cleared, or Done after a swap) returns without resetting it.
            quoting = false
            return
        }
        do { try await sleep(.milliseconds(400)) } catch { return }
        if Task.isCancelled { return }
        await learnSides()
        while !Task.isCancelled, let source = self.source {
            guard curveToken == nil else {
                quoting = false
                return
            }
            quoting = true
            let key = quoteKey
            let request = (sell: sell, buy: buy, amount: amountIn, slippageBps: slippageBps)
            var wait = Self.refreshInterval
            do {
                let answer = try await source.swapQuote(sell: request.sell, buy: request.buy, amount: request.amount, slippageBps: request.slippageBps)
                if Task.isCancelled { return }
                // Only the answer to this very request: the review binds the answer's amount and minimum, so an answer
                // for another amount, pair, direction or slippage is never shown or reviewed.
                let matches = answers(answer, sell: request.sell, buy: request.buy, amount: request.amount, slippageBps: request.slippageBps)
                let offered = matches ? Self.routes(answer, listed: listed) : []
                // An answer whose every route the phone would refuse to sign is no route at all: Monad's words, and
                // nothing to review (a server that offered such a route before it kept to the allowlist itself).
                result = offered.isEmpty ? nil : answer
                resultKey = key
                error = !matches ? Self.unanswered : offered.isEmpty ? Self.noRoute : nil
                selection = selection.following(offered)
                if !offered.isEmpty { wait = Self.refreshDelay(expiresAt: answer.expiresAt, now: now()) }
            } catch {
                if Task.isCancelled { return }
                result = nil
                resultKey = key
                self.error = Self.describe(error)
            }
            quoting = false
            do { try await sleep(wait) } catch { return }
        }
    }

    /// Whether `quote` answers exactly what was asked: `amount` of `sell` for `buy`, in that direction, at `slippageBps`.
    /// The server names a side by its registry id where it has one ("USDC" for its contract or CODE:ISSUER), so two ids
    /// name the same side when they are equal or name the same contract (`assetContract`).
    func answers(_ quote: SwapQuote, sell: String, buy: String, amount: Int64, slippageBps: Int) -> Bool {
        Int64(quote.amountIn) == amount && quote.slippageBps == slippageBps && sameAsset(quote.sell, sell) && sameAsset(quote.buy, buy)
    }

    private func sameAsset(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let contract = assetContract(a) else { return false }
        return contract == assetContract(b)
    }

    /// The contract an asset id names: a registry asset's (by its id or contract), a C… as it is, or a classic asset's
    /// ("native", CODE:ISSUER) as Stellar derives it; nil for anything else.
    private func assetContract(_ id: String) -> String? {
        if let registry = source?.config?.asset(id) { return registry.contract }
        if StrKey.isValid(.contract, id) { return id }
        if id == "native" { return AssetContract.id(.native, network: network) }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, (1...12).contains(parts[0].count), StrKey.isValid(.accountID, parts[1]) else { return nil }
        return AssetContract.id(.credit(code: parts[0], issuer: parts[1]), network: network)
    }

    /// What Swap says when no venue offers a route it would sign, as Monad's Swap says it.
    static var noRoute: String { tr("No venue can route this pair right now.") }

    /// What Swap says when the answer isn't the quote it asked for: an answer the app can't use, as every Stellar screen
    /// words it (`LiteErrorText`). The next refresh asks again.
    static var unanswered: String { LiteErrorText.describe(LiteAPIError.decoding("the swap quote")) }

    /// A failed quote, as a person reads it: the server finding no route at all reads as Monad's Swap words it; anything
    /// else as every Stellar error does (`LiteErrorText`).
    static func describe(_ error: Error) -> String {
        if case .server(_, "no_route", _, _)? = error as? LiteAPIError { return noRoute }
        return LiteErrorText.describe(error)
    }

    /// How long until the next quote: 15 seconds, or until the quote expires when that is sooner (at least a second).
    static func refreshDelay(expiresAt: String, now: Date) -> Duration {
        guard let expiry = StellarFormat.date(expiresAt) else { return refreshInterval }
        let left = expiry.timeIntervalSince(now)
        guard left < 15 else { return refreshInterval }
        return .milliseconds(Int64(max(1, left) * 1000))
    }

    /// A quote's routes, the best first: one per venue that answered (`SwapQuote.routes`), but for a venue Swap doesn't
    /// offer (`venues`) and a route the phone would refuse to sign (`signable`), so the first left is the best. An older
    /// server's answer without them is its best route only, the one the store binds without them.
    static func routes(_ quote: SwapQuote, listed: Set<String>) -> [StellarSwapRoute] {
        guard let routes = quote.routes, !routes.isEmpty else {
            let best = quote.best
            guard venues.contains(best.venue.lowercased()) else { return [] }
            return [route(venue: best.venue, amountOut: best.amountOut, minOut: best.minOut, impact: nil, path: best.path, best: true,
                          slippageBps: quote.slippageBps)]
        }
        let kept = routes.filter { venues.contains($0.venue.lowercased()) && signable(venue: $0.venue, path: $0.path, listed: listed) }
        let best = kept.first(where: \.best)?.venue ?? kept.first?.venue
        return kept.map { route(venue: $0.venue, amountOut: $0.amountOut, minOut: $0.minOut, impact: $0.priceImpactBps, path: $0.path,
                                best: $0.venue == best, slippageBps: quote.slippageBps) }
    }

    /// Whether the phone would sign a route, by the rule its verifier holds a swap's call to (TxVerifier): every token a
    /// Soroswap path or an Aquarius chain goes through between the one sold and the one bought runs inside the swap, so it
    /// must be pinned. The Stellar DEX's path runs no token code. A server that quoted such a route (testnet's Aquarius
    /// goes XLM → AQUA → USDT → USDC) would have it refused at review, so Swap never offers it.
    static func signable(venue: String, path: [String], listed: Set<String>) -> Bool {
        guard venue.lowercased() != "sdex", path.count > 2 else { return true }
        return path.dropFirst().dropLast().allSatisfy(listed.contains)
    }

    private static func route(venue: String, amountOut: String, minOut: String?, impact: Int?, path: [String], best: Bool,
                              slippageBps: Int) -> StellarSwapRoute {
        let out = Int64(amountOut) ?? 0
        return StellarSwapRoute(venue: venue, amountOut: out, minimum: minimum(quoted: out, minOut: minOut.flatMap { Int64($0) }, slippageBps: slippageBps),
                                priceImpactBps: impact, path: path, best: best)
    }

    /// A swap's minimum as the store binds it (`LiteStore.swapPlan`): the route's own minimum, never less than the quoted
    /// amount less the quote's slippage. 0 when there is neither, which the store refuses.
    static func minimum(quoted out: Int64, minOut: Int64?, slippageBps: Int) -> Int64 {
        let bps = Int64(min(max(slippageBps, 0), 10_000))
        let product = out.multipliedFullWidth(by: 10_000 - bps)
        let floor = out > 0 && product.high < 10_000 ? Int64(10_000).dividingFullWidth(product).quotient : 0
        return max(minOut ?? 0, floor)
    }

    /// The assets a route goes through, by code: "XLM → USDC".
    func pathText(_ route: StellarSwapRoute) -> String {
        route.path.map { step in
            if step == "native" { return "XLM" }
            let known = token(step)
            return known.code
        }.joined(separator: " → ")
    }

    // MARK: Swap History

    /// Swap History over `window`: the account's swaps from DyorHQ's activity (`/v1/activity?kind=swap`), each with what it
    /// really brought, in a read of its own (the shared Activity list stays as its screens read it). A passkey account
    /// with no session gets `.needsSignIn` and is asked nothing.
    func loadHistory(_ window: SwapHistoryService.Window) async {
        guard let source else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        let read = await source.readActivity(section: nil, kind: "swap", period: VolumePeriodKey(rawValue: window.rawValue))
        historyStatus = read.status
        guard read.status == .read else {
            // A failed read keeps the range's last answer on screen, never another range's.
            if historyRange != window || read.status == .needsSignIn { history = [] }
            return
        }
        history = StellarSwapHistoryItem.items(read.items) { token($0).code }
        historyRange = window
    }

    private static func units(_ units: Int64, decimals: Int) -> Double {
        Double(units) / pow(10, Double(decimals))
    }
}
#endif
