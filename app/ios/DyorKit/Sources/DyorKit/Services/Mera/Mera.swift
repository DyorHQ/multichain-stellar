import BigInt
import CryptoKit
import Foundation

/* Mera (Category Labs) passkey accounts, implemented natively. A passkey evaluated with the WebAuthn PRF extension
   returns 32 secret bytes that are the same on every sign-in and every synced device; nothing is stored anywhere.
   This file reproduces the published scheme bit for bit so an address created here equals the one
   `@category-labs/mera` derives on the web app:

     account   PRF(salt = sha256("mera.prf.salt.v1")) → BIP-39 (24 words) → seed → BIP-32 m/44'/60'/0'/0/i
     vault     AES-256-GCM with HKDF-SHA-256(PRF(random salt), salt: empty, info: "mera.v1.encrypt.secret")

   and adds DyorHQ's own PRF namespace for everything that is not the wallet (a second, independent PRF salt), from
   which per-purpose keys are derived with HKDF. Test vectors in MeraTests were produced with the JS library, and
   scripts/mera-parity recomputes them with the pinned package. This port is derived from `@category-labs/mera` 0.2.0
   (Category Labs, MIT OR Apache-2.0); the credit and license text are in THIRD_PARTY_NOTICES.md at the repo root. */
public enum Mera {
    // MARK: Relying party

    /// DyorHQ's passkey rpId. Every Mera account is bound to it, so it can never change once a real passkey exists.
    /// It is a dedicated host that serves only the apple-app-site-association file (GitHub Pages, DyorHQ/accounts-domain),
    /// never the apex: the site there injects a third-party script, and a script on the rpId origin could run a
    /// ceremony and read the PRF output, which is the keys. The app's associated-domains entitlement (project.yml)
    /// names the same host; nothing reads it from build settings.
    public static let relyingParty = "accounts.dyorhq.fun"

    // MARK: PRF salts (namespaces)

    /// Mera's default salt: the wallet account namespace. Same bytes as the JS library's `DEFAULT_PRF_SALT`.
    public static let accountSalt = Data(SHA256.hash(data: Data("mera.prf.salt.v1".utf8)))

    /// DyorHQ's namespace for everything that is not signing wallet transactions: capabilities, identities and
    /// encrypted state. Evaluated as the second PRF input of the same ceremony, so one prompt yields both, and the
    /// authenticator keeps the two outputs unrelated.
    public static let utilitySalt = Data(SHA256.hash(data: Data("dyorhq.utility.v1".utf8)))

    /// A custom 32-byte salt for any other namespace (`sha256(label)`), the way Mera lets callers pass `prfSalt`.
    public static func salt(_ label: String) -> Data { Data(SHA256.hash(data: Data(label.utf8))) }

    // MARK: Accounts

    /// The BIP-39 phrase Mera would show for this PRF output (24 words for 32 bytes). Nil for an invalid length.
    public static func mnemonic(entropy: Data) -> String? { Mnemonic.phrase(fromEntropy: entropy) }

    /// The EVM account at `m/44'/60'/0'/0/index` for a 32-byte PRF output: entropy → mnemonic → seed → BIP-32.
    public static func evmAccount(prf: Data, index: UInt32 = 0) -> Secp256k1Account? {
        guard prf.count == 32, let phrase = Mnemonic.phrase(fromEntropy: prf) else { return nil }
        return WalletImport.account(fromMnemonic: phrase, accountIndex: index)
    }

    // MARK: Derived keys under a namespace

    /// A 32-byte key for one purpose, derived from a PRF output with HKDF-SHA-256 (empty salt, the purpose as info).
    /// Different purposes give unrelated keys; the same passkey gives the same key on every device.
    public static func derivedKey(prf: Data, purpose: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: prf), salt: Data(), info: Data(purpose.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// An Ed25519 signing key for a purpose (Perpl's trading key, a social identity), from `derivedKey`.
    public static func ed25519Key(prf: Data, purpose: String) throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: derivedKey(prf: prf, purpose: purpose))
    }

    /// Purposes DyorHQ derives under `utilitySalt`. Each string is part of the key, so they never change.
    public enum Purpose {
        /// Perpl's trade-scoped Ed25519 API key, never stored. The purpose itself is the key of an enrolment made
        /// before enrolments carried a nonce; every enrolment since has its own (`perplTrading(nonce:)`).
        public static let perplTrading = "dyorhq.perpl-trading.v1"

        /// The Perpl trading key of one enrolment. Perpl registers a public key once — enrolling it again is refused
        /// (409), even after it is revoked — and hands out its token once, so the same key can never be enrolled on a
        /// second device, or on this one after it lost the token (Forget This Device, a reinstall). Each enrolment
        /// draws a random nonce (`newPerplNonce`), stored with the token, and its key is derived under `perplTrading`
        /// + "/" + the nonce in hex; nil (or empty) is the pre-nonce key. The key still comes from the passkey alone:
        /// a stored nonce and token without the passkey sign nothing.
        public static func perplTrading(nonce: Data?) -> String {
            guard let nonce, !nonce.isEmpty else { return perplTrading }
            return perplTrading + "/" + nonce.map { String(format: "%02x", $0) }.joined()
        }

        /// A fresh enrolment nonce: 16 random bytes.
        public static func newPerplNonce() -> Data {
            SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        }
        /// Encryption key for the user's app state (alerts, notifications) kept in untrusted storage.
        public static let state = "dyorhq.state.v1"
        /// The social/backend identity, unlinkable to the trading wallet.
        public static let socialIdentity = "dyorhq.social-identity.v1"
    }

    // MARK: Secret vaults

    /// Mera's `PasskeySecretVault` v1, byte-compatible with `parseSecretVault` / `decryptSecretVaultWithPasskey`.
    public struct SecretVault: Codable, Equatable, Sendable {
        public struct Credential: Codable, Equatable, Sendable {
            public var credentialId: String
            public var transports: [String]?
            public init(credentialId: String, transports: [String]? = nil) { self.credentialId = credentialId; self.transports = transports }
        }
        public var version: Int
        public var credential: Credential
        /// The vault's own random 32-byte PRF salt (base64url): the passkey is evaluated with it to unlock this vault.
        public var prfSalt: String
        public var nonce: String
        public var ciphertext: String

        public var prfSaltData: Data? { Base64URL.decode(prfSalt) }
        public var isWellFormed: Bool {
            version == 1 && (Base64URL.decode(credential.credentialId)?.count ?? 0) >= 1 && prfSaltData?.count == 32
                && Base64URL.decode(nonce)?.count == 12 && (Base64URL.decode(ciphertext)?.count ?? 0) >= 16
        }
    }

    public enum VaultError: Error, LocalizedError {
        case malformed, wrongKeyOrTampered
        public var errorDescription: String? {
            switch self {
            case .malformed: return L10n.tr("The vault is not in Mera's format.")
            case .wrongKeyOrTampered: return L10n.tr("The vault could not be opened: wrong passkey or the data was changed.")
            }
        }
    }

    public enum Vault {
        public static let info = "mera.v1.encrypt.secret"

        /// The AES-256-GCM key for a vault, from the PRF output evaluated with that vault's salt.
        public static func key(prf: Data) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: prf), salt: Data(), info: Data(info.utf8), outputByteCount: 32)
        }

        /// Seals `secret` for the passkey evaluated with `prfSalt` (whose output is `prf`). The nonce is random
        /// unless a test supplies one.
        public static func seal(secret: Data, prf: Data, prfSalt: Data, credentialID: Data, transports: [String]? = nil, nonce: Data? = nil) throws -> SecretVault {
            guard prf.count == 32, prfSalt.count == 32 else { throw VaultError.malformed }
            let iv = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
            let box = try AES.GCM.seal(secret, using: key(prf: prf), nonce: iv)
            return SecretVault(version: 1, credential: .init(credentialId: Base64URL.encode(credentialID), transports: transports),
                               prfSalt: Base64URL.encode(prfSalt), nonce: Base64URL.encode(Data(iv)), ciphertext: Base64URL.encode(box.ciphertext + box.tag))
        }

        /// Opens a vault with the PRF output the passkey returns for the vault's salt.
        public static func open(_ vault: SecretVault, prf: Data) throws -> Data {
            guard vault.isWellFormed, let nonce = Base64URL.decode(vault.nonce), let combined = Base64URL.decode(vault.ciphertext) else { throw VaultError.malformed }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: combined.dropLast(16), tag: combined.suffix(16))
            do { return try AES.GCM.open(box, using: key(prf: prf)) } catch { throw VaultError.wrongKeyOrTampered }
        }
    }

    // MARK: Encoding

    public enum Base64URL {
        public static func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        public static func decode(_ text: String) -> Data? {
            var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s.append("=") }
            return Data(base64Encoded: s)
        }
    }
}
