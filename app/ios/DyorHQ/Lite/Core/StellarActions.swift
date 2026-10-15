// What the shared Stellar pieces can ask of the screens around them (docs/DESIGN-stellar-parity.md §3.7). Internal builds
// only (STELLAR_LITE).
#if STELLAR_LITE
import SwiftUI

/// The actions a shared Stellar piece (the review sheet, a history part with no session, the add-funds card) can start
/// without knowing the screens that carry them out: the Stellar root sets them (`.environment(\.stellarActions, …)`).
/// Nothing here unlocks anything: there is no lock (decision 6).
struct StellarActions {
    /// Opens Receive, to add XLM or another asset to the account.
    var addFunds: @MainActor () -> Void = {}
    /// Opens Swap, selling `sell` and buying `buy` (asset ids; nil leaves a side as it is), on the starter swap's terms
    /// when `starter` is true (§8.6.2). Through `openSwap(sell:buy:starter:)`.
    var swap: @MainActor (_ sell: String?, _ buy: String?, _ starter: Bool) -> Void = { _, _, _ in }
    /// `LiteSession.signIn()`: for a history part's "Sign in with your passkey" only (`StellarSignInRow`), a passkey
    /// account with no session. One passkey prompt; throws when it was cancelled or failed.
    var signIn: @MainActor () async throws -> Void = {}
    /// Back to Monad, from a paused Stellar screen.
    var switchToMonad: @MainActor () -> Void = {}

    /// Opens Swap (`swap`).
    @MainActor
    func openSwap(sell: String? = nil, buy: String? = nil, starter: Bool = false) {
        swap(sell, buy, starter)
    }
}

extension EnvironmentValues {
    /// The Stellar root's actions (`StellarActions`); each does nothing until the root sets them.
    @Entry var stellarActions = StellarActions()
}
#endif
