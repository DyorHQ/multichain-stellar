import Foundation
import XCTest
@testable import DyorKit

/// A feed that failed is shown as missing and asked again next time, never cached as fresh; the feeds that answered are
/// kept for two minutes and not asked again meanwhile (security audit 2026-09-26, RS-10).
final class NewsCacheTests: XCTestCase {
    private let a = NewsSource(name: "A", feed: URL(string: "https://a.example/rss")!)
    private let b = NewsSource(name: "B", feed: URL(string: "https://b.example/rss")!)

    override func setUp() { FeedStub.reset() }

    private static func rss(_ title: String, _ link: String) -> String {
        """
        <?xml version="1.0"?><rss version="2.0"><channel><title>x</title>
        <item><title>\(title)</title><link>\(link)</link><pubDate>Sat, 26 Sep 2026 10:00:00 GMT</pubDate></item>
        </channel></rss>
        """
    }

    func testOnlyTheFailedFeedIsAskedAgain() async {
        FeedStub.replies = ["a.example": (500, ""), "b.example": (200, Self.rss("Hello", "https://b.example/1"))]
        let clock = Clock()
        let news = NewsService(sources: [a, b], session: FeedStub.session(), now: { clock.now })
        let first = await news.latest()
        XCTAssertEqual(first.map(\.title), ["Hello"])
        XCTAssertEqual(FeedStub.requests.sorted(), ["a.example", "b.example"])

        // A failed and isn't kept: it is asked again; B answered a moment ago and isn't.
        FeedStub.replies["a.example"] = (200, Self.rss("World", "https://a.example/1"))
        let second = await news.latest()
        XCTAssertEqual(Set(second.map(\.title)), ["Hello", "World"])
        XCTAssertEqual(FeedStub.requests.count, 3)
        XCTAssertEqual(FeedStub.requests.last, "a.example")

        // Both kept for two minutes.
        _ = await news.latest()
        XCTAssertEqual(FeedStub.requests.count, 3)
        clock.now = clock.now.addingTimeInterval(NewsService.freshFor + 1)
        _ = await news.latest()
        XCTAssertEqual(FeedStub.requests.count, 5)
        // A forced refresh asks every feed.
        _ = await news.latest(force: true)
        XCTAssertEqual(FeedStub.requests.count, 7)
    }

    func testAFeedThatKeepsFailingCostsOnlyItsOwnRequest() async {
        FeedStub.replies = ["a.example": (403, ""), "b.example": (200, Self.rss("Hello", "https://b.example/1"))]
        let news = NewsService(sources: [a, b], session: FeedStub.session())
        for _ in 0..<3 { _ = await news.latest() }
        XCTAssertEqual(FeedStub.requests.filter { $0 == "b.example" }.count, 1)
        XCTAssertEqual(FeedStub.requests.filter { $0 == "a.example" }.count, 3)
    }

    private final class Clock: @unchecked Sendable { var now = Date() }
}

/// Answers by host with a queued (status, body) and counts requests.
final class FeedStub: URLProtocol {
    nonisolated(unsafe) static var replies: [String: (Int, String)] = [:]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    /// The hosts asked, in the order the requests started (feeds are fetched concurrently).
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return log }

    static func reset() { replies = [:]; lock.lock(); log = []; lock.unlock() }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.log.append(request.url?.host ?? "")
        Self.lock.unlock()
        let (status, body) = Self.replies[request.url?.host ?? ""] ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/rss+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
