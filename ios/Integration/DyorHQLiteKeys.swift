// The account's Stellar key, from the secret it already has (docs/ARCHITECTURE.md §3.2).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Foundation
import StellarKit

enum DyorHQLiteKeys {
    enum Failure: LocalizedError {
        case unsupported
        case notPrepared
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Lite isn't available for this sign-in method yet."
            case .notPrepared: return "Sign in again to set up Lite on this device."
            }
        }
    }

    private static func storedAddress(_ evm: Address) -> String? { UserDefaults.standard.string(forKey: "lite.stellar.\(evm)") }
    private static func store(_ stellar: String, for evm: Address) { UserDefaults.standard.set(stellar, forKey: "lite.stellar.\(evm)") }

    /// The provider for the signed-in account, without prompting. Nil until `prepare` ran once on this device.
    @MainActor
    static func provider(session: Session) async -> LiteKeyProvider? {
        guard let account = session.account, let stellar = storedAddress(account.address) else { return nil }
        return make(session: session, method: account.method, evm: account.address, stellar: stellar)
    }

    /// Ensures the Stellar address is known (one unlock the first time), then returns the provider.
    @MainActor
    static func prepare(session: Session) async throws -> LiteKeyProvider {
        guard let account = session.account else { throw Failure.unsupported }
        if let p = await provider(session: session) { return p }
        switch account.method {
        case .meraPasskey:
            let words = try await session.mera.revealPhrase(expecting: account.address)
            let signer = try StellarDerivation.sep5(mnemonic: words.joined(separator: " "))
            store(signer.address, for: account.address)
        case .emailPassword, .imported:
            // Derived and stored at sign-in / import by LiteKeyBootstrap; a session from before Lite must sign in again.
            throw Failure.notPrepared
        default:
            throw Failure.unsupported
        }
        guard let stellar = storedAddress(account.address),
              let provider = make(session: session, method: account.method, evm: account.address, stellar: stellar) else { throw Failure.unsupported }
        return provider
    }

    @MainActor
    private static func make(session: Session, method: Session.Method, evm: Address, stellar: String) -> LiteKeyProvider? {
        switch method {
        case .meraPasskey:
            let mera = session.mera
            return PhraseKeyProvider(address: stellar, methodLabel: "Passkey") { _ in
                // A fresh passkey ceremony per signature; the words never outlive this call.
                try await MainActor.run { mera }.revealPhrase(expecting: evm).joined(separator: " ")
            }
        case .emailPassword:
            return StoredSeedKeyProvider(address: stellar, methodLabel: "Email & password", network: "testnet")
        case .imported:
            return StoredSeedKeyProvider(address: stellar, methodLabel: "Imported wallet", network: "testnet")
        default:
            return nil
        }
    }
}

/// Hooks for the two sign-in paths that hold their secret only briefly (docs/INTEGRATION-ios.md §4): the email v2 log-in
/// and bind (`Session.logInWithPassword` / `bindEmailPassword`, where seed and pepper are in hand) and the import flow
/// (`ImportWalletView.runImport`, which still has the phrase or key) call these while they still have the secret.
enum LiteKeyBootstrap {
    static func didDeriveEmailWallet(seed: Data, pepper: Data, evm: Address) {
        guard let signer = try? StellarDerivation.emailV2(seed: [UInt8](seed), pepper: [UInt8](pepper)) else { return }
        save(signer, evm: evm)
    }

    static func didImport(privateKey: Data, evm: Address) {
        guard let signer = try? StellarDerivation.fromSecp256k1(privateKey: [UInt8](privateKey)) else { return }
        save(signer, evm: evm)
    }

    static func didImport(phrase: String, evm: Address) {
        // The words exactly as DyorKit's WalletImport reads them (lowercased, any whitespace), so the Stellar key comes
        // from the same BIP-39 seed as the imported Monad key.
        let words = phrase.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        guard let signer = try? StellarDerivation.sep5(mnemonic: words.joined(separator: " ")) else { return }
        save(signer, evm: evm)
    }

    /// Sign-out and erase: the Stellar seed and Lite session stored for `evm`, and the remembered address and mode.
    /// Call before UserDefaults is wiped (it holds the Stellar address the Keychain items are filed under).
    static func forget(evm: Address) {
        if let stellar = UserDefaults.standard.string(forKey: "lite.stellar.\(evm)") { StellarKeychain.erase(account: stellar) }
        UserDefaults.standard.removeObject(forKey: "lite.stellar.\(evm)")
        UserDefaults.standard.removeObject(forKey: "lite.mode.\(evm)")
    }

    private static func save(_ signer: StellarSigner, evm: Address) {
        guard let seed = try? StrKey.decode(.seed, signer.secret) else { return }
        // Remember the address only once the seed is in the Keychain: an address without its seed can't sign.
        guard (try? StellarKeychain.saveSeed(seed, account: signer.address, network: "testnet")) != nil else { return }
        UserDefaults.standard.set(signer.address, forKey: "lite.stellar.\(evm)")
    }
}
#endif
