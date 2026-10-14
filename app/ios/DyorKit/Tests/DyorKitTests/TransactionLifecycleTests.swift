import BigInt
import XCTest
@testable import DyorKit

/// The broadcast and receipt lifecycle (security audit 2026-09-26, PR-4 and GL-2): a signed transaction's hash is known
/// before it is sent; a broadcast that gets no answer is followed by that hash and never signed again; the receipt wait
/// counts polls rather than wall-clock time, survives failed reads, and always reads once more at the end.
final class TransactionLifecycleTests: XCTestCase {
    private let mon = BigUInt(10).power(18)
    private let target = Address(literal: "0x2222222222222222222222222222222222222222")
    private var chain: SimulatedChain { RPCStub.chain! }

    override func setUp() {
        super.setUp()
        RPCStub.reset()
        RPCStub.chain = SimulatedChain()
        RPCStub.baseFee = "0x174876e800" // 100 gwei
        RPCStub.tip = "0x77359400"       // 2 gwei
        chain.balance = 100 * mon
    }

    override func tearDown() {
        RPCStub.reset()
        super.tearDown()
    }

    private var rpc: RPCClient { RPCClient(url: URL(string: "https://primary.test")!, session: RPCStub.session()) }

    private func sender(chainId: Int = Monad.chainId, receiptPolls: Int = 5, receiptFastPolls: Int = 0) -> TransactionSender {
        var sender = TransactionSender(rpc: rpc, chainId: chainId)
        sender.timing = .init(blockPoll: .milliseconds(1), spacingTimeout: .milliseconds(50), fundingRetry: .milliseconds(1),
                              resendAttempts: 3, resendBackoff: .milliseconds(1), receiptPolls: receiptPolls, receiptInterval: .milliseconds(1),
                              receiptFastPolls: receiptFastPolls, receiptFastInterval: .milliseconds(1))
        return sender
    }

    private var request: TransactionRequest { TransactionRequest(to: target, data: Data([0x01]), value: 0) }

    // MARK: Broadcast (PR-4)

    /// The node took the transaction but its answer was lost: the hash, computed from the signed bytes, finds it.
    func testLostAnswerIsFoundByItsHash() async throws {
        let wallet = CountingWallet()
        chain.lostSendAnswers = 1
        let hash = try await sender().send(request, from: wallet)
        XCTAssertEqual(chain.sent.count, 1, "found by hash: nothing sent again")
        XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        XCTAssertEqual(wallet.signatures, 1)
    }

    /// The broadcast never arrived: the same bytes go out again, and the wallet signs once.
    func testUnansweredBroadcastIsResentWithTheSameBytes() async throws {
        let wallet = CountingWallet()
        chain.unreachableSends = 2
        let hash = try await sender().send(request, from: wallet)
        XCTAssertEqual(chain.sent.count, 1)
        XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        XCTAssertEqual(wallet.signatures, 1, "never a second signature")
    }

    /// No answer at all, ever: possibly sent, with the hash — never reported as not sent.
    func testNoAnswerIsPossiblySentNeverNotSent() async {
        let wallet = CountingWallet()
        chain.unreachableSends = 100
        do {
            _ = try await sender().send(request, from: wallet)
            XCTFail("expected possiblySent")
        } catch let error as TransactionError {
            guard case .possiblySent(let hash) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(hash.count, 32)
            XCTAssertEqual(error.hash, hash)
            XCTAssertEqual(error.localizedDescription, TransactionError.unconfirmed)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(wallet.signatures, 1)
    }

    /// A node's refusal of this very transaction is an answer: it stands, after one look-up by hash.
    func testAnsweredRefusalStands() async {
        chain.sendFailures = 1
        chain.sendFailure = "insufficient funds for gas * price + value"
        do {
            _ = try await sender(chainId: 8453).send(request, from: CountingWallet())
            XCTFail("expected the node's error")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "insufficient funds for gas * price + value")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(chain.sent.count, 1, "a refusal is never resent")
    }

    /// A gateway's error from an upstream that took the transaction, while the first look-up misses it: followed by
    /// hash, never read as "not sent" (which would let the sheet sign it again with the next nonce).
    func testGatewayErrorIsFollowedNotTakenAsARefusal() async throws {
        let wallet = CountingWallet()
        chain.takenSendFailures = 1
        chain.sendFailure = "internal error"
        chain.hiddenLookups = 2 // the receipt and by-hash reads of the first look-up
        let hash = try await sender().send(request, from: wallet)
        XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        XCTAssertEqual(chain.sent.count, 1, "found by hash: nothing sent again")
        XCTAssertEqual(wallet.signatures, 1)
    }

    /// A reply the client can't match to its request ("Missing response") is no answer about the transaction.
    func testUnmatchedReplyIsFollowedByHash() async throws {
        let wallet = CountingWallet()
        chain.unmatchedSendAnswers = 1
        chain.hiddenLookups = 2
        let hash = try await sender().send(request, from: wallet)
        XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        XCTAssertEqual(wallet.signatures, 1)
    }

    /// A gateway that keeps erroring: the same bytes are resent, and the step ends possibly sent — never not sent.
    func testPersistentGatewayErrorIsPossiblySent() async {
        let wallet = CountingWallet()
        chain.sendFailures = 100
        chain.sendFailure = "upstream request timeout"
        do {
            _ = try await sender().send(request, from: wallet)
            XCTFail("expected possiblySent")
        } catch let error as TransactionError {
            guard case .possiblySent(let hash) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(wallet.signatures, 1)
        XCTAssertEqual(Set(chain.sent.map(\.raw)).count, 1, "only ever the same signed bytes")
    }

    /// "Nonce too low" is this transaction's own nonce only when the network turns up the transaction; a node behind
    /// the one that mined it answers it too, so it is looked up again before the refusal stands.
    func testNonceTooLowFromALaggingNodeIsFollowed() async throws {
        let wallet = CountingWallet()
        chain.takenSendFailures = 1
        chain.sendFailure = "nonce too low"
        chain.hiddenLookups = 3 // sendRawTransaction's own look-up, then the first receipt and by-hash reads
        let hash = try await sender().send(request, from: wallet)
        XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        XCTAssertEqual(chain.sent.count, 1)

        RPCStub.chain = SimulatedChain()
        chain.sendFailures = 1
        chain.sendFailure = "nonce too low"
        do {
            _ = try await sender().send(request, from: CountingWallet())
            XCTFail("another transaction used the nonce — must stay an error")
        } catch let error as RPCError {
            XCTAssertTrue(error.message.contains("nonce too low"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRefusalsAreNarrow() {
        for message in ["insufficient funds for gas * price + value", "Signer had insufficient balance", "intrinsic gas too low",
                        "replacement transaction underpriced", "max fee per gas less than block base fee", "nonce too low", "invalid chain id for signer"] {
            XCTAssertTrue(TransactionSender.isRefusal(RPCError(code: -32000, message: message)), message)
        }
        for message in ["internal error", "upstream request timeout", "Missing response", "execution reverted", "rate limit exceeded", "nonce too high", ""] {
            XCTAssertFalse(TransactionSender.isRefusal(RPCError(code: -32603, message: message)), message)
        }
    }

    /// A plan whose broadcast got no answer still follows that step by hash, confirms it, and runs on — one signature
    /// per step, and the step's `.sent` event carries the hash for the View link.
    func testRunFollowsAnUnansweredStepAndSignsOnce() async throws {
        let wallet = CountingWallet()
        chain.unreachableSends = 1
        let events = EventLog()
        let steps: [TransactionStep] = [.call(request, label: "Approve"), .call(TransactionRequest(to: target, data: Data([0x02])), label: "Swap")]
        let last = try await sender().run(steps, from: wallet) { events.append($0) }
        XCTAssertEqual(wallet.signatures, 2)
        XCTAssertEqual(chain.sent.count, 2)
        XCTAssertEqual(last, Keccak.hash256(Data(hex: chain.sent[1].raw)!))
        XCTAssertTrue(events.all.contains(.sent("Approve", Keccak.hash256(Data(hex: chain.sent[0].raw)!))))
    }

    /// A step that may be live but never confirms: the run reports it unconfirmed with its hash, after the `.sent` event,
    /// and signs nothing more.
    func testPossiblySentStepThatNeverConfirmsKeepsItsHash() async {
        let wallet = CountingWallet()
        chain.unreachableSends = 100
        let events = EventLog()
        do {
            _ = try await sender(receiptPolls: 3).run([.call(request, label: "Send"), .call(request, label: "Never")], from: wallet) { events.append($0) }
            XCTFail("expected timedOut")
        } catch let error as TransactionError {
            guard case .timedOut(let hash) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(events.all.contains(.sent("Send", hash)))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(wallet.signatures, 1, "the second step is never signed")
    }

    func testRevertIsReportedWithTheHash() async {
        chain.receiptsSucceed = false
        do {
            _ = try await sender().run([.call(request, label: "Swap")], from: CountingWallet()) { _ in }
            XCTFail("expected reverted")
        } catch let error as TransactionError {
            guard case .reverted(let hash) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Standing approvals (IOST-14)

    /// An exact approval whose amount a standing, effectively unlimited allowance already covers is sent anyway,
    /// replacing it, and the sheet can name it; an ordinary covering allowance still skips the step.
    func testStandingUnlimitedApprovalIsReplacedByTheExactOne() async throws {
        let owner = CountingWallet().address
        let token = Address(literal: "0x3333333333333333333333333333333333333333")
        let step = TransactionStep.approve(token: token, spender: Uniswap.permit2, amount: 50, label: "Approve")
        chain.allowance = SwapCalldata.maxUint160
        let replaced = try await sender().request(for: step, owner: owner)
        XCTAssertEqual(replaced, TransactionRequest(to: token, data: try ERC20.approveCalldata(spender: Uniswap.permit2, amount: 50)))
        let named = await sender().unlimitedAllowancesReplaced(by: [step, .call(request, label: "Swap")], owner: owner)
        XCTAssertEqual(named, [Uniswap.permit2])

        chain.allowance = 50
        let covered = try await sender().request(for: step, owner: owner)
        XCTAssertNil(covered)
        let none = await sender().unlimitedAllowancesReplaced(by: [step], owner: owner)
        XCTAssertEqual(none, [])

        // A step that itself asks for an unlimited amount is covered by an unlimited allowance, as before.
        chain.allowance = SwapCalldata.maxUint160
        let unlimited = try await sender().request(for: .approve(token: token, spender: Uniswap.permit2, amount: SwapCalldata.maxUint160, label: "Approve"), owner: owner)
        XCTAssertNil(unlimited)
    }

    // MARK: Receipt wait (GL-2)

    private func broadcastOne() async throws -> Data {
        try await sender().send(request, from: CountingWallet())
    }

    /// The budget is polls: the last one is followed by one more read, which finds the receipt.
    func testReceiptWaitMakesOneLastReadAfterTheBudget() async throws {
        let hash = try await broadcastOne()
        chain.pendingReceiptReads = 3
        let receipt = try await rpc.waitForReceipt(hash, polls: 3, interval: .milliseconds(1))
        XCTAssertTrue(receipt.success)

        let second = try await sender().send(TransactionRequest(to: target, data: Data([0x09])), from: CountingWallet())
        chain.pendingReceiptReads = 4
        do {
            _ = try await rpc.waitForReceipt(second, polls: 3, interval: .milliseconds(1))
            XCTFail("expected timedOut")
        } catch let error as TransactionError {
            XCTAssertEqual(error.hash, second)
        }
    }

    /// The fast first phase (real-time spec §6.2): its reads come before the budget's, `fastInterval` apart, and count as
    /// polls of their own — the budget is still a number of polls (fast + slow + the last read), never a deadline.
    func testReceiptWaitReadsFastFirst() async throws {
        let hash = try await broadcastOne()
        chain.pendingReceiptReads = 3
        let started = Date()
        // Slow polls 10 s apart: only the fast phase can find it this soon.
        let receipt = try await rpc.waitForReceipt(hash, polls: 2, interval: .seconds(10), fastPolls: 5, fastInterval: .milliseconds(1))
        XCTAssertTrue(receipt.success)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "found in the fast phase")

        // 2 fast + 2 slow + the last read: a receipt on the 5th read is found, one on the 6th is not.
        let second = try await sender().send(TransactionRequest(to: target, data: Data([0x0a])), from: CountingWallet())
        chain.pendingReceiptReads = 4
        let found = try await rpc.waitForReceipt(second, polls: 2, interval: .milliseconds(1), fastPolls: 2, fastInterval: .milliseconds(1))
        XCTAssertTrue(found.success)
        let third = try await sender().send(TransactionRequest(to: target, data: Data([0x0b])), from: CountingWallet())
        chain.pendingReceiptReads = 5
        do {
            _ = try await rpc.waitForReceipt(third, polls: 2, interval: .milliseconds(1), fastPolls: 2, fastInterval: .milliseconds(1))
            XCTFail("expected timedOut")
        } catch let error as TransactionError {
            XCTAssertEqual(error.hash, third)
        }
    }

    /// 20 reads 150 ms apart by default, on Monad only: the Bridge's other chains keep the 500 ms polls. A plan's step on
    /// Monad uses them.
    func testFastReceiptPollsAreMonadsOnly() async throws {
        let defaults = TransactionSender.Timing()
        XCTAssertEqual(defaults.receiptFastPolls, 20)
        XCTAssertEqual(defaults.receiptFastInterval, .milliseconds(150))
        XCTAssertEqual(defaults.receiptPolls, 180, "the budget after them is unchanged")
        XCTAssertEqual(defaults.receiptInterval, .milliseconds(500))
        XCTAssertEqual(TransactionSender(rpc: rpc, chainId: Monad.chainId).receiptFastPollCount, 20)
        XCTAssertEqual(TransactionSender(rpc: rpc, chainId: 1).receiptFastPollCount, 0)
        XCTAssertEqual(TransactionSender(rpc: rpc, chainId: 8453).receiptFastPollCount, 0)

        // A Monad step whose receipt shows on the third read: found by the fast reads, never waiting out a slow poll.
        var monad = sender(receiptFastPolls: 5)
        monad.timing.receiptInterval = .seconds(10)
        chain.pendingReceiptReads = 2
        let started = Date()
        _ = try await monad.run([.call(request, label: "Long BTC-PERP")], from: CountingWallet()) { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Failed reads (a socket that died while the phone was locked) are polls like any other, not a failure.
    func testReceiptWaitRidesOutFailedReads() async throws {
        let hash = try await broadcastOne()
        chain.receiptReadFailures = 4
        let receipt = try await rpc.waitForReceipt(hash, polls: 10, interval: .milliseconds(1))
        XCTAssertTrue(receipt.success)
    }

    func testKnowsTransaction() async throws {
        let hash = try await broadcastOne()
        let known = await rpc.knowsTransaction(hash)
        XCTAssertEqual(known, true)
        let unknown = await rpc.knowsTransaction(Data(repeating: 7, count: 32))
        XCTAssertEqual(unknown, false)
        RPCStub.transportFailure = ["primary.test"]
        let unreachable = await rpc.knowsTransaction(hash)
        XCTAssertNil(unreachable, "no answer says nothing either way")
    }
}

/// Counts signatures; signs nothing real (the unsigned payload stands in for the raw transaction, like `StubWallet`).
final class CountingWallet: Wallet, @unchecked Sendable {
    let address = Address(literal: "0x1111111111111111111111111111111111111111")
    private let lock = NSLock()
    private var count = 0
    var signatures: Int { lock.lock(); defer { lock.unlock() }; return count }

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        lock.withLock { count += 1 }
        return RLP.unsignedPayload(transaction)
    }

    func signMessage(_ message: Data) async throws -> Data { Data() }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransactionEvent] = []
    var all: [TransactionEvent] { lock.lock(); defer { lock.unlock() }; return events }
    func append(_ event: TransactionEvent) { lock.lock(); events.append(event); lock.unlock() }
}
