import XCTest
@testable import DyorKit

/// The client side of the backend's sign-in and email-pepper contracts: the server-issued single-use nonce, the exact
/// message the wallet signs, the email-pepper request, and how refusals and rate limits map to user-facing errors.
final class WalletAuthClientTests: XCTestCase {
    private let base = "https://fmnjqrguvopusfufmirs.supabase.co"
    private lazy var backend = SupabaseClient(url: URL(string: base)!, anonKey: "sb_publishable_test", session: WalletAuthCapture.session())
    private let account = Secp256k1Account(privateKeyHex: "0x" + String(repeating: "11", count: 32))!
    private let serverNonce = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

    /// The backend's anchored EIP-4361 template (wallet-auth `sign_in.ts`), with the same capture groups: address, nonce,
    /// Issued At, Expiration Time.
    private let template = try! NSRegularExpression(pattern:
        #"^dyorhq\.fun wants you to sign in with your Ethereum account:\n(0x[0-9a-fA-F]{40})\n\nSign in to DyorHQ\.\n\n"# +
        #"URI: https://dyorhq\.fun\nVersion: 1\nChain ID: 143\nNonce: ([0-9a-f]{64})\n"# +
        #"Issued At: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)\nExpiration Time: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)$"#)

    override func setUp() {
        super.setUp()
        WalletAuthCapture.reset()
    }

    private final class Signed { var messages: [Data] = [] }

    private func json(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: WalletAuthCapture.body(request)) as? [String: Any]) ?? [:]
    }

    private func matchesTemplate(_ message: String) -> [String]? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = template.firstMatch(in: message, range: range), match.range == range else { return nil }
        return (1...4).map { String(message[Range(match.range(at: $0), in: message)!]) }
    }

    // MARK: Sign-in message

    /// The IOSK-7 SIWE contract, byte for byte (the same text as wallet-auth's sign_in_test.ts).
    func testSignInMessageIsTheExactTemplate() {
        let address = "0x52908400098527886E0F7030069857D2E4169EE7" // an EIP-55 test vector
        let issued = 1_790_424_000_000 // 2026-09-26T12:00:00.000Z
        let message = SupabaseClient.signInMessage(address: address, nonce: serverNonce, issuedAt: issued)
        XCTAssertEqual(message, [
            "dyorhq.fun wants you to sign in with your Ethereum account:",
            address,
            "",
            "Sign in to DyorHQ.",
            "",
            "URI: https://dyorhq.fun",
            "Version: 1",
            "Chain ID: 143",
            "Nonce: \(serverNonce)",
            "Issued At: 2026-09-26T12:00:00.000Z",
            "Expiration Time: 2026-09-26T12:10:00.000Z",
        ].joined(separator: "\n"))
        XCTAssertEqual(matchesTemplate(message), [address, serverNonce, "2026-09-26T12:00:00.000Z", "2026-09-26T12:10:00.000Z"])
        XCTAssertFalse(message.hasSuffix("\n"))
        XCTAssertFalse(message.contains("\r"))
    }

    /// Timestamps are JavaScript's `toISOString` form, from integer milliseconds, and only that form parses back.
    func testSignInTimestampsMatchToISOString() {
        XCTAssertEqual(SupabaseClient.iso8601(millis: 1_758_600_000_123), "2025-09-23T04:00:00.123Z")
        XCTAssertEqual(SupabaseClient.iso8601(millis: 1_790_424_000_007), "2026-09-26T12:00:00.007Z")
        XCTAssertEqual(SupabaseClient.iso8601(millis: 1_790_424_059_999), "2026-09-26T12:00:59.999Z")
        XCTAssertEqual(SupabaseClient.iso8601(millis: 0), "1970-01-01T00:00:00.000Z")
        for millis in [0, 1_758_600_000_123, 1_790_424_000_007, 1_790_424_059_999, 1_709_164_800_000 /* 2024-02-29 */] {
            XCTAssertEqual(SupabaseClient.millis(iso8601: SupabaseClient.iso8601(millis: millis)), millis)
        }
        for bad in ["2026-09-26T12:00:00Z", "2026-09-26T12:00:00.000+00:00", "2026-02-30T12:00:00.000Z", "2026-09-26T24:00:00.000Z",
                    "2026-09-26T12:00:00.0000Z", "2026-09-26 12:00:00.000Z", "2026-09-26T12:00:00.000z", "", "２026-09-26T12:00:00.000Z"] {
            XCTAssertNil(SupabaseClient.millis(iso8601: bad), bad)
        }
    }

    /// The message names the wallet with its EIP-55 checksum even when the request's address is lowercase.
    func testSignInMessageChecksumsTheAddress() async throws {
        let address = account.address.checksummed
        WalletAuthCapture.replies = [
            (200, #"{"nonce":"\#(serverNonce)","expiresAt":1758600300000}"#),
            (200, #"{"access_token":"session.jwt","token_type":"bearer","expires_in":43200,"wallet":"\#(address.lowercased())"}"#),
        ]
        _ = try await backend.signIn(address: address.lowercased()) { try self.account.signMessage($0) }
        let authBody = json(WalletAuthCapture.requests[1])
        XCTAssertEqual(authBody["address"] as? String, address.lowercased())
        let fields = try XCTUnwrap(matchesTemplate(try XCTUnwrap(authBody["message"] as? String)))
        XCTAssertEqual(fields[0], address)
    }

    func testSignInSignsTheServerNonce() async throws {
        let address = account.address.checksummed
        WalletAuthCapture.replies = [
            (200, #"{"nonce":"\#(serverNonce)","expiresAt":1758600300000}"#),
            (200, #"{"access_token":"session.jwt","token_type":"bearer","expires_in":43200,"wallet":"\#(address.lowercased())"}"#),
        ]
        let signed = Signed()
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let session = try await backend.signIn(address: address) { message in
            signed.messages.append(message)
            return try self.account.signMessage(message)
        }
        let after = Int(Date().timeIntervalSince1970 * 1000)

        let requests = WalletAuthCapture.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "\(base)/functions/v1/wallet-auth")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sb_publishable_test")
        }
        // 1. The nonce request names the wallet exactly as the sign-in will.
        let nonceBody = json(requests[0])
        XCTAssertEqual(nonceBody.count, 2)
        XCTAssertEqual(nonceBody["action"] as? String, "nonce")
        XCTAssertEqual(nonceBody["address"] as? String, address)

        // 2. The wallet signed exactly the template around the server's nonce, and that is what was sent.
        let authBody = json(requests[1])
        let message = try XCTUnwrap(authBody["message"] as? String)
        XCTAssertEqual(authBody["address"] as? String, address)
        XCTAssertEqual(signed.messages, [Data(message.utf8)])
        let fields = try XCTUnwrap(matchesTemplate(message))
        XCTAssertEqual(fields[0], address)
        XCTAssertEqual(fields[1], serverNonce)
        let issued = try XCTUnwrap(SupabaseClient.millis(iso8601: fields[2]))
        XCTAssertTrue((before...after).contains(issued))
        XCTAssertEqual(SupabaseClient.millis(iso8601: fields[3]), issued + 10 * 60 * 1000)
        XCTAssertEqual(message, SupabaseClient.signInMessage(address: address, nonce: serverNonce, issuedAt: issued))
        XCTAssertEqual(authBody["signature"] as? String, try account.signMessage(Data(message.utf8)).hexString)

        XCTAssertEqual(session.accessToken, "session.jwt")
        XCTAssertEqual(session.wallet, address.lowercased())
        let current = await backend.currentSession
        XCTAssertEqual(current, session)
    }

    /// `adopt: false` (SocialSession, which may have moved on to another wallet by the time wallet-auth answers) returns
    /// the session without making it the client's; `restore` then adopts it.
    func testSignInWithoutAdoptingLeavesTheClientAsItWas() async throws {
        let address = account.address.checksummed
        WalletAuthCapture.replies = [
            (200, #"{"nonce":"\#(serverNonce)","expiresAt":1758600300000}"#),
            (200, #"{"access_token":"session.jwt","token_type":"bearer","expires_in":43200,"wallet":"\#(address.lowercased())"}"#),
        ]
        let session = try await backend.signIn(address: address, adopt: false) { try self.account.signMessage($0) }
        XCTAssertEqual(session.accessToken, "session.jwt")
        let before = await backend.currentSession
        XCTAssertNil(before, "not the client's until restored")
        await backend.restore(session)
        let after = await backend.currentSession
        XCTAssertEqual(after, session)
    }

    /// A sign-out that finishes late (after its network call) ends only the session it was for: a sign-in adopted
    /// meanwhile keeps its session (RS-6).
    func testSignOutOnlyEndsTheSessionItWasFor() async {
        let old = SupabaseSession(accessToken: "old.jwt", wallet: "0xaa", expiresAt: Date().addingTimeInterval(3600))
        let new = SupabaseSession(accessToken: "new.jwt", wallet: "0xbb", expiresAt: Date().addingTimeInterval(3600))
        await backend.restore(new)
        await backend.signOut(ifAccessToken: old.accessToken)
        let kept = await backend.currentSession
        XCTAssertEqual(kept, new, "a newer sign-in survives the late sign-out of an older one")
        await backend.signOut(ifAccessToken: new.accessToken)
        let gone = await backend.currentSession
        XCTAssertNil(gone)
    }

    func testMalformedNonceIsRefusedBeforeAnythingIsSigned() async {
        for bad in [String(repeating: "A", count: 64), "abc123", serverNonce + "00", String(serverNonce.dropLast()) + "g"] {
            WalletAuthCapture.reset()
            WalletAuthCapture.replies = [(200, #"{"nonce":"\#(bad)","expiresAt":1}"#)]
            let signed = Signed()
            do {
                _ = try await backend.signIn(address: account.address.checksummed) { signed.messages.append($0); return Data(count: 65) }
                XCTFail("accepted nonce \(bad)")
            } catch SupabaseError.decoding {} catch { XCTFail("unexpected \(error)") }
            XCTAssertTrue(signed.messages.isEmpty)
            XCTAssertEqual(WalletAuthCapture.requests.count, 1)
        }
    }

    func testSpentOrExpiredNonceIsAClearError() async {
        WalletAuthCapture.replies = [
            (200, #"{"nonce":"\#(serverNonce)","expiresAt":1}"#),
            (401, #"{"error":"sign-in nonce invalid, expired or already used"}"#),
        ]
        do {
            _ = try await backend.signIn(address: account.address.checksummed) { try self.account.signMessage($0) }
            XCTFail("expected signInRejected")
        } catch let error as SupabaseError {
            guard case .signInRejected(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(reason, "sign-in nonce invalid, expired or already used")
            XCTAssertEqual(error.errorDescription, "That sign-in expired or was already used. Please try again.")
        } catch { XCTFail("unexpected \(error)") }
        let current = await backend.currentSession
        XCTAssertNil(current)
    }

    func testTooManyPendingSignInsIsRateLimited() async {
        WalletAuthCapture.replies = [(429, #"{"error":"too many pending sign-ins"}"#)]
        let signed = Signed()
        do {
            _ = try await backend.signIn(address: account.address.checksummed) { signed.messages.append($0); return Data(count: 65) }
            XCTFail("expected rateLimited")
        } catch let error as SupabaseError {
            guard case .rateLimited(let retryAfter) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertNil(retryAfter)
            XCTAssertEqual(error.errorDescription, "Too many attempts. Please wait a few minutes and try again.")
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertTrue(signed.messages.isEmpty)
    }

    // MARK: email-pepper

    private let pepperHex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let privyToken = "eyJhbGciOiJFUzI1NiJ9.privy-access-token.signature"
    private let alice = "  Alice.Test@Example.com \n"

    func testEmailPepperSendsOnlyTheHashes() async throws {
        let e = Data(repeating: 0xE0, count: 32), t = Data(repeating: 0x0F, count: 32)
        WalletAuthCapture.replies = [(200, #"{"p":"\#(pepperHex)"}"#)]
        let pepper = try await backend.emailPepper(e: e, t: t)
        XCTAssertEqual(pepper, Data(hex: pepperHex))

        let request = try XCTUnwrap(WalletAuthCapture.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "\(base)/functions/v1/email-pepper")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        // Anonymous budget: no Authorization at all — a bearer there is always read as an email proof.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = json(request)
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body["e"] as? String, String(repeating: "e0", count: 32))
        XCTAssertEqual(body["t"] as? String, String(repeating: "0f", count: 32))
    }

    /// The anonymous budget is spent (maybe by someone who knows the email): the caller is asked to verify the email,
    /// not to wait — waiting would let whoever spends it keep the owner out. (A 429 without `limit` reads as "email".)
    func testAnonymousRateLimitAsksForEmailVerification() async {
        for body in [#"{"error":"too many attempts","retryAfter":873,"limit":"email"}"#, #"{"error":"too many attempts","retryAfter":873}"#] {
            WalletAuthCapture.reset()
            WalletAuthCapture.replies = [(429, body)]
            do {
                _ = try await backend.emailPepper(e: EmailWallet.emailHash(alice), t: Data(count: 32))
                XCTFail("expected verificationRequired")
            } catch let error as EmailPepperError {
                XCTAssertEqual(error, .verificationRequired(retryAfter: 873))
                XCTAssertEqual(error.errorDescription, "Too many attempts for this email. Verify your email to continue.")
            } catch { XCTFail("unexpected \(error)") }
            XCTAssertEqual(WalletAuthCapture.requests.count, 1)
        }
    }

    /// The client network's limit counts proven and anonymous requests alike, so a one-time code can't help: wait —
    /// whether or not a proof was sent, and without dropping the proof or retrying.
    func testNetworkLimitMeansWaitNotVerification() async {
        let network = #"{"error":"too many attempts","retryAfter":420,"limit":"network"}"#
        for proven in [false, true] {
            WalletAuthCapture.reset()
            await backend.forgetEmailProofs()
            if proven { await backend.rememberEmailProof(privyToken, forEmail: alice) }
            WalletAuthCapture.replies = [(429, network), (200, #"{"p":"\#(pepperHex)"}"#)]
            do {
                _ = try await backend.emailPepper(e: EmailWallet.emailHash(alice), t: Data(count: 32))
                XCTFail("expected rateLimited")
            } catch let error as SupabaseError {
                guard case .rateLimited(let wait) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(wait, 420)
                XCTAssertEqual(error.errorDescription, "Too many attempts. Try again in 7 min.")
            } catch { XCTFail("unexpected \(error)") }
            XCTAssertEqual(WalletAuthCapture.requests.count, 1)
            // The proof (if any) is kept for the next attempt.
            _ = try? await backend.emailPepper(e: EmailWallet.emailHash(alice), t: Data(count: 32))
            XCTAssertEqual(WalletAuthCapture.requests[1].value(forHTTPHeaderField: "Authorization"), proven ? "Bearer \(privyToken)" : nil)
        }
    }

    /// The log-in path end to end at the client: anonymous 429 → the email one-time code's Privy token is remembered →
    /// the retry carries it as the bearer (verified budget) with the very same e and t, and yields the pepper.
    func testAnonymousLimitThenOTPRetryUsesTheVerifiedBudget() async throws {
        let seed = try XCTUnwrap(Data(hex: "ae3a32efcd63fdefae6f1777ac66baf43ce15c0b76da6741cca91f435b52cb2c"))
        let input = EmailWallet.pepperInput(email: alice, seed: seed)
        WalletAuthCapture.replies = [(429, #"{"error":"too many attempts","retryAfter":600,"limit":"email"}"#), (200, #"{"p":"\#(pepperHex)"}"#)]

        do {
            _ = try await backend.emailPepper(e: input.e, t: input.t)
            XCTFail("expected verificationRequired")
        } catch EmailPepperError.verificationRequired(let wait) { XCTAssertEqual(wait, 600) }

        // The user verifies the email they typed (any spacing/case — it is the same normalized email).
        await backend.rememberEmailProof(privyToken, forEmail: "alice.test@EXAMPLE.com")
        let pepper = try await backend.emailPepper(e: input.e, t: input.t)
        XCTAssertEqual(pepper, Data(hex: pepperHex))

        let requests = WalletAuthCapture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(privyToken)")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(requests[1].url?.absoluteString, "\(base)/functions/v1/email-pepper")
        XCTAssertEqual(json(requests[1]) as NSDictionary, json(requests[0]) as NSDictionary)
        XCTAssertEqual(json(requests[1])["e"] as? String, "2ecf504cb940af9ff3e0171edd90a0849991bb2273583a0cb2e46391cecc63ee")
    }

    /// A proof only ever travels with the e of the email it proves — never for another email, never after it is
    /// forgotten, and never to any other endpoint.
    func testEmailProofIsSentOnlyForItsOwnEmail() async throws {
        await backend.rememberEmailProof(privyToken, forEmail: alice)
        WalletAuthCapture.replies = [(200, #"{"p":"\#(pepperHex)"}"#), (200, #"{"nonce":"\#(serverNonce)","expiresAt":1}"#), (401, "{}")]
        _ = try await backend.emailPepper(e: EmailWallet.emailHash("vector@dyorhq.test"), t: Data(count: 32))
        _ = try? await backend.signIn(address: account.address.checksummed) { try self.account.signMessage($0) }
        XCTAssertNil(WalletAuthCapture.requests[0].value(forHTTPHeaderField: "Authorization"))
        for request in WalletAuthCapture.requests {
            XCTAssertFalse((request.allHTTPHeaderFields ?? [:]).values.contains { $0.contains(privyToken) })
            XCTAssertFalse(String(decoding: WalletAuthCapture.body(request), as: UTF8.self).contains(privyToken))
        }

        WalletAuthCapture.reset()
        await backend.forgetEmailProofs()
        WalletAuthCapture.replies = [(200, #"{"p":"\#(pepperHex)"}"#)]
        _ = try await backend.emailPepper(e: EmailWallet.emailHash(alice), t: Data(count: 32))
        XCTAssertNil(WalletAuthCapture.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    /// With a proof, a 429 for the email means the verified budget (or this Privy user's lookups) is spent — but the
    /// anonymous budget is separate and may have recovered: the proof is dropped and the request made once more
    /// without it. No lock-out until the token expires, and nothing more than one extra request.
    func testSpentVerifiedBudgetFallsBackToAnonymousOnce() async throws {
        let e = EmailWallet.emailHash(alice)
        for limit in ["email", "proof"] {
            WalletAuthCapture.reset()
            await backend.rememberEmailProof(privyToken, forEmail: alice)
            WalletAuthCapture.replies = [(429, #"{"error":"too many attempts","retryAfter":86000,"limit":"\#(limit)"}"#),
                                         (200, #"{"p":"\#(pepperHex)"}"#), (200, #"{"p":"\#(pepperHex)"}"#)]
            let pepper = try await backend.emailPepper(e: e, t: Data(count: 32))
            XCTAssertEqual(pepper, Data(hex: pepperHex))
            let requests = WalletAuthCapture.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(privyToken)")
            XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(json(requests[1]) as NSDictionary, json(requests[0]) as NSDictionary)
            // The spent proof is gone: the next request is anonymous straight away.
            _ = try await backend.emailPepper(e: e, t: Data(count: 32))
            XCTAssertNil(WalletAuthCapture.requests[2].value(forHTTPHeaderField: "Authorization"))
        }
    }

    /// Both of the email's budgets spent: wait for whichever frees first — asking to verify again would only loop.
    func testBothBudgetsSpentMeansWait() async {
        let e = EmailWallet.emailHash(alice)
        for (verifiedWait, anonymousWait, expected, text) in [(86_000, 600, 600, "Too many attempts. Try again in 10 min."),
                                                              (61, 900, 61, "Too many attempts. Try again in 2 min."),
                                                              (5, 7, 5, "Too many attempts. Try again in 1 min.")] {
            WalletAuthCapture.reset()
            await backend.rememberEmailProof(privyToken, forEmail: alice)
            WalletAuthCapture.replies = [(429, #"{"error":"too many attempts","retryAfter":\#(verifiedWait),"limit":"email"}"#),
                                         (429, #"{"error":"too many attempts","retryAfter":\#(anonymousWait),"limit":"email"}"#)]
            do {
                _ = try await backend.emailPepper(e: e, t: Data(count: 32))
                XCTFail("expected rateLimited")
            } catch let error as SupabaseError {
                guard case .rateLimited(let wait) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(wait, expected)
                XCTAssertEqual(error.errorDescription, text)
            } catch { XCTFail("unexpected \(error)") }
            XCTAssertEqual(WalletAuthCapture.requests.count, 2)
            XCTAssertEqual(WalletAuthCapture.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(privyToken)")
            XCTAssertNil(WalletAuthCapture.requests[1].value(forHTTPHeaderField: "Authorization"))
        }
        // The anonymous retry hitting the network's limit: that wait, whatever the verified one was.
        WalletAuthCapture.reset()
        await backend.rememberEmailProof(privyToken, forEmail: alice)
        WalletAuthCapture.replies = [(429, #"{"error":"too many attempts","retryAfter":86000,"limit":"email"}"#),
                                     (429, #"{"error":"too many attempts","retryAfter":300,"limit":"network"}"#)]
        do { _ = try await backend.emailPepper(e: e, t: Data(count: 32)); XCTFail("expected rateLimited") }
        catch SupabaseError.rateLimited(let wait) { XCTAssertEqual(wait, 300) } catch { XCTFail("unexpected \(error)") }
    }

    /// A refused proof (expired → 401, or for another email → 400) is forgotten and turns into "verify again" — the
    /// next request is anonymous, never a silent retry with the bad token.
    func testRefusedProofIsForgottenAndAsksToVerifyAgain() async throws {
        let e = EmailWallet.emailHash(alice)
        for (status, body, expected) in [(401, #"{"error":"invalid Privy access token"}"#, EmailPepperError.verificationExpired),
                                         (400, #"{"error":"the verified email does not match"}"#, EmailPepperError.verificationMismatch),
                                         (400, #"{"error":"no verified email on this Privy account"}"#, EmailPepperError.verificationMismatch)] {
            WalletAuthCapture.reset()
            await backend.rememberEmailProof(privyToken, forEmail: alice)
            WalletAuthCapture.replies = [(status, body), (200, #"{"p":"\#(pepperHex)"}"#)]
            do {
                _ = try await backend.emailPepper(e: e, t: Data(count: 32))
                XCTFail("expected \(expected)")
            } catch let error as EmailPepperError {
                XCTAssertEqual(error, expected)
            } catch { XCTFail("unexpected \(error)") }
            _ = try await backend.emailPepper(e: e, t: Data(count: 32))
            XCTAssertEqual(WalletAuthCapture.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(privyToken)")
            XCTAssertNil(WalletAuthCapture.requests[1].value(forHTTPHeaderField: "Authorization"))
        }
        // Any other 400 (e.g. malformed input) is not about the proof: it stays.
        WalletAuthCapture.reset()
        await backend.rememberEmailProof(privyToken, forEmail: alice)
        WalletAuthCapture.replies = [(400, #"{"error":"e and t must each be 64 lowercase hex characters"}"#), (200, #"{"p":"\#(pepperHex)"}"#)]
        do { _ = try await backend.emailPepper(e: e, t: Data(count: 32)); XCTFail("expected http 400") }
        catch SupabaseError.http(400, _) {} catch { XCTFail("unexpected \(error)") }
        _ = try await backend.emailPepper(e: e, t: Data(count: 32))
        XCTAssertEqual(WalletAuthCapture.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(privyToken)")
    }

    /// `retryAfter` is network input: huge, negative or non-numeric values must clamp or drop, never trap.
    func testRetryAfterNeverTraps() {
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":1e300}"#), 86_400)
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":-1e300}"#), 0)
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":9223372036854775807}"#), 86_400)
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":59.2}"#), 60)
        XCTAssertNil(SupabaseClient.retryAfter(#"{"retryAfter":"soon"}"#))
        XCTAssertNil(SupabaseClient.retryAfter("not json"))
        XCTAssertEqual(SupabaseError.rateLimited(retryAfter: 86_400).errorDescription, "Too many attempts. Try again in 1440 min.")
    }

    func testEmailPepperRefusesAMalformedAnswer() async {
        for body in [#"{"p":"xyz"}"#, #"{"p":"\#(String(repeating: "AB", count: 32))"}"#, "{}", #"{"p":"\#(String(repeating: "ab", count: 31))"}"#] {
            WalletAuthCapture.reset()
            WalletAuthCapture.replies = [(200, body)]
            do {
                _ = try await backend.emailPepper(e: Data(count: 32), t: Data(count: 32))
                XCTFail("accepted \(body)")
            } catch SupabaseError.decoding {} catch { XCTFail("unexpected \(error)") }
        }
    }
}

/// Answers each request with the next queued reply and records it.
final class WalletAuthCapture: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var replies: [(Int, String)] = []

    static func reset() { requests = []; replies = [] }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WalletAuthCapture.self]
        return URLSession(configuration: configuration)
    }

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // Keep the body readable after the request is recorded (the stream can only be read once).
        var recorded = request
        recorded.httpBody = Self.body(request)
        Self.requests.append(recorded)
        let (status, body) = Self.replies.isEmpty ? (500, #"{"error":"no reply queued"}"#) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
