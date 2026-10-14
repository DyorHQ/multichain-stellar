import BigInt
import Foundation
@testable import DyorKit

/// A chain answered from memory block by block, for `BlockClock` and `PriceService`: `eth_getBlockByNumber` reports the
/// headers given (any other block is an error, as a node that doesn't hold it), `eth_blockNumber` the head, and every
/// `eth_call` — plain, inside a Multicall3 `aggregate3`, or batched — is answered at the block it names ("latest" is the
/// head) from `answers` (the exact target and calldata at that block, then at any block), then from what an empty chain
/// says: no pool on any factory, no liquidity in any v4 pool, an empty record of any coin on every DyorHQ launchpad,
/// Moment id 0 on every cohort, and Multicall3's `getBlockNumber` the block asked at. Anything else reverts. Every header
/// asked and every call answered is recorded, and every HTTP request and `aggregate3` envelope counted.
final class VenueChainStub: URLProtocol {
    struct Call: Hashable {
        let block: UInt64
        let to: Address
        let data: Data
    }

    struct State {
        var head: BlockHeader = BlockHeader(number: 1_000_000, timestamp: 1_800_000_000)
        var headers: [UInt64: Int] = [:]
        /// Answers at one block, then answers at any block (keyed by `UInt64.max`).
        var answers: [UInt64: [Call: Data]] = [:]
        /// v4 pool ids with liquidity (StateView `getLiquidity`), at any block.
        var liquidity: [Data: BigUInt] = [:]
        var failHeaders = false
        var headersAsked: [UInt64?] = []
        var calls: [Call] = []
        /// HTTP requests answered (a batch is one), and Multicall3 `aggregate3` envelopes among their calls.
        var requests = 0
        var aggregates = 0
        /// The request held next (`hold`).
        var gate: Gate?
    }

    /// Holds the answer to the first request that asks `selector` until `release` is signalled: a slow node, so a test
    /// can act while a reader is suspended on it.
    final class Gate: @unchecked Sendable {
        let selector: Data
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        init(_ selector: Data) { self.selector = selector }

        /// Waits, without blocking a thread, until the request is held.
        func arrival() async throws {
            for _ in 0 ..< 2_000 {
                if arrived.wait(timeout: .now()) == .success { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw URLError(.timedOut)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset(head: BlockHeader) {
        lock.lock(); defer { lock.unlock() }
        state = State(head: head, headers: [head.number: head.timestamp])
    }

    static func update(_ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&state)
    }

    static var snapshot: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// `data` answers `call` to `to` at `block` (nil: at any block).
    static func answer(_ to: Address, _ call: ContractCall, at block: UInt64? = nil, with data: Data) {
        update { $0.answers[block ?? .max, default: [:]][Call(block: block ?? .max, to: to, data: call.data)] = data }
    }

    static func header(_ number: UInt64, _ timestamp: Int) { update { $0.headers[number] = timestamp } }

    /// Holds the next request that asks `selector` (`Gate`).
    static func hold(_ selector: Data) -> Gate {
        let gate = Gate(selector)
        update { $0.gate = gate }
        return gate
    }

    /// The gate for a request that asked `selectors`, taken so that it holds one request only.
    private static func takeGate(asked selectors: Set<Data>) -> Gate? {
        lock.lock(); defer { lock.unlock() }
        guard let gate = state.gate, selectors.contains(gate.selector) else { return nil }
        state.gate = nil
        return gate
    }

    static func rpc() -> RPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VenueChainStub.self]
        return RPCClient(url: URL(string: "https://rpc.venue-stub.invalid")!, session: URLSession(configuration: configuration))
    }

    /// The eth_calls answered at `block`, as (target, selector).
    static func asked(at block: UInt64) -> [Call] { snapshot.calls.filter { $0.block == block } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let json = (try? JSONDecoder().decode(JSON.self, from: Self.body(of: request))) ?? .null
        Self.update { $0.requests += 1 }
        var asked: Set<Data> = []
        let response: JSON = json.array.map { .array($0.map { Self.reply($0, asked: &asked) }) } ?? Self.reply(json, asked: &asked)
        let body = try! JSONEncoder().encode(response)
        guard let gate = Self.takeGate(asked: asked) else { return deliver(body) }
        // Held without blocking the thread it was asked on, which every custom protocol in the process shares: the other
        // requests are answered meanwhile, and this one's answer is sent on that thread once the gate is released.
        let thread = Thread.current
        DispatchQueue.global().async { [self] in
            gate.arrived.signal()
            _ = gate.release.wait(timeout: .now() + 30)
            perform(#selector(deliverHeld(_:)), on: thread, with: body, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
        }
    }

    @objc private func deliverHeld(_ body: Data) { deliver(body) }

    private func deliver(_ body: Data) {
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    /// The answer to one JSON-RPC request; `asked` gains the selector of every call in it.
    private static func reply(_ request: JSON, asked: inout Set<Data>) -> JSON {
        let id = request["id"]
        func result(_ value: JSON) -> JSON { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
        func error(_ code: Int, _ message: String) -> JSON {
            .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message), "data": .string("0x")])])
        }
        let current = snapshot
        func block(_ tag: JSON) -> UInt64? {
            guard let text = tag.string else { return current.head.number }
            if text == "latest" || text == "pending" { return current.head.number }
            return BigUInt(hexQuantity: text).flatMap { UInt64(exactly: $0) }
        }
        switch request["method"].string {
        case "eth_blockNumber":
            return result(.string(BigUInt(current.head.number).hexQuantity))
        case "eth_getBlockByNumber":
            let number = block(request["params"][0])
            update { $0.headersAsked.append(number) }
            guard !current.failHeaders, let number, let timestamp = current.headers[number] else { return error(-32000, "header not found") }
            return result(.object(["number": .string(BigUInt(number).hexQuantity), "timestamp": .string(BigUInt(timestamp).hexQuantity)]))
        case "eth_call":
            let tx = request["params"][0]
            guard let at = block(request["params"][1]), let to = tx["to"].string.flatMap(Address.init),
                  let data = tx["data"].string.flatMap({ Data(hex: $0) }) else { return error(-32602, "bad call") }
            if to == Multicall.address, let inner = try? ABI.decode(data.dropFirst(4), "(address,bool,bytes)[]")[0].elements {
                update { $0.aggregates += 1 }
                let items: [ABIValue] = inner.map { call in
                    asked.insert(Data(call[2].bytes.prefix(4)))
                    let answer = Self.answer(at: at, to: call[0].address, call[2].bytes)
                    return .tuple([.bool(answer != nil), .bytes(answer ?? Data())])
                }
                return result(.string(try! ABI.encode([.array(items)], "(bool,bytes)[]").hexString))
            }
            asked.insert(Data(data.prefix(4)))
            guard let answer = Self.answer(at: at, to: to, data) else { return error(3, "execution reverted") }
            return result(.string(answer.hexString))
        default:
            return error(-32601, "Unsupported in stub")
        }
    }

    private static func answer(at block: UInt64, to: Address, _ data: Data) -> Data? {
        update { $0.calls.append(Call(block: block, to: to, data: data)) }
        let current = snapshot
        if let exact = current.answers[block]?[Call(block: block, to: to, data: data)] { return exact }
        if let any = current.answers[.max]?[Call(block: .max, to: to, data: data)] { return any }
        let selector = data.prefix(4)
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        if selector == ABI.selector("getPool(address,address,uint24)") || selector == ABI.selector("getPair(address,address)") {
            return encode([.address(.zero)], "address")
        }
        if selector == ABI.selector("getBlockNumber()"), to == Multicall.address {
            return encode([.uint(BigUInt(block))], "uint256")
        }
        if selector == ABI.selector("getLiquidity(bytes32)"), to == Uniswap.stateView {
            let poolId = Data(data.dropFirst(4).prefix(32))
            return encode([.uint(current.liquidity[poolId] ?? 0)], "uint128")
        }
        if selector == ABI.selector(LaunchpadABI.Factory.getLaunchedToken), let stack = DyorCoinRegistry.launchpads(live: .monadMainnet).first(where: { $0.factory == to }) {
            let legacy = stack.generation.legacyRecord
            return encode([.tuple(DyorCoinChain.record(nil, legacy: legacy))], LaunchpadABI.launchedTokenReturns(legacy: legacy))
        }
        if selector == ABI.selector(MomentsABI.Factory.momentIdByCoin), DyorCoinRegistry.cohorts(live: .monadMainnet).contains(where: { $0.factory == to }) {
            return encode([.uint(0)], "uint256")
        }
        return nil
    }
}
