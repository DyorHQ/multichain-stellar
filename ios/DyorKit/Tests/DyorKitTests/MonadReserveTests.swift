import BigInt
import XCTest
@testable import DyorKit

/// Monad's reserve balance and the honest "Max" (MERA-PLAN §5), for every account type: a plan step that sends MON
/// while the account holds under 10 MON + the value waits until 3 blocks after the run's previous step; a broadcast
/// refused because the funding is still settling is resent once and then explained; a native Max keeps back what the
/// transaction can be charged.
final class MonadReserveTests: XCTestCase {
    private let mon = BigUInt(10).power(18)
    private let gwei = BigUInt(1_000_000_000)
    private let wallet = StubWallet()
    private let target = Address(literal: "0x2222222222222222222222222222222222222222")
    private var chain: SimulatedChain { RPCStub.chain! }

    override func setUp() {
        super.setUp()
        RPCStub.reset()
        RPCStub.chain = SimulatedChain()
        RPCStub.baseFee = "0x174876e800" // 100 gwei
        RPCStub.tip = "0x77359400"       // 2 gwei → max fee 202 gwei
    }

    override func tearDown() {
        RPCStub.reset()
        super.tearDown()
    }

    private func sender(chainId: Int = Monad.chainId, spacingTimeout: Duration = .seconds(5)) -> TransactionSender {
        var sender = TransactionSender(rpc: RPCClient(url: URL(string: "https://primary.test")!, session: RPCStub.session()), chainId: chainId)
        sender.timing = .init(blockPoll: .milliseconds(5), spacingTimeout: spacingTimeout, fundingRetry: .milliseconds(5), resendBackoff: .milliseconds(1))
        return sender
    }

    private func step(_ value: BigUInt, _ label: String) -> TransactionStep {
        .call(TransactionRequest(to: target, data: Data([0x01]), value: value), label: label)
    }

    private func run(_ steps: [TransactionStep], on sender: TransactionSender) async throws {
        _ = try await sender.run(steps, from: wallet) { _ in }
    }

    // MARK: Reserve spacing

    /// The at-risk plan: approve, then a step that sends MON (launchAndBuy with its 5 MON fee) from an account under the
    /// reserve. The second broadcast waits for the head to reach the approve's block + 3.
    func testMONStepAfterAPriorStepWaitsThreeBlocks() async throws {
        chain.balance = 5 * mon
        try await run([step(0, "Approve"), step(mon, "Launch and buy")], on: sender())
        XCTAssertEqual(chain.sent.count, 2)
        XCTAssertGreaterThanOrEqual(chain.sent[1].head, chain.receiptBlocks[0] + 3, "sent only once the head is 3 blocks past the approve")
        XCTAssertGreaterThanOrEqual(chain.blockNumberReads, 4, "polled the head from the approve's block until it was 3 past")
    }

    func testFirstStepNeverWaits() async throws {
        chain.balance = 2 * mon
        try await run([step(mon, "Swap")], on: sender())
        XCTAssertEqual(chain.sent.count, 1)
        XCTAssertEqual(chain.blockNumberReads, 0)
        XCTAssertEqual(chain.balanceReads, 0)
    }

    func testStepsWithoutValueNeverWait() async throws {
        chain.balance = 0
        try await run([step(0, "Approve"), step(0, "Swap")], on: sender())
        XCTAssertEqual(chain.sent.count, 2)
        XCTAssertEqual(chain.blockNumberReads, 0)
        XCTAssertEqual(chain.balanceReads, 0)
    }

    func testAccountAtOrAboveTheReserveNeverWaits() async throws {
        chain.balance = TransactionSender.monadReserveBalance + mon // exactly 10 MON + the value
        try await run([step(0, "Approve"), step(mon, "Launch and buy")], on: sender())
        XCTAssertEqual(chain.sent.count, 2)
        XCTAssertEqual(chain.balanceReads, 1)
        XCTAssertEqual(chain.blockNumberReads, 0)
        XCTAssertEqual(chain.sent[1].head, chain.receiptBlocks[0])

        // One wei under the reserve waits.
        RPCStub.chain = SimulatedChain()
        chain.balance = TransactionSender.monadReserveBalance + mon - 1
        try await run([step(0, "Approve"), step(mon, "Launch and buy")], on: sender())
        XCTAssertGreaterThanOrEqual(chain.sent[1].head, chain.receiptBlocks[0] + 3)
    }

    func testOtherChainsNeverWait() async throws {
        chain.balance = mon / 100
        try await run([step(0, "Approve"), step(mon / 1000, "Deposit")], on: sender(chainId: 8453))
        XCTAssertEqual(chain.sent.count, 2)
        XCTAssertEqual(chain.blockNumberReads, 0)
        XCTAssertEqual(chain.balanceReads, 0)
    }

    /// A head that never moves (a local fork that mines on demand, a stalled node) delays the step, never hangs it.
    func testStalledHeadGivesUpAndSends() async throws {
        chain.balance = 5 * mon
        chain.frozen = true
        let start = ContinuousClock.now
        try await run([step(0, "Approve"), step(mon, "Launch and buy")], on: sender(spacingTimeout: .milliseconds(200)))
        XCTAssertEqual(chain.sent.count, 2)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(200))
    }

    // MARK: Funding still settling

    func testFundingRefusalIsResentOnceWithTheSameBytes() async throws {
        chain.balance = 5 * mon
        chain.sendFailures = 1
        let hash = try await sender().send(TransactionRequest(to: target, value: mon), from: wallet)
        XCTAssertEqual(chain.sent.count, 2)
        XCTAssertEqual(chain.sent[0].raw, chain.sent[1].raw, "the same signed transaction: no second signature, no second Face ID")
        XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[1].raw)!))
    }

    func testFundingStillSettlingIsExplained() async {
        chain.balance = 5 * mon // covers 1 MON + 25,200 × 202 gwei
        chain.sendFailures = 5
        do {
            _ = try await sender().send(TransactionRequest(to: target, value: mon), from: wallet)
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Your funds are still arriving. Try again in a moment.")
        }
        XCTAssertEqual(chain.sent.count, 2, "one resend, never a loop")
    }

    func testARealShortfallIsNotCalledArriving() async {
        chain.balance = mon // short of 1 MON + the fee
        chain.sendFailures = 5
        do {
            _ = try await sender().send(TransactionRequest(to: target, value: mon), from: wallet)
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Not enough MON to pay for gas.")
        }
    }

    func testOtherRefusalsAndOtherChainsAreNotRetried() async {
        chain.balance = 5 * mon
        chain.sendFailures = 1
        chain.sendFailure = "nonce too low"
        do { _ = try await sender().send(TransactionRequest(to: target, value: mon), from: wallet); XCTFail("expected the node's error") } catch {}
        XCTAssertEqual(chain.sent.count, 1)

        RPCStub.chain = SimulatedChain()
        chain.sendFailures = 1
        do {
            _ = try await sender(chainId: 8453).send(TransactionRequest(to: target, value: mon), from: wallet)
            XCTFail("expected the node's error")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "Signer had insufficient balance")
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(chain.sent.count, 1)
    }

    // MARK: Max

    /// The estimate (21,000 → a 25,200 limit) × the max fee (2 × 100 + 2 gwei), with Monad's 5/4 headroom.
    func testMaxKeepsBackTheEstimatedFee() async {
        let max = await sender().maxValue(balance: mon, like: TransactionRequest(to: target, value: 1), from: wallet.address, budget: NetworkFeeReserve.swapGasLimit)
        XCTAssertEqual(max, mon - BigUInt(25_200) * 202 * gwei * 5 / 4) // 0.0063630 MON kept
    }

    func testMaxUsesTheBudgetWhenThereIsNothingToEstimate() async {
        let expected = mon - NetworkFeeReserve.swapGasLimit * 202 * gwei * 5 / 4 // 0.07575 MON kept
        let noRequest = await sender().maxValue(balance: mon, like: nil, from: wallet.address, budget: NetworkFeeReserve.swapGasLimit)
        XCTAssertEqual(noRequest, expected)
        chain.estimate = nil
        let reverts = await sender().maxValue(balance: mon, like: TransactionRequest(to: target, value: 1), from: wallet.address, budget: NetworkFeeReserve.swapGasLimit)
        XCTAssertEqual(reverts, expected)
    }

    func testMaxFallsBackWhenTheFeeCantBeRead() async {
        RPCStub.baseFee = nil
        RPCStub.tip = nil
        RPCStub.gasPrice = nil
        let monad = await sender().maxValue(balance: mon, like: nil, from: wallet.address, budget: NetworkFeeReserve.swapGasLimit)
        XCTAssertEqual(monad, mon - 6 * BigUInt(10).power(16), "0.06 MON")
        let base = await sender(chainId: 8453).maxValue(balance: mon, like: nil, from: wallet.address, budget: NetworkFeeReserve.transferGasLimit)
        XCTAssertEqual(base, mon - NetworkFeeReserve.fallback(chainId: 8453))
    }

    /// Other chains: × 2 headroom, plus the L1 data-fee allowance on Base, Optimism and Scroll.
    func testMaxOnOtherChains() async {
        let base = await sender(chainId: 8453).maxValue(balance: mon, like: TransactionRequest(to: target, value: 1), from: wallet.address, budget: 0)
        XCTAssertEqual(base, mon - (BigUInt(25_200) * 202 * gwei * 2 + BigUInt(10).power(13)))
        let arbitrum = await sender(chainId: 42161).maxValue(balance: mon, like: TransactionRequest(to: target, value: 1), from: wallet.address, budget: 0)
        XCTAssertEqual(arbitrum, mon - BigUInt(25_200) * 202 * gwei * 2)
    }

    func testMaxIsZeroWhenTheFeeTakesEverything() async {
        let max = await sender().maxValue(balance: BigUInt(10).power(15), like: nil, from: wallet.address, budget: NetworkFeeReserve.swapGasLimit)
        XCTAssertEqual(max, 0)
        XCTAssertEqual(NetworkFeeReserve.spendable(balance: 5, reserve: 5), 0)
        XCTAssertEqual(NetworkFeeReserve.spendable(balance: 6, reserve: 5), 1)
    }

    func testEveryBridgeChainHasAFallback() {
        XCTAssertEqual(NetworkFeeReserve.fallback(chainId: Monad.chainId), 6 * BigUInt(10).power(16))
        for chain in EVMChain.supported {
            let fallback = NetworkFeeReserve.fallback(chainId: chain.chainId)
            XCTAssertGreaterThan(fallback, 0, chain.name)
            XCTAssertLessThanOrEqual(fallback, BigUInt(10).power(17), "\(chain.name): a fallback never keeps back more than 0.1 of the coin")
        }
    }
}
