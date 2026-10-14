import XCTest
@testable import DyorKit

/// Deleting a passkey account (MERA-PLAN §8): the owner confirms first, the server rows go next, the passkey provider
/// hears about it only after they are gone — for exactly DyorHQ's rpId and the credential the confirmation captured —
/// and the phone is erased last. A server failure leaves the phone untouched and sends nothing.
@MainActor
final class MeraAccountDeletionTests: XCTestCase {
    enum Step: Equatable {
        case confirm, server, signal(relyingParty: String, credentialID: Data), erase
    }

    /// Records every report and answers with `outcome`.
    final class SpySignal: PasskeySignaling {
        var outcome: PasskeySignalOutcome = .reported
        var onReport: ((String, Data) -> Void)?
        private(set) var reports: [(relyingParty: String, credentialID: Data)] = []

        func reportUnknown(relyingParty: String, credentialID: Data) async -> PasskeySignalOutcome {
            reports.append((relyingParty, credentialID))
            onReport?(relyingParty, credentialID)
            return outcome
        }
    }

    struct ServerDown: Error {}

    let account = Address("0x9858effd232b4033e47d90003d41ec34ecaeda94")!
    let other = Address("0x6fac4d18c912343bf86fa7049364dd4e424ab9c0")!
    let credentialID = Data([0xC0, 0xFF, 0xEE, 0x01, 0x02])

    /// Runs a deletion that logs each step; `stored` stands for `MeraCredentialStore`, which the erase clears.
    private func delete(confirmsAs confirmed: Address? = nil, confirmFails: Error? = nil, serverFails: Bool = false,
                        signal: SpySignal, log: inout [Step]) async throws -> PasskeySignalOutcome {
        var steps: [Step] = []
        var stored: Data? = credentialID
        signal.onReport = { steps.append(.signal(relyingParty: $0, credentialID: $1)) }
        defer { log = steps }
        return try await Mera.AccountDeletion.run(
            account: account,
            confirm: {
                steps.append(.confirm)
                if let confirmFails { throw confirmFails }
                return Mera.AccountDeletion.Confirmation(credentialID: stored!, address: confirmed ?? account)
            },
            deleteServerData: {
                steps.append(.server)
                if serverFails { throw ServerDown() }
            },
            signal: signal,
            eraseLocalData: {
                steps.append(.erase)
                stored = nil
            })
    }

    func testServerDeleteThenSignalThenErase() async throws {
        let signal = SpySignal()
        var log: [Step] = []
        let outcome = try await delete(signal: signal, log: &log)
        XCTAssertEqual(log, [.confirm, .server, .signal(relyingParty: "accounts.dyorhq.fun", credentialID: credentialID), .erase])
        XCTAssertEqual(outcome, .reported)
        XCTAssertEqual(signal.reports.count, 1)
    }

    func testSignalUsesTheRelyingPartyAndTheCapturedCredentialID() async throws {
        let signal = SpySignal()
        var log: [Step] = []
        _ = try await delete(signal: signal, log: &log)
        let report = try XCTUnwrap(signal.reports.first)
        XCTAssertEqual(report.relyingParty, Mera.relyingParty)
        XCTAssertEqual(report.relyingParty, "accounts.dyorhq.fun")
        // The ID the confirmation captured, not whatever the store holds by then: the erase clears it afterwards.
        XCTAssertEqual(report.credentialID, credentialID)
    }

    func testServerFailureLeavesThePhoneUntouchedAndSendsNoSignal() async {
        let signal = SpySignal()
        var log: [Step] = []
        do {
            _ = try await delete(serverFails: true, signal: signal, log: &log)
            XCTFail("a failed server delete must stop the deletion")
        } catch let error as Mera.AccountDeletion.ServerDataNotDeleted {
            XCTAssertTrue(error.underlying is ServerDown)
            XCTAssertEqual(error.errorDescription, "Couldn't delete your data. Nothing on this phone was changed. Try again.")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(log, [.confirm, .server])
        XCTAssertTrue(signal.reports.isEmpty)
    }

    func testCancelledConfirmationDoesNothing() async {
        let signal = SpySignal()
        var log: [Step] = []
        do {
            _ = try await delete(confirmFails: CancellationError(), signal: signal, log: &log)
            XCTFail("a cancelled prompt must stop the deletion")
        } catch {
            // Rethrown as it is, so the sheet can tell a cancel from a failure.
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(log, [.confirm])
        XCTAssertTrue(signal.reports.isEmpty)
    }

    func testAPasskeyForAnotherAccountDeletesNothing() async {
        let signal = SpySignal()
        var log: [Step] = []
        do {
            _ = try await delete(confirmsAs: other, signal: signal, log: &log)
            XCTFail("a passkey that derives another account must stop the deletion")
        } catch {
            XCTAssertEqual(error as? Mera.AccountDeletion.Failure, .differentAccount(expected: account, got: other))
        }
        XCTAssertEqual(log, [.confirm])
        XCTAssertTrue(signal.reports.isEmpty)
    }

    func testThePhoneIsErasedWhateverTheSignalReturns() async throws {
        for outcome: PasskeySignalOutcome in [.reported, .unsupported, .failed] {
            let signal = SpySignal()
            signal.outcome = outcome
            var log: [Step] = []
            let returned = try await delete(signal: signal, log: &log)
            XCTAssertEqual(returned, outcome)
            XCTAssertEqual(log.last, .erase, "\(outcome)")
            XCTAssertEqual(log.count, 4, "\(outcome)")
        }
    }

    func testDoneScreenCopy() {
        typealias Done = Mera.AccountDeletion.Done
        let steps = [
            "Open the Passwords app › Passkeys › search \"dyorhq\" › tap the DyorHQ passkey › Edit › Delete.",
            "If your passkey is in 1Password or another app, delete it there.",
            "If you signed in with a passkey from another phone, delete it on that phone.",
        ]
        // iOS 26: the provider took the report. The note on the Passwords app's Deleted list, and the steps in case it still
        // shows.
        let reported = Done(outcome: .reported)
        XCTAssertEqual(reported.title, "Account deleted.")
        XCTAssertEqual(reported.recentlyDeleted, "If your passkey is in iCloud Keychain, Passwords may keep it in Deleted for up to 30 days.")
        XCTAssertEqual(reported.steps, steps)
        XCTAssertFalse(reported.passkeyRemains)
        // iOS 18 has no signal, and a refused report reached nothing: the steps are the one step left.
        for outcome: PasskeySignalOutcome in [.unsupported, .failed] {
            let done = Done(outcome: outcome)
            XCTAssertEqual(done.title, "Account deleted.")
            XCTAssertNil(done.recentlyDeleted)
            XCTAssertEqual(done.stepsHeading, "One step left: delete the passkey yourself")
            XCTAssertEqual(done.steps, steps)
            XCTAssertTrue(done.passkeyRemains)
        }
    }
}
