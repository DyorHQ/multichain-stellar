import Foundation
import XCTest
@testable import DyorKit

/// Kuru's logo directory (about 800 KB, about 6 s to arrive) is read at most once a day: the copy kept on the phone
/// answers in between with no network, from the first call after a launch; an older one answers at once while Kuru is read
/// again behind it; a failed read keeps the last directory and is retried after a few minutes, never cached empty for the
/// session; an SVG logo, which the app can't draw, is left out; and the erase deletes the file.
final class KuruLogosTests: XCTestCase {
    private var files: [URL] = []

    override func setUp() { KuruStub.reset() }

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        files = []
    }

    private func file() -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kuru-logos-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("kuru-logos-v1.json")
        files.append(file)
        return file
    }

    private let chog = Address(literal: "0x3333333333333333333333333333333333333333")
    private let wmon = Address(literal: "0x3bd359c1119da7da1d913d1c4d2b7c461115433a")
    private let usdc = Address(literal: "0x754704bc059f8c67012fed69bc8a327a5aafb603")

    /// A markets answer: CHOG and WMON with PNG logos, USDC with an SVG one.
    private func markets(chogLogo: String = "https://dsvxs4ecepqgj.cloudfront.net/chog.png") -> String {
        """
        {"success":true,"data":{"data":[
          {"basetoken":{"address":"\(chog.hex)","imageurl":"\(chogLogo)"},"quotetoken":{"address":"\(wmon.hex)","imageurl":"https://dsvxs4ecepqgj.cloudfront.net/wmon.png"}},
          {"basetoken":{"address":"\(chog.hex)","imageurl":"\(chogLogo)"},"quotetoken":{"address":"\(usdc.hex)","imageurl":"https://dsvxs4ecepqgj.cloudfront.net/tokens/USDC/logo.svg"}}
        ]}}
        """
    }

    private func client(_ file: URL?, clock: TestClock) -> KuruTokenListClient {
        KuruTokenListClient(session: KuruStub.session(), logosFile: file, now: clock.read)
    }

    /// Read once, kept on the phone: a relaunch within the day answers from the file with no network; an SVG is left out.
    func testTheDirectoryIsReadOnceADayAndKeptOnThePhone() async throws {
        let file = file()
        let clock = TestClock()
        KuruStub.replies = [(200, markets())]
        let first = await client(file, clock: clock).logos()
        XCTAssertEqual(first[chog]?.absoluteString, "https://dsvxs4ecepqgj.cloudfront.net/chog.png")
        XCTAssertNotNil(first[wmon])
        XCTAssertNil(first[usdc], "an SVG the app can't draw is left out")
        XCTAssertEqual(KuruStub.requests.count, 1)
        XCTAssertEqual(KuruStub.requests.first?.url?.path, "/api/v1/markets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        clock.advance(23 * 3_600)
        let relaunched = client(file, clock: clock)
        let kept = await relaunched.logos()
        XCTAssertEqual(kept, first)
        let again = await relaunched.logos()
        XCTAssertEqual(again, first)
        XCTAssertEqual(KuruStub.requests.count, 1, "within the day: no network")
        XCTAssertEqual(KuruTokenListClient.logosLifetime, 86_400)
    }

    /// A day on, the kept directory answers at once while Kuru is read again behind it; the next call has the new one.
    /// Kuru's answer is held until the test lets it go, so "at once" is "before Kuru answered", on any machine.
    func testADayOldDirectoryAnswersAtOnceWhileItIsReadAgain() async throws {
        let file = file()
        let clock = TestClock()
        KuruStub.replies = [(200, markets())]
        _ = await client(file, clock: clock).logos()

        clock.advance(25 * 3_600)
        KuruStub.replies = [(200, markets(chogLogo: "https://dsvxs4ecepqgj.cloudfront.net/chog-2.png"))]
        KuruStub.hold()
        let answered = KuruStub.answers
        let relaunched = client(file, clock: clock)
        let stale = await relaunched.logos()
        XCTAssertEqual(KuruStub.answers, answered, "the kept directory, before Kuru answered")
        XCTAssertEqual(stale[chog]?.absoluteString, "https://dsvxs4ecepqgj.cloudfront.net/chog.png")
        let reading = await relaunched.readingLogos
        XCTAssertTrue(reading, "read again behind it")
        KuruStub.release()
        try await finished(relaunched)
        let fresh = await relaunched.logos()
        XCTAssertEqual(fresh[chog]?.absoluteString, "https://dsvxs4ecepqgj.cloudfront.net/chog-2.png")
        XCTAssertEqual(KuruStub.requests.count, 2, "one read behind it")
        let saved = await client(file, clock: clock).logos()
        XCTAssertEqual(saved[chog]?.absoluteString, "https://dsvxs4ecepqgj.cloudfront.net/chog-2.png", "and kept")
    }

    /// With nothing kept, callers at once share one read. A failed read (or one with no logo) keeps the last directory —
    /// empty when there is none — and isn't retried for a few minutes; then it is, never cached empty for the session.
    func testAFailedReadKeepsTheLastDirectoryAndIsRetriedLater() async throws {
        let clock = TestClock()
        KuruStub.replies = [(503, "{}")]
        KuruStub.delay = 0.1
        let kuru = client(nil, clock: clock)
        async let a = kuru.logos()
        async let b = kuru.logos()
        let (first, second) = await (a, b)
        XCTAssertEqual(first, [:])
        XCTAssertEqual(second, [:])
        XCTAssertEqual(KuruStub.requests.count, 1, "one read for both")

        KuruStub.replies = [(200, markets())]
        let soon = await kuru.logos()
        XCTAssertEqual(soon, [:])
        XCTAssertEqual(KuruStub.requests.count, 1, "not retried within the wait")
        XCTAssertEqual(KuruTokenListClient.logosRetryAfter, 300)

        clock.advance(301)
        let later = await kuru.logos()
        XCTAssertNotNil(later[chog], "retried, not cached empty for the session")

        clock.advance(2 * 86_400)
        KuruStub.replies = [(200, #"{"success":true,"data":{"data":[]}}"#)]
        let afterEmpty = await kuru.logos() // the old directory at once; the read behind it brings nothing
        XCTAssertNotNil(afterEmpty[chog])
        try await finished(kuru)
        XCTAssertEqual(KuruStub.requests.count, 3)
        let kept = await kuru.logos()
        XCTAssertNotNil(kept[chog], "a read with no logo keeps the last directory")
        XCTAssertEqual(KuruStub.requests.count, 3, "and counts as a failure: not asked again within the wait")
    }

    /// Waits for the read under way to end.
    private func finished(_ kuru: KuruTokenListClient) async throws {
        for _ in 0..<1_000 {
            if await !kuru.readingLogos { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the read never ended")
    }

    /// The erase (Forget This Device, Delete Account) deletes the kept directory.
    func testTheEraseDeletesTheKeptDirectory() async throws {
        let file = file()
        KuruStub.replies = [(200, markets())]
        _ = await client(file, clock: TestClock()).logos()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        KuruTokenListClient.removeSavedLogos(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(KuruTokenListClient.defaultLogosFile?.lastPathComponent, "kuru-logos-v1.json")
        XCTAssertTrue(KuruTokenListClient.defaultLogosFile?.path.contains("/Caches/") == true, "re-fetchable: Caches, not backed up")
    }
}

/// Answers each request with the next queued (status, body), after `delay` — and, while `hold()` is in force, not before
/// `release()` (or 30 s) — and records the requests and how many answers it sent.
final class KuruStub: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var replies: [(Int, String)] = []
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) private static var held = false
    nonisolated(unsafe) private static var answered = 0
    private static let lock = NSLock()

    static func reset() { lock.lock(); requests = []; replies = []; delay = 0; held = false; answered = 0; lock.unlock() }
    static func hold() { lock.lock(); held = true; lock.unlock() }
    static func release() { lock.lock(); held = false; lock.unlock() }
    static var answers: Int { lock.lock(); defer { lock.unlock() }; return answered }
    private static var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KuruStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let (status, text) = Self.replies.isEmpty ? (500, "{}") : (Self.replies.count == 1 ? Self.replies[0] : Self.replies.removeFirst())
        let delay = Self.delay
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let deadline = Date().addingTimeInterval(30)
            while Self.isHeld, Date() < deadline { usleep(2_000) }
            Self.lock.lock()
            Self.answered += 1
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
