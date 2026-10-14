import BigInt
import XCTest
@testable import DyorKit

/// The keyless-RPC transport: failover between public endpoints on transport errors and 429/5xx (never on a request
/// error), batch splitting at the endpoint's cap, and a transaction resend that the network already knows resolving to
/// its hash instead of an error.
final class RPCFailoverTests: XCTestCase {
    private let primary = URL(string: "https://primary.test")!
    private let secondary = URL(string: "https://secondary.test")!

    override func setUp() {
        super.setUp()
        RPCStub.reset()
    }

    private func client(maxBatch: Int = 100) -> RPCClient {
        RPCClient(urls: [primary, secondary], session: RPCStub.session(), maxBatch: maxBatch)
    }

    /// EIP-1559 fees: tip = the node's suggestion, max fee = 2 × base + tip (Monad: base 100 gwei, tip 2 gwei → an
    /// effective 102 gwei instead of the 202 gwei the old "tip = gas price" rule paid). Without the tip method, the old
    /// rule is the fallback.
    func testFeeParametersUseSuggestedTip() async throws {
        RPCStub.baseFee = "0x174876e800" // 100 gwei
        RPCStub.tip = "0x77359400"       // 2 gwei
        let fees = try await TransactionSender(rpc: client()).feeParameters()
        XCTAssertEqual(fees.tip, BigUInt(2_000_000_000))
        XCTAssertEqual(fees.maxFee, BigUInt(202_000_000_000))

        RPCStub.reset() // no eth_maxPriorityFeePerGas, no baseFeePerGas
        let fallback = try await TransactionSender(rpc: client()).feeParameters()
        XCTAssertEqual(fallback.tip, BigUInt(102_000_000_000))
        XCTAssertEqual(fallback.maxFee, BigUInt(204_000_000_000))
    }

    /// The same request sent as a read (the head: raced across the endpoints, `RPCClient.race`) and as anything else (the
    /// gas price a transaction is signed with: one endpoint at a time, `post`, the path of broadcasts, receipts, the
    /// pending nonce, gas and the base fee), with what each answers here. Failover, backoff, fail-fast and the preference
    /// must hold for both.
    private let sends: [(kind: String, send: (RPCClient) async throws -> BigUInt, answer: BigUInt)] = [
        ("a read", { BigUInt(try await $0.blockNumber()) }, 0x10),
        ("not a read", { try await $0.gasPrice() }, BigUInt(102_000_000_000)),
    ]

    func testFailsOverOn429() async throws {
        for (kind, send, answer) in sends {
            RPCStub.reset()
            RPCStub.status["primary.test"] = 429
            let value = try await send(client())
            XCTAssertEqual(value, answer, kind)
            XCTAssertEqual(RPCStub.hosts, ["primary.test", "secondary.test"], kind)
        }
    }

    func testFailsOverOnServerErrorAndTransportFailure() async throws {
        for (kind, send, _) in sends {
            RPCStub.reset()
            RPCStub.status["primary.test"] = 503
            _ = try await send(client())
            XCTAssertEqual(RPCStub.hosts, ["primary.test", "secondary.test"], kind)

            RPCStub.reset()
            RPCStub.transportFailure.insert("primary.test")
            _ = try await send(client())
            XCTAssertEqual(RPCStub.hosts, ["primary.test", "secondary.test"], kind)
        }
    }

    func testDoesNotFailOverOnARequestError() async {
        for (kind, send, _) in sends {
            RPCStub.reset()
            RPCStub.status["primary.test"] = 400
            do {
                _ = try await send(client())
                XCTFail("\(kind): expected badStatus(400)")
            } catch NetworkError.badStatus(let code) {
                XCTAssertEqual(code, 400, kind)
            } catch { XCTFail("\(kind): unexpected \(error)") }
            XCTAssertEqual(RPCStub.hosts, ["primary.test"], kind)
        }
    }

    /// A request error whose body is the JSON-RPC error of the call is that error, as rpc1 sends a single-object
    /// `eth_getLogs` over its log cap (HTTP 400, measured 2026-09-30; the same call in a one-item array: HTTP 200), and
    /// rpc.monad.xyz a range over its 100 blocks (HTTP 413): the refusal and the range it names reach the scan. No other
    /// endpoint is asked, as before.
    func testARequestErrorWhoseBodyIsTheJSONRPCErrorIsThatError() async throws {
        let refusal = "Log response size exceeded. Based on your parameters and the response size limit, this block range should work: [0x0, 0x5876751]"
        for (status, code, message) in [(400, -32602, refusal), (413, -32614, "eth_getLogs is limited to a 100 range")] {
            RPCStub.reset()
            RPCStub.status["primary.test"] = status
            RPCStub.statusError["primary.test"] = (code, message)
            do {
                _ = try await client().call("eth_getLogs", [.object(["fromBlock": .string("0x0"), "toBlock": .string("latest")])])
                XCTFail("expected the JSON-RPC error")
            } catch let error as RPCError {
                XCTAssertEqual(error, RPCError(code: code, message: message), "\(status)")
                XCTAssertTrue(RPCClient.refusesSize(error))
            }
            XCTAssertEqual(RPCStub.hosts, ["primary.test"], "\(status): never failed over")
        }
        // A batch refused the same way: each call its own error, in order.
        RPCStub.reset()
        RPCStub.status["primary.test"] = 400
        RPCStub.statusError["primary.test"] = (-32602, refusal)
        let results = try await client().batch([(method: "eth_getLogs", params: []), (method: "eth_getLogs", params: [])])
        XCTAssertEqual(results.map { result -> Int? in if case .failure(let error) = result { return error.code }; return nil }, [-32602, -32602])
        XCTAssertEqual(RPCStub.hosts, ["primary.test"])
    }

    /// Anything else in a request error's body is the status, as before: none, text, an error for another id, a result.
    func testARequestErrorWithoutTheCallsJSONRPCErrorIsItsStatus() async {
        for (kind, send, _) in sends {
            for body in ["", "Bad Request", #"{"jsonrpc":"2.0","id":999,"error":{"code":-32602,"message":"x"}}"#, #"{"jsonrpc":"2.0","id":1,"result":"0x10"}"#] {
                RPCStub.reset()
                RPCStub.status["primary.test"] = 400
                RPCStub.statusBody["primary.test"] = body
                do {
                    _ = try await send(client())
                    XCTFail("expected badStatus(400)")
                } catch NetworkError.badStatus(let code) {
                    XCTAssertEqual(code, 400, "\(kind) \(body)")
                } catch { XCTFail("unexpected \(error) for \(kind) \(body)") }
                XCTAssertEqual(RPCStub.hosts, ["primary.test"], "\(kind) \(body)")
            }
        }
    }

    /// A 429 or a 5xx fails over and backs off as before, whatever its body says.
    func testAThrottleWithAJSONRPCBodyStillFailsOver() async throws {
        for (kind, send, answer) in sends {
            RPCStub.reset()
            RPCStub.status["primary.test"] = 429
            RPCStub.statusError["primary.test"] = (-32005, "rate limit exceeded")
            let value = try await send(client())
            XCTAssertEqual(value, answer, kind)
            XCTAssertEqual(RPCStub.hosts, ["primary.test", "secondary.test"], kind)

            RPCStub.reset()
            RPCStub.status = ["primary.test": 429, "secondary.test": 503]
            RPCStub.statusError = ["primary.test": (-32005, "rate limit exceeded"), "secondary.test": (-32603, "Internal error")]
            do {
                _ = try await send(client())
                XCTFail("\(kind): expected failure")
            } catch NetworkError.badStatus(let code) {
                XCTAssertEqual(code, 503, kind)
            } catch { XCTFail("\(kind): unexpected \(error)") }
            XCTAssertEqual(RPCStub.hosts.count, 10, "\(kind): every endpoint in each of the five rounds, as before")
        }
    }

    func testThrowsWhenEveryEndpointFails() async {
        for (kind, send, _) in sends {
            RPCStub.reset()
            RPCStub.status["primary.test"] = 429
            RPCStub.status["secondary.test"] = 502
            do {
                _ = try await send(client())
                XCTFail("\(kind): expected failure")
            } catch NetworkError.badStatus(let code) {
                XCTAssertEqual(code, 502, kind)
            } catch { XCTFail("\(kind): unexpected \(error)") }
        }
    }

    func testBacksOffWhenEveryEndpointThrottlesAtOnce() async throws {
        for (kind, send, answer) in sends {
            RPCStub.reset()
            // Measured live: under a burst both public endpoints can answer 429 to the same request.
            RPCStub.failFirst = ["primary.test": 1, "secondary.test": 1]
            let value = try await send(client())
            XCTAssertEqual(value, answer, kind)
            XCTAssertEqual(RPCStub.hosts, ["primary.test", "secondary.test", "primary.test"], "\(kind): one full round throttled, then a retry after backoff")
        }
    }

    func testFailsFastWhenOffline() async {
        for (kind, send, _) in sends {
            RPCStub.reset()
            RPCStub.transportFailure = ["primary.test", "secondary.test"]
            let start = Date()
            do { _ = try await send(client()); XCTFail("\(kind): expected a transport error") } catch {}
            XCTAssertEqual(RPCStub.hosts.count, 2, "\(kind): no backoff rounds when nothing answered at all")
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, kind)
        }
    }

    func testPrefersTheEndpointThatAnswered() async throws {
        for (kind, send, _) in sends {
            RPCStub.reset()
            let rpc = client()
            RPCStub.status["primary.test"] = 429
            _ = try await send(rpc)
            RPCStub.hosts = []
            _ = try await send(rpc)
            XCTAssertEqual(RPCStub.hosts, ["secondary.test"], "\(kind): a throttled primary is not retried on every call")
            // And the other kind of request after it, on the same client: the preference is the client's, not the path's.
            RPCStub.hosts = []
            _ = try await sends.first { $0.kind != kind }!.send(rpc)
            XCTAssertEqual(RPCStub.hosts, ["secondary.test"], kind)
        }
    }

    func testSplitsBatchesAtTheCapAndKeepsOrder() async throws {
        let rpc = client(maxBatch: 3)
        let calls = (0..<7).map { i in (method: "echo", params: [JSON.number(Double(i))]) }
        let results = try await rpc.batch(calls)
        XCTAssertEqual(RPCStub.requestSizes, [3, 3, 1])
        XCTAssertEqual(results.map { try? $0.get().number }, (0..<7).map { Double($0) })
    }

    func testRetriesOnlyTheItemsTheEndpointThrottled() async throws {
        // rpc.monad.xyz behaviour: HTTP 200, the items over its per-second budget fail with a rate-limit message.
        RPCStub.itemBudget["primary.test"] = 2
        let calls = (0..<5).map { i in (method: "echo", params: [JSON.number(Double(i))]) }
        let results = try await client().batch(calls)
        XCTAssertEqual(results.map { try? $0.get().number }, (0..<5).map { Double($0) }, "every call answered, in order")
        XCTAssertEqual(RPCStub.hosts, ["primary.test", "secondary.test"])
        XCTAssertEqual(RPCStub.requestSizes, [5, 3], "only the 3 throttled calls are re-sent")
    }

    func testGivesUpAfterBoundedRetriesWhenEverythingThrottles() async throws {
        RPCStub.itemBudget["primary.test"] = 0
        RPCStub.itemBudget["secondary.test"] = 0
        let results = try await client().batch([(method: "echo", params: [.number(1)])])
        guard case .failure(let error) = results[0] else { return XCTFail("expected the throttle error to surface") }
        XCTAssertTrue(RPCClient.isRateLimited(error))
        XCTAssertEqual(RPCStub.hosts.count, 5, "1 attempt + 4 bounded retries, never an endless loop")
    }

    func testThrottleClassificationNeverSwallowsRealErrors() {
        func e(_ code: Int, _ m: String) -> RPCError { RPCError(code: code, message: m) }
        // Throttling, as the live endpoints phrase it (measured 2026-09-22).
        XCTAssertTrue(RPCClient.isRateLimited(e(-32007, "50/second request limit reached - reduce calls per second or upgrade your account")))
        XCTAssertTrue(RPCClient.isRateLimited(e(-32000, "Too many requests, reason: call rate limit exhausted, retry in 10s")))
        XCTAssertTrue(RPCClient.isRateLimited(e(-32005, "limit exceeded")))
        XCTAssertTrue(RPCClient.isRateLimited(e(429, "Your app has exceeded its compute units per second capacity")))
        // Real answers about the call — must never be retried as throttling.
        for m in ["execution reverted", "execution reverted: ERC20: transfer amount exceeds balance", "nonce too low",
                  "gas required exceeds allowance (30000000)", "insufficient funds for gas * price + value",
                  "max fee per gas less than block base fee", "intrinsic gas too low", "already known", "out of gas"] {
            XCTAssertFalse(RPCClient.isRateLimited(e(-32000, m)), m)
        }
        XCTAssertFalse(RPCClient.isRateLimited(e(3, "execution reverted")))
    }

    /// Live burst against Monad's real public endpoints — opt-in (DYORHQ_NETWORK_TESTS=1) so CI stays offline. Mixes the
    /// shapes that trip each endpoint's limit: an oversized batch, a burst of concurrent single calls, and concurrent
    /// batches. The client, made as the app makes it, must answer every call.
    func testLiveBurstAgainstPublicMonadRPC() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DYORHQ_NETWORK_TESTS"] == "1", "set DYORHQ_NETWORK_TESTS=1")
        let rpc = RPCClient(urls: Monad.publicRPCs, maxBatch: 40, itemsPerSecond: 50)
        let big = try await rpc.batch((0..<150).map { _ in (method: "eth_chainId", params: []) })
        let singles = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<60 { group.addTask { try await rpc.chainId() } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        let batches = try await withThrowingTaskGroup(of: [Result<JSON, RPCError>].self) { group in
            for _ in 0..<6 { group.addTask { try await rpc.batch((0..<30).map { _ in (method: "eth_blockNumber", params: []) }) } }
            return try await group.reduce(into: [Result<JSON, RPCError>]()) { $0 += $1 }
        }
        let failures = (big + batches).filter { if case .failure = $0 { return true }; return false }.count
        XCTAssertEqual(failures, 0, "\(failures) of \(big.count + batches.count) batched calls failed")
        XCTAssertEqual(singles.count, 60)
        XCTAssertTrue(singles.allSatisfy { $0 == Monad.chainId })
    }

    func testResendTheNetworkAlreadyKnowsResolvesToTheHash() async throws {
        let signed = Data(hex: "0x02f86b818f8085174876e800850ba43b7400825208941111111111111111111111111111111111111111880de0b6b3a764000080c001a0aaaa")!
        RPCStub.sendError = "already known"
        let hash = try await client().sendRawTransaction(signed)
        XCTAssertEqual(hash, Keccak.hash256(signed))
    }

    func testNonceTooLowIsSuccessOnlyForThisVeryTransaction() async throws {
        let signed = Data(hex: "0x02f86b818f0185174876e800850ba43b7400825208942222222222222222222222222222222222222222880de0b6b3a764000080c001a0bbbb")!
        RPCStub.sendError = "nonce too low"
        RPCStub.knownTransactions = [Keccak.hash256(signed).hexString]
        let hash = try await client().sendRawTransaction(signed)
        XCTAssertEqual(hash, Keccak.hash256(signed))

        RPCStub.knownTransactions = []
        do {
            _ = try await client().sendRawTransaction(signed)
            XCTFail("another transaction used the nonce — must stay an error")
        } catch let error as RPCError {
            XCTAssertTrue(error.message.contains("nonce too low"))
        }
    }
}

/// A JSON-RPC endpoint stub keyed by host: a status per host, transport failures, and per-method replies.
final class RPCStub: URLProtocol {
    nonisolated(unsafe) static var status: [String: Int] = [:]
    nonisolated(unsafe) static var transportFailure: Set<String> = []
    nonisolated(unsafe) static var hosts: [String] = []
    nonisolated(unsafe) static var requestSizes: [Int] = []
    nonisolated(unsafe) static var sendError: String?
    nonisolated(unsafe) static var knownTransactions: [String] = []
    /// Items per request the host answers before failing the rest with rpc.monad.xyz's throttle message (HTTP 200).
    nonisolated(unsafe) static var itemBudget: [String: Int] = [:]
    /// The first N requests to a host answer HTTP 429, then it serves normally.
    nonisolated(unsafe) static var failFirst: [String: Int] = [:]
    /// A JSON-RPC error a host sends for every call as the body of its `status` (none: an empty body), as rpc1 sends a
    /// size refusal in an HTTP 400; `statusBody` sends that text instead.
    nonisolated(unsafe) static var statusError: [String: (code: Int, message: String)] = [:]
    nonisolated(unsafe) static var statusBody: [String: String] = [:]
    /// Fee answers (hex quantities); nil makes the method fail the way a node without it would.
    nonisolated(unsafe) static var baseFee: String?
    nonisolated(unsafe) static var tip: String?
    nonisolated(unsafe) static var gasPrice: String? = "0x17bfac7c00" // 102 gwei
    /// A small simulated chain for running whole plans; nil keeps the fixed answers the transport tests rely on.
    nonisolated(unsafe) static var chain: SimulatedChain?
    /// Receipts by transaction hash (lowercased hex): `eth_getTransactionReceipt` answers them, after `nullReceiptReads`
    /// null answers (a node that hasn't seen the block yet). A hash with none fails as before.
    nonisolated(unsafe) static var receipts: [String: JSON] = [:]
    nonisolated(unsafe) static var nullReceiptReads = 0
    nonisolated(unsafe) static var receiptReads = 0

    static func reset() {
        status = [:]; transportFailure = []; hosts = []; requestSizes = []; sendError = nil; knownTransactions = []; itemBudget = [:]; failFirst = [:]
        statusError = [:]; statusBody = [:]
        baseFee = nil; tip = nil; gasPrice = "0x17bfac7c00"; chain = nil
        receipts = [:]; nullReceiptReads = 0; receiptReads = 0
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RPCStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.hosts.append(host)
        if Self.transportFailure.contains(host) {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var code = Self.status[host] ?? 200
        if let remaining = Self.failFirst[host], remaining > 0 { Self.failFirst[host] = remaining - 1; code = 429 }
        var body = Data()
        if code == 200 {
            let payload = Self.bodyData(request)
            let decoded = (try? JSONDecoder().decode(JSON.self, from: payload)) ?? .null
            let calls = decoded.array ?? [decoded]
            Self.requestSizes.append(calls.count)
            let budget = Self.itemBudget[host] ?? Int.max
            let replies = calls.enumerated().map { i, call -> JSON in
                guard i < budget else {
                    return .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object([
                        "code": .number(-32007), "message": .string("50/second request limit reached - reduce calls per second")])])
                }
                return Self.reply(call)
            }
            body = (try? JSONEncoder().encode(decoded.array == nil ? replies[0] : .array(replies))) ?? Data()
            // The simulated chain handled the request but its answer never arrives (or the request never did).
            if let chain = Self.chain, chain.takeTransportFailure() {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
        } else if let error = Self.statusError[host] {
            let decoded = (try? JSONDecoder().decode(JSON.self, from: Self.bodyData(request))) ?? .null
            let replies = (decoded.array ?? [decoded]).map { call -> JSON in
                .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object(["code": .number(Double(error.code)), "message": .string(error.message)])])
            }
            body = (try? JSONEncoder().encode(decoded.array == nil ? replies[0] : .array(replies))) ?? Data()
        } else if let text = Self.statusBody[host] {
            body = Data(text.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func reply(_ call: JSON) -> JSON {
        let id = call["id"]
        func result(_ value: JSON) -> JSON { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
        func failure(_ message: String) -> JSON {
            .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32000), "message": .string(message)])])
        }
        if let chain, let answer = chain.reply(call, result: result, failure: failure) { return answer }
        switch call["method"].string {
        case "eth_blockNumber": return result(.string("0x10"))
        case "echo": return result(call["params"].array?.first ?? .null)
        case "eth_getBlockByNumber": return result(.object(baseFee.map { ["number": .string("0x10"), "baseFeePerGas": .string($0)] } ?? ["number": .string("0x10")]))
        case "eth_maxPriorityFeePerGas": return tip.map { result(.string($0)) } ?? failure("method not found")
        case "eth_gasPrice": return gasPrice.map { result(.string($0)) } ?? failure("method not found")
        case "eth_sendRawTransaction": return sendError.map(failure) ?? result(.string("0x" + String(repeating: "ab", count: 32)))
        case "eth_getTransactionByHash":
            let asked = call["params"].array?.first?.string ?? ""
            return knownTransactions.contains(asked) ? result(.object(["hash": .string(asked)])) : result(.null)
        case "eth_getTransactionReceipt":
            let asked = (call["params"].array?.first?.string ?? "").lowercased()
            guard let receipt = receipts[asked] else { return failure("method not found") }
            receiptReads += 1
            if nullReceiptReads > 0 { nullReceiptReads -= 1; return result(.null) }
            return result(receipt)
        default: return failure("method not found")
        }
    }

    private static func bodyData(_ request: URLRequest) -> Data {
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

/// The chain behind `RPCStub.chain`: the head moves one block each time `eth_blockNumber` is read (time passing while a
/// caller polls) unless `frozen`, receipts confirm at the current head, and every broadcast is recorded with the head it
/// arrived at. Fees come from the stub's `baseFee` / `tip` / `gasPrice`.
final class SimulatedChain: @unchecked Sendable {
    var head: UInt64 = 100
    var frozen = false
    var balance: BigUInt = 0
    /// `eth_estimateGas`'s answer; nil fails it like a revert.
    var estimate: String? = "0x5208" // 21,000
    /// The next N broadcasts fail with `sendFailure`.
    var sendFailures = 0
    var sendFailure = "Signer had insufficient balance"
    /// The next N broadcasts are taken, but their answer is lost on the way back (a transport failure).
    var lostSendAnswers = 0
    /// The next N broadcasts never reach the node (a transport failure; nothing is taken).
    var unreachableSends = 0
    /// The next N broadcasts are taken, but answered with `sendFailure` (a gateway whose upstream took them).
    var takenSendFailures = 0
    /// The next N broadcasts are taken, but answered under another id (a reply the client can't match to its request).
    var unmatchedSendAnswers = 0
    /// The next N receipt or by-hash reads answer "unknown" whatever was taken (a node behind the one that took it).
    var hiddenLookups = 0
    /// Receipt reads that answer "pending" before a taken transaction's receipt appears.
    var pendingReceiptReads = 0
    /// The next N receipt reads fail at the transport (a socket that died while the app was suspended).
    var receiptReadFailures = 0
    /// Whether mined transactions succeed; false makes every receipt a revert.
    var receiptsSucceed = true
    /// When set, every multicall read answers one successful call returning this word (an ERC-20 allowance).
    var allowance: BigUInt?
    private(set) var blockNumberReads = 0
    private(set) var balanceReads = 0
    private(set) var sent: [(raw: String, head: UInt64)] = []
    private(set) var receiptBlocks: [UInt64] = []
    /// Hashes of the broadcasts the chain took: the only transactions it knows and has receipts for.
    private(set) var accepted: Set<String> = []
    private var transportFailure = false

    /// Whether the request just answered must fail at the transport instead (read once by `RPCStub`).
    func takeTransportFailure() -> Bool {
        defer { transportFailure = false }
        return transportFailure
    }

    func reply(_ call: JSON, result: (JSON) -> JSON, failure: (String) -> JSON) -> JSON? {
        func quantity(_ n: BigUInt) -> JSON { .string(n.hexQuantity) }
        switch call["method"].string {
        case "eth_blockNumber":
            blockNumberReads += 1
            defer { if !frozen { head += 1 } }
            return result(quantity(BigUInt(head)))
        case "eth_getBalance":
            balanceReads += 1
            return result(quantity(balance))
        case "eth_call":
            guard let allowance else { return result(.string("0x")) }
            return result(.string(try! ABI.encode([.array([.tuple([.bool(true), .bytes(allowance.word)])])], [.array(.tuple([.bool, .bytes]))]).hexString))
        case "eth_getTransactionCount": return result(.string("0x0"))
        case "eth_estimateGas": return estimate.map { result(.string($0)) } ?? failure("execution reverted")
        case "eth_sendRawTransaction":
            let raw = call["params"].array?.first?.string ?? ""
            if unreachableSends > 0 { unreachableSends -= 1; transportFailure = true; return result(.null) }
            sent.append((raw, head))
            if sendFailures > 0 { sendFailures -= 1; return failure(sendFailure) }
            let hash = Keccak.hash256(Data(hex: raw) ?? Data()).hexString
            accepted.insert(hash)
            if takenSendFailures > 0 { takenSendFailures -= 1; return failure(sendFailure) }
            if unmatchedSendAnswers > 0 { unmatchedSendAnswers -= 1; return .object(["jsonrpc": .string("2.0"), "id": .number(-7), "result": .string(hash)]) }
            if lostSendAnswers > 0 { lostSendAnswers -= 1; transportFailure = true }
            return result(.string(hash))
        case "eth_getTransactionReceipt":
            if receiptReadFailures > 0 { receiptReadFailures -= 1; transportFailure = true; return result(.null) }
            if hiddenLookups > 0 { hiddenLookups -= 1; return result(.null) }
            guard let asked = call["params"].array?.first?.string, accepted.contains(asked) else { return result(.null) }
            if pendingReceiptReads > 0 { pendingReceiptReads -= 1; return result(.null) }
            receiptBlocks.append(head)
            return result(.object(["status": .string(receiptsSucceed ? "0x1" : "0x0"), "blockNumber": quantity(BigUInt(head)), "gasUsed": .string("0x5208")]))
        case "eth_getTransactionByHash":
            if hiddenLookups > 0 { hiddenLookups -= 1; return result(.null) }
            let asked = call["params"].array?.first?.string ?? ""
            return result(accepted.contains(asked) ? .object(["hash": .string(asked)]) : .null)
        default: return nil
        }
    }
}

/// Signs nothing real: the unsigned payload stands in for the raw transaction, so each step broadcasts distinct bytes.
struct StubWallet: Wallet {
    let address = Address(literal: "0x1111111111111111111111111111111111111111")
    func sign(_ transaction: PreparedTransaction) async throws -> Data { RLP.unsignedPayload(transaction) }
    func signMessage(_ message: Data) async throws -> Data { Data() }
}
