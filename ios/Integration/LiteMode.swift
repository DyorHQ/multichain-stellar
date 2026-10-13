// Drop-in for the DyorHQ app target (after the Oct 13 submission; see docs/INTEGRATION-ios.md).
// Compiled only into builds with the STELLAR_LITE flag (internal TestFlight group).
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Pro (Monad) or Lite (Stellar), remembered per account.
enum AppMode: String {
    case pro, lite

    static func current(for address: Address?) -> AppMode {
        guard let address else { return .pro }
        return AppMode(rawValue: UserDefaults.standard.string(forKey: "lite.mode.\(address)") ?? "") ?? .pro
    }

    static func set(_ mode: AppMode, for address: Address?) {
        guard let address else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "lite.mode.\(address)")
    }
}

/// Whether the Pro ⇄ Lite switch appears: this build has Lite (STELLAR_LITE), the `stellarLite` remote flag is
/// explicitly true (unlike the other RemoteFlags it defaults to OFF; see docs/INTEGRATION-ios.md), and the account
/// method has a Stellar key in phase 1. The Lite API's own tester allowlist is the third gate.
enum LiteGate {
    @MainActor
    static func isAvailable(session: Session, serverFlag: Bool) -> Bool {
        guard serverFlag, apiURL != nil, let method = session.account?.method else { return false }
        switch method {
        case .meraPasskey, .emailPassword, .imported: return true
        case .apple, .google, .email, .passkey, .watchOnly: return false // Privy Stellar wallets: phase 2
        }
    }

    /// LITE_API_URL from Info.plist; nil (and no pill) in a build that doesn't set it.
    static var apiURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "LITE_API_URL") as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    /// Only read once `isAvailable` said yes, which needs `apiURL`.
    static var environment: LiteEnvironment {
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        return LiteEnvironment(apiURL: apiURL!, pinned: .testnet, buildNumber: build)
    }
}
#endif
