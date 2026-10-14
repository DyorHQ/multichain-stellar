import Foundation
import LocalAuthentication

/// What this device's owner check asks for, as App Lock and the passkey prompts name it: Face ID, Touch ID or Optic ID,
/// or the device passcode when no biometrics are enrolled. The app reads it from the device once
/// (`BiometricGate.promptKind`); the prompt's icon and its name both come from the kind, so the icon never depends on
/// text that is translated.
public enum BiometricPromptKind: Sendable, CaseIterable {
    case faceID, touchID, opticID, passcode

    /// The kind for a device that can (or can't) evaluate biometrics, with the biometry it reports. Without biometrics a
    /// passkey or App Lock takes the device passcode.
    public init(biometricsAvailable: Bool, biometry: LABiometryType) {
        guard biometricsAvailable else { self = .passcode; return }
        switch biometry {
        case .faceID: self = .faceID
        case .touchID: self = .touchID
        case .opticID: self = .opticID
        default: self = .passcode
        }
    }

    /// The prompt's SF Symbol.
    public var symbol: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode: "lock"
        }
    }

    /// The prompt's name in copy like "Confirm with Face ID": Apple's names stay as they are in every language, and
    /// "Passcode" is in the app's language.
    public var name: String {
        switch self {
        case .faceID: "Face ID" // not localized: Apple's name
        case .touchID: "Touch ID" // not localized: Apple's name
        case .opticID: "Optic ID" // not localized: Apple's name
        case .passcode: L10n.string(LocalizedStringResource("Passcode", bundle: L10n.kit, comment: "The device passcode, named where a passkey or App Lock asks for it: “Confirm with Passcode”."))
        }
    }
}
