import Foundation
import StellarKit

/// The launchpad's figures as the screens show them (docs/DESIGN-stellar-parity.md §8.10): board sorts on the phone,
/// progress toward graduation, the holders count, and a trade's minimum at the fixed 1% slippage.
public enum StellarLaunchMath {
    /// The board's sorts, with the server's names (`LaunchSort` on Monad).
    public enum Sort: String, CaseIterable, Sendable {
        case newest
        case marketCap = "market_cap"
        case nearGraduation = "near_graduation"
    }

    /// `launches` in a board sort, on the phone (saved boards, merged pages): the newest first; by market cap in USD,
    /// every coin whose quote has no USD price after the priced ones (caps in different quote assets can't be weighed
    /// against each other); by progress toward graduation. Ties: the newest first, then by contract.
    public static func sorted(_ launches: [StellarLaunch], by sort: Sort) -> [StellarLaunch] {
        func newer(_ a: StellarLaunch, _ b: StellarLaunch) -> Bool {
            let (x, y) = (a.createdAt.liteDate ?? .distantPast, b.createdAt.liteDate ?? .distantPast)
            return x != y ? x > y : a.token < b.token
        }
        switch sort {
        case .newest:
            return launches.sorted(by: newer)
        case .marketCap:
            return launches.sorted { a, b in
                switch (a.marketCapUsd, b.marketCapUsd) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return newer(a, b)
                }
            }
        case .nearGraduation:
            return launches.sorted { a, b in
                let (x, y) = (progress(a), progress(b))
                return x != y ? x > y : newer(a, b)
            }
        }
    }

    /// Progress toward graduation, 0...1: 1 once the curve is complete or the coin has graduated.
    public static func progress(_ launch: StellarLaunch) -> Double {
        if launch.completed || launch.graduated { return 1 }
        guard launch.progress.isFinite else { return 0 }
        return min(1, max(0, launch.progress))
    }

    /// The whole percent for "%lld%% to graduation", floored so that 99.6% doesn't read 100% before the curve is full.
    public static func progressPercent(_ launch: StellarLaunch) -> Int {
        if launch.completed || launch.graduated { return 100 }
        return min(99, Int((progress(launch) * 100).rounded(.down)))
    }

    /// "5" holders, or "5+" when some of the coin's transfers couldn't be read (so there may be more), in the current
    /// language's digits; nil while unknown.
    public static func holdersText(_ holders: Int?, complete: Bool?) -> String? {
        guard let holders, holders >= 0 else { return nil }
        let count = holders.formatted(.number.locale(LiteL10n.locale))
        return complete == false ? count + "+" : count
    }

    /// A trade's minimum: the quote less 1% (the curve's fixed slippage, R11), rounded down.
    public static func minOut(_ quoted: Int64) -> Int64 {
        guard quoted > 0 else { return 0 }
        return quoted / 100 * 99 + quoted % 100 * 99 / 100
    }
}
