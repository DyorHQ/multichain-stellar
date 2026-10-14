import Foundation

/// What a system failure means for the person who met it, told by the error's domain and code, never by its text: iOS
/// writes an error's description in the device's language, which need not be the app's, and its wording changes between
/// releases. The app's `describe(_:)` names these two in the app's own words for an error that has no description of its
/// own (one that isn't a `LocalizedError`). They are the errors whose English text it used to match ("cancelled",
/// "Canceled by user.", "The Internet connection appears to be offline.", "The network connection was lost."), so
/// English reads as before; anything else keeps the description iOS gives it.
public enum FailureKind: Equatable, Sendable {
    /// Cancelled: a task, a URL request, a Face ID or passcode prompt, or an operation the user cancelled.
    case cancelled
    /// No connection: the device is offline, or its connection dropped during the request.
    case offline
    /// Anything else, a server that doesn't answer included.
    case other

    /// The kind of `error`, by its type, or its domain and code.
    public static func of(_ error: Error) -> FailureKind {
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if cancelledCodes[ns.domain]?.contains(ns.code) == true { return .cancelled }
        if offlineCodes[ns.domain]?.contains(ns.code) == true { return .offline }
        return .other
    }

    /// The codes, by error domain, of a cancellation: a URL request cancelled; a Face ID or passcode prompt cancelled by
    /// the user, the system or the app (LocalAuthentication's -2, -4 and -9); an operation the user cancelled.
    static let cancelledCodes: [String: Set<Int>] = [
        NSURLErrorDomain: [URLError.Code.cancelled.rawValue],
        "com.apple.LocalAuthentication": [-2, -4, -9], // not localized: LAError's domain
        NSCocoaErrorDomain: [CocoaError.Code.userCancelled.rawValue],
    ]

    /// The URL loading codes of a device that can't reach the network: no internet, or the connection lost. A server that
    /// doesn't answer (a timeout, an unknown host) is not the device being offline, and cellular data turned off says so
    /// itself.
    static let offlineCodes: [String: Set<Int>] = [
        NSURLErrorDomain: [URLError.Code.notConnectedToInternet.rawValue, URLError.Code.networkConnectionLost.rawValue],
    ]
}
