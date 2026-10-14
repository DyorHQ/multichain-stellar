// DEBUG Simulator builds only. In any other build this file compiles to nothing, so no Release binary can contain the
// stub or a path to it; `PasskeyBackend.forThisBuild` references it under the same condition.
#if DEBUG && targetEnvironment(simulator)
import DyorKit
import Foundation
import Security

/// A stand-in passkey provider for exercising the Mera flows in the Simulator, where no real passkey can associate with
/// accounts.dyorhq.fun (Apple's CDN has to serve the association file, and a Simulator passkey needs an iCloud
/// sign-in). It runs only when the app is launched with the argument, e.g.
///
///     xcrun simctl launch <device> fun.dyorhq.app -MeraStubAuthenticator [full|unsupported|deferred|single]
///
/// `full` (the default) evaluates both salts on every ceremony. The other modes reproduce MERA-PLAN §2's registration
/// cases: `unsupported` reports `prf.isSupported == false`, `deferred` registers without outputs (so the pinned
/// fallback assertion runs), and `single` evaluates only the first salt (so the utility output is fetched lazily).
///
/// - Each credential it creates is a random 32-byte secret generated on this install — never a repo constant — kept in
///   its own UserDefaults suite. An account wipe clears the app's own defaults but not this suite, as a real passkey
///   outlives the app's data; deleting the app removes it.
/// - PRF outputs are WebAuthn's evaluation over that secret (`Mera.Stub.prf`).
/// - It refuses to run unless every RPC endpoint is on this Mac (an anvil fork, `MONAD_RPC_URL=http://127.0.0.1:8545`):
///   its secrets sit in plain UserDefaults, so an account it derives must never hold anything on a real network.
/// - That check runs at ceremony time only, so the account stays confined where it signs (`MeraSession.isStub`,
///   `Mera.Stub.permits`): transactions for Monad's chain id (the fork's) and nothing else. No message — the backend
///   (wallet-auth) sign-in is skipped quietly — no Perpl enrolment, and the Bridge screen reads "Not available in
///   Simulator test mode".
@MainActor
final class StubPasskeyAuthenticator: PasskeyAuthenticator, PasskeySignaling {
    enum Mode: String {
        case full, unsupported, deferred, single
    }

    enum Refusal: LocalizedError {
        case notLocal, wrongRelyingParty, noPasskey
        // not localized: a developer's message, in DEBUG Simulator builds only
        var errorDescription: String? {
            switch self {
            case .notLocal: return "The Simulator stub authenticator runs only against a local fork. Build with MONAD_RPC_URL=http://127.0.0.1:8545 (anvil), or launch without -MeraStubAuthenticator."
            case .wrongRelyingParty: return "The Simulator stub authenticator serves \(Mera.relyingParty) only."
            case .noPasskey: return "No stub passkey on this Simulator for that request. Create an account first."
            }
        }
    }

    static let launchArgument = "-MeraStubAuthenticator"

    /// The mode the launch arguments ask for, or nil when the stub isn't requested.
    static var requestedMode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgument) else { return nil }
        let next = arguments.index(after: index)
        return next < arguments.endIndex ? Mode(rawValue: arguments[next].lowercased()) ?? .full : .full
    }

    private struct Credential: Codable {
        let id: Data
        let userID: Data
        let secret: Data
        let name: String
    }

    private let mode: Mode
    private let rpcURLs: [URL]
    private let store = UserDefaults(suiteName: "fun.dyorhq.app.mera-stub") ?? .standard
    private let storeKey = "credentials.v1"

    init(mode: Mode, rpcURLs: [URL]) {
        self.mode = mode
        self.rpcURLs = rpcURLs
    }

    func register(rpId: String, name: String, userID: Data, salts: (Data, Data)) async throws -> PasskeyResponse {
        try check(rpId)
        let credential = Credential(id: try Self.random(16), userID: userID, secret: try Self.random(32), name: name)
        save(credentials() + [credential])
        switch mode {
        case .unsupported:
            return PasskeyResponse(credentialID: credential.id, userID: userID, prfSupported: false, first: nil, second: nil)
        case .deferred:
            return PasskeyResponse(credentialID: credential.id, userID: userID, prfSupported: true, first: nil, second: nil)
        case .full, .single:
            return response(credential, salts: salts, prfSupported: true)
        }
    }

    func assert(rpId: String, salts: (Data, Data), credentialID: Data?) async throws -> PasskeyResponse {
        try check(rpId)
        let all = credentials()
        // Discoverable: the newest stub passkey stands for the one the person would pick in the sheet.
        guard let credential = credentialID.map({ id in all.first { $0.id == id } }) ?? all.last else { throw Refusal.noPasskey }
        if mode == .unsupported { return PasskeyResponse(credentialID: credential.id, userID: credential.userID, prfSupported: nil, first: nil, second: nil) }
        return response(credential, salts: salts, prfSupported: nil)
    }

    /// The stub's provider honours the signal at once: the credential is gone.
    @discardableResult
    func reportUnknown(relyingParty: String, credentialID: Data) async -> PasskeySignalOutcome {
        guard relyingParty == Mera.relyingParty else { return .failed }
        save(credentials().filter { $0.id != credentialID })
        return .reported
    }

    private func response(_ credential: Credential, salts: (Data, Data), prfSupported: Bool?) -> PasskeyResponse {
        PasskeyResponse(credentialID: credential.id, userID: credential.userID, prfSupported: prfSupported,
                        first: Mera.Stub.prf(secret: credential.secret, salt: salts.0),
                        second: mode == .single ? nil : Mera.Stub.prf(secret: credential.secret, salt: salts.1))
    }

    private func check(_ rpId: String) throws {
        guard Mera.Stub.allows(rpcURLs: rpcURLs) else { throw Refusal.notLocal }
        guard rpId == Mera.relyingParty else { throw Refusal.wrongRelyingParty }
    }

    private func credentials() -> [Credential] {
        store.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([Credential].self, from: $0) } ?? []
    }

    private func save(_ credentials: [Credential]) {
        store.set(try? JSONEncoder().encode(credentials), forKey: storeKey)
    }

    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw PasskeyCeremony.Failure.failed }
        return Data(bytes)
    }
}
#endif
