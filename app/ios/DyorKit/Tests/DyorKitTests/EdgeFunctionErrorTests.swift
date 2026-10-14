import Foundation
import XCTest
@testable import DyorKit

/// The Edge Functions' refusals the app knows (`EdgeFunctionError`): each matched English text is still what the function
/// sends, English reads as the screens showed it before, and a text the app doesn't know is shown as the server wrote it.
final class EdgeFunctionErrorTests: XCTestCase {
    /// A function's source (supabase/functions/<name>/index.ts).
    static func function(_ name: String) throws -> String {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios → repo
        let file = repo.appendingPathComponent("supabase/functions/\(name)/index.ts")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("supabase/functions is not in this checkout") }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The text the sign-up, reset and upgrade screens made of a refusal before: a capital and a full stop.
    private static func sentence(_ error: String) -> String {
        let capped = error.prefix(1).uppercased() + error.dropFirst()
        return capped.hasSuffix(".") ? capped : capped + "."
    }

    func testEmailRebindRefusals() throws {
        let known = ["missing Privy access token", "invalid Privy access token", "this reset expired — start again", "invalid wallet signature",
                     "wallet signature did not match", "too many attempts — try again in a few minutes",
                     "no verified email on this Privy account", "the code you entered was for a different email"]
        let source = try Self.function("email-rebind")
        for error in known {
            XCTAssertTrue(source.contains("\"\(error)\""), "email-rebind no longer sends \"\(error)\"")
            XCTAssertEqual(EdgeFunctionError.emailRebind(error), Self.sentence(error), "English as before")
        }
        XCTAssertEqual(EdgeFunctionError.emailRebind("something new"), "Something new.", "an unknown text as the server wrote it")
        XCTAssertEqual(EdgeFunctionError.emailRebind("Done."), "Done.")
    }

    func testDeleteAccountRefusals() throws {
        let known = ["too many attempts — try again in a few minutes", "account deletion is unavailable right now — try again in a minute",
                     "account deletion failed — contact support", "missing access token", "server not configured",
                     "sign in again to delete your account", "a signed-in wallet session is required"]
        let source = try Self.function("delete-account")
        for error in known {
            XCTAssertTrue(source.contains("\"\(error)\""), "delete-account no longer sends \"\(error)\"")
            XCTAssertEqual(EdgeFunctionError.deleteAccount(error), error, "English as before")
        }
        XCTAssertEqual(EdgeFunctionError.deleteAccount("something new"), "something new")
    }
}
