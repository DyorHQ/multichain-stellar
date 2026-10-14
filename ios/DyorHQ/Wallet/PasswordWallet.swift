import Foundation

/* Deterministic email + password wallet. The private key is derived from the email + password and NEVER stored
   anywhere but this device's Keychain — the same email + password always regenerate the same wallet on any device,
   so there is no backup and no verification code at log-in. The derivation lives in DyorKit's `EmailWallet` (moved
   there unchanged from this file so its vectors are pinned by `swift test`):

     v2      every new account: the password's slow seed mixed with a server pepper (the `email-pepper` Edge
             Function), so a password can't be tested offline — each guess is a rate-limited server round-trip.
     legacy  accounts created before v2: the seed alone (a "brainwallet"). Log-in still finds them, then moves the
             email to the v2 wallet of a NEW password once the user re-verifies it (`Session.logInWithPassword` →
             `bindEmailPassword(upgradingFrom:)`), and only while the legacy wallet is empty. The old password can't
             carry over: its legacy address is public, so its seed stays guessable offline.

   A wrong password silently derives a *different* wallet, and the password cannot be reset into the same wallet.
   That is why sign-up enforces a strong password (`PasswordStrength`) and the UI is blunt that the password IS the
   wallet. Users who want stronger guarantees use a passkey or import their own key. */

/// Sign-up password rules. The password is the wallet's only secret the user holds: v2 keeps it from being guessed
/// offline, but a weak one still falls to patient online guessing (or to offline guessing if the server key ever
/// leaked), so weak passwords are rejected outright.
enum PasswordStrength {
    static let minLength = 12

    /// A 0…4 score for the strength meter.
    static func score(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        var score = 0
        if password.count >= minLength { score += 1 }
        if password.count >= 16 { score += 1 }
        if classes(password) >= 3 { score += 1 }
        if password.count >= minLength, classes(password) >= 3, !isPredictable(password) { score += 1 }
        return min(score, 4)
    }

    /// `nil` when the password is acceptable, otherwise a short reason to show and block sign-up on, in the app's
    /// language.
    static func rejection(_ password: String, email: String) -> String? {
        if password.count < minLength { return tr("Use at least \(minLength) characters.") }
        if classes(password) < 3 { return tr("Mix uppercase, lowercase, numbers and symbols (any three).") }
        if isPredictable(password) { return tr("Too predictable — avoid repeats and simple sequences.") }
        let lower = password.lowercased()
        if blocked.contains(lower) { return tr("That password is too common.") }
        // not localized: matched against what is typed, in every language
        for weak in ["password", "dyorhq", "qwerty", "letmein", "monad", "crypto", "wallet"] where lower.contains(weak) {
            return tr("Avoid common words like “\(weak)”.")
        }
        let localPart = email.split(separator: "@").first.map { $0.lowercased() } ?? ""
        if localPart.count >= 3, lower.contains(localPart) { return tr("Don’t base your password on your email.") }
        return nil
    }

    private static func classes(_ password: String) -> Int {
        var found = 0
        if password.contains(where: \.isLowercase) { found += 1 }
        if password.contains(where: \.isUppercase) { found += 1 }
        if password.contains(where: \.isNumber) { found += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) { found += 1 }
        return found
    }

    /// All one character, or a run of sequential characters (abcd / 1234) covering most of the password.
    private static func isPredictable(_ password: String) -> Bool {
        let chars = Array(password)
        if Set(chars).count <= 2 { return true }
        var longestRun = 1, run = 1
        for i in 1..<chars.count {
            guard let a = chars[i - 1].asciiValue, let b = chars[i].asciiValue else { run = 1; continue }
            if b == a + 1 || b == a - 1 { run += 1; longestRun = max(longestRun, run) } else { run = 1 }
        }
        return longestRun >= max(4, chars.count - 2)
    }

    private static let blocked: Set<String> = [
        "password123!", "password1234", "letmein12345", "qwerty123456", "iloveyou1234",
        "admin1234567", "welcome12345", "abcd1234!@#$", "aaaaaaaaaaaa", "123456789012",
    ]
}
