import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DyorKit

/// Untrusted remote media is read up to a byte cap and decoded only as a thumbnail, after its declared size is checked
/// (security audit 2026-09-26, RI-5).
final class RemoteMediaTests: XCTestCase {
    override func setUp() { MediaStub.reset() }

    // MARK: Decoding

    func testThumbnailDownsamplesToTheLongerSide() throws {
        let image = try RemoteMedia.thumbnail(Self.png(width: 400, height: 200), maxPixelSize: 100)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
    }

    func testThumbnailNeverScalesUp() throws {
        let image = try RemoteMedia.thumbnail(Self.png(width: 40, height: 30), maxPixelSize: 1000)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)
    }

    func testDeclaredSideOverTheCapIsRefusedBeforeDecoding() throws {
        let data = try Self.png(width: 9000, height: 2)
        XCTAssertThrowsError(try RemoteMedia.thumbnail(data, maxPixelSize: 64)) { XCTAssertEqual($0 as? RemoteMedia.Failure, .tooManyPixels) }
    }

    func testDeclaredAreaOverTheCapIsRefused() throws {
        let data = try Self.png(width: 300, height: 300)
        XCTAssertThrowsError(try RemoteMedia.thumbnail(data, maxPixelSize: 64, maxSourcePixels: 300 * 299)) {
            XCTAssertEqual($0 as? RemoteMedia.Failure, .tooManyPixels)
        }
        XCTAssertNoThrow(try RemoteMedia.thumbnail(data, maxPixelSize: 64, maxSourcePixels: 300 * 300))
    }

    func testHTMLIsNotAnImage() {
        let html = Data("<html><body>Index of /ipfs/bafy…</body></html>".utf8)
        XCTAssertThrowsError(try RemoteMedia.thumbnail(html, maxPixelSize: 64)) { XCTAssertEqual($0 as? RemoteMedia.Failure, .notAnImage) }
    }

    // MARK: Fetching

    func testFetchReturnsTheBody() async throws {
        MediaStub.reply = (200, ["Content-Type": "image/png"], Data(repeating: 7, count: 2048))
        let data = try await RemoteMedia.fetch(URL(string: "https://cdn.example/logo.png")!, session: MediaStub.session(), maxBytes: 4096)
        XCTAssertEqual(data.count, 2048)
    }

    func testDeclaredLengthOverTheCapIsRefused() async {
        MediaStub.reply = (200, ["Content-Length": "5000"], Data(repeating: 1, count: 5000))
        await XCTAssertThrowsFailure(.tooLarge) { try await RemoteMedia.fetch(URL(string: "https://cdn.example/big.png")!, session: MediaStub.session(), maxBytes: 4096) }
    }

    func testUndeclaredBodyOverTheCapIsCutOff() async {
        MediaStub.reply = (200, [:], Data(repeating: 1, count: 10_000))
        MediaStub.omitLength = true
        await XCTAssertThrowsFailure(.tooLarge) { try await RemoteMedia.fetch(URL(string: "https://cdn.example/stream")!, session: MediaStub.session(), maxBytes: 4096) }
    }

    func testErrorStatusIsRefused() async {
        MediaStub.reply = (429, [:], Data("slow down".utf8))
        await XCTAssertThrowsFailure(.status(429)) { try await RemoteMedia.fetch(URL(string: "https://ipfs.io/ipfs/bafy")!, session: MediaStub.session()) }
    }

    func testACancelledFetchEnds() async {
        MediaStub.reply = (200, [:], Data(repeating: 1, count: 2048))
        let task = Task { () -> Data in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RemoteMedia.fetch(URL(string: "https://cdn.example/logo.png")!, session: MediaStub.session())
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled fetch must not return data")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)")
        }
    }

    func testFetchesCancelledAtAnyMomentAllEnd() async {
        // A cancellation can land before the task is resumed, between the check and the resume, or mid-download:
        // every one of these fetches must still answer, exactly once.
        MediaStub.reply = (200, [:], Data(repeating: 1, count: 4096))
        let session = MediaStub.session()
        let tasks = (0..<200).map { i in
            Task { () -> Data? in
                for _ in 0..<(i % 4) { await Task.yield() }
                return try? await RemoteMedia.fetch(URL(string: "https://cdn.example/\(i).png")!, session: session)
            }
        }
        for (i, task) in tasks.enumerated() where i % 2 == 0 { task.cancel() }
        let done = expectation(description: "every fetch answered")
        Task {
            for task in tasks { _ = await task.value }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
    }

    func testSmallThumbnailsGetSmallCaps() {
        let logo = RemoteMedia.caps(forThumbnail: 34 * 3)
        XCTAssertEqual(logo, RemoteMedia.Caps(maxBytes: 2 * 1024 * 1024, maxSourcePixels: 16_000_000))
        XCTAssertEqual(RemoteMedia.caps(forThumbnail: RemoteMedia.smallThumbnail), logo)
        XCTAssertEqual(RemoteMedia.caps(forThumbnail: 1200), RemoteMedia.Caps(maxBytes: RemoteMedia.maxImageBytes, maxSourcePixels: RemoteMedia.maxSourcePixels),
                       "a Moment's detail artwork keeps the full caps")
    }

    /// The image pipeline's sessions keep nothing in URLCache and never answer from it (it keeps what it accepted
    /// itself); DyorHQ's host and the gateways may take two minutes for a whole transfer, any other host 30 s. Any other
    /// session the app makes for remote media keeps the shared cache, as before.
    func testTheImageSessionsStoreNothingAndTrustOnlyDyorHQsHostsWithTime() {
        let unstored = RemoteMedia.makeSession(storesResponses: false).configuration
        XCTAssertNil(unstored.urlCache)
        XCTAssertEqual(unstored.requestCachePolicy, .reloadIgnoringLocalCacheData)
        let stored = RemoteMedia.makeSession().configuration
        XCTAssertNotNil(stored.urlCache)
        XCTAssertEqual(stored.requestCachePolicy, .useProtocolCachePolicy)
        for configuration in [ImageFetcher.trustedSession.configuration, ImageFetcher.otherSession.configuration] {
            XCTAssertNil(configuration.urlCache)
            XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertNil(configuration.urlCredentialStorage)
            XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
            XCTAssertFalse(configuration.httpShouldSetCookies)
        }
        XCTAssertEqual(ImageFetcher.trustedSession.configuration.timeoutIntervalForResource, RemoteMedia.trustedResourceTimeout)
        XCTAssertEqual(RemoteMedia.trustedResourceTimeout, 120)
        XCTAssertEqual(ImageFetcher.otherSession.configuration.timeoutIntervalForResource, 30)
    }

    /// Logo-sized downloads and Storage's resized copies (up to 2 MB) wait in eight slots; whole originals under the full
    /// caps in four of their own, so each has a quarter of the link and a legacy multi-MB photo isn't cut off.
    func testWholeOriginalsHaveFewerSlotsOfTheirOwn() async {
        XCTAssertEqual(RemoteMedia.smallImageBytes, 2 * 1024 * 1024)
        XCTAssertEqual(RemoteMedia.caps(forThumbnail: 96).maxBytes, RemoteMedia.smallImageBytes)
        XCTAssertTrue(RemoteMedia.fetchSlots(maxBytes: RemoteMedia.smallImageBytes) === RemoteMedia.fetches)
        XCTAssertTrue(RemoteMedia.fetchSlots(maxBytes: RemoteMedia.smallImageBytes + 1) === RemoteMedia.largeFetches)
        XCTAssertTrue(RemoteMedia.fetchSlots(maxBytes: RemoteMedia.maxImageBytes) === RemoteMedia.largeFetches)
        let (small, large) = (await RemoteMedia.fetches.limit, await RemoteMedia.largeFetches.limit)
        XCTAssertEqual(small, 8)
        XCTAssertEqual(large, 4)
    }

    /// A request waits for data as long as its source's host allows (`ImageSourcePolicy.requestTimeout`), and says when a
    /// 2xx answer's body starts — never for a refused status. Eight small downloads run at once app-wide.
    func testAFetchUsesItsSourcesTimeoutAndSaysWhenTheBodyStarts() async throws {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func add() { lock.lock(); value += 1; lock.unlock() }
            var total: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let answered = Count()
        MediaStub.reply = (200, [:], Data(repeating: 7, count: 2048))
        _ = try await RemoteMedia.fetch(URL(string: "https://cdn.example/logo.png")!, session: MediaStub.session(), timeout: 8, onResponse: { answered.add() })
        XCTAssertEqual(MediaStub.requests.last?.timeoutInterval, 8)
        XCTAssertEqual(answered.total, 1)
        MediaStub.reply = (404, [:], Data("not found".utf8))
        await XCTAssertThrowsFailure(.status(404)) {
            try await RemoteMedia.fetch(URL(string: "https://cdn.example/gone.png")!, session: MediaStub.session(), onResponse: { answered.add() })
        }
        XCTAssertEqual(answered.total, 1, "a refused answer never starts a body")
        let (fetches, decodes) = (await RemoteMedia.fetches.limit, await RemoteMedia.decodes.limit)
        XCTAssertEqual(fetches, 8)
        XCTAssertEqual(decodes, 2)
        XCTAssertEqual(try RemoteMedia.inspect(try Self.png(width: 30, height: 20)).width, 30)
    }

    func testOnlyHTTPSIsFetched() async {
        await XCTAssertThrowsFailure(.insecureURL) { try await RemoteMedia.fetch(URL(string: "http://cdn.example/logo.png")!, session: MediaStub.session()) }
        XCTAssertTrue(MediaStub.requests.isEmpty)
    }

    // MARK: Helpers

    private func XCTAssertThrowsFailure(_ expected: RemoteMedia.Failure, _ body: () async throws -> Data, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteMedia.Failure, expected, file: file, line: line)
        }
    }

    static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Serves one canned response to every request, and records the requests.
final class MediaStub: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var reply: (Int, [String: String], Data) = (500, [:], Data())
    /// Leave Content-Length out, as a streaming server would.
    nonisolated(unsafe) static var omitLength = false

    static func reset() { requests = []; reply = (500, [:], Data()); omitLength = false }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static let lock = NSLock()

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()
        let (status, headers, body) = Self.reply
        var fields = headers
        if !Self.omitLength, fields["Content-Length"] == nil { fields["Content-Length"] = "\(body.count)" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a network would deliver it.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 1024, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
