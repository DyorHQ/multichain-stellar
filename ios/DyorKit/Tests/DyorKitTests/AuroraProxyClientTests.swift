import XCTest
@testable import DyorKit

/// The Bridge talks to Aurora only through DyorHQ's aurora-proxy Edge Function: the exact URLs and headers the client
/// sends, that it never carries an Aurora key, that no session means no request at all, and how proxy answers map to
/// user-facing errors.
final class AuroraProxyClientTests: XCTestCase {
    private let backend = SupabaseClient(url: URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!, anonKey: "sb_publishable_test")

    override func setUp() {
        super.setUp()
        ProxyCapture.reset()
    }

    private func aurora(headers: [String: String]? = ["apikey": "sb_publishable_test", "Authorization": "Bearer session.jwt"]) -> AuroraIntents {
        AuroraIntents(proxy: backend.functionURL("aurora-proxy"), authorize: {
            guard let headers else { throw SupabaseError.notSignedIn }
            return headers
        }, session: ProxyCapture.session())
    }

    func testFunctionURL() {
        XCTAssertEqual(backend.functionURL("aurora-proxy").absoluteString, "https://fmnjqrguvopusfufmirs.supabase.co/functions/v1/aurora-proxy")
    }

    func testRequestsGoToTheProxyWithTheSessionAndNoKey() async throws {
        ProxyCapture.body = #"{"tokens":[]}"#
        _ = try await aurora().tokens()
        ProxyCapture.body = #"{"depositAddress":"0xabc","status":"PENDING_DEPOSIT"}"#
        _ = try? await aurora().submitDeposit(txHash: "0x01", depositAddress: "0xabc")
        _ = try? await aurora().status(depositAddress: "0xabc", depositMemo: "m")

        let urls = ProxyCapture.requests.map { $0.url!.absoluteString }
        XCTAssertEqual(urls, [
            "https://fmnjqrguvopusfufmirs.supabase.co/functions/v1/aurora-proxy/tokens",
            "https://fmnjqrguvopusfufmirs.supabase.co/functions/v1/aurora-proxy/deposit/submit",
            "https://fmnjqrguvopusfufmirs.supabase.co/functions/v1/aurora-proxy/status?depositAddress=0xabc&depositMemo=m",
        ])
        for request in ProxyCapture.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session.jwt")
            XCTAssertFalse(request.url!.absoluteString.contains("intents-api.aurora.dev"), "never direct to Aurora")
        }
        XCTAssertEqual(ProxyCapture.requests[1].httpMethod, "POST")
    }

    func testNoSessionMeansNoRequest() async {
        do { _ = try await aurora(headers: nil).tokens(); XCTFail("expected signInRequired") }
        catch AuroraError.signInRequired {} catch { XCTFail("unexpected \(error)") }
        XCTAssertTrue(ProxyCapture.requests.isEmpty)
    }

    func testProxyAnswersMapToClearErrors() async {
        ProxyCapture.status = 503; ProxyCapture.body = #"{"error":"bridge not configured"}"#
        do { _ = try await aurora().tokens(); XCTFail() } catch AuroraError.notConfigured {} catch { XCTFail("unexpected \(error)") }
        ProxyCapture.status = 403; ProxyCapture.body = #"{"error":"a signed-in wallet session is required"}"#
        do { _ = try await aurora().tokens(); XCTFail() } catch AuroraError.signInRequired {} catch { XCTFail("unexpected \(error)") }
        ProxyCapture.status = 400; ProxyCapture.body = #"{"message":"Amount is too low for bridge"}"#
        do { _ = try await aurora().tokens(); XCTFail() }
        catch AuroraError.api(let status, let message) { XCTAssertEqual(status, 400); XCTAssertEqual(message, "Amount is too low for bridge") }
        catch { XCTFail("unexpected \(error)") }
    }
}

final class ProxyCapture: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "{}"

    static func reset() { requests = []; status = 200; body = "{}" }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyCapture.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
