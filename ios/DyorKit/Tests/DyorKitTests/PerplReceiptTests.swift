import BigInt
import XCTest
@testable import DyorKit

/// What an on-chain Perpl transaction did, decoded from its receipt. The fixture (Fixtures/perpl-receipts.json) holds the
/// raw Exchange logs of ten PUBLIC Monad mainnet transactions and one read-only `debug_traceCall` of an IOC that can't
/// match, each with the decode an independent reference decoder (Python) produced. Nothing was signed or sent.
final class PerplReceiptTests: XCTestCase {
    private struct Fixture: Decodable {
        let exchange: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let hash: String?
        let logs: [RawLog]
        let expected: [Expected]
    }

    private struct RawLog: Decodable {
        let address: String
        let topics: [String]
        let data: String
        let blockNumber: String
        let transactionHash: String
        let logIndex: String
    }

    private struct Expected: Decodable {
        struct Fill: Decodable { let entryPricePNS: Int; let lotLNS: Int; let feeCNS: Int }
        struct Change: Decodable { let kind: String; let positionType: Int; let pricePNS: Int?; let endLotLNS: Int; let deltaPnlCNS: Int? }
        let perpId: Int, accountId: Int, orderDescId: Int, orderId: Int, orderType: Int, pricePNS: Int, lotLNS: Int
        let postOnly: Bool, fillOrKill: Bool, immediateOrCancel: Bool, leverageHdths: Int
        let takerFills: [Fill]
        let iocUnmatchedLNS: Int?, iocTotalLNS: Int?, placedOrderId: Int?, placedLotLNS: Int?
        let cancelled: Bool
        let collateralAddedCNS: Int?
        let ownPositionEvents: [Change]
        let errors: [String]
        let filledLotLNS: Int, avgPricePNS: Int?, feeCNS: Int
        let outcome: String
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "perpl-receipts", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func logs(_ raw: [RawLog]) throws -> [Log] {
        try raw.map { log in
            Log(address: try XCTUnwrap(Address(log.address)), topics: try log.topics.map { try XCTUnwrap(Data(hex: $0)) },
                data: try XCTUnwrap(Data(hex: log.data)), blockNumber: try XCTUnwrap(UInt64(log.blockNumber.dropFirst(2), radix: 16)),
                transactionHash: try XCTUnwrap(Data(hex: log.transactionHash)), logIndex: try XCTUnwrap(Int(log.logIndex.dropFirst(2), radix: 16)))
        }
    }

    private func logs(of name: String) throws -> [Log] {
        try logs(XCTUnwrap(fixture().cases.first { $0.name == name }).logs)
    }

    /// The two forwarded batches run with `revertOnFail: false`; every other case is shaped as the app sends (`true`).
    private static let forwardedBatches: Set<String> = ["batch-with-error", "batch-error-then-ioc-no-fill"]
    private static let failureCodes = ["OrderDoesNotExist": 33, "WrongAccountForOrder": 50]
    private static let changeKinds: [String: PerplReceipt.PositionChange.Kind] = [
        "PositionOpenedV2": .opened, "PositionIncreasedV2": .increased, "PositionDecreased": .decreased, "PositionClosed": .closed, "PositionInverted": .inverted,
    ]

    private func expectedOutcome(_ e: Expected, txid: String, revertOnFail: Bool) -> PerplOrderOutcome? {
        let fill = PerplFillSummary(filledSizeRaw: e.filledLotLNS, requestedSizeRaw: e.lotLNS, priceRaw: e.avgPricePNS, feeCNS: String(e.feeCNS), txid: txid)
        switch e.outcome {
        case "filled": return .filled(fill)
        case "partlyFilled": return .partlyFilled(fill, rest: .cancelled(PerplOrderReason(status: 5, reason: 16)))
        case "notFilled": return .notFilled(PerplOrderReason(status: 5, reason: 16))
        case "resting": return .resting(orderId: e.placedOrderId)
        case "cancelled": return .cancelled(PerplOrderReason(status: 5, reason: 28))
        case "failed": return revertOnFail ? nil : e.errors.first.flatMap { Self.failureCodes[$0] }.map { .failed(PerplOrderReason(status: 7, reason: $0)) }
        default: return nil // marginAdded: read collateralAddedCNS
        }
    }

    // MARK: 29 Every fixture case

    func testEveryCaseDecodesAsTheReference() throws {
        let fixture = try fixture()
        XCTAssertEqual(Address(fixture.exchange), Perpl.exchange)
        XCTAssertEqual(fixture.cases.count, 11)
        for testCase in fixture.cases {
            let decoded = PerplReceipt.decode(try logs(testCase.logs))
            XCTAssertEqual(decoded.count, testCase.expected.count, testCase.name)
            let revertOnFail = !Self.forwardedBatches.contains(testCase.name)
            for (request, e) in zip(decoded, testCase.expected) {
                let at = "\(testCase.name) #\(e.orderDescId)"
                XCTAssertEqual(request.perpId, e.perpId, at)
                XCTAssertEqual(request.accountId, e.accountId, at)
                XCTAssertEqual(request.orderDescId, BigUInt(e.orderDescId), at)
                XCTAssertEqual(request.orderId, e.orderId, at)
                XCTAssertEqual(request.orderType, e.orderType, at)
                XCTAssertEqual(request.pricePNS, e.pricePNS, at)
                XCTAssertEqual(request.lotLNS, e.lotLNS, at)
                XCTAssertEqual(request.postOnly, e.postOnly, at)
                XCTAssertEqual(request.fillOrKill, e.fillOrKill, at)
                XCTAssertEqual(request.immediateOrCancel, e.immediateOrCancel, at)
                XCTAssertEqual(request.leverageHdths, e.leverageHdths, at)
                XCTAssertEqual(request.takerFills, e.takerFills.map { PerplReceipt.TakerFill(entryPricePNS: $0.entryPricePNS, lotLNS: $0.lotLNS, feeCNS: BigUInt($0.feeCNS)) }, at)
                XCTAssertEqual(request.iocUnmatchedLNS, e.iocUnmatchedLNS, at)
                XCTAssertEqual(request.iocTotalLNS, e.iocTotalLNS, at)
                XCTAssertEqual(request.placedOrderId, e.placedOrderId, at)
                XCTAssertEqual(request.placedLotLNS, e.placedLotLNS, at)
                XCTAssertEqual(request.cancelled, e.cancelled, at)
                XCTAssertEqual(request.collateralAddedCNS, e.collateralAddedCNS.map { BigUInt($0) }, at)
                XCTAssertEqual(request.positionChanges.count, e.ownPositionEvents.count, at)
                for (change, expected) in zip(request.positionChanges, e.ownPositionEvents) {
                    XCTAssertEqual(change.kind, Self.changeKinds[expected.kind], at)
                    XCTAssertEqual(change.isLong, expected.positionType == 0, at)
                    XCTAssertEqual(change.pricePNS, expected.pricePNS, at)
                    XCTAssertEqual(change.endLotLNS, expected.endLotLNS, at)
                    XCTAssertEqual(change.deltaPnlCNS, expected.deltaPnlCNS.map { BigInt($0) }, at)
                }
                XCTAssertEqual(request.failureReasons, e.errors.compactMap { Self.failureCodes[$0] }, at)
                XCTAssertEqual(request.legacyEvents, 0, at)
                XCTAssertEqual(request.unknownEvents, 0, at)
                XCTAssertEqual(request.filledLotLNS, e.filledLotLNS, at)
                XCTAssertEqual(request.averagePricePNS, e.avgPricePNS, at)
                XCTAssertEqual(request.feeCNS, BigUInt(e.feeCNS), at)
                XCTAssertEqual(request.outcome(revertOnFail: revertOnFail),
                               expectedOutcome(e, txid: request.transactionHash.hexString, revertOnFail: revertOnFail), at)
            }
        }
    }

    func testTheTopicsAreTheExchanges() {
        // keccak256 of each canonical signature, as the reference decoder computed them (cast keccak).
        let expected: [(Data, String)] = [
            (PerplReceipt.Topic.orderRequestV2, "0xb585865280072cb0f2cb5cf0f49f0e0224c09fa012c92c5f33eabf10287b8beb"),
            (PerplReceipt.Topic.orderBatchCompleted, "0xc2813e86d911b51775079b03b9fcab443ec450bc1634cf75dd578874a0af7add"),
            (PerplReceipt.Topic.takerOrderFilledV2, "0x9d9bc0117914a61672fc4d289495e1031d64c5f8d4a714db38b52c85856d4999"),
            (PerplReceipt.Topic.makerOrderFilledV2, "0xa59d6df87b5cb9e8cca8c09e8f1e240b7a1d4a2ee8f6c636c12ce22b43b82d70"),
            (PerplReceipt.Topic.immediateOrCancelExecuted, "0x59468f520017226c0116472def96f905dbeff518444091b355de591a2161cdbe"),
            (PerplReceipt.Topic.orderPlaced, "0x5d5d31f82cb7d7cf1b09787031cd282c6accc62145d50de980d298bb340a9aba"),
            (PerplReceipt.Topic.orderCancelled, "0xe9805f82cb3729e97b234bb6bb4f90ea971e2c274201ff71818ebde153e1b0a6"),
            (PerplReceipt.Topic.positionOpenedV2, "0x04cc3d2fc73a9dca30eba1d05eca80b1b1216350243580027046f434fed4db18"),
            (PerplReceipt.Topic.positionIncreasedV2, "0x99a74f70c224396b9ba5fcd5a6e5f480db23e7a25a2b16a8c133ec2efb3e646c"),
            (PerplReceipt.Topic.positionDecreased, "0xcd4a9f7ae1cc250eaa0be6bdb30d07efaf0faafb4ff0e76d8fe09a8373e43f85"),
            (PerplReceipt.Topic.positionClosed, "0x599b5f439ed4daf1f28ae8638e5439d3982e8001fb26dd8f70021b38672eb26f"),
            (PerplReceipt.Topic.positionInverted, "0x01a0596385c75b269e896ca6468a2be2edc8b2b5459f4e25ca0a75944390a10c"),
            (PerplReceipt.Topic.increasePositionCollateral, "0x577ed0a8f65f2feb5a407660b0a3009c2ee155a17d0e34947c58ecdd6c8b3771"),
        ]
        for (topic, hex) in expected { XCTAssertEqual(topic.hexString, hex) }
        let failures: [(String, Int)] = [("0x69b92a906c4fe940cd3de572076c4a5181ddced80218575cc4959b1d8f6a6e3f", 33),
                                         ("0x0ff65eacbb5b956c92957d3a4c76260d051566a34945c41b4e621bc895918ee7", 50)]
        for (hex, code) in failures { XCTAssertEqual(PerplReceipt.failureReasons[Data(hex: hex)!], code, hex) }
        XCTAssertEqual(PerplReceipt.failureReasons.count, 32, "every failure event types.md names")
        XCTAssertEqual(Set(PerplReceipt.failureReasons.values).count, 32)
    }

    // MARK: 30 Only a consistent group is read

    private func word(_ data: Data, _ index: Int, _ value: Int) -> Data {
        var out = data
        out.replaceSubrange((index * 32)..<((index + 1) * 32), with: Data(BigUInt(value).serialize()).leftPadded(to: 32))
        return out
    }

    private func relabel(_ log: Log, topic: Data? = nil, data: Data? = nil, address: Address? = nil, index: Int? = nil) -> Log {
        Log(address: address ?? log.address, topics: [topic ?? log.topics[0]], data: data ?? log.data, blockNumber: log.blockNumber,
            transactionHash: log.transactionHash, logIndex: index ?? log.logIndex)
    }

    private func outcome(_ logs: [Log], revertOnFail: Bool = true) -> PerplOrderOutcome? {
        PerplReceipt.decode(logs).first?.outcome(revertOnFail: revertOnFail)
    }

    func testOnlyAConsistentGroupYieldsAnOutcome() throws {
        // An IOC whose taker fill is missing: unmatched ≠ total − filled.
        let partial = try logs(of: "ioc-partial")
        XCTAssertNotNil(outcome(partial))
        XCTAssertNil(outcome(partial.filter { $0.topics[0] != PerplReceipt.Topic.takerOrderFilledV2 }))
        // A V1 fill inside the group: invisible to the V2 reading, so nothing is read.
        let open = try logs(of: "open-full-fill")
        let taker = try XCTUnwrap(open.first { $0.topics[0] == PerplReceipt.Topic.takerOrderFilledV2 })
        let legacy = relabel(taker, topic: PerplReceipt.Topic.takerOrderFilled, index: taker.logIndex - 1)
        let withLegacy = PerplReceipt.decode(open + [legacy])
        XCTAssertEqual(withLegacy.first?.legacyEvents, 1)
        XCTAssertNil(withLegacy.first?.outcome(revertOnFail: true))
        // A resting order whose placed size doesn't add up.
        let limit = try logs(of: "limit-placed")
        XCTAssertEqual(outcome(limit), .resting(orderId: 6))
        let placed = try XCTUnwrap(limit.first { $0.topics[0] == PerplReceipt.Topic.orderPlaced })
        XCTAssertNil(outcome(limit.map { $0 == placed ? relabel($0, data: word($0.data, 1, 283_000)) : $0 }))
        // Its own position opened but no taker fill could be read.
        XCTAssertNil(outcome(open.filter { $0.topics[0] != PerplReceipt.Topic.takerOrderFilledV2 }))
        // A cancel without its OrderCancelled, sent revertOnFail: true: nothing to read (it can't have failed).
        let cancel = try logs(of: "cancel")
        XCTAssertEqual(outcome(cancel), .cancelled(PerplOrderReason(status: 5, reason: 28)))
        XCTAssertNil(outcome(cancel.filter { $0.topics[0] != PerplReceipt.Topic.orderCancelled }))
        // `.failed` is never read from a successful revertOnFail receipt.
        let batch = try logs(of: "batch-with-error")
        let refusedCancel = PerplReceipt.decode(batch)[1]
        XCTAssertEqual(refusedCancel.outcome(revertOnFail: false), .failed(PerplOrderReason(status: 7, reason: 33)))
        XCTAssertNil(refusedCancel.outcome(revertOnFail: true))
        XCTAssertEqual(PerplReceipt.decode(try logs(of: "add-margin")).first?.collateralAddedCNS, 322_970_000)
        XCTAssertNil(outcome(try logs(of: "add-margin")), "margin: read the amount, not an order outcome")
    }

    // MARK: 31 Robustness

    func testRobustness() throws {
        let open = try logs(of: "open-full-fill")
        // An event cut short is counted, never fatal, and the group isn't read.
        let truncated = PerplReceipt.decode(open.map { $0.topics[0] == PerplReceipt.Topic.takerOrderFilledV2 ? relabel($0, data: $0.data.prefix(31)) : $0 })
        XCTAssertEqual(truncated.first?.unknownEvents, 1)
        XCTAssertNil(truncated.first?.outcome(revertOnFail: true))
        // A cut-short request starts no group.
        XCTAssertTrue(PerplReceipt.decode(open.map { $0.topics[0] == PerplReceipt.Topic.orderRequestV2 ? relabel($0, data: $0.data.prefix(31)) : $0 }).isEmpty)
        // Without its OrderBatchCompleted, the last group still closes.
        let unclosed = PerplReceipt.decode(open.filter { $0.topics[0] != PerplReceipt.Topic.orderBatchCompleted })
        XCTAssertEqual(unclosed.count, 1)
        XCTAssertEqual(unclosed.first?.filledLotLNS, 63)
        // Another contract's log inside the group is ignored.
        let taker = try XCTUnwrap(open.first { $0.topics[0] == PerplReceipt.Topic.takerOrderFilledV2 })
        let foreign = relabel(taker, address: Address(literal: "0x00000000000000000000000000000000000c0074"), index: taker.logIndex - 1)
        XCTAssertEqual(PerplReceipt.decode(open + [foreign]).first?.filledLotLNS, 63)
        // Logs out of order are read in log order.
        XCTAssertEqual(PerplReceipt.decode(Array(open.reversed())), PerplReceipt.decode(open))
        // A limit that partly fills at once and rests the rest.
        let limit = try logs(of: "limit-placed")
        let placed = try XCTUnwrap(limit.first { $0.topics[0] == PerplReceipt.Topic.orderPlaced })
        let fill = relabel(taker, index: placed.logIndex)
        let rest = relabel(placed, data: word(placed.data, 1, 283_537 - 63), index: placed.logIndex + 1)
        let synthetic = limit.filter { $0 != placed }.map { $0.topics[0] == PerplReceipt.Topic.orderBatchCompleted ? relabel($0, index: placed.logIndex + 2) : $0 } + [fill, rest]
        let request = try XCTUnwrap(PerplReceipt.decode(synthetic).first)
        XCTAssertEqual(request.outcome(revertOnFail: true),
                       .partlyFilled(PerplFillSummary(filledSizeRaw: 63, requestedSizeRaw: 283_537, priceRaw: 45212, feeCNS: "983", txid: request.transactionHash.hexString),
                                     rest: .resting(orderId: 6)))
    }

    // MARK: 32 Plans and the account's own request

    func testPlansAndTheAccountsOwnRequest() throws {
        let btc = PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0, mark: 95000, last: 95000, oracle: 95000,
                             markTimestamp: 0, longOI: 0, shortOI: 0, fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
        let input = OrderInput(market: btc, side: .long, kind: .market, size: 0.1, leverage: 5)
        let one = PerplExchange.execOrdersCalldata([PerplExchange.orderDesc(input, descId: 1925)], revertOnFail: true)
        let plan = try XCTUnwrap(PerplReceipt.plan(execOrdersCalldata: one))
        XCTAssertEqual(plan.descIds, [1925])
        XCTAssertTrue(plan.revertOnFail)
        let two = PerplExchange.execOrdersCalldata([PerplExchange.orderDesc(input, descId: 7), PerplExchange.cancelDesc(perpId: 1, orderId: 3, descId: 8)], revertOnFail: false)
        let both = try XCTUnwrap(PerplReceipt.plan(execOrdersCalldata: two))
        XCTAssertEqual(both.descIds, [7, 8])
        XCTAssertFalse(both.revertOnFail)
        XCTAssertNil(PerplReceipt.plan(execOrdersCalldata: Data([0x12, 0x34, 0x56, 0x78, 0x00])))
        XCTAssertNil(PerplReceipt.plan(execOrdersCalldata: try ABI.encodeCall("allowOrderForwarding(bool)", [.bool(true)])))

        let batch = PerplReceipt.decode(try logs(of: "batch-with-error"))
        let close = try XCTUnwrap(PerplReceipt.request(in: batch, accountId: 2118, descId: 1_777_687))
        XCTAssertEqual(close.orderType, 3)
        XCTAssertEqual(close.outcome(revertOnFail: false)?.fill?.filledSizeRaw, 15)
        XCTAssertNil(PerplReceipt.request(in: batch, accountId: 2118, descId: nil), "two requests of that account: say which")
        XCTAssertEqual(PerplReceipt.request(in: batch, accountId: 2171, descId: nil)?.placedOrderId, 21)
        XCTAssertNil(PerplReceipt.request(in: batch, accountId: 2118, descId: 1))
    }

    // MARK: 33 Nothing filled

    func testAllOrdersNotFilled() throws {
        XCTAssertTrue(PerplReceipt.allOrdersNotFilled(PerplReceipt.decode(try logs(of: "ioc-no-fill-simulated"))))
        XCTAssertTrue(PerplReceipt.allOrdersNotFilled(PerplReceipt.decode(try logs(of: "cancel-then-ioc-no-fill"))))
        XCTAssertFalse(PerplReceipt.allOrdersNotFilled(PerplReceipt.decode(try logs(of: "ioc-partial"))))
        XCTAssertFalse(PerplReceipt.allOrdersNotFilled(PerplReceipt.decode(try logs(of: "open-full-fill"))))
        XCTAssertFalse(PerplReceipt.allOrdersNotFilled(PerplReceipt.decode(try logs(of: "cancel"))), "no order request at all")
        // An unmatched IOC whose own position changed anyway: never read as "nothing filled".
        let noFill = try logs(of: "ioc-no-fill-simulated")
        let opened = try XCTUnwrap(try logs(of: "open-full-fill").first { $0.topics[0] == PerplReceipt.Topic.positionOpenedV2 })
        let end = try XCTUnwrap(noFill.first { $0.topics[0] == PerplReceipt.Topic.orderBatchCompleted })
        let changed = noFill.filter { $0 != end } + [relabel(opened, index: end.logIndex), relabel(end, index: end.logIndex + 1)]
        XCTAssertEqual(PerplReceipt.decode(changed).first?.positionChanges.count, 1)
        XCTAssertFalse(PerplReceipt.allOrdersNotFilled(PerplReceipt.decode(changed)))
    }

    // MARK: Phase 3 (real-time spec §6.3–6.5): a wallet-signed order's own result

    /// The sheet's read: the order's own request (account and the plan's desc id), and only an order (types 0–3). Anything
    /// it can't say for certain is nil — "couldn't be read" — never a guess.
    func testAWalletSignedOrdersOwnOutcome() throws {
        let open = PerplReceipt.decode(try logs(of: "open-full-fill"))
        let filled = try XCTUnwrap(PerplReceipt.orderOutcome(open, accountId: 10, descId: 1925))
        XCTAssertEqual(filled.fill?.filledSizeRaw, 63)
        XCTAssertEqual(filled.fill?.priceRaw, 45212)
        XCTAssertEqual(try XCTUnwrap(filled.volumeUSD(priceDecimals: 1, lotDecimals: 5)), 0.00063 * 4521.2, accuracy: 1e-9, "volume: what filled, at its price")
        XCTAssertEqual(PerplReceipt.orderOutcome(open, accountId: 10, descId: nil), filled, "without a desc id: the account's only request")
        XCTAssertNil(PerplReceipt.orderOutcome(open, accountId: 10, descId: 1926), "another desc id: not this order")
        XCTAssertNil(PerplReceipt.orderOutcome(open, accountId: 11, descId: 1925), "another account")
        XCTAssertNil(PerplReceipt.orderOutcome(nil, accountId: 10, descId: 1925), "the receipt never read back")
        XCTAssertNil(PerplReceipt.orderOutcome([], accountId: 10, descId: 1925))

        XCTAssertEqual(PerplReceipt.orderOutcome(PerplReceipt.decode(try logs(of: "ioc-no-fill-simulated")), accountId: 10, descId: nil),
                       .notFilled(PerplOrderReason(status: 5, reason: 16)), "a market order with nothing within its slippage confirms, and filled nothing")
        XCTAssertEqual(PerplReceipt.orderOutcome(PerplReceipt.decode(try logs(of: "limit-placed")), accountId: 1767, descId: 1_791_470_524_873_655),
                       .resting(orderId: 6))
        let close = PerplReceipt.decode(try logs(of: "close-full-fill"))
        XCTAssertEqual(PerplReceipt.orderOutcome(close, accountId: 10, descId: 1919)?.fill?.filledSizeRaw, 23)
        let partial = try XCTUnwrap(PerplReceipt.orderOutcome(PerplReceipt.decode(try logs(of: "ioc-partial")), accountId: 25, descId: 470))
        guard case .partlyFilled(let fill, rest: .cancelled(let reason)) = partial else { return XCTFail("\(partial)") }
        XCTAssertEqual(fill.filledSizeRaw, 13)
        XCTAssertEqual(reason.reason, 16)
        // A cancel or an add-margin request is not an order: no order outcome.
        XCTAssertNil(PerplReceipt.orderOutcome(PerplReceipt.decode(try logs(of: "cancel")), accountId: 1767, descId: nil))
        XCTAssertNil(PerplReceipt.orderOutcome(PerplReceipt.decode(try logs(of: "add-margin")), accountId: 3499, descId: 4203))
        // A group that doesn't add up is never read (I3): the partial IOC without its fill.
        let unreadable = try logs(of: "ioc-partial").filter { $0.topics[0] != PerplReceipt.Topic.takerOrderFilledV2 }
        XCTAssertNil(PerplReceipt.orderOutcome(PerplReceipt.decode(unreadable), accountId: 25, descId: 470))
        // The app's plans revert whole on a refusal: a successful receipt never reads as "failed".
        let refused = PerplReceipt.decode(try logs(of: "batch-error-then-ioc-no-fill"))
        XCTAssertNil(PerplReceipt.orderOutcome(refused, accountId: 5201, descId: 74_265_683))
        XCTAssertEqual(PerplReceipt.orderOutcome(PerplReceipt.decode(try logs(of: "batch-with-error")), accountId: 2118, descId: 1_777_687, revertOnFail: false)?.fill?.filledSizeRaw, 15)
    }

    /// Add Margin's line: the collateral its own event moved, for the account's add-margin request only.
    func testTheMarginAWalletSignedRequestAdded() throws {
        let margin = PerplReceipt.decode(try logs(of: "add-margin"))
        XCTAssertEqual(PerplReceipt.marginAdded(margin, accountId: 3499, descId: 4203), 322_970_000)
        XCTAssertEqual(PerplReceipt.marginAdded(margin, accountId: 3499, descId: nil), 322_970_000)
        XCTAssertNil(PerplReceipt.marginAdded(margin, accountId: 3500, descId: 4203))
        XCTAssertNil(PerplReceipt.marginAdded(margin, accountId: 3499, descId: 4204))
        XCTAssertNil(PerplReceipt.marginAdded(nil, accountId: 3499, descId: 4203))
        XCTAssertNil(PerplReceipt.marginAdded(PerplReceipt.decode(try logs(of: "open-full-fill")), accountId: 10, descId: 1925), "an order adds no margin")
    }

    /// The desc id is read from the steps that are signed (each build of a plan takes a new one).
    func testThePlansDescIdIsTheOneItSigns() throws {
        let cancel = PerplExchange.execOrdersCalldata([PerplExchange.cancelDesc(perpId: 1, orderId: 6, descId: 1_791_470_524_873_615)], revertOnFail: true)
        let step = TransactionStep.call(TransactionRequest(to: Perpl.exchange, data: cancel), label: "Cancel")
        XCTAssertEqual(PerplReceipt.descId(ofPlan: [step]), 1_791_470_524_873_615)
        let margin = PerplExchange.execOrdersCalldata([PerplExchange.addMarginDesc(perpId: 1, amountCNS: 25_000_000, descId: 4203)], revertOnFail: true)
        let approve = TransactionStep.approve(token: Perpl.collateral, spender: Perpl.exchange, amount: 1, label: "Approve")
        XCTAssertEqual(PerplReceipt.descId(ofPlan: [approve, .call(TransactionRequest(to: Perpl.exchange, data: margin), label: "Add")]), 4203, "the last step")
        XCTAssertNil(PerplReceipt.descId(ofPlan: [approve]))
        XCTAssertNil(PerplReceipt.descId(ofPlan: []))
        XCTAssertNil(PerplReceipt.descId(ofPlan: [.call(TransactionRequest(to: Perpl.exchange, data: try ABI.encodeCall("allowOrderForwarding(bool)", [.bool(true)])), label: "x")]))
        let huge = PerplExchange.execOrdersCalldata([PerplExchange.cancelDesc(perpId: 1, orderId: 6, descId: BigUInt(1) << 70)], revertOnFail: true)
        XCTAssertNil(PerplReceipt.descId(ofPlan: [.call(TransactionRequest(to: Perpl.exchange, data: huge), label: "x")]), "not an id the app issued")
    }

    /// The receipt read (§6.7): a node that hasn't seen the block yet answers null; the read tries again, 300 ms apart by
    /// default, three times in all, and gives up (nil, "couldn't be read") after three nulls.
    func testTheReceiptIsReadAgainWhileItReadsBackNull() async throws {
        let fixture = try fixture()
        let open = try XCTUnwrap(fixture.cases.first { $0.name == "open-full-fill" })
        let hash = try XCTUnwrap(open.hash).lowercased()
        let logs: [JSON] = open.logs.map { log in
            .object(["address": .string(log.address), "topics": .array(log.topics.map { .string($0) }), "data": .string(log.data),
                     "blockNumber": .string(log.blockNumber), "transactionHash": .string(log.transactionHash), "logIndex": .string(log.logIndex)])
        }
        RPCStub.reset()
        defer { RPCStub.reset() }
        RPCStub.receipts[hash] = .object(["status": .string("0x1"), "blockNumber": .string("0x1"), "gasUsed": .string("0x5208"), "logs": .array(logs)])
        let rpc = RPCClient(url: URL(string: "https://primary.test")!, session: RPCStub.session())
        let txHash = try XCTUnwrap(Data(hex: hash))

        RPCStub.nullReceiptReads = 2
        let requests = try await PerplReceipt.requests(ofTransaction: txHash, rpc: rpc, attempts: 3, interval: .milliseconds(1))
        XCTAssertEqual(RPCStub.receiptReads, 3, "two nulls, then the receipt")
        XCTAssertEqual(PerplReceipt.orderOutcome(requests, accountId: 10, descId: 1925)?.fill?.filledSizeRaw, 63)

        RPCStub.receiptReads = 0
        RPCStub.nullReceiptReads = 3
        let never = try await PerplReceipt.requests(ofTransaction: txHash, rpc: rpc, attempts: 3, interval: .milliseconds(1))
        XCTAssertNil(never)
        XCTAssertEqual(RPCStub.receiptReads, 3, "three reads, no more")
        XCTAssertNil(PerplReceipt.orderOutcome(never, accountId: 10, descId: 1925))
    }
}
