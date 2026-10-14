import BigInt
import Foundation
@testable import DyorKit

/// Contract reads answered from memory, with every sub-call recorded. A Multicall3 `aggregate3` is split into its
/// sub-calls and each is answered by the installed `answer(to, calldata)` (nil reverts that sub-call, as a missing getter
/// does on chain); a plain `eth_call` is answered the same way. `batches()` lists what each request asked, as
/// (target, selector) pairs, so a test can check which contract was asked for what, and in which aggregate;
/// `batches(host:)` only those sent to one host, a client of its own (`rpc(host:)`), so a test can tell its reads from
/// those of an earlier client's task still finishing. A request whose read a test holds (`hold(_:)`) is recorded as it
/// arrives and answered only once the test lets it go (`releaseHeld()`).
/// `eth_getLogs` is answered from the installed `logs` (filtered by address, topics and range, like a node), every
/// filter is recorded (`logQueries()`), `eth_getBlockByNumber` reports `head`, and `eth_getTransactionReceipt` the
/// installed `receipts`.
final class MomentsChainStub: URLProtocol {
    typealias Answer = @Sendable (_ to: Address, _ data: Data) -> Data?

    static let rpcURL = URL(string: "https://rpc.moments-stub.invalid")!
    /// The chain head `eth_getBlockByNumber` reports.
    static let head = BlockHeader(number: 1_000, timestamp: 1_790_000_000)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: Answer = { _, _ in nil }
    nonisolated(unsafe) private static var asked: [[Call]] = []
    /// The host each of `asked` was sent to, in the same order.
    nonisolated(unsafe) private static var askedHosts: [String] = []
    nonisolated(unsafe) private static var chainLogs: [Log] = []
    nonisolated(unsafe) private static var receipts: [Data: [Log]] = [:]
    nonisolated(unsafe) private static var filters: [LogQuery] = []
    nonisolated(unsafe) private static var refused: Set<String> = []
    nonisolated(unsafe) private static var breaking: Set<Address> = []
    nonisolated(unsafe) private static var breakingSelectors: Set<Data> = []
    nonisolated(unsafe) private static var starving: Set<Address> = []
    nonisolated(unsafe) private static var nativeBalances: [Address: BigUInt] = [:]
    nonisolated(unsafe) private static var responseCap: Int?
    /// Which reads are held (`hold(_:)`), and the requests held so far.
    nonisolated(unsafe) private static var holding: (@Sendable ([Call]) -> Bool)?
    nonisolated(unsafe) private static var heldStubs: [MomentsChainStub] = []
    /// This request's answer while it is held, and the thread it is given on.
    private var heldReply: (response: HTTPURLResponse, body: Data, thread: Thread)?

    struct Call: Hashable, CustomStringConvertible {
        let to: Address
        let selector: String
        var description: String { "\(to.short) \(selector)" }
    }

    /// One `eth_getLogs` filter as a test sees it: the address (nil for any) and the topics (nil for any).
    struct LogQuery: Hashable {
        let address: Address?
        let topics: [Data?]
    }

    /// `refusing`: JSON-RPC methods the node answers with an error (not a throttle, so nothing retries), as a node that
    /// can't serve them. `breaking`: contracts that make any `eth_call` reaching them fail as a whole, out of gas — as a
    /// token whose return bomb exhausts a Multicall3 aggregate does, taking every other call in it down too.
    /// `breakingSelectors` do the same for any call with one of those selectors, whatever it reaches. `starving`: contracts
    /// that burn the gas of the aggregate they are in, which still answers: their sub-call and every one after it fail, as
    /// Multicall3 reports a sub-call starved of gas (`(false, 0x)`). `native`: what `eth_getBalance` answers for each
    /// account (any other account reverts). `responseCap`: an aggregate whose answer would be longer than this many bytes
    /// fails as a whole, out of gas, as Monad refuses one returning more than about 4.1 MB (its memory then costs more gas
    /// than an `eth_call` may use).
    static func install(_ answer: @escaping Answer, logs: [Log] = [], receipts: [Data: [Log]] = [:], refusing: Set<String> = [], breaking: Set<Address> = [],
                        breakingSelectors: Set<Data> = [], starving: Set<Address> = [], native: [Address: BigUInt] = [:], responseCap: Int? = nil) {
        releaseHeld()
        lock.lock(); defer { lock.unlock() }
        self.answer = answer
        asked = []
        askedHosts = []
        chainLogs = logs
        self.receipts = receipts
        filters = []
        refused = refusing
        self.breaking = breaking
        self.breakingSelectors = breakingSelectors
        self.starving = starving
        nativeBalances = native
        self.responseCap = responseCap
    }

    /// Every `eth_getLogs` filter asked, in order.
    static func logQueries() -> [LogQuery] {
        lock.lock(); defer { lock.unlock() }
        return filters
    }

    /// One entry per `eth_call`: the sub-calls of an aggregate, or the single call.
    static func batches() -> [[Call]] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    static func calls() -> [Call] { batches().flatMap { $0 } }

    /// Holds the answer of every request with a read that `matches` (an aggregate's sub-calls, or a single call), recorded
    /// as it arrives, until `releaseHeld()`: a read that comes back late, while the reads after it are answered. Until the
    /// next `install` or `releaseHeld()`.
    static func hold(_ matches: @escaping @Sendable ([Call]) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        holding = matches
    }

    /// Answers every request held, and holds none from now on.
    static func releaseHeld() {
        lock.lock()
        let stubs = heldStubs
        heldStubs = []
        holding = nil
        lock.unlock()
        for stub in stubs {
            guard let thread = stub.heldReply?.thread else { continue }
            stub.perform(#selector(deliverHeld), on: thread, with: nil, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
        }
    }

    /// How many requests are held now.
    static func heldCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return heldStubs.count
    }

    /// `batches()`, only those sent to `host` (`rpc(host:)`).
    static func batches(host: String) -> [[Call]] {
        lock.lock(); defer { lock.unlock() }
        return zip(asked, askedHosts).filter { $0.1 == host }.map(\.0)
    }

    static func rpc() -> RPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MomentsChainStub.self]
        return RPCClient(url: rpcURL, session: URLSession(configuration: configuration))
    }

    /// A client of this chain at `host` of its own, whose reads `batches(host:)` lists.
    static func rpc(host: String) -> RPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MomentsChainStub.self]
        return RPCClient(url: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let decoded = (try? JSONDecoder().decode(JSON.self, from: Self.body(request))) ?? .null
        let host = request.url?.host() ?? ""
        var held = false
        let replies = (decoded.array ?? [decoded]).map { Self.reply($0, host: host, held: &held) }
        let body = (try? JSONEncoder().encode(decoded.array == nil ? replies[0] : .array(replies))) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        if held {
            heldReply = (response, body, Thread.current)
            Self.lock.lock(); Self.heldStubs.append(self); Self.lock.unlock()
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Gives a held request its answer (`releaseHeld()`), on the thread it arrived on.
    @objc private func deliverHeld() {
        guard let heldReply else { return }
        client?.urlProtocol(self, didReceive: heldReply.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: heldReply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func reply(_ call: JSON, host: String, held: inout Bool) -> JSON {
        let id = call["id"]
        func result(_ data: Data) -> JSON { .object(["jsonrpc": .string("2.0"), "id": id, "result": .string(hex(data))]) }
        func json(_ value: JSON) -> JSON { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
        let reverted: JSON = .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(3), "message": .string("execution reverted"), "data": .string("0x")])])
        lock.lock(); let refusedMethods = refused; lock.unlock()
        if let method = call["method"].string, refusedMethods.contains(method) {
            return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32000), "message": .string("header not found")])])
        }
        switch call["method"].string {
        case "eth_getBlockByNumber":
            return json(.object(["number": .string(BigUInt(head.number).hexQuantity), "timestamp": .string(BigUInt(head.timestamp).hexQuantity)]))
        case "eth_getLogs":
            let filter = call["params"][0]
            let query = LogQuery(address: filter["address"].string.flatMap(Address.init),
                                 topics: (filter["topics"].array ?? []).map { $0.string.flatMap { Data(hex: $0) } })
            let from = filter["fromBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? 0
            let to = filter["toBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? head.number
            lock.lock(); filters.append(query); let logs = chainLogs; lock.unlock()
            let matching = logs.filter { log in
                (query.address == nil || query.address == log.address) && (from...to).contains(log.blockNumber)
                    && query.topics.enumerated().allSatisfy { i, topic in topic == nil || (log.topics.indices.contains(i) && log.topics[i] == topic) }
            }
            return json(.array(matching.map(Self.json)))
        case "eth_getBalance":
            lock.lock(); let balance = call["params"][0].string.flatMap(Address.init).flatMap { nativeBalances[$0] }; lock.unlock()
            if let balance { return json(.string(balance.hexQuantity)) }
        case "eth_getTransactionReceipt":
            lock.lock(); let receipt = call["params"][0].string.flatMap { Data(hex: $0) }.flatMap { receipts[$0] }; lock.unlock()
            return json(receipt.map { .object(["status": .string("0x1"), "logs": .array($0.map(Self.json))]) } ?? .null)
        default:
            break
        }
        guard call["method"].string == "eth_call", let tx = call["params"].array?.first,
              let to = tx["to"].string.flatMap(Address.init), let data = tx["data"].string.flatMap({ Data(hex: $0) }) else { return reverted }
        lock.lock(); let answer = self.answer; let breaking = self.breaking; let breakingSelectors = self.breakingSelectors; let starving = self.starving; let cap = responseCap; lock.unlock()
        let outOfGas: JSON = .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32000), "message": .string("out of gas")])])
        if to == Multicall.address, let inner = try? ABI.decode(data.dropFirst(4), "(address,bool,bytes)[]")[0].elements {
            var batch: [Call] = []
            var out: [ABIValue] = []
            var starved = false
            for item in inner {
                let target = item[0].address, calldata = item[2].bytes
                batch.append(Call(to: target, selector: calldata.prefix(4).hexString))
                starved = starved || starving.contains(target)
                let returned = starved ? nil : answer(target, calldata)
                out.append(.tuple([.bool(returned != nil), .bytes(returned ?? Data())]))
            }
            held = record(batch, host: host) || held
            if batch.contains(where: { breaking.contains($0.to) || breakingSelectors.contains(Data(hex: $0.selector) ?? Data()) }) { return outOfGas }
            let encoded = (try? ABI.encode([.array(out)], "(bool,bytes)[]")) ?? Data()
            if let cap, encoded.count > cap {
                return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32603), "message": .string("out of gas")])])
            }
            return result(encoded)
        }
        if breaking.contains(to) || breakingSelectors.contains(Data(data.prefix(4))) { return outOfGas }
        held = record([Call(to: to, selector: data.prefix(4).hexString)], host: host) || held
        return answer(to, data).map(result) ?? reverted
    }

    /// `data.hexString`, fast enough for the megabyte answers the size tests send.
    private static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: 2 + data.count * 2)
        out[0] = UInt8(ascii: "0")
        out[1] = UInt8(ascii: "x")
        var i = 2
        for byte in data {
            out[i] = digits[Int(byte >> 4)]
            out[i + 1] = digits[Int(byte & 0x0f)]
            i += 2
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func json(_ log: Log) -> JSON {
        .object(["address": .string(log.address.hex), "topics": .array(log.topics.map { .string($0.hexString) }), "data": .string(log.data.hexString),
                 "blockNumber": .string(BigUInt(log.blockNumber).hexQuantity), "transactionHash": .string(log.transactionHash.hexString),
                 "logIndex": .string(BigUInt(log.logIndex).hexQuantity)])
    }

    /// Records `batch`, sent to `host`; true when a test holds it (`hold(_:)`).
    private static func record(_ batch: [Call], host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        asked.append(batch)
        askedHosts.append(host)
        return holding?(batch) ?? false
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

/// `ABI.selector(signature)`, hashed once per signature: a stub answers thousands of calls, and Keccak takes about half a
/// millisecond in a debug build.
enum StubSelector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hashed: [String: Data] = [:]

    static func of(_ signature: String) -> Data {
        lock.lock(); defer { lock.unlock() }
        if let selector = hashed[signature] { return selector }
        let selector = ABI.selector(signature)
        hashed[signature] = selector
        return selector
    }
}

/// One Moments stack's getters, answered from fixed values: its factory (policy, counts, Moment #1…), its collect,
/// vesting and graduation, and each Moment's coin and NFT. v2-only getters are answered only when `addresses` is v2,
/// so a v1 stack asked for one reverts exactly as the deployed v1 contracts do.
struct FakeMomentsStack: Sendable {
    var addresses: MomentsAddresses
    var policy: MomentPolicy
    /// The factory's current `externalBaseURI()`.
    var factoryBase: String
    /// What each v2 NFT answers for its own `externalBaseURI()` (the base it was published with).
    var nftBase: String
    var names: [String] = ["Nature"]
    var momentCount: Int?

    func coin(_ id: Int) -> Address { Address(data: addresses.factory.data.prefix(16) + Data([0xc0, 0x1a, 0, UInt8(id)]))! }
    func nft(_ id: Int) -> Address { Address(data: addresses.factory.data.prefix(16) + Data([0x0f, 0x7f, 0, UInt8(id)]))! }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        let args = data.dropFirst(4)
        func is_(_ signature: String) -> Bool { selector == StubSelector.of(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let v2 = addresses.generation >= .v2
        let count = momentCount ?? names.count
        let id = args.count >= 32 ? Int(BigUInt(args.prefix(32))) : 0
        let p = policy
        let policyWords: [ABIValue] = [.uint(p.threshold), .uint(p.minPrice), .uint(p.creatorBps), .uint(p.platformBps), .uint(p.reserveBps), .uint(p.maxCreatorAllocBps),
                                       .uint(p.expiryCreatorBps), .uint(p.royaltyBps), .address(p.platform), .address(p.treasury)]
        switch to {
        case addresses.factory:
            if is_(MomentsABI.Factory.policy) { return encode(policyWords, MomentsABI.policyFlat) }
            if is_(MomentsABI.Factory.pendingPolicy) { return encode(policyWords, MomentsABI.policyFlat) }
            if is_(MomentsABI.Factory.pendingPolicyAt) { return encode([.uint(0)], "uint64") }
            if is_(MomentsABI.Factory.momentCount) { return encode([.uint(count)], "uint256") }
            if is_(MomentsABI.Factory.publishingPaused) { return encode([.bool(p.publishingPaused)], "bool") }
            if is_(MomentsABI.Factory.externalBaseURI) { return encode([.string(factoryBase)], "string") }
            if is_(MomentsABI.Factory.getMoment), id >= 1, id <= count {
                return encode([.tuple([.address(Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")), .address(p.platform), .address(p.treasury), .address(coin(id)), .address(nft(id)),
                                       .uint(100_000), .uint(p.threshold), .uint(1), .uint(1), .uint(2_000), .uint(500), .uint(7_500), .uint(1_000), .uint(7_000), .uint(500),
                                       .uint(1_790_570_817), .uint(1_790_657_217)])], MomentsABI.momentTuple)
            }
            if v2, is_(MomentsABI.Factory.termsHash) { return encode([.bytes(p.termsHash ?? Data(count: 32))], "bytes32") }
            if v2, is_(MomentsABI.Factory.guardian) { return encode([.address(p.guardian ?? .zero)], "address") }
            if v2, is_(MomentsABI.Factory.guardianPaused) { return encode([.bool(p.guardianPaused)], "bool") }
            return nil
        case addresses.collect:
            if is_(MomentsABI.Collect.ledger) { return encode([.tuple(Array(repeating: .uint(0), count: 10))], MomentsABI.ledgerTuple) }
            if is_(MomentsABI.Collect.supplyCheck) { return encode(Array(repeating: .uint(0), count: 5), "uint256,uint256,uint256,uint256,uint256") }
            return nil
        case addresses.vesting:
            return is_(MomentsABI.Vesting.totalEntitlement) ? encode([.uint(0)], "uint256") : nil
        case addresses.graduation:
            return is_(MomentsABI.Graduation.isGraduated) ? encode([.bool(false)], "bool") : nil
        default:
            // Moment #i's coin or NFT (`coin(i)`, `nft(i)`), found from the address itself: a stack of a few hundred
            // Moments is then answered as fast as one of three.
            let bytes = [UInt8](to.data)
            guard bytes.count == 20, to.data.prefix(16) == addresses.factory.data.prefix(16), bytes[18] == 0 else { return nil }
            let i = Int(bytes[19])
            guard (1...max(1, names.count)).contains(i) else { return nil }
            if to == coin(i) {
                if is_(MomentsABI.Coin.name) { return encode([.string(names[i - 1])], "string") }
                if is_(MomentsABI.Coin.symbol) { return encode([.string("M\(i)")], "string") }
                if is_(MomentsABI.Coin.totalSupply) { return encode([.uint(0)], "uint256") }
            }
            if to == nft(i) {
                if is_(MomentsABI.NFT.totalMinted) { return encode([.uint(1)], "uint256") }
                if is_(MomentsABI.NFT.closed) { return encode([.bool(false)], "bool") }
                if is_(MomentsABI.NFT.provenance) {
                    return encode([.tuple([.string("ipfs://x"), .bytes(Data(count: 32)), .string("Accra"), .uint(0), .string("")])], MomentsABI.provenanceTuple)
                }
                if v2, is_(MomentsABI.NFT.externalBaseURI) { return encode([.string(nftBase)], "string") }
            }
            return nil
        }
    }
}
