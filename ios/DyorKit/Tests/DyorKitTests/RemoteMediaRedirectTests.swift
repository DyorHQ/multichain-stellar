import XCTest
@testable import DyorKit

/// The image loader (`RemoteMedia`) follows no redirect to another host: a gateway that applies a creator's `_redirects`
/// file could otherwise send a coin's picture request to a host its creator chose (pick 6).
final class RemoteMediaRedirectTests: XCTestCase {
    private let cid = "bafybeid4i22y4u6jdmdcsqfr3el3mhsy76pcbdufk2jnwxrdueusbjtp4q"

    override func setUp() { RedirectStub.reset() }

    /// The image loader follows a redirect only over https to the same host or one under it (dweb.link's own hop to its
    /// subdomain gateway); one to another host — a gateway applying a creator's `_redirects` — or down to http ends the
    /// fetch, and the host it pointed at is never asked. The rule is the fetch's own (its task delegate), so it holds in
    /// whatever session the fetch runs.
    func testTheImageLoaderFollowsNoRedirectToAnotherHost() async throws {
        let png = Data(repeating: 7, count: 64)
        RedirectStub.routes = [
            "https://cdn.example/same": .redirect("https://cdn.example/final.png"),
            "https://dweb.link/ipfs/\(cid)": .redirect("https://\(cid).ipfs.dweb.link/"),
            "https://dweb.link/ipfs/other": .redirect("https://creator-tracker.example/pixel.png"),
            "https://cdn.example/down": .redirect("http://cdn.example/final.png"),
            "https://cdn.example/final.png": .body(png),
            "https://\(cid).ipfs.dweb.link/": .body(png),
            "https://creator-tracker.example/pixel.png": .body(png),
            "http://cdn.example/final.png": .body(png),
        ]
        let session = RedirectStub.session()
        let same = try await RemoteMedia.fetch(URL(string: "https://cdn.example/same")!, session: session)
        XCTAssertEqual(same, png, "same host")
        let sub = try await RemoteMedia.fetch(URL(string: "https://dweb.link/ipfs/\(cid)")!, session: session)
        XCTAssertEqual(sub, png, "a subdomain of the host")
        for refused in ["https://dweb.link/ipfs/other", "https://cdn.example/down"] {
            do {
                _ = try await RemoteMedia.fetch(URL(string: refused)!, session: session)
                XCTFail("followed \(refused)")
            } catch {
                XCTAssertEqual(error as? RemoteMedia.Failure, .redirected, refused)
            }
        }
        XCTAssertFalse(RedirectStub.asked().contains("https://creator-tracker.example/pixel.png"), "the creator's host is never asked")
        XCTAssertFalse(RedirectStub.asked().contains("http://cdn.example/final.png"))
        XCTAssertTrue(RemoteMedia.mayFollow(from: URL(string: "https://dweb.link/ipfs/x")!, to: URL(string: "https://x.ipfs.dweb.link/")!))
        XCTAssertFalse(RemoteMedia.mayFollow(from: URL(string: "https://dweb.link/ipfs/x")!, to: URL(string: "https://evildweb.link/")!), "a suffix that isn't a subdomain")
        XCTAssertFalse(RemoteMedia.mayFollow(from: URL(string: "https://cdn.example/a")!, to: URL(string: "https://cdn.example:8443/a")!))
    }
}

/// Answers each URL from `routes`: a body, or a 302 to another URL; records every URL asked.
final class RedirectStub: URLProtocol {
    enum Route { case body(Data), redirect(String) }

    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var requested: [String] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        requested = []
    }

    static func asked() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requested.append(url.absoluteString)
        let route = Self.routes[url.absoluteString]
        Self.lock.unlock()
        switch route {
        case .redirect(let target)?:
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let data)?:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
