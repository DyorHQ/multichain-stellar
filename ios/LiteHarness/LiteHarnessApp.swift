// LiteHarness: runs DyorHQ Lite on its own, for internal testers, without touching the DyorHQ app.
// Its account is a 24-word phrase generated on first launch and kept in the Keychain (this device only); Settings
// can show the phrase so a tester can move to the real app later (same SEP-5 account).
import DyorLite
import LocalAuthentication
import StellarKit
import SwiftUI

@main
struct LiteHarnessApp: App {
    var body: some Scene {
        WindowGroup { HarnessRoot() }
    }
}

struct HarnessRoot: View {
    @State private var keys: PhraseKeyProvider?
    @State private var proAlert = false

    var body: some View {
        Group {
            if let keys {
                LiteRootView(env: HarnessConfig.environment, keys: keys) { proAlert = true }
            } else {
                ProgressView().task { keys = HarnessAccount.provider() }
            }
        }
        .alert("Pro lives in the DyorHQ app", isPresented: $proAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This internal build only runs Lite. In DyorHQ, the same switch takes you back to Pro on Monad.")
        }
    }
}

enum HarnessConfig {
    static var environment: LiteEnvironment {
        let url = Bundle.main.object(forInfoDictionaryKey: "LITE_API_URL") as? String ?? ""
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
        return LiteEnvironment(apiURL: URL(string: url)!, pinned: .testnet, buildNumber: build)
    }
}

enum HarnessAccount {
    private static let slot = "harness-entropy"

    static func provider() -> PhraseKeyProvider {
        let entropy = StellarKeychain.seed(account: slot, network: "testnet") ?? {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            try? StellarKeychain.saveSeed(bytes, account: slot, network: "testnet")
            return bytes
        }()
        let phrase = Mnemonic.phrase(entropy: entropy) ?? ""
        let address = (try? StellarDerivation.sep5(mnemonic: phrase).address) ?? ""
        return PhraseKeyProvider(address: address, methodLabel: "Test phrase (this device)") { reason in
            let ctx = LAContext()
            _ = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return phrase
        }
    }
}
