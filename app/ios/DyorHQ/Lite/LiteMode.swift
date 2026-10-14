// Drop-in for the DyorHQ app target (after the Oct 13 submission; see docs/INTEGRATION-ios.md).
// Compiled only into builds with the STELLAR_LITE flag (internal TestFlight group).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// Whether the network control exists, and what it offers the account signed in (docs/DESIGN-network-switch.md §2.1). It
/// exists in this build (STELLAR_LITE) with a Lite API URL and the owner's `stellarLite` switch explicitly true
/// (`StellarRemoteFlag`: off unless the row says so). The Lite API's own tester allowlist is the third gate, met by
/// Setup's invite step.
enum LiteGate {
    /// What the network control offers the account signed in; nil where the control doesn't exist (no API URL, the
    /// owner's switch off, nobody signed in), and the screens are build 23's. An account that can't use Stellar still sees
    /// the control, and the sheet says why (open question 3).
    @MainActor
    static func availability(session: Session) -> NetworkAvailability? {
        guard StellarRemoteFlag.shared.isOn || debugForceOn, apiURL != nil, let account = session.account else { return nil }
        switch account.method {
        case .meraPasskey:
            // The first switch derives the Stellar key from the passkey, with one prompt.
            return .offered
        case .emailPassword:
            // Derived at sign-in (`LiteKeyBootstrap`): an account signed in before Stellar support signs in again.
            return DyorHQLiteKeys.stellarAddress(for: account.address) == nil ? .unavailable(.signInAgain) : .offered
        case .imported:
            // Derived at import, from the phrase or key still in hand: a wallet imported before then is imported again.
            return DyorHQLiteKeys.stellarAddress(for: account.address) == nil ? .unavailable(.importAgain) : .offered
        case .watchOnly:
            return .unavailable(.watchOnly)
        case .apple, .google, .email, .passkey:
            // Privy holds these wallets' keys: no Stellar key for them yet (Privy Stellar wallets come later).
            return .unavailable(.signInMethod(account.method))
        }
    }

    /// Debug builds only: `LiteDebugForceOn` (YES in the internal project's Debug configuration) stands in for the
    /// `stellarLite` remote flag, so the simulator can use Stellar without changing the server's flags. Release ignores it.
    static var debugForceOn: Bool {
        #if DEBUG
        return (Bundle.main.object(forInfoDictionaryKey: "LiteDebugForceOn") as? String) == "YES"
        #else
        return false
        #endif
    }

    /// LITE_API_URL from Info.plist; nil (and no network control) in a build that doesn't set it.
    static var apiURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "LITE_API_URL") as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    /// The contracts this build signs calls to: Stellar's testnet deployment. The server's sponsor must match, or Setup
    /// stops at its first check ("Update DyorHQ to use Stellar"), so the server's network is this one.
    static let pinned: PinnedContracts = .testnet

    /// Whether that network is a test network, whose balances have no value (`AppNetwork.isTestnet`).
    static var isTestnet: Bool { pinned.network != .mainnet }

    /// Only read once the control exists, which needs `apiURL`.
    static var environment: LiteEnvironment {
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        return LiteEnvironment(apiURL: apiURL!, pinned: pinned, buildNumber: build)
    }
}
#endif
