import CryptoKit
import Foundation
import Observation

/* The platform-independent half of a Mera passkey ceremony: what the app does with the PRF outputs an authenticator
   returned, how a new passkey is named, how a failed ceremony reads, and the rule that only one ceremony runs at a
   time. The AuthenticationServices half lives in the app (Wallet/Mera/PasskeyCeremony.swift); keeping the decisions
   here lets `swift test` pin them. */
extension Mera {
    public enum Ceremony {
        // MARK: What the outputs mean

        /// The next step after a ceremony, given the PRF outputs it returned.
        public enum Next: Equatable {
            /// Adopt the account output. `utility` is nil when the authenticator evaluated only the first salt: it is
            /// fetched with a pinned assertion when something first needs it, never with an extra prompt now.
            case adopt(account: Data, utility: Data?)
            /// The passkey was registered with PRF support but returned no output: run one pinned assertion over both
            /// salts.
            case assertPinned
            /// The provider can't evaluate PRF, so no account can come from this passkey. Stop, with no second prompt.
            case prfUnavailable
        }

        /// After registering a passkey. `supported` is the provider's `prf.isSupported`, or nil when it returned no PRF
        /// result at all. Nil counts as unsupported: a provider that ignores the extension at registration ignores it
        /// at assertion too, so a second prompt could only fail.
        public static func afterRegistration(supported: Bool?, first: Data?, second: Data?) -> Next {
            guard supported == true else { return .prfUnavailable }
            guard let account = usable(first) else { return .assertPinned }
            return .adopt(account: account, utility: usable(second))
        }

        /// After an assertion (sign-in, the registration fallback, a re-prompt): the account output, or nothing usable.
        public static func afterAssertion(first: Data?, second: Data?) -> Next {
            guard let account = usable(first) else { return .prfUnavailable }
            return .adopt(account: account, utility: usable(second))
        }

        /// A PRF output is 32 bytes; anything else counts as missing.
        public static func usable(_ output: Data?) -> Data? {
            guard let output, output.count == 32 else { return nil }
            return output
        }

        // MARK: Naming

        /// The name a new passkey is saved under, e.g. "DyorHQ · Sep 25, 2026", so several DyorHQ passkeys can be told
        /// apart in Passwords. It never carries an email address or anything else about the person.
        public static func passkeyName(createdAt date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            var calendar = locale.calendar
            calendar.timeZone = timeZone
            let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
            return "DyorHQ · \(date.formatted(style))"
        }

        // MARK: Failures

        /// What a failed ceremony means to the person.
        public enum FailureKind: Equatable {
            /// They closed the sheet: nothing to show.
            case cancelled
            /// The app isn't associated with the rpId on this device (the association file isn't served or cached yet,
            /// or the build lacks the entitlement): a setup problem, not theirs.
            case associationUnavailable
            /// Anything else, shown as a generic failure.
            case other
        }

        /// ASAuthorizationError code (domain `com.apple.AuthenticationServices.AuthorizationError`) → meaning:
        /// 1001 canceled, 1004 failed. Nothing else is special. In particular there is no error code for "no passkey"
        /// (the system sheet offers another device instead), so no message text is ever matched.
        public static func failureKind(authorizationErrorCode code: Int) -> FailureKind {
            switch code {
            case 1001: return .cancelled
            case 1004: return .associationUnavailable
            default: return .other
            }
        }

        // MARK: One at a time

        /// A second ceremony requested while one is open.
        public struct Busy: LocalizedError, Equatable {
            public init() {}
            public var errorDescription: String? { L10n.tr("A passkey prompt is already open. Finish or cancel it, then try again.") }
        }

        /// Lets one ceremony run at a time. A request made while another is open fails at once with `Busy`, instead of
        /// stacking a second system sheet or replacing the first one's pending continuation (which would never resume).
        /// A multi-step ceremony (registration plus its fallback assertion) runs inside one `run`. Observable, so a view
        /// can tell a scene made inactive by the passkey sheet from one leaving the foreground (the privacy cover).
        @Observable
        @MainActor
        public final class Gate {
            /// Whether a ceremony is open. A request refused with `Busy` doesn't change it.
            public private(set) var isBusy = false

            public init() {}

            public func run<T>(_ body: () async throws -> T) async throws -> T {
                guard !isBusy else { throw Busy() }
                isBusy = true
                defer { isBusy = false }
                return try await body()
            }
        }
    }
}

#if DEBUG
extension Mera {
    /// The math behind the app's Simulator stub authenticator (Wallet/Mera/StubPasskeyAuthenticator.swift). DEBUG only,
    /// like the stub itself, which is also Simulator-only: none of it exists in a Release build.
    public enum Stub {
        /// A PRF output from a stub credential: HMAC-SHA-256 keyed by the credential's random secret over
        /// SHA-256("WebAuthn PRF" ‖ 0x00 ‖ salt), the evaluation WebAuthn's PRF extension defines. Each salt gives an
        /// unrelated 32-byte output, and the same salt always gives the same one, as with a real passkey.
        public static func prf(secret: Data, salt: Data) -> Data {
            let input = Data(SHA256.hash(data: Data("WebAuthn PRF".utf8) + [0x00] + salt))
            return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret)))
        }

        /// Whether the stub may run: only when every RPC endpoint is on this machine (an anvil fork). Its secrets sit in
        /// plain UserDefaults, so an account it derives must never hold anything on a real network.
        public static func allows(rpcURLs: [URL]) -> Bool {
            !rpcURLs.isEmpty && rpcURLs.allSatisfy { url in
                guard let host = url.host?.lowercased() else { return false }
                return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
            }
        }

        /// Something an account the stub derived could be asked to do.
        public enum Use: Equatable, Sendable {
            case transaction(chainId: Int)
            case message
            case perplEnrolment
        }

        /// What an account the stub derived may do. `allows` runs only at ceremony time, and the key it derives sits in
        /// plain UserDefaults, so the app enforces this where it signs (`MeraSession`): a transaction for Monad's chain
        /// id only, which the local fork runs; no message, since wallet-auth would sign in to the production backend;
        /// no Perpl enrolment, which registers the key with Perpl's production API. The Bridge screen, which signs on
        /// other chains, is closed to it in the app.
        public static func permits(_ use: Use) -> Bool {
            if case .transaction(let chainId) = use { return chainId == Monad.chainId }
            return false
        }

        /// Throws `Unavailable` unless a stub account may do `use`.
        public static func require(_ use: Use) throws {
            guard permits(use) else { throw Unavailable() }
        }

        /// The one text for anything a stub account can't do: the error below, and the Bridge screen's disabled state.
        // not localized: Simulator test mode only (DEBUG builds), for developers
        public static let unavailableTitle = "Not available in Simulator test mode"

        /// A stub account asked for something outside the local fork (`permits`).
        public struct Unavailable: LocalizedError, Equatable {
            public init() {}
            public var errorDescription: String? { "\(Stub.unavailableTitle)." }
        }
    }
}
#endif
