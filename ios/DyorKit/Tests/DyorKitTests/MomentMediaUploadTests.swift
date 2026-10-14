import Foundation
import XCTest
@testable import DyorKit

/// Moment media goes to a write-once bucket and is pinned before it goes on-chain (security audit 2026-09-26, PR-2,
/// RI-9, RW-9): uploads never overwrite, an object already there reads as uploaded, and a pin that fails, is refused
/// or times out comes back as an error the app can show.
final class MomentMediaUploadTests: XCTestCase {
    private let base = URL(string: "https://project.supabase.co")!

    override func setUp() { UploadStub.reset() }

    private func client() async -> SupabaseClient {
        let client = SupabaseClient(url: base, anonKey: "anon", session: UploadStub.session())
        await client.restore(SupabaseSession(accessToken: "token", wallet: "0x" + String(repeating: "a", count: 40), expiresAt: Date().addingTimeInterval(3600)))
        return client
    }

    func testWriteOnceUploadAsksStorageNotToOverwrite() async throws {
        UploadStub.replies = [(200, "{}"), (200, "{}")]
        let client = await client()
        let url = try await client.uploadPublic(bucket: "launch-media", path: "0xaa/moment-1.jpg", data: Data([1, 2, 3]), contentType: "image/jpeg", upsert: false)
        _ = try await client.uploadPublic(bucket: "avatars", path: "0xaa/avatar.jpg", data: Data([4]), contentType: "image/jpeg")
        XCTAssertEqual(url.absoluteString, "https://project.supabase.co/storage/v1/object/public/launch-media/0xaa/moment-1.jpg")
        XCTAssertEqual(UploadStub.requests[0].value(forHTTPHeaderField: "x-upsert"), "false")
        XCTAssertEqual(UploadStub.bodies[0], Data([1, 2, 3]))
        XCTAssertEqual(UploadStub.requests[1].value(forHTTPHeaderField: "x-upsert"), "true")
        // Served from then on as the bucket allows: write-once objects for a week, an avatar (uploaded over) as Storage
        // serves it without a header (`no-cache`).
        XCTAssertEqual(UploadStub.requests[0].value(forHTTPHeaderField: "Cache-Control"), "public, max-age=604800")
        XCTAssertNil(UploadStub.requests[1].value(forHTTPHeaderField: "Cache-Control"))
    }

    /// Storage keeps an upload's Cache-Control as the object's and serves every read with it (`no-cache` without one).
    /// The write-once bucket's objects never change, but a takedown deletes one, so they may be kept a week — as the app
    /// keeps its own copy (`ImagePipeline.immutableLifetime`) — never a year, nor `immutable`, which no takedown could
    /// reach outside the app. An avatar is uploaded over its own path, and no other bucket gets one.
    func testEachBucketsUploadsSayHowLongTheyMayBeKept() {
        XCTAssertEqual(SupabaseClient.cacheControl(forBucket: "launch-media"), "public, max-age=604800")
        XCTAssertEqual(TimeInterval(604_800), ImagePipeline.immutableLifetime)
        XCTAssertNil(SupabaseClient.cacheControl(forBucket: "avatars"))
        XCTAssertNil(SupabaseClient.cacheControl(forBucket: "other"))
        XCTAssertNil(SupabaseClient.cacheControl(forBucket: "Launch-Media"), "bucket ids are exact")
    }

    func testFileUploadSendsTheFileBytes() async throws {
        UploadStub.replies = [(200, "{}")]
        let file = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).mov")
        let bytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let client = await client()
        _ = try await client.uploadPublic(bucket: "launch-media", path: "0xaa/moment-2.mov", file: file, contentType: "video/quicktime", upsert: false)
        XCTAssertEqual(UploadStub.bodies.first, bytes)
        XCTAssertEqual(UploadStub.requests.first?.value(forHTTPHeaderField: "Content-Type"), "video/quicktime")
        XCTAssertEqual(UploadStub.requests.first?.value(forHTTPHeaderField: "Cache-Control"), "public, max-age=604800")
    }

    /// A new Moment photo is encoded once, at most 2048 px on its long side at quality 0.85 (4096 px at 0.92 made files of
    /// up to 4.8 MB, which every viewer downloads whole to check the hash), off the main thread together with its hash and
    /// the form's preview; those very bytes are hashed, uploaded under that hash and pinned. A video's poster frame keeps
    /// its own encoding.
    func testANewMomentPhotoIsEncodedSmallerOffTheMainThread() throws {
        XCTAssertEqual(MomentsMath.photoMaxPixels, 2048)
        XCTAssertEqual(MomentsMath.photoJPEGQuality, 0.85)
        let create = try DocsLinksTests.appSource("Moments/CreateMomentView.swift").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let photo = try XCTUnwrap(create.range(of: "let photo = await Task.detached(priority: .userInitiated, operation: { () -> (jpeg: Data, hash: Data, preview: CGImage?)? in"))
        let encode = try XCTUnwrap(create.range(of: "guard let jpeg = UIImage(data: data)?.avatarJPEG(maxDimension: CGFloat(MomentsMath.photoMaxPixels), quality: CGFloat(MomentsMath.photoJPEGQuality))"))
        let hashed = try XCTUnwrap(create.range(of: "return (jpeg, Keccak.hash256(jpeg), preview) }).value else {"))
        XCTAssertLessThan(photo.upperBound, encode.lowerBound)
        XCTAssertLessThan(encode.upperBound, hashed.lowerBound, "encoded and hashed in the detached task")
        let upload = try XCTUnwrap(create.range(of: #"social.uploadMomentMedia(photo.jpeg, contentType: "image/jpeg", fileExtension: "jpg", name: MomentsMath.mediaName(hash: photo.hash))"#))
        let recorded = try XCTUnwrap(create.range(of: "mediaHash = photo.hash await pin(MediaPins(image: photoUpload, video: nil))"))
        XCTAssertLessThan(hashed.upperBound, upload.lowerBound)
        XCTAssertLessThan(upload.upperBound, recorded.lowerBound)
        XCTAssertFalse(create.contains("maxDimension: 4096"))
        XCTAssertTrue(create.contains("posterImage.avatarJPEG(maxDimension: 2048, quality: 0.9)"), "the poster frame as before")
    }

    func testAnObjectThatAlreadyExistsIsRecognised() {
        XCTAssertTrue(SupabaseClient.isDuplicateUpload(SupabaseError.http(409, #"{"error":"Duplicate"}"#)))
        XCTAssertTrue(SupabaseClient.isDuplicateUpload(SupabaseError.http(400, #"{"statusCode":"409","error":"Duplicate","message":"The resource already exists"}"#)))
        XCTAssertTrue(SupabaseClient.isDuplicateUpload(SupabaseError.http(400, #"{"statusCode":409,"error":"Duplicate"}"#)))
        XCTAssertFalse(SupabaseClient.isDuplicateUpload(SupabaseError.http(400, #"{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy"}"#)))
        XCTAssertFalse(SupabaseClient.isDuplicateUpload(SupabaseError.http(403, "")))
        XCTAssertFalse(SupabaseClient.isDuplicateUpload(URLError(.timedOut)))
    }

    func testPinReturnsTheIPFSURIAndWaitsTheServersBudget() async throws {
        UploadStub.replies = [(200, #"{"cid":"bafy","uri":"ipfs://bafy","contentType":"image/jpeg","wrapped":false}"#)]
        let uri = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
        XCTAssertEqual(uri, "ipfs://bafy")
        XCTAssertEqual(UploadStub.requests.first?.url?.path, "/functions/v1/pin-media")
        // pin-media answers within its 20 s budget; the app waits a little longer, never less.
        XCTAssertEqual(UploadStub.requests.first?.timeoutInterval, SupabaseClient.pinMediaTimeout)
        XCTAssertGreaterThan(SupabaseClient.pinMediaTimeout, 20)
    }

    func testPinThatIsRateLimitedSaysWhenToRetry() async {
        UploadStub.replies = [(429, #"{"error":"too many requests — try again later","retryAfter":120,"limit":"subject"}"#)]
        do {
            _ = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
            XCTFail("expected a rate limit")
        } catch SupabaseError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 120)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPinThatFailsThrowsInsteadOfFallingBack() async {
        UploadStub.replies = [(502, #"{"error":"pinning failed"}"#)]
        do {
            _ = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
            XCTFail("expected an error")
        } catch SupabaseError.http(let code, _) {
            XCTAssertEqual(code, 502)
        } catch {
            XCTFail("unexpected \(error)")
        }
        UploadStub.replies = [(200, #"{"uri":"https://project.supabase.co/storage/v1/object/public/launch-media/0xaa/moment-1.jpg"}"#)]
        do {
            _ = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
            XCTFail("an https answer is not a pin")
        } catch {
            XCTAssertEqual((error as? SupabaseError).map { "\($0)" }, "\(SupabaseError.decoding("the pin-media response"))")
        }
    }
}

/// Answers each request with the next queued (status, JSON body) and records the request and the body it carried.
final class UploadStub: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var replies: [(Int, String)] = []

    static func reset() { requests = []; bodies = []; replies = [] }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.bodies.append(body)
        let (status, text) = Self.replies.isEmpty ? (500, #"{"error":"no reply queued"}"#) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
