#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
import Observation
import XCTest
@testable import DyorKit

/// The ceremony rules in MERA-PLAN §2: what a registration or assertion result leads to, passkey names, the error
/// mapping, and one ceremony at a time.
final class MeraCeremonyTests: XCTestCase {
    let account = Data(repeating: 0xA1, count: 32)
    let utility = Data(repeating: 0xB2, count: 32)

    func testRegistrationOutcomes() {
        typealias C = Mera.Ceremony
        // Both outputs: one prompt, done.
        XCTAssertEqual(C.afterRegistration(supported: true, first: account, second: utility), .adopt(account: account, utility: utility))
        // Unsupported (or no PRF result at all): stop, no second prompt — whatever else came back.
        XCTAssertEqual(C.afterRegistration(supported: false, first: nil, second: nil), .prfUnavailable)
        XCTAssertEqual(C.afterRegistration(supported: false, first: account, second: utility), .prfUnavailable)
        XCTAssertEqual(C.afterRegistration(supported: nil, first: nil, second: nil), .prfUnavailable)
        // Supported but the first output is missing (or malformed): one pinned fallback assertion.
        XCTAssertEqual(C.afterRegistration(supported: true, first: nil, second: nil), .assertPinned)
        XCTAssertEqual(C.afterRegistration(supported: true, first: nil, second: utility), .assertPinned)
        XCTAssertEqual(C.afterRegistration(supported: true, first: Data(repeating: 1, count: 31), second: nil), .assertPinned)
        // Second missing: carry on; the utility output is fetched later.
        XCTAssertEqual(C.afterRegistration(supported: true, first: account, second: nil), .adopt(account: account, utility: nil))
        XCTAssertEqual(C.afterRegistration(supported: true, first: account, second: Data()), .adopt(account: account, utility: nil))
    }

    func testAssertionOutcomes() {
        typealias C = Mera.Ceremony
        XCTAssertEqual(C.afterAssertion(first: account, second: utility), .adopt(account: account, utility: utility))
        XCTAssertEqual(C.afterAssertion(first: account, second: nil), .adopt(account: account, utility: nil))
        // An assertion never leads to another prompt: no account output is the end.
        XCTAssertEqual(C.afterAssertion(first: nil, second: utility), .prfUnavailable)
        XCTAssertEqual(C.afterAssertion(first: Data(repeating: 1, count: 33), second: nil), .prfUnavailable)
    }

    func testPasskeyNamesCarryTheDateAndNothingPersonal() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(Mera.Ceremony.passkeyName(createdAt: date, locale: Locale(identifier: "en_US"), timeZone: utc), "DyorHQ · Sep 25, 2026")
        // The date is the creation day where the person is, not in UTC.
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let late = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T20:00:00Z"))
        XCTAssertEqual(Mera.Ceremony.passkeyName(createdAt: late, locale: Locale(identifier: "en_US"), timeZone: tokyo), "DyorHQ · Sep 26, 2026")
        // Localised, and always under the DyorHQ prefix.
        let german = Mera.Ceremony.passkeyName(createdAt: date, locale: Locale(identifier: "de_DE"), timeZone: utc)
        XCTAssertTrue(german.hasPrefix("DyorHQ · "))
        XCTAssertTrue(german.contains("2026"))
        XCTAssertFalse(german.contains("@"))
    }

    func testFailureMapping() {
        typealias C = Mera.Ceremony
        XCTAssertEqual(C.failureKind(authorizationErrorCode: 1001), .cancelled)
        XCTAssertEqual(C.failureKind(authorizationErrorCode: 1004), .associationUnavailable)
        for code in [1000, 1002, 1003, 1005, 1006, 1007, 1008, 1009, 1010, 0, -1] {
            XCTAssertEqual(C.failureKind(authorizationErrorCode: code), .other, "code \(code)")
        }
        #if canImport(AuthenticationServices)
        // The raw codes are Apple's.
        XCTAssertEqual(C.failureKind(authorizationErrorCode: ASAuthorizationError.Code.canceled.rawValue), .cancelled)
        XCTAssertEqual(C.failureKind(authorizationErrorCode: ASAuthorizationError.Code.failed.rawValue), .associationUnavailable)
        XCTAssertEqual(C.failureKind(authorizationErrorCode: ASAuthorizationError.Code.unknown.rawValue), .other)
        #endif
    }

    /// A second ceremony while one is open fails at once; the gate reopens when the first ends, however it ends.
    @MainActor
    func testGateRunsOneCeremonyAtATime() async throws {
        let gate = Mera.Ceremony.Gate()
        var release: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            try await gate.run { await withCheckedContinuation { release = $0 }; return 1 }
        }
        while release == nil { await Task.yield() }
        XCTAssertTrue(gate.isBusy)
        do {
            _ = try await gate.run { 2 }
            XCTFail("a concurrent ceremony must fail")
        } catch {
            XCTAssertEqual(error as? Mera.Ceremony.Busy, Mera.Ceremony.Busy())
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        release?.resume()
        let value = try await first.value
        XCTAssertEqual(value, 1)
        XCTAssertFalse(gate.isBusy)
        // A ceremony that throws releases the gate too.
        struct Boom: Error {}
        do { _ = try await gate.run { () async throws -> Int in throw Boom() } } catch { XCTAssertTrue(error is Boom) }
        XCTAssertFalse(gate.isBusy)
        let next = try await gate.run { 3 }
        XCTAssertEqual(next, 3)
    }

    /// `isBusy` is observable (the app's privacy cover follows it): opening and closing a ceremony each notify, and a
    /// request refused with `Busy` leaves it alone.
    @MainActor
    func testGateBusyStateIsObservable() async throws {
        let gate = Mera.Ceremony.Gate()
        var changes = 0
        func track() { withObservationTracking { _ = gate.isBusy } onChange: { changes += 1 } }
        track()
        var release: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            try await gate.run { await withCheckedContinuation { release = $0 } }
        }
        while release == nil { await Task.yield() }
        XCTAssertEqual(changes, 1)
        track()
        _ = try? await gate.run { () }
        XCTAssertEqual(changes, 1, "a refused request must not touch isBusy")
        release?.resume()
        try await first.value
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(gate.isBusy)
    }

    #if DEBUG
    /// The Simulator stub's PRF behaves like a real one: per-salt, deterministic, unrelated across secrets and salts.
    func testStubPRF() {
        let secret = Data(repeating: 7, count: 32)
        let a = Mera.Stub.prf(secret: secret, salt: Mera.accountSalt)
        let u = Mera.Stub.prf(secret: secret, salt: Mera.utilitySalt)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(u.count, 32)
        XCTAssertNotEqual(a, u)
        XCTAssertEqual(a, Mera.Stub.prf(secret: secret, salt: Mera.accountSalt))
        XCTAssertNotEqual(a, Mera.Stub.prf(secret: Data(repeating: 8, count: 32), salt: Mera.accountSalt))
        XCTAssertNotNil(Mera.evmAccount(prf: a))
    }

    /// The stub refuses anything but a local fork.
    func testStubRunsOnlyAgainstLocalRPC() {
        func allows(_ urls: String...) -> Bool { Mera.Stub.allows(rpcURLs: urls.compactMap(URL.init(string:))) }
        XCTAssertTrue(allows("http://127.0.0.1:8545"))
        XCTAssertTrue(allows("http://localhost:8545"))
        XCTAssertTrue(allows("http://[::1]:8545"))
        XCTAssertFalse(allows())
        XCTAssertFalse(Mera.Stub.allows(rpcURLs: Monad.publicRPCs))
        XCTAssertFalse(allows("http://127.0.0.1:8545", "https://rpc.monad.xyz"))
        XCTAssertFalse(allows("http://localhost.example.com:8545"))
        XCTAssertFalse(allows("http://127.0.0.1.nip.io:8545"))
        XCTAssertFalse(allows("http://10.0.0.5:8545"))
    }

    /// A stub account is confined to the local fork: transactions for Monad's chain id (the fork's) and nothing else —
    /// no other chain the Bridge reaches, no message (production wallet-auth), no Perpl enrolment.
    func testStubAccountConfinedToLocalFork() {
        XCTAssertTrue(Mera.Stub.permits(.transaction(chainId: 143)))
        XCTAssertTrue(Mera.Stub.permits(.transaction(chainId: Monad.chainId)))
        for chain in EVMChain.supported where !chain.isMonad {
            XCTAssertFalse(Mera.Stub.permits(.transaction(chainId: chain.chainId)), chain.name)
        }
        for chainId in [0, 1, 10143, 31337, -143, Int.max] {
            XCTAssertFalse(Mera.Stub.permits(.transaction(chainId: chainId)), "\(chainId)")
        }
        XCTAssertFalse(Mera.Stub.permits(.message))
        XCTAssertFalse(Mera.Stub.permits(.perplEnrolment))

        XCTAssertNoThrow(try Mera.Stub.require(.transaction(chainId: Monad.chainId)))
        for use in [Mera.Stub.Use.transaction(chainId: 8453), .message, .perplEnrolment] {
            XCTAssertThrowsError(try Mera.Stub.require(use)) { error in
                XCTAssertEqual(error as? Mera.Stub.Unavailable, Mera.Stub.Unavailable())
                XCTAssertEqual(error.localizedDescription, "Not available in Simulator test mode.")
            }
        }
    }
    #endif
}
