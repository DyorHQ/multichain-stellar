import BigInt
import XCTest
@testable import DyorKit

/// Network fee ceilings for every wallet (security audit 2026-09-26, IOST-1): the RPC sets the gas limit, base fee and
/// tip, so `prepare` refuses — never clamps — a fee out of bounds, before any wallet is asked to sign.
final class NetworkFeeLimitsTests: XCTestCase {
    private let gwei = BigUInt(1_000_000_000)
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

    private func sender(chainId: Int = Monad.chainId) -> TransactionSender {
        TransactionSender(rpc: RPCClient(url: URL(string: "https://primary.test")!, session: RPCStub.session()), chainId: chainId)
    }

    private var request: TransactionRequest { TransactionRequest(to: target, data: Data([0x01])) }

    private func hex(_ value: BigUInt) -> String { value.hexQuantity }

    private func assertRefused(_ message: String, chainId: Int = Monad.chainId, file: StaticString = #filePath, line: UInt = #line) async {
        let wallet = CountingWallet()
        do {
            _ = try await sender(chainId: chainId).send(request, from: wallet)
            XCTFail("expected a refusal", file: file, line: line)
        } catch let error as TransactionError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected \(error)", file: file, line: line) }
            XCTAssertTrue(reason.contains(message), reason, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
        XCTAssertEqual(wallet.signatures, 0, "nothing is signed", file: file, line: line)
        XCTAssertTrue(chain.sent.isEmpty, "nothing is sent", file: file, line: line)
    }

    func testNormalMonadFeePasses() async throws {
        let prepared = try await sender().prepare(request, from: CountingWallet())
        XCTAssertEqual(prepared.gasLimit, 25_200)
        XCTAssertEqual(prepared.maxFeePerGas, 202 * gwei)
        XCTAssertEqual(prepared.maxPriorityFeePerGas, 2 * gwei)
    }

    func testHostileGasEstimateIsRefused() async {
        chain.estimate = hex(13_000_000) // × 1.2 = 15.6M, over the 15M ceiling
        await assertRefused("unusually high fee")
    }

    func testTotalOverFiveMONIsRefused() async {
        chain.estimate = hex(10_000_000) // 12M limit
        RPCStub.baseFee = hex(300 * gwei) // max fee 602 gwei → 7.2 MON
        await assertRefused("unusually high fee (up to 7.224 MON)")
    }

    func testHostileBaseFeeIsRefused() async {
        RPCStub.baseFee = hex(50_000 * gwei) // max fee 100,002 gwei, over the 10,000 gwei ceiling
        await assertRefused("unusual gas price")
    }

    /// A tip up to twice the base fee is congestion; above that, an RPC out of bounds.
    func testTipAboveTwiceTheBaseFeeIsRefusedOnMonad() async throws {
        RPCStub.tip = hex(200 * gwei)
        let busy = try await sender().prepare(request, from: CountingWallet())
        XCTAssertEqual(busy.maxPriorityFeePerGas, 200 * gwei)
        RPCStub.tip = hex(200 * gwei + 1)
        await assertRefused("unusual gas price")
    }

    /// A base fee that decayed toward zero (a local fork's empty blocks) with the node's usual 1 gwei tip: still an
    /// ordinary fee. The base-relative bound applies only above a 10 gwei floor.
    func testTipBoundHasAFloorForADecayedBaseFee() async throws {
        RPCStub.baseFee = hex(gwei / 5) // 0.2 gwei
        RPCStub.tip = hex(gwei)
        let prepared = try await sender().prepare(request, from: CountingWallet())
        XCTAssertEqual(prepared.maxPriorityFeePerGas, gwei)
        XCTAssertEqual(prepared.maxFeePerGas, gwei * 2 / 5 + gwei)
        RPCStub.tip = hex(10 * gwei)
        _ = try await sender().prepare(request, from: CountingWallet())
        RPCStub.tip = hex(10 * gwei + 1)
        await assertRefused("unusual gas price")
    }

    /// Without a suggested tip the fee falls back to the gas price (tip = price, a little over the base fee): no base-fee
    /// check applies to a fee that isn't derived from the base fee.
    func testGasPriceFallbackIsNotMistakenForAHostileTip() async throws {
        RPCStub.tip = nil
        let prepared = try await sender().prepare(request, from: CountingWallet())
        XCTAssertEqual(prepared.maxPriorityFeePerGas, 102 * gwei)
        XCTAssertEqual(prepared.maxFeePerGas, 204 * gwei)
    }

    /// Other chains: only the total (and a sanity gas ceiling) — tips there routinely exceed the base fee.
    func testOtherChainsAreBoundedByTheirTotal() async throws {
        RPCStub.baseFee = hex(gwei / 100) // 0.01 gwei, Base-like
        RPCStub.tip = hex(gwei / 50)      // 0.02 gwei
        _ = try await sender(chainId: 8453).prepare(request, from: CountingWallet())
        RPCStub.baseFee = hex(10_000_000 * gwei) // 25,200 × 20M gwei ≈ 504 ETH
        await assertRefused("unusually high fee", chainId: 8453)
    }

    /// The Monad caps stay 15,000,000 gas and 5 MON (owner decision: no exception for graduation). The v2 launchpad's
    /// `graduateFallback` reverts below 22,062,500 gas, so a prepared one is refused before any wallet signs; the keepers
    /// send it instead.
    func testCapsArePinnedAndAV2GraduateFallbackIsRefused() async {
        XCTAssertEqual(NetworkFeeLimits.monad.maxGasLimit, 15_000_000)
        XCTAssertEqual(NetworkFeeLimits.monad.maxNetworkFee, 5 * mon)
        XCTAssertEqual(NetworkFeeLimits.violation(gasLimit: 22_100_000, maxFeePerGas: 102 * gwei, maxPriorityFeePerGas: 2 * gwei, baseFee: 100 * gwei, chainId: Monad.chainId), .gasLimit)
        chain.estimate = hex(22_100_000) // what a node estimates for v2's graduateFallback (× 1.2 on top)
        await assertRefused("unusually high fee")
    }

    func testViolations() {
        let v = { (gas: BigUInt, fee: BigUInt, tip: BigUInt, base: BigUInt?, chain: Int) in
            NetworkFeeLimits.violation(gasLimit: gas, maxFeePerGas: fee, maxPriorityFeePerGas: tip, baseFee: base, chainId: chain)
        }
        XCTAssertNil(v(360_000, 202 * gwei, 2 * gwei, 100 * gwei, Monad.chainId))
        XCTAssertNil(v(10_000_000, 500 * gwei, 2 * gwei, nil, Monad.chainId), "exactly 5 MON")
        XCTAssertEqual(v(10_000_000, 500 * gwei + 1, 2 * gwei, nil, Monad.chainId), .total)
        XCTAssertEqual(v(15_000_001, 1, 1, nil, Monad.chainId), .gasLimit)
        XCTAssertEqual(v(21_000, 10_000 * gwei + 1, 1, nil, Monad.chainId), .feePerGas)
        XCTAssertEqual(v(21_000, 202 * gwei, 203 * gwei, nil, Monad.chainId), .tip)
        XCTAssertEqual(v(21_000, 300 * gwei, 2 * gwei, 100 * gwei, Monad.chainId), .feePerGas, "above 2 × base + tip")
        XCTAssertNil(v(21_000, gwei * 2 / 5 + 10 * gwei, 10 * gwei, gwei / 5, Monad.chainId), "a 10 gwei tip whatever the base fee")
        XCTAssertEqual(v(21_000, gwei * 2 / 5 + 10 * gwei + 1, 10 * gwei + 1, gwei / 5, Monad.chainId), .tip)
        XCTAssertNil(v(2_000_000, gwei / 10, gwei / 10, gwei / 1000, 42161), "Arbitrum: a big estimate at a tiny fee")
        XCTAssertEqual(v(78_000, 700 * gwei, 2 * gwei, 349 * gwei, 1), .total, "Ethereum over 0.05 ETH")
        XCTAssertNil(v(78_000, 600 * gwei, 2 * gwei, 299 * gwei, 1))
        for chain in EVMChain.supported {
            XCTAssertNil(v(78_000, NetworkFeeReserve.fallback(chainId: chain.chainId) / 25_200, 1, nil, chain.chainId),
                         "\(chain.name): a busy day's transfer (the fee reserve's fallback) is within bounds")
        }
    }

    // MARK: Preview

    func testFeePreviewSumsEstimableSteps() async throws {
        let steps: [TransactionStep] = [.call(request, label: "One"), .call(TransactionRequest(to: target, data: Data([0x02])), label: "Two")]
        let first = await sender().feePreview(steps, from: CountingWallet().address)
        let preview = try XCTUnwrap(first)
        XCTAssertEqual(preview.maxFee, 2 * 25_200 * 202 * gwei)
        XCTAssertEqual(preview.unestimated, 0)
        chain.estimate = nil
        let second = await sender().feePreview(steps, from: CountingWallet().address)
        let blind = try XCTUnwrap(second)
        XCTAssertEqual(blind.maxFee, 0)
        XCTAssertEqual(blind.unestimated, 2)
    }
}
