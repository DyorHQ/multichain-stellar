import Foundation
import LocalAuthentication
import XCTest
@testable import DyorKit

/// `FailureKind`: a cancelled request and a lost connection are told by the error's type, or its domain and code, never by
/// its text. They are the system errors the app's `describe(_:)` used to recognise by their English text, so English
/// reads as before, and nothing else is caught.
final class FailureKindTests: XCTestCase {
    func testCancelledByTypeAndCode() {
        XCTAssertEqual(FailureKind.of(CancellationError()), .cancelled)
        XCTAssertEqual(FailureKind.of(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(FailureKind.of(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)), .cancelled)
        for code in [LAError.userCancel, .systemCancel, .appCancel] {
            XCTAssertEqual(FailureKind.of(LAError(code)), .cancelled, "\(code)")
        }
        XCTAssertEqual(FailureKind.of(CocoaError(.userCancelled)), .cancelled)
        // A prompt that failed or fell back is not a cancellation.
        for code in [LAError.authenticationFailed, .userFallback, .passcodeNotSet] {
            XCTAssertEqual(FailureKind.of(LAError(code)), .other, "\(code)")
        }
        XCTAssertEqual(FailureKind.cancelledCodes["com.apple.LocalAuthentication"], [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue])
        XCTAssertEqual(LAError.errorDomain, "com.apple.LocalAuthentication")
    }

    func testOfflineByCode() {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost] {
            XCTAssertEqual(FailureKind.of(URLError(code)), .offline, "\(code)")
        }
        XCTAssertEqual(FailureKind.of(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)), .offline)
        // A server that doesn't answer is not this device being offline, and iOS's own words for cellular data turned off
        // say more than "No connection" would.
        for code in [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .badServerResponse, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed] {
            XCTAssertEqual(FailureKind.of(URLError(code)), .other, "\(code)")
        }
    }

    /// The text never decides: an error that only says "cancelled" or "offline" in its description is any other error, and
    /// so is a DyorKit error (it has a description of its own, which `describe(_:)` shows first).
    func testNeverByText() {
        let worded = NSError(domain: "com.example", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cancelled: the network is offline."])
        XCTAssertEqual(FailureKind.of(worded), .other)
        XCTAssertEqual(FailureKind.of(RPCError(code: -32000, message: "request cancelled, network offline")), .other)
        XCTAssertEqual(FailureKind.of(NetworkError.badStatus(503)), .other)
        XCTAssertEqual(FailureKind.of(NSError(domain: "com.example", code: NSURLErrorCancelled)), .other, "the code counts in its own domain only")
    }
}
