import CoreGraphics
import Foundation
import ImageIO

/// Fetching and decoding images from hosts DyorHQ does not control — coin logos written on-chain by whoever launched
/// the coin, Moment media, NFT art, news thumbnails, profile avatars (security audit 2026-09-26, RI-5). A few MB on the
/// wire can declare a 30 000 × 30 000 image that takes gigabytes to decode, and a server can stream forever, so every
/// such image goes through here: the body is read up to a byte cap, the image's declared size is checked before any
/// pixel is decoded, and only a thumbnail at the size the screen shows is ever decoded.
public enum RemoteMedia {
    /// The most bytes read for one image.
    public static let maxImageBytes = 10 * 1024 * 1024
    /// The longest side, in pixels, an image may declare and still be decoded.
    public static let maxSourceDimension = 8192
    /// The most pixels an image may declare and still be decoded (a 48 MP camera photo fits).
    public static let maxSourcePixels = 50_000_000

    /// What one image may cost before it is refused: bytes read, and pixels it may declare.
    public struct Caps: Equatable, Sendable {
        public let maxBytes: Int
        public let maxSourcePixels: Int
        public init(maxBytes: Int, maxSourcePixels: Int) { self.maxBytes = maxBytes; self.maxSourcePixels = maxSourcePixels }
    }

    /// The largest thumbnail, in pixels across, that is held to the small caps.
    public static let smallThumbnail = 512
    /// The most bytes read for a logo-sized image (`caps(forThumbnail:)`): also the line between the two kinds of download
    /// slot (`fetchSlots`).
    public static let smallImageBytes = 2 * 1024 * 1024

    /// The caps for an image shown at most `maxPixelSize` pixels across. A logo, avatar, chain badge or list thumbnail
    /// (up to `smallThumbnail`) needs no more than 2 MB and 16 MP, and a scrolling list loads dozens of them; larger
    /// artwork keeps the full caps.
    public static func caps(forThumbnail maxPixelSize: Int) -> Caps {
        maxPixelSize <= smallThumbnail ? Caps(maxBytes: smallImageBytes, maxSourcePixels: 16_000_000)
            : Caps(maxBytes: maxImageBytes, maxSourcePixels: maxSourcePixels)
    }

    /// Small remote image downloads (capped at `smallImageBytes`: logos, list thumbnails, Storage's resized copies),
    /// app-wide, at once: a list of hostile logos can't hold more than 8 × 2 MB of bodies. Eight: a board's first screen
    /// is about that many pictures, and DyorHQ's own hosts answer them over one HTTP/2 connection, so they don't come in
    /// two rounds.
    public static let fetches = AsyncLimiter(8)
    /// Downloads under the full caps (a Moment's hash-checked original, a page header's picture), app-wide, at once, in
    /// slots of their own: four, not eight, so each has a quarter of the link rather than an eighth — a legacy 4096 px
    /// Moment photo (up to 4.8 MB) arrives in time on a slow link, and the first of a board's cards paints before the
    /// last starts — and at most 4 × 10 MB of bodies.
    public static let largeFetches = AsyncLimiter(4)
    /// How long a download from DyorHQ's own host or one of the app's gateways may take in all (`ImageFetcher.network`):
    /// two minutes, where any other host has 30 s. The byte cap bounds the transfer, and the wait for data (8 or 12 s,
    /// `ImageSourcePolicy.requestTimeout`) still ends one whose server stalls; 30 s cut off a whole Moment photo sharing
    /// a slow link with the other cards (3.5 MB at about 5 Mbps shared four ways takes about 22 s, eight ways over 40).
    public static let trustedResourceTimeout: TimeInterval = 120

    /// The slots a download capped at `maxBytes` waits its turn for: `largeFetches` past `smallImageBytes`, else `fetches`.
    public static func fetchSlots(maxBytes: Int) -> AsyncLimiter { maxBytes > smallImageBytes ? largeFetches : fetches }
    /// Remote image decodes, app-wide, at once: an image ImageIO can't subsample (a PNG) may need its full bitmap.
    public static let decodes = AsyncLimiter(2)

    public enum Failure: Error, Equatable {
        /// Only https is fetched.
        case insecureURL
        /// The server answered with a status outside 2xx.
        case status(Int)
        /// The body is, or says it is, larger than the cap.
        case tooLarge
        /// The bytes are not an image ImageIO can read (an HTML page, an SVG, garbage).
        case notAnImage
        /// The image declares more pixels than may be decoded.
        case tooManyPixels
        /// The server sent the request somewhere `mayFollow` doesn't allow.
        case redirected
    }

    /// Whether a fetch of `original` may follow a redirect to `target`: https, on the same host or one under it — as
    /// dweb.link sends `/ipfs/<cid>` to `<cid>.ipfs.dweb.link` — and no other port. Anything else could be a host a
    /// coin's creator chose (a gateway applies a creator's `_redirects` file), which must never learn who looked (pick 6).
    public static func mayFollow(from original: URL, to target: URL) -> Bool {
        guard target.scheme?.lowercased() == "https", target.port == nil || target.port == 443, target.user == nil, target.password == nil,
              let from = original.host?.lowercased(), !from.isEmpty, let to = target.host?.lowercased(), !to.isEmpty else { return false }
        return to == from || to.hasSuffix("." + from)
    }

    /// A session for untrusted media: no cookies or stored credentials, and a limit on the whole transfer as well as
    /// on each wait for data, so a server that trickles bytes can't hold a request open. `storesResponses: false` keeps
    /// its answers out of `URLCache` altogether, and never answers from it: the image pipeline keeps what it accepted
    /// itself (`ImageDiskCache`), so a second copy would only crowd out the app's other responses.
    public static func makeSession(requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 30, storesResponses: Bool = true) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        if !storesResponses {
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        }
        return URLSession(configuration: configuration)
    }

    /// GETs `url` (https only) and returns its body, reading at most `maxBytes`: refused up front when the declared
    /// Content-Length is larger, and cancelled as soon as the body grows past the cap. The body arrives in the chunks
    /// the network delivers (a task delegate), so the cap costs nothing per byte. A redirect is followed only where
    /// `mayFollow` allows; any other ends the fetch (`Failure.redirected`), whatever session it runs in. `timeout`, when
    /// given, is this request's longest wait for data (shorter than the session's for a host that answers fast when it
    /// is up, `ImageSourcePolicy.requestTimeout`); `onResponse` is called once the server has answered 2xx within the
    /// cap and the body starts — what the image pipeline waits for before it asks the next source (`ImageSourceRace`).
    public static func fetch(_ url: URL, session: URLSession, maxBytes: Int = maxImageBytes, timeout: TimeInterval? = nil,
                             onResponse: (@Sendable () -> Void)? = nil) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.insecureURL }
        var request = URLRequest(url: url)
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if let timeout { request.timeoutInterval = timeout }
        let task = session.dataTask(with: request)
        let load = CappedLoad(maxBytes: maxBytes, onResponse: onResponse)
        task.delegate = load
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in load.start(task, continuation) }
        } onCancel: {
            task.cancel()
        }
    }

    /// The pixel size `data` declares, read from its header without decoding a pixel, once it is checked: an image
    /// ImageIO can read (not an HTML page, an SVG or garbage: `Failure.notAnImage`) within the caps
    /// (`Failure.tooManyPixels`). `thumbnail` runs the same check first; the image pipeline runs it on a download before
    /// it accepts it, so a source whose bytes are no image falls through to the next.
    public static func inspect(_ data: Data, maxSourceDimension: Int = maxSourceDimension, maxSourcePixels: Int = maxSourcePixels) throws -> (width: Int, height: Int) {
        try inspected(data, maxSourceDimension: maxSourceDimension, maxSourcePixels: maxSourcePixels).size
    }

    private static func inspected(_ data: Data, maxSourceDimension: Int, maxSourcePixels: Int) throws -> (source: CGImageSource, size: (width: Int, height: Int)) {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw Failure.notAnImage }
        guard width <= maxSourceDimension, height <= maxSourceDimension, width * height <= maxSourcePixels else { throw Failure.tooManyPixels }
        return (source, (width, height))
    }

    /// Decodes `data` as a thumbnail whose longer side is at most `maxPixelSize` (never scaled up), after checking the
    /// size the image declares (`inspect`) — so the full-resolution image is never decoded. The EXIF orientation is
    /// applied, and any thumbnail embedded in the file is ignored (it need not match the image).
    public static func thumbnail(_ data: Data, maxPixelSize: Int, maxSourceDimension: Int = maxSourceDimension,
                                 maxSourcePixels: Int = maxSourcePixels) throws -> CGImage {
        let (source, (width, height)) = try inspected(data, maxSourceDimension: maxSourceDimension, maxSourcePixels: maxSourcePixels)
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, max(width, height))),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw Failure.notAnImage }
        return image
    }
}

/// One capped download: checks the response, appends the body's chunks up to the cap, and answers once. Its callbacks
/// run on the session's serial delegate queue; `start` runs on the caller's. The continuation is handed between the
/// two under a lock, so it is resumed exactly once, whichever comes first — the task's completion, or a cancellation
/// that got in before the task was resumed.
private final class CappedLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let onResponse: (@Sendable () -> Void)?
    private var data = Data()
    private var failure: RemoteMedia.Failure?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(maxBytes: Int, onResponse: (@Sendable () -> Void)?) {
        self.maxBytes = maxBytes
        self.onResponse = onResponse
    }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Data, Error>) {
        // Only a task never resumed can be started. One already cancelled (canceling, or completed if its completion
        // came first) may never report back, so it is answered here; one cancelled from now on reports its
        // completion, which finds the continuation stored.
        lock.lock()
        let startable = task.state == .suspended
        if startable { self.continuation = continuation }
        lock.unlock()
        guard startable else { continuation.resume(throwing: CancellationError()); return }
        task.resume()
    }

    /// The continuation, taken once.
    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url, RemoteMedia.mayFollow(from: original, to: target) else {
            failure = .redirected
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if failure != nil {
            completionHandler(.cancel)
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = .status(http.statusCode)
            completionHandler(.cancel)
        } else if response.expectedContentLength > Int64(maxBytes) {
            failure = .tooLarge
            completionHandler(.cancel)
        } else {
            data.reserveCapacity(Int(max(response.expectedContentLength, 0)))
            completionHandler(.allow)
            onResponse?()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard data.count + chunk.count <= maxBytes else {
            failure = .tooLarge
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = take() else { return }
        if let failure { continuation.resume(throwing: failure) }
        else if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: data) }
    }
}
