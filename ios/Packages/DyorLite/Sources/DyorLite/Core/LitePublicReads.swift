import Foundation
import Observation
import StellarKit

/// What anyone can read about Stellar's markets, with no session and no account (docs/DESIGN-stellar-parity.md §7.2):
/// Top Tokens and the token pages. Always there, from the session's first moment, so these show whatever the session
/// is doing; no request here ever carries the session's token.
@MainActor
@Observable
public final class LitePublicReads {
    /// Top Tokens, in Popular order (the other tabs are sorted on the phone: `StellarMarketRanking`).
    public private(set) var markets: [StellarMarketRow] = []
    /// How the markets' USD values are priced (reference prices on testnet).
    public private(set) var pricing: StellarPricing?
    /// The last markets read's failure, in the current language; nil once a read goes through.
    public private(set) var marketsError: String?
    /// When the markets were last read.
    public private(set) var marketsUpdatedAt: Date?

    let api: LiteAPI
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(api: LiteAPI) {
        self.api = api
    }

    /// Reads the markets again, in place: the rows stay until new ones replace them. A call while a read is under way
    /// waits for it.
    public func refreshMarkets() async {
        if let refreshing { return await refreshing.value }
        let task = Task {
            do {
                let markets = try await api.markets()
                self.markets = markets.rows
                pricing = markets.pricing
                marketsError = nil
                marketsUpdatedAt = Date()
            } catch {
                marketsError = LiteErrorText.describe(error)
            }
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// A token page: a registry id ("XLM") or a launch token's contract.
    public func market(_ id: String) async throws -> StellarMarketDetail { try await api.market(id) }

    /// A token's USD price over `range`, oldest first.
    public func history(_ id: String, range: VolumePeriodKey) async throws -> StellarPriceHistory {
        try await api.marketHistory(id, range: range)
    }
}
