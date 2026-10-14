// The account's Stellar key, from the secret it already has (docs/ARCHITECTURE.md §3.2), and its unlock for the network
// switch's setup run (docs/DESIGN-network-switch.md §8.1).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Foundation
import StellarKit

enum DyorHQLiteKeys {
    /// The Stellar address of `evm`'s account on this iPhone (public), stored once its key was derived here; nil before.
    /// An email & password or imported account has it only with its seed in the Keychain (`LiteKeyBootstrap.save`), so
    /// for them it also says the Stellar key is on this iPhone (`LiteGate.availability`).
    static func stellarAddress(for evm: Address) -> String? { UserDefaults.standard.string(forKey: "lite.stellar.\(evm)") }
    private static func store(_ stellar: String, for evm: Address) { UserDefaults.standard.set(stellar, forKey: "lite.stellar.\(evm)") }

    /// The network the Keychain files the seeds and sessions under: the build's pinned one.
    static var network: String { LiteGate.pinned.network.name }

    /// The provider for the signed-in account, made without a prompt; nil while its Stellar address isn't known (a passkey
    /// account before its first unlock). It signs every transaction after the setup run, with one prompt each.
    @MainActor
    static func provider(session: Session) -> LiteKeyProvider? {
        guard let account = session.account, let stellar = stellarAddress(for: account.address) else { return nil }
        return make(session: session, method: account.method, evm: account.address, stellar: stellar)
    }

    /// The setup run's one prompt (`LiteSession`'s `unlock`), for `evm`'s account only: the passkey once for a passkey
    /// account, whose Stellar address it derives and stores; Face ID or the passcode through `BiometricGate`, then the
    /// Keychain's seed, for an email & password or imported account. Returns the provider for later signatures and this
    /// run's signer. `reason` comes translated.
    @MainActor
    static func unlock(session: Session, evm: Address, reason: String) async throws -> LiteSession.UnlockResult {
        guard let account = session.account, account.address == evm else { throw LiteSession.Failure.keyNotOnDevice }
        switch account.method {
        case .meraPasskey:
            let signer = try StellarDerivation.sep5(mnemonic: try await passkeyPhrase(session.mera, evm: evm))
            store(signer.address, for: evm)
            return LiteSession.UnlockResult(keys: passkeyProvider(session.mera, evm: evm, stellar: signer.address), signer: signer)
        case .emailPassword, .imported:
            // Derived and stored at sign-in or import (`LiteKeyBootstrap`): an account from before Stellar support has none.
            guard let stellar = stellarAddress(for: evm), StellarKeychain.seed(account: stellar, network: network) != nil else {
                throw LiteSession.Failure.keyNotOnDevice
            }
            let keys = GatedSeedKeyProvider(address: stellar, methodLabel: account.method.title, network: network)
            return LiteSession.UnlockResult(keys: keys, signer: try await keys.signer(reason: reason))
        case .apple, .google, .email, .passkey, .watchOnly:
            throw LiteSession.Failure.keyNotOnDevice
        }
    }

    @MainActor
    private static func make(session: Session, method: Session.Method, evm: Address, stellar: String) -> LiteKeyProvider? {
        switch method {
        case .meraPasskey: return passkeyProvider(session.mera, evm: evm, stellar: stellar)
        case .emailPassword, .imported: return GatedSeedKeyProvider(address: stellar, methodLabel: method.title, network: network)
        case .apple, .google, .email, .passkey, .watchOnly: return nil
        }
    }

    /// A passkey account's Stellar key: a fresh passkey ceremony per signature; the words never outlive the call.
    private static func passkeyProvider(_ mera: MeraSession, evm: Address, stellar: String) -> LiteKeyProvider {
        PhraseKeyProvider(address: stellar, methodLabel: Session.Method.meraPasskey.title) { _ in
            try await passkeyPhrase(mera, evm: evm)
        }
    }

    /// The passkey account's recovery phrase, from one ceremony pinned to `evm`'s passkey. A cancelled ceremony and another
    /// account's passkey are said as the setup run says them.
    @MainActor
    private static func passkeyPhrase(_ mera: MeraSession, evm: Address) async throws -> String {
        do {
            return try await mera.revealPhrase(expecting: evm).joined(separator: " ")
        } catch PasskeyCeremony.Failure.cancelled {
            throw LiteSession.Failure.cancelled
        } catch PasskeyCeremony.Failure.wrongCredential, MeraSession.Failure.differentPasskey {
            throw LiteSession.Failure.otherAccountsKey
        }
    }
}

/// The Stellar seed of an email & password or imported account, kept in this iPhone's Keychain (`StellarKeychain`). Every
/// signature asks for Face ID or the passcode through `BiometricGate`, so the privacy cover stays off behind the prompt
/// (RootView), then reads the seed. DyorLite's `StoredSeedKeyProvider` asks LocalAuthentication itself, which the cover
/// doesn't know about.
struct GatedSeedKeyProvider: LiteKeyProvider {
    let address: String
    let methodLabel: String
    let network: String
    let canSign = true
    let canExportSecret = true

    func signer(reason: String) async throws -> StellarSigner {
        guard await BiometricGate.authenticate(reason: reason) else { throw LiteSession.Failure.cancelled }
        guard let seed = StellarKeychain.seed(account: address, network: network) else { throw LiteSession.Failure.keyNotOnDevice }
        let signer = try StellarSigner(seed: seed)
        guard signer.address == address else { throw KeyError.badSeed }
        return signer
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

    /// Sign-out and erase: the Stellar seed and session stored for `evm`, DyorLite's "this account is set up" cache
    /// (`lite.activated.<G…>`, `LiteSession.activatedKey`), the remembered address, and the network and Stellar intro
    /// remembered for the account (`AppNetwork.forget`). Call before UserDefaults is wiped (it holds the Stellar address
    /// the Keychain items are filed under).
    static func forget(evm: Address) {
        if let stellar = UserDefaults.standard.string(forKey: "lite.stellar.\(evm)") {
            StellarKeychain.erase(account: stellar)
            UserDefaults.standard.removeObject(forKey: "lite.activated.\(stellar)")
        }
        UserDefaults.standard.removeObject(forKey: "lite.stellar.\(evm)")
        AppNetwork.forget(evm)
    }

    private static func save(_ signer: StellarSigner, evm: Address) {
        guard let seed = try? StrKey.decode(.seed, signer.secret) else { return }
        // Remember the address only once the seed is in the Keychain: an address without its seed can't sign.
        guard (try? StellarKeychain.saveSeed(seed, account: signer.address, network: DyorHQLiteKeys.network)) != nil else { return }
        UserDefaults.standard.set(signer.address, forKey: "lite.stellar.\(evm)")
    }
}
#endif
