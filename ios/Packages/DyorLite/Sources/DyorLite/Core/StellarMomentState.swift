import Foundation
import StellarKit

/// Where a Stellar Moment is (docs/DESIGN-stellar-parity.md §8.11): collecting, sold out or its window closed. Stellar
/// Moments are editions with no coin, so there is no graduation. Worked out at an instant, so a board re-filters the
/// moment a window closes (`Clock`), whatever the server's `state` said when it was read.
public enum StellarMomentState: String, Equatable, Sendable {
    case collecting, soldOut, windowClosed

    /// At `now`: sold out once a capped edition has minted its last (an open edition, `maxEditions` 0, never sells
    /// out); the window closed from its deadline on; collecting otherwise. A sold-out Moment says so even after its
    /// window closes.
    public init(maxEditions: Int, minted: Int, deadline: Date, now: Date) {
        if maxEditions > 0, minted >= maxEditions {
            self = .soldOut
        } else if now >= deadline {
            self = .windowClosed
        } else {
            self = .collecting
        }
    }

    /// `moment` at `now`; the server's `state` (or `open`) only when its deadline can't be read.
    public init(_ moment: StellarMoment, now: Date) {
        if let deadline = moment.deadline.liteDate {
            self.init(maxEditions: moment.maxEditions, minted: moment.minted, deadline: deadline, now: now)
        } else if moment.state == "sold_out" || (moment.maxEditions > 0 && moment.minted >= moment.maxEditions) {
            self = .soldOut
        } else {
            let collecting = moment.state.map { $0 == "collecting" } ?? moment.open
            self = collecting ? .collecting : .windowClosed
        }
    }

    public var isCollecting: Bool { self == .collecting }

    /// The most editions one collect may take now: at least 1, at most the contract's per-collect maximum and, for a
    /// capped edition, what is left of it. (A stepper over 1...0 would trap: the ticket hides once sold out.)
    public static func collectLimit(maxEditions: Int, minted: Int, maxPerCollect: Int) -> Int {
        let left = maxEditions > 0 ? maxEditions - minted : maxPerCollect
        return max(1, min(maxPerCollect, left))
    }
}
