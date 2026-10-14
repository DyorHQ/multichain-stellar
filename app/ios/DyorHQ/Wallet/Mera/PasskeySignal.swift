import AuthenticationServices
import DyorKit
import Foundation

/// The system's signal API behind `PasskeySignaling` (DyorKit, with `PasskeySignalOutcome` and the deletion order that
/// uses it, `Mera.AccountDeletion`): `ASCredentialDataManager` from iOS 26.2, `ASCredentialUpdater` (the same call,
/// deprecated in 26.2) on iOS 26.0–26.1, nothing on iOS 18.
struct SystemPasskeySignal: PasskeySignaling {
    @discardableResult
    func reportUnknown(relyingParty: String, credentialID: Data) async -> PasskeySignalOutcome {
        do {
            if #available(iOS 26.2, *) {
                try await ASCredentialDataManager().reportUnknownPublicKeyCredential(relyingPartyIdentifier: relyingParty, credentialID: credentialID)
            } else if #available(iOS 26.0, *) {
                try await ASCredentialUpdater().reportUnknownPublicKeyCredential(relyingPartyIdentifier: relyingParty, credentialID: credentialID)
            } else {
                return .unsupported
            }
            return .reported
        } catch {
            return .failed
        }
    }
}
