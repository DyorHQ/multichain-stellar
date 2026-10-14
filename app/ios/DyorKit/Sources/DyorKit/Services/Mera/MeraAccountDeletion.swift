import Foundation

/* Deleting a passkey (Mera) account, the platform-independent half (MERA-PLAN §8): the order the steps run in, what
   stops it, and the copy of the screen it ends on. The AuthenticationServices signal (`SystemPasskeySignal`), the
   server calls and the screens live in the app (Wallet/Mera/PasskeySignal.swift, Profile/AccountDeletion.swift);
   keeping the order here lets `swift test` pin it. */

/// What became of a report to the credential provider.
public enum PasskeySignalOutcome: Equatable, Sendable {
    /// The system took the report. Apple doesn't confirm what the provider did with it.
    case reported
    /// iOS 18: there is no API. The person has to delete the passkey themselves.
    case unsupported
    /// The system refused the report.
    case failed
}

/// Tells the credential provider that a DyorHQ passkey is no longer valid (MERA-PLAN §8), so it stops offering it.
/// Used for account deletion, and for orphan cleanup: a passkey whose creation never derived an address.
///
/// No guarantee comes back. The passkey "may be removed or hidden" — Apple Passwords was seen moving it to its Deleted
/// list for 30 days — third-party managers act only if they opt in, and a passkey used by QR from another phone is
/// never reached. Signing out ("Forget this device") never signals: the passkey is the account.
@MainActor
public protocol PasskeySignaling {
    @discardableResult
    func reportUnknown(relyingParty: String, credentialID: Data) async -> PasskeySignalOutcome
}

extension Mera {
    public enum AccountDeletion {
        /// What the forced pinned ceremony at "Delete with Face ID" proved: the passkey it ran with and the account that
        /// passkey derives.
        public struct Confirmation: Equatable, Sendable {
            public let credentialID: Data
            public let address: Address

            public init(credentialID: Data, address: Address) {
                self.credentialID = credentialID
                self.address = address
            }
        }

        public enum Failure: LocalizedError, Equatable {
            /// The passkey that answered derives another account than the one on screen. Nothing was deleted.
            case differentAccount(expected: Address, got: Address)

            public var errorDescription: String? {
                switch self {
                case .differentAccount(let expected, let got):
                    return L10n.tr("That passkey belongs to \(got.short), not to this account (\(expected.short)). Nothing was deleted.")
                }
            }
        }

        /// A server step failed. Nothing on this phone was changed and the passkey wasn't reported, so trying again
        /// works with the same passkey.
        public struct ServerDataNotDeleted: LocalizedError {
            public let underlying: Error

            public init(underlying: Error) { self.underlying = underlying }

            public var errorDescription: String? { L10n.tr("Couldn't delete your data. Nothing on this phone was changed. Try again.") }
        }

        /// Deletes a passkey account in the only order that can't strand it:
        ///
        /// 1. `confirm`: a forced pinned ceremony, even while a session is live, that must derive `account` (the address
        ///    on screen). Its credential ID is captured here, in memory — the erase at the end forgets the stored one.
        /// 2. `deleteServerData`: the server rows, authorized by the session that ceremony opened. On failure the
        ///    deletion stops (`ServerDataNotDeleted`): the phone is untouched and the passkey is not reported, since a
        ///    passkey the provider hides could no longer sign the retry.
        /// 3. The signal, only now: `reportUnknown` for exactly `Mera.relyingParty` and the captured credential ID.
        /// 4. `eraseLocalData`, whatever the signal returned: the server data is gone either way.
        ///
        /// Returns what the signal returned, for the "Account deleted." screen (`Done`). An error from `confirm` (a
        /// cancelled prompt) is rethrown as it is, with nothing else done.
        @MainActor
        public static func run(account: Address,
                               confirm: () async throws -> Confirmation,
                               deleteServerData: () async throws -> Void,
                               signal: any PasskeySignaling,
                               eraseLocalData: () async -> Void) async throws -> PasskeySignalOutcome {
            let confirmation = try await confirm()
            guard confirmation.address == account else { throw Failure.differentAccount(expected: account, got: confirmation.address) }
            let credentialID = confirmation.credentialID
            do {
                try await deleteServerData()
            } catch {
                throw ServerDataNotDeleted(underlying: error)
            }
            let outcome = await signal.reportUnknown(relyingParty: Mera.relyingParty, credentialID: credentialID)
            await eraseLocalData()
            return outcome
        }

        /// The screen a deletion ends on, for what the signal returned. The manual steps are always there: Apple doesn't
        /// confirm the result, a third-party manager acts only if it opted in, and a passkey used by QR from another phone
        /// is never reached.
        public struct Done: Equatable, Sendable {
            public let title: String
            /// Only when the provider took the report (iOS 26): iCloud Keychain may keep the passkey a while.
            public let recentlyDeleted: String?
            /// Over the manual steps. "One step left" when the provider wasn't told (iOS 18) or refused the report.
            public let stepsHeading: String
            public let steps: [String]
            /// Whether the passkey is most likely still there (nothing took the report).
            public let passkeyRemains: Bool

            /// The steps to delete the passkey by hand, in the app's language.
            public static var manualSteps: [String] {
                [
                    L10n.string(LocalizedStringResource("Open the Passwords app › Passkeys › search \"dyorhq\" › tap the DyorHQ passkey › Edit › Delete.", bundle: L10n.kit,
                        comment: "A step to delete a passkey by hand. Passwords, Passkeys, Edit and Delete are iOS's own names: use iOS's words for them in this language; “dyorhq” is typed as it is.")),
                    L10n.tr("If your passkey is in 1Password or another app, delete it there."),
                    L10n.tr("If you signed in with a passkey from another phone, delete it on that phone."),
                ]
            }

            public init(outcome: PasskeySignalOutcome) {
                title = L10n.tr("Account deleted.")
                steps = Self.manualSteps
                switch outcome {
                case .reported:
                    recentlyDeleted = L10n.string(LocalizedStringResource("If your passkey is in iCloud Keychain, Passwords may keep it in Deleted for up to 30 days.", bundle: L10n.kit,
                        comment: "Passwords is iOS's Passwords app and Deleted its list of deleted passwords and passkeys (iOS 18 and later): use iOS's own names for them in this language."))
                    stepsHeading = L10n.tr("If your passkey still shows up")
                    passkeyRemains = false
                case .unsupported, .failed:
                    recentlyDeleted = nil
                    stepsHeading = L10n.tr("One step left: delete the passkey yourself")
                    passkeyRemains = true
                }
            }
        }
    }
}
