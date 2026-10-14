import BigInt
import XCTest
@testable import DyorKit

/// How the client waits (speed work, 2026-10-10): a read's answer must start within its limit on an endpoint (`readTimeout`
/// and a third more), then is read whole, and the read is asked of the next as well when the first's answer hasn't
/// started within `hedgeDelay`, the first good answer taken and the other request cancelled; a split read goes out at once
/// within the endpoints' item budget; and nothing that isn't a read — a broadcast, a receipt, a transaction's nonce, gas
/// or fees, a rehearsal of a transaction, a log scan — is ever asked of two endpoints at once or cut short at the read
/// limit. The app opens its connections ahead of its reads, with requests that read and change nothing.
final class RPCHedgeTests: XCTestCase {
    private let primary = URL(string: "https://primary.hedge.invalid")!
    private let secondary = URL(string: "https://secondary.hedge.invalid")!
    private let owner = Address(literal: "0x1111111111111111111111111111111111111111")
    private let target = Address(literal: "0x2222222222222222222222222222222222222222")

    override func setUp() {
        super.setUp()
        HedgeStub.reset()
        HedgeStub.set(primary) { $0.head = 1 }
        HedgeStub.set(secondary) { $0.head = 2 }
    }

    private func client(readTimeout: TimeInterval = 2, hedgeDelay: TimeInterval = 0.1, maxBatch: Int = 100, itemsPerSecond: Int? = nil) -> RPCClient {
        RPCClient(urls: [primary, secondary], session: HedgeStub.session(), maxBatch: maxBatch, itemsPerSecond: itemsPerSecond,
                  readTimeout: readTimeout, hedgeDelay: hedgeDelay)
    }

    // MARK: Which calls are reads

    /// Only what reads the chain, and is no part of a transaction being made, is a read.
    func testOnlyCallsThatReadTheChainAreReads() {
        let plain = CallRequest(to: target, data: Data([1, 2, 3])).json
        let rehearsal = CallRequest(from: owner, to: target, data: Data([1])).json
        let paying = CallRequest(to: target, data: Data([1]), value: 5).json
        let at: JSON = .string("0x10")
        for (method, params) in [("eth_blockNumber", []), ("eth_chainId", []), ("eth_getBalance", [.string(owner.hex), at]),
                                 ("eth_getCode", [.string(owner.hex), .string("latest")]), ("eth_getBlockByNumber", [.string("latest"), .bool(false)]),
                                 ("eth_call", [plain, .string("latest")]), ("eth_call", [plain, at]),
                                 ("eth_getTransactionCount", [.string(owner.hex), at])] as [(String, [JSON])] {
            XCTAssertTrue(RPCClient.isRead(method, params), "\(method) \(params)")
        }
        for (method, params) in [("eth_sendRawTransaction", [.string("0x02")]), ("eth_getTransactionReceipt", [.string("0xab")]),
                                 ("eth_getTransactionByHash", [.string("0xab")]), ("eth_estimateGas", [plain]), ("eth_gasPrice", []),
                                 ("eth_maxPriorityFeePerGas", []), ("eth_getTransactionCount", [.string(owner.hex), .string("pending")]),
                                 ("eth_getTransactionCount", [.string(owner.hex), .string("latest")]), ("eth_getTransactionCount", [.string(owner.hex)]),
                                 ("eth_call", [rehearsal, .string("latest")]), ("eth_call", [paying, .string("latest")]), ("eth_call", []),
                                 ("eth_getLogs", [.object([:])]), ("anvil_metadata", [])] as [(String, [JSON])] {
            XCTAssertFalse(RPCClient.isRead(method, params), "\(method) \(params)")
        }
        XCTAssertTrue(RPCClient.isRead([("eth_blockNumber", []), ("eth_call", [plain, .string("latest")])]))
        XCTAssertFalse(RPCClient.isRead([("eth_blockNumber", []), ("eth_getTransactionReceipt", [.string("0xab")])]), "one call that isn't a read")
        XCTAssertFalse(RPCClient.isRead([]))
    }

    // MARK: A slow endpoint

    /// A read its endpoint hasn't answered within the hedge delay is asked of the next; the first answer is taken, the
    /// slow request is cancelled, and the endpoint that answered is preferred from then on, as after a failover.
    func testASlowReadIsAskedOfTheNextEndpointAndTheFirstAnswerWins() async throws {
        HedgeStub.set(primary) { $0.delay = 5 }
        let rpc = client()
        let started = ContinuousClock.now
        let block = try await rpc.blockNumber()
        XCTAssertEqual(block, 2, "the second endpoint's answer")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "never the slow endpoint's 5 s")
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!, secondary.host()!])
        try await waitUntil { HedgeStub.stopped().contains(self.primary.host()!) }

        HedgeStub.clearLog()
        HedgeStub.set(primary) { $0.delay = 0 }
        _ = try await rpc.blockNumber()
        XCTAssertEqual(HedgeStub.hosts(), [secondary.host()!], "the endpoint that answered is preferred")
    }

    /// A read whose task is cancelled (a screen closed) stops at once: its request is cancelled, and no other endpoint is
    /// asked, then or at the hedge delay.
    func testACancelledReadAsksNoOtherEndpoint() async throws {
        HedgeStub.set(primary) { $0.delay = 3 }
        let rpc = client(hedgeDelay: 0.3)
        let read = Task { try await rpc.blockNumber() }
        try await Task.sleep(for: .milliseconds(100))
        read.cancel()
        let started = ContinuousClock.now
        do {
            _ = try await read.value
            XCTFail("expected the cancellation")
        } catch NetworkError.transport(let error) {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!], "never the next endpoint")
        try await waitUntil { HedgeStub.stopped().contains(self.primary.host()!) }
    }

    /// An endpoint that answers within the hedge delay is the only one asked.
    func testAReadAnsweredInTimeIsAskedOnce() async throws {
        HedgeStub.set(primary) { $0.delay = 0.05 }
        let block = try await client(hedgeDelay: 0.5).blockNumber()
        XCTAssertEqual(block, 1)
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!])
    }

    /// A read no endpoint answers fails after the read limit, never 30 s: on two endpoints, each given its limit, the
    /// second asked at the hedge delay; on one, its limit alone.
    func testAStalledReadFailsAtTheReadLimit() async throws {
        HedgeStub.set(primary) { $0.delay = .infinity }
        HedgeStub.set(secondary) { $0.delay = .infinity }
        var started = ContinuousClock.now
        do {
            _ = try await client(readTimeout: 0.3).blockNumber()
            XCTFail("expected a timeout")
        } catch NetworkError.transport(let error) {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(Set(HedgeStub.hosts()), [primary.host()!, secondary.host()!])
        XCTAssertEqual(HedgeStub.hosts().count, 2, "no backoff rounds when nothing answered at all")

        HedgeStub.clearLog()
        started = ContinuousClock.now
        let single = RPCClient(url: primary, session: HedgeStub.session(), readTimeout: 0.3)
        do {
            _ = try await single.balance(of: owner)
            XCTFail("expected a timeout")
        } catch {}
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!])
    }

    /// The default read limit is 6 s without a byte and 8 s in all, the hedge delay 1.3 s, a read limit never above the
    /// client's timeout, and a read of a local node keeps the timeout (a fork reads state it doesn't hold from its upstream
    /// first).
    func testTheReadLimits() async throws {
        XCTAssertEqual(RPCClient.readTimeout, 6)
        XCTAssertEqual(RPCClient.readDeadline(idle: RPCClient.readTimeout), 8)
        XCTAssertEqual(RPCClient.hedgeDelay, 1.3)
        // A router's client (12 s) reads within 6 s; one given less keeps its own.
        HedgeStub.set(primary) { $0.delay = 0.6 }
        do {
            _ = try await RPCClient(url: primary, session: HedgeStub.session(), timeout: 0.3).blockNumber()
            XCTFail("expected a timeout at the client's own 0.3 s")
        } catch {}
        let local = URL(string: "http://127.0.0.1:8545")!
        HedgeStub.set(local) { $0.delay = 0.6; $0.head = 7 }
        let fork = try await RPCClient(url: local, session: HedgeStub.session(), readTimeout: 0.2).blockNumber()
        XCTAssertEqual(fork, 7, "a local node's read waits its timeout, not the read limit")
    }

    /// A read whose answer has started is read whole, however long its body takes, and is never asked of another endpoint
    /// meanwhile: a page of creator text on a slow link (up to about 1.8 MB) was cut off at the read limit, its board
    /// failing on every retry, and asked again over the same link at the hedge delay. An answer that hasn't started by the
    /// limit still fails there (`testAStalledReadFailsAtTheReadLimit`).
    func testAnAnswerThatHasStartedIsReadWholeAndNeverRaced() async throws {
        // Its status at once, then its body in eight parts 0.15 s apart: 1.2 s in all, each gap well within the 0.3 s
        // without a byte, three times the 0.4 s an answer has to start in.
        HedgeStub.set(primary) { $0.trickle = (parts: 8, gap: 0.15) }
        let rpc = client(readTimeout: 0.3, hedgeDelay: 0.2)
        let page = Data((0 ..< 4_000).map { UInt8($0 % 251) })
        let started = ContinuousClock.now
        let read = try await rpc.ethCall(CallRequest(to: target, data: page))
        XCTAssertEqual(read, page, "the whole answer")
        XCTAssertGreaterThan(ContinuousClock.now - started, .milliseconds(1_000))
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!], "never raced once its answer started")
        XCTAssertEqual(HedgeStub.stopped(), [], "never cut off")

        // On one endpoint, with no other to ask: read whole all the same.
        HedgeStub.clearLog()
        let single = try await RPCClient(url: primary, session: HedgeStub.session(), readTimeout: 0.3).ethCall(CallRequest(to: target, data: page))
        XCTAssertEqual(single, page)
        XCTAssertEqual(HedgeStub.stopped(), [])

        // The same answer, its status late: past the hedge delay the next endpoint is asked, and its answer taken.
        HedgeStub.clearLog()
        HedgeStub.set(primary) { $0.delay = 0.3 }
        let raced = try await client(readTimeout: 2, hedgeDelay: 0.1).ethCall(CallRequest(to: target, data: page))
        XCTAssertEqual(raced, page)
        XCTAssertEqual(Set(HedgeStub.hosts()), [primary.host()!, secondary.host()!])
    }

    /// A request given a limit in all (`RPCClient.data(for:session:limit:)`, Kuru Flow's token) is given up at its limit
    /// even while its answer trickles in; the same answer read as a read's (`answerWithin`) is read whole.
    func testALimitInAllCutsATricklingAnswer() async throws {
        HedgeStub.set(primary) { $0.trickle = (parts: 8, gap: 0.15) }
        var request = URLRequest(url: primary)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}"#.utf8)
        let started = ContinuousClock.now
        do {
            _ = try await RPCClient.data(for: request, session: HedgeStub.session(), limit: 0.4)
            XCTFail("expected the limit")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(900))
        let (whole, response) = try await RPCClient.data(for: request, session: HedgeStub.session(), answerWithin: 0.4)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: whole)["result"].string, "0x1")
    }

    // MARK: Never twice

    /// Nothing that isn't a read is ever asked of two endpoints at once, however slow the first, nor cut short at the read
    /// limit: a broadcast, a receipt, a transaction by hash, gas, fees, the pending nonce, a rehearsal of a transaction
    /// before it is signed (a sender or a value), the base fee a transaction is signed with, a log scan, and a request
    /// with any of them in it.
    func testOnlyReadsAreAskedOfTwoEndpoints() async throws {
        HedgeStub.set(primary) { $0.delay = 0.4 }
        let rpc = client(readTimeout: 0.2, hedgeDelay: 0.05)
        let rehearsal = CallRequest(from: owner, to: target, data: Data([1]))
        let checks: [(String, () async throws -> Void)] = [
            ("broadcast", { _ = try await rpc.call("eth_sendRawTransaction", [.string("0x02")]) }),
            ("receipt", { _ = try await rpc.transactionReceipt(Data(repeating: 0xab, count: 32)) }),
            ("by hash", { _ = try await rpc.call("eth_getTransactionByHash", [.string("0xab")]) }),
            ("estimate", { _ = try await rpc.estimateGas(rehearsal) }),
            ("gas price", { _ = try await rpc.gasPrice() }),
            ("tip", { _ = try await rpc.maxPriorityFeePerGas() }),
            ("pending nonce", { _ = try await rpc.transactionCount(of: self.owner) }),
            ("rehearsal", { _ = try await rpc.ethCall(rehearsal) }),
            ("paying call", { _ = try await rpc.ethCall(CallRequest(to: self.target, data: Data([1]), value: 1)) }),
            ("base fee", { _ = try await rpc.latestBaseFee() }),
            ("logs", { _ = try await rpc.call("eth_getLogs", [.object([:])]) }),
            ("mixed batch", { _ = try await rpc.batch([("eth_blockNumber", []), ("eth_getTransactionReceipt", [.string("0xab")])]) }),
        ]
        for (name, check) in checks {
            HedgeStub.clearLog()
            try await check()
            XCTAssertEqual(HedgeStub.hosts(), [primary.host()!], "\(name): one endpoint, answered after the read limit")
        }
        // Each read, as slow, is asked of both (a client each: the one that answered is preferred after).
        let reads: [(String, (RPCClient) async throws -> Void)] = [
            ("head", { _ = try await $0.blockNumber() }),
            ("chain id", { _ = try await $0.chainId() }),
            ("balance", { _ = try await $0.balance(of: self.owner) }),
            ("code", { _ = try await $0.code(at: self.target) }),
            ("header", { _ = try await $0.block(.latest) }),
            ("contract read", { _ = try await $0.ethCall(CallRequest(to: self.target, data: Data([1]))) }),
            ("past nonce", { _ = try await $0.transactionCount(of: self.owner, block: .number(16)) }),
        ]
        for (name, read) in reads {
            HedgeStub.clearLog()
            try await read(client(readTimeout: 2, hedgeDelay: 0.05))
            XCTAssertEqual(Set(HedgeStub.hosts()), [primary.host()!, secondary.host()!], name)
        }
    }

    // MARK: Which answer

    /// A failed call from the faster endpoint (one that doesn't hold a block, say) never beats a good answer from the one
    /// asked first: it is kept while the other may still answer. With no good answer, the round ends as one endpoint at a
    /// time would have: the one asked first.
    func testAFailedCallNeverBeatsAGoodAnswer() async throws {
        HedgeStub.set(primary) { $0.delay = 0.3 }
        HedgeStub.set(secondary) { $0.callError = "missing trie node" }
        let read = try await client(hedgeDelay: 0.05).ethCall(CallRequest(to: target, data: Data([0xaa])), block: .number(16))
        XCTAssertEqual(read, Data([0xaa]), "the first endpoint's answer, the call echoed")

        HedgeStub.clearLog()
        HedgeStub.set(primary) { $0.delay = 0.3; $0.callError = "header not found" }
        do {
            _ = try await client(hedgeDelay: 0.05).ethCall(CallRequest(to: target, data: Data([0xaa])), block: .number(16))
            XCTFail("expected the call's failure")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "header not found", "the endpoint asked first")
        }
        XCTAssertEqual(Set(HedgeStub.hosts()), [primary.host()!, secondary.host()!])

        // A failed call that answers before the hedge delay is the answer, as before: no other endpoint is asked.
        HedgeStub.clearLog()
        HedgeStub.set(primary) { $0.delay = 0; $0.callError = "execution reverted" }
        do {
            _ = try await client(hedgeDelay: 0.5).ethCall(CallRequest(to: target, data: Data([0xaa])))
            XCTFail("expected the revert")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "execution reverted")
        }
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!])
    }

    /// A read the first endpoint refuses at once (429) goes to the next at once, as before; a read both endpoints
    /// throttle backs off and is asked again, counted as throttles.
    func testAThrottledReadFailsOverAtOnce() async throws {
        HedgeStub.set(primary) { $0.status = 429 }
        let rpc = client(hedgeDelay: 1)
        let started = ContinuousClock.now
        let block = try await rpc.blockNumber()
        XCTAssertEqual(block, 2)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "not after the hedge delay")
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!, secondary.host()!])
        let throttles = await rpc.throttles
        XCTAssertEqual(throttles, 1)
    }

    // MARK: Split reads

    /// Where each request of a split read starts: over the endpoints from the preferred one, never more than the budget
    /// to one endpoint in a second; a request larger than the budget alone.
    func testASplitReadIsSpreadWithinTheItemBudget() {
        func plan(_ sizes: [Int], order: [Int] = [0, 1], budget: Int = 50) -> [String] {
            RPCClient.schedule(sizes, order: order, budget: budget).map { "\($0.endpoint)@\(Int($0.after))" }
        }
        XCTAssertEqual(plan([40, 9]), ["0@0", "1@0"], "a 49-call read: both endpoints at once")
        XCTAssertEqual(plan([40, 40, 16]), ["0@0", "1@0", "0@1"], "96 calls: two at once, the rest a second later")
        XCTAssertEqual(plan([40, 40, 16], order: [1, 0]), ["1@0", "0@0", "1@1"], "from the preferred endpoint")
        XCTAssertEqual(plan([40, 40, 16], order: [0]), ["0@0", "0@1", "0@2"], "one endpoint that takes batches")
        XCTAssertEqual(plan([20, 20, 10]), ["0@0", "1@0", "0@0"], "spread over the endpoints, the preferred first when they tie")
        XCTAssertEqual(plan([10, 10, 10], order: [2, 0, 1]), ["2@0", "0@0", "1@0"])
        XCTAssertEqual(plan([60, 60]), ["0@0", "1@0"], "larger than the budget: alone")
    }

    /// An endpoint that refuses a batch outright (HTTP 403, as rpc1 refuses every batch, measured 2026-10-10) is passed over
    /// for the next at once, with no backoff, and is sent no batch again: a split read goes to the endpoints that take
    /// batches; a single call still goes to it; the same refusal of a request that isn't a read fails over too.
    func testAnEndpointThatRefusesBatchesIsSentNoneAgain() async throws {
        HedgeStub.set(secondary) { $0.refusesBatches = true }
        let rpc = client(hedgeDelay: 2, maxBatch: 3, itemsPerSecond: 4)
        let calls = (0..<6).map { i in (CallRequest(to: target, data: Data([UInt8(i)])), BlockTag.latest) }
        let started = ContinuousClock.now
        let first = try await rpc.ethCalls(calls)
        XCTAssertEqual(first.map { try? $0.get() }, (0..<6).map { Data([UInt8($0)]) }, "every answer, in order")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "no backoff")
        XCTAssertEqual(HedgeStub.hosts().filter { $0 == secondary.host()! }.count, 1, "refused once")

        HedgeStub.clearLog()
        let again = try await rpc.ethCalls(calls)
        XCTAssertEqual(again.map { try? $0.get() }, (0..<6).map { Data([UInt8($0)]) })
        XCTAssertEqual(Set(HedgeStub.hosts()), [primary.host()!], "never sent a batch again")
        HedgeStub.clearLog()
        HedgeStub.set(primary) { $0.status = 429 }
        let single = try await rpc.blockNumber()
        XCTAssertEqual(single, 2, "a single call still goes to it")

        // Not a read: a batch of receipts refused by the first endpoint goes to the next.
        HedgeStub.reset()
        HedgeStub.set(primary) { $0.refusesBatches = true; $0.head = 1 }
        HedgeStub.set(secondary) { $0.head = 2 }
        let receipts = try await client().batch([("eth_getTransactionReceipt", [.string("0xab")]), ("eth_getTransactionReceipt", [.string("0xcd")])])
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!, secondary.host()!])
        XCTAssertTrue(RPCClient.isRefusal(status: 403))
        XCTAssertFalse(RPCClient.isRefusal(status: 400))
    }

    /// A local node (a fork) has no item budget: a split read goes out at once there, however big.
    func testAForkHasNoItemBudget() async throws {
        let local = URL(string: "http://127.0.0.1:8545")!
        HedgeStub.set(local) { $0.delay = 0.3 }
        let fork = RPCClient(urls: [local], session: HedgeStub.session(), maxBatch: 3, itemsPerSecond: 4)
        let started = ContinuousClock.now
        let results = try await fork.ethCalls((0..<9).map { i in (CallRequest(to: target, data: Data([UInt8(i)])), BlockTag.latest) })
        XCTAssertEqual(results.map { try? $0.get() }, (0..<9).map { Data([UInt8($0)]) })
        XCTAssertEqual(HedgeStub.mostInFlight(), 3)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(850), "never a second's wait")
        XCTAssertTrue(RPCClient.isLocal(local))
        XCTAssertFalse(RPCClient.isLocal(primary))
    }

    /// A split read goes out at once, over both endpoints, and its answers come back in request order; a split request
    /// that isn't a read still goes one after another (`RPCFailoverTests.testSplitsBatchesAtTheCapAndKeepsOrder`).
    func testASplitReadGoesOutAtOnceInOrder() async throws {
        HedgeStub.set(primary) { $0.delay = 0.3 }
        HedgeStub.set(secondary) { $0.delay = 0.3 }
        let rpc = client(hedgeDelay: 2, maxBatch: 3, itemsPerSecond: 4)
        let calls = (0..<7).map { i in (CallRequest(to: target, data: Data([UInt8(i)])), BlockTag.latest) }
        let started = ContinuousClock.now
        let results = try await rpc.ethCalls(calls)
        XCTAssertEqual(results.map { try? $0.get() }, (0..<7).map { Data([UInt8($0)]) }, "every answer, in order")
        XCTAssertEqual(HedgeStub.mostInFlight(), 3, "three requests at once")
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(850), "one round trip, not three one after another")
        XCTAssertEqual(HedgeStub.sizes().sorted(), [1, 3, 3])
        XCTAssertEqual(Set(HedgeStub.hosts()), [primary.host()!, secondary.host()!])
    }

    // MARK: Warming

    /// A warm-up asks each endpoint for the chain id, and changes nothing the client keeps.
    func testAWarmUpOpensEveryEndpointAndChangesNothing() async throws {
        let rpc = client()
        await rpc.warm()
        XCTAssertEqual(Set(HedgeStub.hosts()), [primary.host()!, secondary.host()!])
        XCTAssertEqual(HedgeStub.methods(), ["eth_chainId", "eth_chainId"])
        HedgeStub.clearLog()
        await rpc.warm(first: 1)
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!])
        HedgeStub.clearLog()
        _ = try await rpc.blockNumber()
        XCTAssertEqual(HedgeStub.hosts(), [primary.host()!], "the preference unchanged")
    }

    /// The backend's warm-up (`SupabaseClient.warm`) is a `HEAD` of the project's root and nothing more: no key, no
    /// session, no table, no function — a request that reads nothing and changes nothing, made only to open the
    /// connection.
    func testTheBackendWarmUpCarriesNoKey() async throws {
        let project = URL(string: "https://project.warm-stub.invalid")!
        let client = SupabaseClient(url: project, anonKey: "sb_publishable_test", session: WarmStub.session())
        WarmStub.reset()
        await client.warm()
        let requests = WarmStub.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertEqual(request.url, project, "the project's root, no table or function")
        XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
    }

    /// The app opens its connections at launch and on every return to it, at most every 30 s: the app's endpoints, the
    /// logs endpoint the history reads first, and the backend, each with a request that reads nothing and changes
    /// nothing (`RPCClient.warm`, `SupabaseClient.warm`).
    func testTheAppWarmsItsConnectionsAtMostEvery30Seconds() throws {
        let environment = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        XCTAssertTrue(environment.contains("guard now.timeIntervalSince(warmedAt) > 30 else { return }\n        warmedAt = now"), "at most every 30 s")
        XCTAssertTrue(environment.contains("async let app: Void = rpc.warm()"))
        XCTAssertTrue(environment.contains("async let logs: Void = logsClient.warm(first: 1)"))
        XCTAssertTrue(environment.contains("async let social: Void = backend.warm()"))
        XCTAssertEqual(environment.components(separatedBy: "warmConnections()").count - 1, 2, "declared once, and called once, from init")
        XCTAssertTrue(environment.contains("updateGate.onFlags = { [weak self] flags in self?.apply(flags) }\n        // The connections the first screens read over, opened before they ask.\n        warmConnections()"))
        let root = try DocsLinksTests.appSource("App/RootView.swift")
        let active = try XCTUnwrap(root.range(of: "if phase == .active {"))
        let warm = try XCTUnwrap(root.range(of: "env.warmConnections()"), "on every return to the app")
        XCTAssertLessThan(active.lowerBound, warm.lowerBound)
        XCTAssertEqual(root.components(separatedBy: "env.warmConnections()").count - 1, 1)
    }

    // MARK: Bridge balances

    /// A chain's native balance and its tokens are read at once, and a chain gives what answered within its cap: a token
    /// read that never answers is left out, as a failed read is, never shown as 0 — and the chain is said to be read in
    /// part, so the Bridge reads it again rather than take it as read (`BridgeModel.loadBalances`).
    func testAChainsBalancesAreReadAtOnceWithinTheCap() async throws {
        let usdc = AuroraToken.stub(assetId: "base:usdc", contract: "0x3333333333333333333333333333333333333333")
        let eth = AuroraToken.stub(assetId: "base:eth", contract: nil)
        let chain = EVMChain(auroraId: "base", chainId: 8453, name: "Base", nativeSymbol: "ETH", rpcURL: primary)
        HedgeStub.set(primary) { $0.methodDelay = ["eth_call": 0.2, "eth_getBalance": 0.2] }
        let both = await MultiChainBalances(session: HedgeStub.session()).read(owner: owner, chain: chain, tokens: [usdc, eth])
        XCTAssertEqual(both, .init(balances: ["base:usdc": 7, "base:eth": 5], complete: true))
        XCTAssertEqual(HedgeStub.mostInFlight(), 2, "both reads at once")

        HedgeStub.reset()
        HedgeStub.set(primary) { $0.methodDelay = ["eth_call": .infinity] }
        let started = ContinuousClock.now
        let balances = MultiChainBalances(session: HedgeStub.session(), cap: .milliseconds(300))
        let capped = await balances.read(owner: owner, chain: chain, tokens: [usdc, eth])
        XCTAssertEqual(capped, .init(balances: ["base:eth": 5], complete: false), "the tokens left out, never 0, and the chain read in part")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        let plain = await balances.balances(owner: owner, chain: chain, tokens: [usdc, eth])
        XCTAssertEqual(plain, ["base:eth": 5], "the balances alone")
        XCTAssertEqual(MultiChainBalances.cap, .seconds(6))

        // A read that fails leaves the chain read in part too; one that answers with a token's own call failed is read.
        HedgeStub.reset()
        HedgeStub.set(primary) { $0.status = 400 }
        let failed = await balances.read(owner: owner, chain: chain, tokens: [usdc, eth])
        XCTAssertEqual(failed, .init(balances: [:], complete: false))
        let none = await balances.read(owner: owner, chain: chain, tokens: [])
        XCTAssertEqual(none, .init(balances: [:], complete: true), "nothing to read")
    }

    /// The Bridge takes a chain as read only once every read of it answered: a chain read in part is read again at once and
    /// on every load after, its balances never latched as read; each chain's balances show as it answers; a forced load
    /// asked during another runs after it.
    func testTheBridgeReadsAChainReadInPartAgain() throws {
        let bridge = Self.squeezed(try DocsLinksTests.appSource("Bridge/BridgeModel.swift"))
        XCTAssertFalse(bridge.contains("didLoadBalances"))
        XCTAssertTrue(bridge.contains("return toks.isEmpty || (!force && chainsRead.contains(chain.auroraId)) ? nil : (chain, toks)"))
        XCTAssertTrue(bridge.contains("if read.complete { chainsRead.insert(chain.auroraId) readingChains.remove(chain.auroraId) } else { chainsRead.remove(chain.auroraId) inPart.append((chain, toks)) }"))
        XCTAssertTrue(bridge.contains("plan = inPart"))
        XCTAssertTrue(bridge.contains("for _ in 0 ..< 2 where !plan.isEmpty {"))
        XCTAssertTrue(bridge.contains("guard !loadingBalances else { if force { forceAfterLoad = true }; return }"))
        XCTAssertTrue(bridge.contains("guard env.session.address == owner else { return }"), "never another wallet's balances")
        let view = Self.squeezed(try DocsLinksTests.appSource("Bridge/BridgeView.swift"))
        XCTAssertTrue(view.contains("if model.readingFromBalance { ProgressView().controlSize(.mini) }"), "the source's balance waits only for its own chain")
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Waits until `condition` holds, for at most five seconds.
    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held", file: file, line: line)
    }
}

/// Records every request it is sent, and answers each with an empty 200.
private final class WarmStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [URLRequest] = []

    static func reset() { lock.lock(); log = []; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WarmStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); Self.log.append(request); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private extension AuroraToken {
    static func stub(assetId: String, contract: String?) -> AuroraToken {
        var json: [String: Any] = ["assetId": assetId, "decimals": 6, "blockchain": "base", "symbol": "T", "price": 1.0]
        if let contract { json["contractAddress"] = contract }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(AuroraToken.self, from: data)
    }
}

/// JSON-RPC endpoints keyed by host, each answering after its own delay (`.infinity`: never, until the request is
/// cancelled), with its own head, status and call failure, its body sent whole or a little at a time (`trickle`). Every
/// request is logged with its host and methods, every cancelled one noted, and the most answered at once counted. An
/// `eth_call` echoes its data, or answers a Multicall3 `aggregate3` with 7 for every call; a balance is 5.
final class HedgeStub: URLProtocol {
    struct Host {
        var delay: TimeInterval = 0
        var methodDelay: [String: TimeInterval] = [:]
        var status = 200
        var head: UInt64 = 1
        var callError: String?
        /// Answers every batch (a JSON array) with 403 "Restricted JSON RPC method", as rpc1 does.
        var refusesBatches = false
        /// The body sent in this many parts, `gap` seconds apart, after the status and headers: a large answer on a slow
        /// link. Nil: the body at once.
        var trickle: (parts: Int, gap: TimeInterval)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var config: [String: Host] = [:]
    nonisolated(unsafe) private static var log: [(host: String, methods: [String])] = []
    nonisolated(unsafe) private static var cancelled: [String] = []
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var most = 0
    private var stoppedLoading = false
    private var answered = false

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        config = [:]; log = []; cancelled = []; inFlight = 0; most = 0
    }

    static func set(_ url: URL, _ change: (inout Host) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var host = config[url.host() ?? ""] ?? Host()
        change(&host)
        config[url.host() ?? ""] = host
    }

    static func clearLog() {
        lock.lock(); defer { lock.unlock() }
        log = []; cancelled = []; most = 0
    }

    static func hosts() -> [String] { lock.lock(); defer { lock.unlock() }; return log.map(\.host) }
    static func methods() -> [String] { lock.lock(); defer { lock.unlock() }; return log.flatMap(\.methods) }
    static func sizes() -> [Int] { lock.lock(); defer { lock.unlock() }; return log.map(\.methods.count) }
    static func stopped() -> [String] { lock.lock(); defer { lock.unlock() }; return cancelled }
    static func mostInFlight() -> Int { lock.lock(); defer { lock.unlock() }; return most }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HedgeStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {
        stoppedLoading = true
        guard !answered else { return }
        Self.lock.lock()
        Self.cancelled.append(request.url?.host() ?? "")
        Self.inFlight -= 1
        Self.lock.unlock()
    }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let decoded = (try? JSONDecoder().decode(JSON.self, from: Self.body(request))) ?? .null
        let calls = decoded.array ?? [decoded]
        let methods = calls.map { $0["method"].string ?? "" }
        Self.lock.lock()
        let config = Self.config[host] ?? Host()
        Self.log.append((host, methods))
        Self.inFlight += 1
        Self.most = max(Self.most, Self.inFlight)
        Self.lock.unlock()
        let delay = methods.map { config.methodDelay[$0] ?? config.delay }.max() ?? 0
        guard delay.isFinite else { return } // never answers: held until cancelled
        let thread = Thread.current
        let answer = Self.reply(decoded, calls: calls, config: config)
        let reply: NSArray = [answer[0], answer[1], config.trickle != nil]
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            perform(#selector(deliver(_:)), on: thread, with: reply, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
            guard let trickle = config.trickle, let body = reply[1] as? Data else { return }
            // The body's parts, each sent on the loading thread a gap after the one before.
            let size = max(1, (body.count + trickle.parts - 1) / trickle.parts)
            let parts = stride(from: 0, to: body.count, by: size).map { body.subdata(in: $0 ..< min($0 + size, body.count)) }
            for (i, part) in parts.enumerated() {
                let last = i == parts.count - 1
                DispatchQueue.global().asyncAfter(deadline: .now() + trickle.gap * Double(i + 1)) { [self] in
                    perform(#selector(deliverPart(_:)), on: thread, with: [part, last] as NSArray, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
                }
            }
        }
    }

    @objc private func deliver(_ reply: NSArray) {
        guard !stoppedLoading, let status = reply[0] as? Int, let body = reply[1] as? Data, let trickled = reply[2] as? Bool else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !trickled else { return } // the body follows in parts (`deliverPart`)
        answered = true
        Self.lock.lock(); Self.inFlight -= 1; Self.lock.unlock()
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// One part of a trickled body (`Host.trickle`); the last ends the answer.
    @objc private func deliverPart(_ part: NSArray) {
        guard !stoppedLoading, let data = part[0] as? Data, let last = part[1] as? Bool else { return }
        client?.urlProtocol(self, didLoad: data)
        guard last else { return }
        answered = true
        Self.lock.lock(); Self.inFlight -= 1; Self.lock.unlock()
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func reply(_ decoded: JSON, calls: [JSON], config: Host) -> NSArray {
        guard config.status == 200 else { return [config.status, Data()] }
        if config.refusesBatches, decoded.array != nil { return [403, Data("Restricted JSON RPC method".utf8)] }
        let replies = calls.map { call -> JSON in
            let id = call["id"]
            func result(_ value: JSON) -> JSON { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
            func failure(_ message: String) -> JSON {
                .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32000), "message": .string(message)])])
            }
            let head = BigUInt(config.head).hexQuantity
            switch call["method"].string {
            case "eth_blockNumber": return result(.string(head))
            case "eth_chainId": return result(.string(Monad.chainIdHex))
            case "eth_getBalance": return result(.string("0x5"))
            case "eth_getBlockByNumber": return result(.object(["number": .string(head), "timestamp": .string("0x6a000000"), "baseFeePerGas": .string("0x1")]))
            case "eth_call":
                if let error = config.callError { return failure(error) }
                let request = call["params"][0]
                let data = request["data"].string.flatMap { Data(hex: $0) } ?? Data()
                guard request["to"].string?.lowercased() == Multicall.address.hex.lowercased(),
                      let inner = try? ABI.decode(data.dropFirst(4), "(address,bool,bytes)[]")[0].elements else { return result(.string(data.hexString)) }
                let answers: [ABIValue] = inner.map { _ in .tuple([.bool(true), .bytes(BigUInt(7).word)]) }
                return result(.string(((try? ABI.encode([.array(answers)], "(bool,bytes)[]")) ?? Data()).hexString))
            case "eth_getTransactionReceipt", "eth_getTransactionByHash": return result(.null)
            case "eth_getLogs": return result(.array([]))
            default: return result(.string("0x1"))
            }
        }
        let body = (try? JSONEncoder().encode(decoded.array == nil ? replies[0] : .array(replies))) ?? Data()
        return [200, body]
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
