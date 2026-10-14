import Foundation

/// Switches the owner can flip from the backend, without a new build: the optional `flags` object of the public,
/// read-only `app_config` row 'ios' (`{"min_build": 16, "flags": {"dyorVenuePrices": false}}`), read with the minimum
/// build (`SupabaseClient.iosAppConfig`, by the app's `UpdateGate`). All five switches are kill switches
/// (`dyorVenuePrices`, `dyorBadges`, `serverHistory`, `perpsLiveOutcome`, `perpsApiActions`): each is on unless the row
/// says JSON `false` for it. A row without `flags`, a switch left out, and a value that isn't JSON true or false (a
/// string, a number, null, an object) all leave it on. So shipping writes nothing to production, and a typo in the row
/// can't turn a feature off.
///
/// The server's history of a wallet (`serverHistory`) follows the same rule, by the owner's decision (2026-10-09): the
/// owner asked for it, the server has an instant switch of its own (`history_read` answering `serving: false`, which the
/// app discards at once), and everything the app takes from it fails open — a read that fails or doesn't check out is
/// discarded and the device reads the chain as it always has. The history epoch (`historyEpoch`) is no switch but a
/// number the owner raises to drop what the server's history added to every device (`HistoryStore.apply(epoch:)`): a
/// whole number from 0 up, anything else 0.
public struct RemoteFlags: Equatable, Sendable {
    /// DyorHQ coins priced on their own curve or pool (`PriceService.setUsesDyorVenues`). Off, they are priced like any
    /// other token, as build 16 priced them.
    public let dyorVenuePrices: Bool
    /// The DyorHQ Launch and DyorHQ Moment labels (`TokenBadge`). Off, a DyorHQ coin shows as build 16 showed it: no
    /// DyorHQ label, and one sent to the wallet Unverified.
    public let dyorBadges: Bool
    /// The wallet's history taken from the server's cache of it (`ServerHistorySync`, supabase migration 32's
    /// `history_read`) before the device reads the chain on. Off, the app asks the server nothing about the history and
    /// reads it all from the chain, as build 22 did; what it took in before stays until the epoch drops it.
    public let serverHistory: Bool
    /// The owner's history epoch: every entry that took the server's history in under a lower one is read again from
    /// nothing (`HistoryStore.apply(epoch:)`), whether `serverHistory` is on or off. 0 until the owner raises it.
    public let historyEpoch: Int
    /// The one-click order sheet shows Perpl's real outcome (filled, resting, not filled…) instead of ending at the
    /// gateway's acknowledgement. Off (JSON `false`): today's acknowledgement sheet (`placeLegacy`), and Close / Add
    /// Margin / Cancel Order go on-chain. Requests already sent keep the mode of their tap.
    public let perpsLiveOutcome: Bool
    /// Close / Add Margin / Cancel Order go over the trading connection when one-click is live. Off (JSON `false`): they
    /// go on-chain; the order sheet is unaffected. Requests already sent keep the mode of their tap.
    public let perpsApiActions: Bool

    /// Every switch on, and the epoch 0: what the app uses until the row is read (or the last values read are restored),
    /// and for a row that says nothing.
    public static let on = RemoteFlags()

    /// The highest history epoch read as given: past it (or below 0, or not a whole number), the row says 0.
    public static let largestEpoch = Int(Int32.max)

    public init(dyorVenuePrices: Bool = true, dyorBadges: Bool = true, serverHistory: Bool = true, historyEpoch: Int = 0,
                perpsLiveOutcome: Bool = true, perpsApiActions: Bool = true) {
        self.dyorVenuePrices = dyorVenuePrices
        self.dyorBadges = dyorBadges
        self.serverHistory = serverHistory
        self.historyEpoch = historyEpoch
        self.perpsLiveOutcome = perpsLiveOutcome
        self.perpsApiActions = perpsApiActions
    }

    /// The switches in PostgREST's answer to `app_config?key=eq.ios&select=value` (`[{"value": {...}}]`). Anything that
    /// isn't that answer, or a `flags` that isn't an object, is every switch on and the epoch 0.
    public static func parse(_ data: Data) -> RemoteFlags {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 1,
              let value = rows[0]["value"] as? [String: Any], let flags = value["flags"] as? [String: Any] else { return .on }
        return RemoteFlags(dyorVenuePrices: flag(flags["dyorVenuePrices"]), dyorBadges: flag(flags["dyorBadges"]), serverHistory: flag(flags["serverHistory"]),
                           historyEpoch: epoch(flags["historyEpoch"]),
                           perpsLiveOutcome: flag(flags["perpsLiveOutcome"]), perpsApiActions: flag(flags["perpsApiActions"]))
    }

    /// A kill switch's value: false only for JSON `false`; on for everything else.
    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return true }
        return number.boolValue
    }

    /// The epoch's value: a JSON number that is a whole number from 0 to `largestEpoch` (JSON has no integers apart, so
    /// `3.0` is 3); 0 for everything else — a fraction, a negative, a string, a boolean, null, left out.
    private static func epoch(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(largestEpoch), double.rounded(.towardZero) == double else { return 0 }
        return Int(double)
    }
}
