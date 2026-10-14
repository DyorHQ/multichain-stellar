import BigInt
import CommonCrypto
import CryptoKit
import Foundation

/* The email + password wallet's key derivation. Two generations share one slow step:

     S       PBKDF2-HMAC-SHA256(password, salt: sha256("dyorhq.email-password.v1|" + email), 1,000,000 rounds), 32 bytes
     legacy  S → BIP-39 (24 words) → seed → BIP-32 m/44'/60'/0'/0/0        — accounts created before v2
     v2      e = sha256("dyorhq/email-pepper/v1/email:" + email)
             t = sha256("dyorhq/email-pepper/v1/t:" || S)
             p = the `email-pepper` Edge Function's HMAC of (e, t) under a key only the server holds
             key = HKDF-SHA256(ikm: S || p, salt: "dyorhq/email-wallet/v2", info: "secp256k1"), 32 bytes

   The legacy wallet is a brainwallet: anyone who knows the email can test password guesses offline. v2 mixes in p,
   which only the server can compute, so every guess costs a rate-limited server round-trip. The server sees only e
   and t — hashes, never the email, the password or S — so a compromised server is no better off than an attacker is
   against the legacy scheme. Every constant here is part of the derived addresses: never change one. Test vectors
   (EmailWalletTests) were computed independently with Python's hashlib/hmac and eth_account. */
public enum EmailWallet {
    /// Legacy domain separation + version (the PBKDF2 salt prefix). Defines every legacy address.
    private static let legacyVersion = "dyorhq.email-password.v1"
    /// PBKDF2-HMAC-SHA256 rounds for S: an offline guess costs ~a second on commodity hardware, a single on-device
    /// derivation stays well under one.
    private static let iterations: UInt32 = 1_000_000
    private static let pepperEmailLabel = "dyorhq/email-pepper/v1/email:"
    private static let pepperSeedLabel = "dyorhq/email-pepper/v1/t:"
    private static let v2Salt = "dyorhq/email-wallet/v2"
    private static let v2Info = "secp256k1"
    /// How many HKDF candidates to try before giving up. A candidate is invalid with probability ~2⁻¹²⁸, so the
    /// bound is never reached in practice; it only keeps a broken validity check from looping forever.
    static let maxV2Attempts = 256

    /// The email exactly as the derivation sees it: trimmed and lowercased. The `email-pepper` function replicates
    /// this exactly (its `normalizeEmail`); change neither.
    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Legacy (and v2's input)

    /// S: the slow, password-derived 32-byte seed both generations start from. Pure and deterministic; takes ~a
    /// second, so run it off the main actor. Nil for an empty email or password.
    public static func legacySeed(email: String, password: String) -> Data? {
        let normalizedEmail = normalize(email)
        guard !normalizedEmail.isEmpty, !password.isEmpty else { return nil }
        // Salt binds the key to this app + version + the exact email, so the same password under different emails
        // yields different wallets and a single rainbow table can't cover every user.
        let salt = Data(SHA256.hash(data: Data("\(legacyVersion)|\(normalizedEmail)".utf8)))
        return pbkdf2(password: Data(password.utf8), salt: salt, keyLength: 32)
    }

    /// The legacy wallet for S: seed (32 bytes) → BIP-39 (24 words) → seed → BIP-32 m/44'/60'/0'/0/0.
    public static func legacyAccount(seed: Data) -> Secp256k1Account? {
        Mera.evmAccount(prf: seed)
    }

    // MARK: v2 (server-peppered)

    /// What the `email-pepper` function is sent: e names the email, t commits to S. Both are one-way hashes.
    public static func pepperInput(email: String, seed: Data) -> (e: Data, t: Data) {
        let t = Data(SHA256.hash(data: Data(pepperSeedLabel.utf8) + seed))
        return (emailHash(email), t)
    }

    /// e alone: SHA256("dyorhq/email-pepper/v1/email:" + normalized email). `email-pepper` recomputes it from the
    /// email a Privy one-time-code token attests before it lets that token pay from the email's verified budget, so
    /// the server's normalisation must equal `normalize` byte for byte — Fixtures/email-pepper.json pins both sides.
    public static func emailHash(_ email: String) -> Data {
        Data(SHA256.hash(data: Data((pepperEmailLabel + normalize(email)).utf8)))
    }

    /// The v2 private key: HKDF-SHA256(S || p). A candidate that is not a valid secp256k1 scalar (0 or ≥ n) is
    /// skipped by re-deriving with info "secp256k1/1", "secp256k1/2", …. `isValid` is injectable only for tests.
    public static func v2PrivateKey(seed: Data, pepper: Data,
                                    isValid: (Data) -> Bool = isValidPrivateKey) -> Data? {
        let ikm = SymmetricKey(data: seed + pepper)
        for attempt in 0..<maxV2Attempts {
            let info = attempt == 0 ? v2Info : "\(v2Info)/\(attempt)"
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data(v2Salt.utf8), info: Data(info.utf8),
                                             outputByteCount: 32)
            let candidate = key.withUnsafeBytes { Data($0) }
            if isValid(candidate) { return candidate }
        }
        return nil
    }

    /// The v2 wallet for S and the server pepper p.
    public static func v2Account(seed: Data, pepper: Data) -> Secp256k1Account? {
        v2PrivateKey(seed: seed, pepper: pepper).flatMap { Secp256k1Account(privateKey: $0) }
    }

    // MARK: Input hygiene and history

    /// Whether `password` holds anything outside printable ASCII — curly quotes and long dashes from smart punctuation,
    /// letters with accents, a non-breaking space, emoji — which another keyboard or device may type as different bytes
    /// (security audit 2026-09-26, IOSK-9). The derivation always uses the exact bytes typed: normalising them would move
    /// every existing wallet with such a password to another address. So sign-up only warns.
    public static func hasHardToRetypeCharacters(_ password: String) -> Bool {
        password.unicodeScalars.contains { !(0x20...0x7E).contains($0.value) }
    }

    /// Before this instant an email account may still be bound to its legacy (pre-v2) wallet: build 13, the first to
    /// derive v2 wallets, reached TestFlight on the evening of 2026-09-23 (UTC), and older builds could no longer sign in
    /// from then on. Rounded up to the next midnight, so a legacy wallet is never taken for a v2 one.
    public static let v2Cutoff = Date(timeIntervalSince1970: 1_790_208_000) // 2026-09-24T00:00:00Z

    /// Whether the wallet an email is bound to may be a legacy (pre-v2) one, judged by when its public profile was
    /// created: nil (no profile, or it couldn't be read) counts as maybe, so a funded legacy wallet is never let go of
    /// by mistake (GE-1).
    public static func mayBeLegacy(profileCreatedAt: Date?) -> Bool {
        guard let created = profileCreatedAt else { return true }
        return created < v2Cutoff
    }

    /// A usable secp256k1 private key: 32 bytes, 1 ≤ k < n.
    public static func isValidPrivateKey(_ key: Data) -> Bool {
        guard key.count == 32 else { return false }
        let scalar = BigUInt(key)
        return scalar > 0 && scalar < Secp256k1Account.curveOrder
    }

    private static func pbkdf2(password: Data, salt: Data, keyLength: Int) -> Data? {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }
}
