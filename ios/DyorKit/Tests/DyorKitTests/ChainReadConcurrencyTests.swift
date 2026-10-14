import BigInt
import XCTest
@testable import DyorKit

/// A list is read at most `Multicall.readsInFlight` (4) reads at a time, its chunks and its per-item retries alike: the
/// public RPC answers about 50 requests a second and throttles a burst of 100 (measured), and a big list used to send
/// every chunk, then every retry, at once. The results still come back item by item, in order, and an error that isn't
/// about the call still throws.
final class ChainReadConcurrencyTests: XCTestCase {
    /// Item `i`'s one call, answered with `i`.
    private static func call(_ i: Int) -> ContractCall {
        try! ContractCall(to: Address(literal: "0x0000000000000000000000000000000000c0c0c0"), "value(uint256)", [.uint(BigUInt(i))], returns: "uint256")
    }

    private static func values(_ results: [[Result<[ABIValue], Error>]]) -> [BigUInt?] {
        results.map { (try? $0[0].get())?.first?.uint }
    }

    func testChunksAreReadFourAtATimeAndInOrder() async throws {
        SlowChainStub.install()
        let results = try await Multicall(rpc: SlowChainStub.rpc()).readItems((0..<20).map { [Self.call($0)] }, text: [], what: .launch, chunk: 1)
        XCTAssertEqual(Self.values(results), (0..<20).map { BigUInt($0) })
        let seen = SlowChainStub.seen()
        XCTAssertEqual(seen.requests, 20, "20 chunks")
        XCTAssertLessThanOrEqual(seen.maxInFlight, Multicall.readsInFlight)
        XCTAssertGreaterThan(seen.maxInFlight, 1, "still several at once")
        XCTAssertEqual(Multicall.readsInFlight, 4)
    }

    /// Every chunk of two is refused as a whole (out of gas), so all 40 items are read again one at a time: four at a time.
    func testRetriesAreReadFourAtATimeAndInOrder() async throws {
        SlowChainStub.install(refusingMoreThan: 1)
        let results = try await Multicall(rpc: SlowChainStub.rpc()).readItems((0..<40).map { [Self.call($0)] }, text: [], what: .launch, chunk: 2)
        XCTAssertEqual(Self.values(results), (0..<40).map { BigUInt($0) })
        let seen = SlowChainStub.seen()
        XCTAssertEqual(seen.requests, 20 + 40, "20 refused chunks, then 40 items alone")
        XCTAssertLessThanOrEqual(seen.maxInFlight, Multicall.readsInFlight)
        XCTAssertGreaterThan(seen.maxInFlight, 1)
    }

    /// An error that isn't about the call (a node that can't serve the read) throws, from a chunk and from a retry, as
    /// before: never a shorter list.
    func testAnErrorThatIsntAboutTheCallStillThrows() async {
        SlowChainStub.install(failingAll: true)
        do {
            _ = try await Multicall(rpc: SlowChainStub.rpc()).readItems((0..<20).map { [Self.call($0)] }, text: [], what: .launch, chunk: 1)
            XCTFail("a read the node can't serve throws")
        } catch {
            XCTAssertFalse(error is ChainListUnread, "the node's error, not a missing item: \(error)")
        }
        SlowChainStub.install(refusingMoreThan: 1, failingAlone: true)
        do {
            _ = try await Multicall(rpc: SlowChainStub.rpc()).readItems((0..<8).map { [Self.call($0)] }, text: [], what: .launch, chunk: 2)
            XCTFail("a retry the node can't serve throws")
        } catch {
            XCTAssertFalse(error is ChainListUnread, "the node's error, not a missing item: \(error)")
        }
    }
}

/// A node that answers each `eth_call` to Multicall3 after 30 ms, counting how many requests are in flight at once. Each
/// sub-call `value(uint256 i)` answers `i`. `refusingMoreThan`: an aggregate of more sub-calls fails as a whole, out of
/// gas (a call error, which `readItems` retries item by item). `failingAll` / `failingAlone`: every request, or every
/// single-call aggregate, fails with an error that isn't about the call.
final class SlowChainStub: URLProtocol {
    static let rpcURL = URL(string: "https://rpc.slow-stub.invalid")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var maxInFlight = 0
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var refusingMoreThan: Int?
    nonisolated(unsafe) private static var failingAll = false
    nonisolated(unsafe) private static var failingAlone = false

    static func install(refusingMoreThan: Int? = nil, failingAll: Bool = false, failingAlone: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        inFlight = 0
        maxInFlight = 0
        requests = 0
        self.refusingMoreThan = refusingMoreThan
        self.failingAll = failingAll
        self.failingAlone = failingAlone
    }

    static func seen() -> (requests: Int, maxInFlight: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, maxInFlight)
    }

    static func rpc() -> RPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowChainStub.self]
        return RPCClient(url: rpcURL, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.inFlight += 1
        Self.requests += 1
        Self.maxInFlight = max(Self.maxInFlight, Self.inFlight)
        let refusing = Self.refusingMoreThan, failingAll = Self.failingAll, failingAlone = Self.failingAlone
        Self.lock.unlock()
        let body = Self.body(request)
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) { [self] in
            let decoded = (try? JSONDecoder().decode(JSON.self, from: body)) ?? .null
            let calls = decoded.array ?? [decoded]
            let replies = calls.map { Self.reply($0, refusing: refusing, failingAll: failingAll, failingAlone: failingAlone) }
            let data = (try? JSONEncoder().encode(decoded.array == nil ? replies[0] : .array(replies))) ?? Data()
            Self.lock.lock(); Self.inFlight -= 1; Self.lock.unlock()
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func reply(_ call: JSON, refusing: Int?, failingAll: Bool, failingAlone: Bool) -> JSON {
        let id = call["id"]
        func error(_ message: String) -> JSON {
            .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32000), "message": .string(message)])])
        }
        guard call["method"].string == "eth_call", let tx = call["params"].array?.first, let data = tx["data"].string.flatMap({ Data(hex: $0) }),
              let inner = try? ABI.decode(data.dropFirst(4), "(address,bool,bytes)[]")[0].elements else { return error("unsupported") }
        if failingAll || (failingAlone && inner.count == 1) { return error("header not found") }
        if let refusing, inner.count > refusing { return error("out of gas") }
        let answers: [ABIValue] = inner.map { item in
            let calldata = item[2].bytes
            return .tuple([.bool(true), .bytes(try! ABI.encode([.uint(BigUInt(calldata.suffix(32)))], "uint256"))])
        }
        let encoded = (try? ABI.encode([.array(answers)], "(bool,bytes)[]")) ?? Data()
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": .string(encoded.hexString)])
    }

    private static func body(_ request: URLRequest) -> Data {
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
}
