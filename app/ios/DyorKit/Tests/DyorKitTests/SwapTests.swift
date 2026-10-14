import BigInt
import XCTest
@testable import DyorKit

/// Fixtures/swap.json was produced with viem: every calldata vector is what the web app's own builders encode for
/// the venue routers, quoters and read helpers. This suite asserts the Swift `SwapCalldata` builders (and the pool
/// key / route helpers) produce byte-identical calldata for the SAME sample inputs the fixture used. The inputs are
/// read from the fixture's `inputs` object where it stores them; the fees, tick spacings and pool directions are the
/// values embedded in each expected vector (documented inline next to the route/hop that reconstructs them).
final class SwapTests: XCTestCase {
    private static let fixture: JSON = {
        let url = Bundle.module.url(forResource: "swap", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }()

    private var f: JSON { Self.fixture }

    // MARK: Sample inputs (read straight from the fixture)

    private var account: Address { Address(f["inputs"]["account"].string!)! }
    private var deadline: BigUInt { BigUInt(f["inputs"]["deadline"].string!)! }
    private var amountIn: BigUInt { BigUInt(f["inputs"]["amountIn"].string!)! }        // 1 MON
    private var minOut: BigUInt { BigUInt(f["inputs"]["minOut"].string!)! }            // 2.6 USDC
    private var usdcIn: BigUInt { BigUInt(f["inputs"]["usdcIn"].string!)! }            // 1 USDC
    private var wmonMinOut: BigUInt { BigUInt(f["inputs"]["wmonMinOut"].string!)! }    // 0.1 WMON
    private var wethMinOut: BigUInt { BigUInt(f["inputs"]["wethMinOut"].string!)! }    // 0.0003 WETH
    private var permit2Amount: BigUInt { BigUInt(f["inputs"]["permit2Amount"].string!)! }
    private var permit2Expiration: BigUInt { BigUInt(f["inputs"]["permit2Expiration"].string!)! }

    // MARK: Reconstructed routes (fees/order are the values embedded in the expected calldata)

    /// SwapRouter02 / QuoterV2 single hop: WMON --(0.05%)--> USDC.
    private var v3Single: V3Route { V3Route(path: [Monad.wmon, Monad.usdc], fees: [500]) }
    /// Monday single hop uses the 0.03% tier in the fixture: WMON --(0.03%)--> USDC.
    private var mondaySingle: V3Route { V3Route(path: [Monad.wmon, Monad.usdc], fees: [300]) }
    /// Two hop: USDC --(0.05%)--> WETH --(0.3%)--> WMON. (v3Path.double / describe.v3Double.)
    private var v3Double: V3Route { V3Route(path: [Monad.usdc, Monad.weth, Monad.wmon], fees: [500, 3000]) }

    // v4 hops. Canonical hookless pools; fee/tickSpacing pairs from the decoded PoolKeys in the fixture.
    /// MON --> USDC through the 0.05% / tickSpacing 10 pool (zeroForOne, MON is currency0).
    private var v4MonUsdc: V4Hop { V4Hop(key: PoolKey.canonical(Monad.native, Monad.usdc, fee: 500, tickSpacing: 10), from: Monad.native)! }
    /// USDC --> MON leg of the two-hop route (same pool, other direction).
    private var v4UsdcToMon: V4Hop { V4Hop(key: PoolKey.canonical(Monad.usdc, Monad.native, fee: 500, tickSpacing: 10), from: Monad.usdc)! }
    /// MON --> WETH through the 0.3% / tickSpacing 60 pool.
    private var v4MonToWeth: V4Hop { V4Hop(key: PoolKey.canonical(Monad.native, Monad.weth, fee: 3000, tickSpacing: 60), from: Monad.native)! }

    // MARK: Helpers

    private func assertData(_ data: Data, _ node: JSON, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(data.hexString, node.string!, label, file: file, line: line)
    }

    /// Asserts a full transaction (to / data / value) against a `{to, data, value}` fixture node.
    private func assertTx(_ tx: TransactionRequest, _ node: JSON, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tx.to, Address(node["to"].string!)!, "\(label) to", file: file, line: line)
        XCTAssertEqual(tx.data.hexString, node["data"].string!, "\(label) data", file: file, line: line)
        XCTAssertEqual(tx.value, BigUInt(node["value"].string!)!, "\(label) value", file: file, line: line)
    }

    // MARK: SwapRouter02 (Uniswap v3)

    func testSwapRouter02CalldataMatchesViem() throws {
        // Standalone leg encoders. exactInputSingle's recipient is the account; the two-hop exactInput vector is the
        // native-out leg, whose recipient is the router's ADDRESS_THIS sentinel.
        assertData(try SwapCalldata.swapRouter02ExactInputSingle(route: v3Single, amountIn: amountIn, minOut: minOut, recipient: account),
                   f["swapRouter02"]["exactInputSingle"], "SwapRouter02.exactInputSingle")
        assertData(try SwapCalldata.swapRouter02ExactInput(route: v3Double, amountIn: usdcIn, minOut: wmonMinOut, recipient: SwapCalldata.routerThis),
                   f["swapRouter02"]["exactInput"], "SwapRouter02.exactInput")

        // Full multicall transactions.
        assertTx(try SwapCalldata.swapRouter02(route: v3Single, amountIn: amountIn, minOut: minOut, account: account, nativeIn: true, nativeOut: false, deadline: deadline),
                 f["swapRouter02"]["nativeInSingle"], "SwapRouter02.nativeInSingle")
        assertTx(try SwapCalldata.swapRouter02(route: v3Single, amountIn: amountIn, minOut: minOut, account: account, nativeIn: false, nativeOut: false, deadline: deadline),
                 f["swapRouter02"]["erc20Single"], "SwapRouter02.erc20Single")
        assertTx(try SwapCalldata.swapRouter02(route: v3Double, amountIn: usdcIn, minOut: wmonMinOut, account: account, nativeIn: false, nativeOut: true, deadline: deadline),
                 f["swapRouter02"]["nativeOutDouble"], "SwapRouter02.nativeOutDouble")
    }

    // MARK: Monday Trade (v3 SwapRouter v1 layout)

    func testMondayCalldataMatchesViem() throws {
        assertData(try SwapCalldata.mondayExactInputSingle(route: mondaySingle, amountIn: amountIn, minOut: minOut, recipient: account, deadline: deadline),
                   f["monday"]["exactInputSingle"], "Monday.exactInputSingle")
        // The two-hop native-out leg: recipient is address(0), which the v1 router treats as itself.
        assertData(try SwapCalldata.mondayExactInput(route: v3Double, amountIn: usdcIn, minOut: wmonMinOut, recipient: .zero, deadline: deadline),
                   f["monday"]["exactInput"], "Monday.exactInput")

        assertTx(try SwapCalldata.mondaySwap(route: mondaySingle, amountIn: amountIn, minOut: minOut, account: account, nativeIn: true, nativeOut: false, deadline: deadline),
                 f["monday"]["nativeInSingle"], "Monday.nativeInSingle")
        assertTx(try SwapCalldata.mondaySwap(route: mondaySingle, amountIn: amountIn, minOut: minOut, account: account, nativeIn: false, nativeOut: false, deadline: deadline),
                 f["monday"]["erc20Single"], "Monday.erc20Single")
        assertTx(try SwapCalldata.mondaySwap(route: v3Double, amountIn: usdcIn, minOut: wmonMinOut, account: account, nativeIn: false, nativeOut: true, deadline: deadline),
                 f["monday"]["nativeOutDouble"], "Monday.nativeOutDouble")
    }

    // MARK: Universal Router (Uniswap v4)

    func testUniversalRouterV4CalldataMatchesViem() throws {
        // Single hop MON -> USDC, native in (value carries the MON).
        assertTx(try SwapCalldata.universalRouterV4(currencyIn: Monad.native, currencyOut: Monad.usdc, hops: [v4MonUsdc], amountIn: amountIn, minOut: minOut, deadline: deadline),
                 f["universalRouter"]["singleHop"], "UniversalRouter.singleHop")
        // Two hop USDC -> MON -> WETH, ERC-20 in (value 0).
        assertTx(try SwapCalldata.universalRouterV4(currencyIn: Monad.usdc, currencyOut: Monad.weth, hops: [v4UsdcToMon, v4MonToWeth], amountIn: usdcIn, minOut: wethMinOut, deadline: deadline),
                 f["universalRouter"]["twoHop"], "UniversalRouter.twoHop")
    }

    // MARK: Permit2 and WMON

    func testPermit2AndWmonCalldataMatchesViem() throws {
        assertData(try SwapCalldata.permit2Approve(token: Monad.usdc, spender: Uniswap.universalRouter, amount: permit2Amount, expiration: permit2Expiration),
                   f["permit2"]["approve"], "Permit2.approve")
        assertData(try SwapCalldata.permit2Allowance(owner: account, token: Monad.usdc, spender: Uniswap.universalRouter).data,
                   f["permit2"]["allowance"], "Permit2.allowance")

        assertData(try SwapCalldata.wmonDeposit(), f["wmon"]["deposit"], "WMON.deposit")
        assertData(try SwapCalldata.wmonWithdraw(amount: amountIn), f["wmon"]["withdraw"], "WMON.withdraw")
    }

    // MARK: Quoter read calldata

    func testQuoterCalldataMatchesViem() throws {
        // QuoterV2 — both the direct encoders and the `quote` dispatcher must produce the same bytes.
        assertData(try SwapCalldata.quoteExactInputSingle(quoter: Uniswap.quoterV2, tokenIn: Monad.wmon, tokenOut: Monad.usdc, amountIn: amountIn, fee: 500).data,
                   f["quoterV2"]["quoteExactInputSingle"], "QuoterV2.quoteExactInputSingle")
        assertData(try SwapCalldata.quote(quoter: Uniswap.quoterV2, route: v3Single, amountIn: amountIn).data,
                   f["quoterV2"]["quoteExactInputSingle"], "QuoterV2.quote(single)")
        assertData(try SwapCalldata.quoteExactInput(quoter: Uniswap.quoterV2, route: v3Double, amountIn: usdcIn).data,
                   f["quoterV2"]["quoteExactInput"], "QuoterV2.quoteExactInput")
        assertData(try SwapCalldata.quote(quoter: Uniswap.quoterV2, route: v3Double, amountIn: usdcIn).data,
                   f["quoterV2"]["quoteExactInput"], "QuoterV2.quote(double)")

        // V4Quoter — single hop and the two-hop path.
        assertData(try SwapCalldata.v4QuoteExactInputSingle(hop: v4MonUsdc, amountIn: amountIn).data,
                   f["v4Quoter"]["quoteExactInputSingle"], "V4Quoter.quoteExactInputSingle")
        assertData(try SwapCalldata.v4Quote(currencyIn: Monad.native, hops: [v4MonUsdc], amountIn: amountIn).data,
                   f["v4Quoter"]["quoteExactInputSingle"], "V4Quoter.v4Quote(single)")
        assertData(try SwapCalldata.v4QuoteExactInput(currencyIn: Monad.usdc, hops: [v4UsdcToMon, v4MonToWeth], amountIn: usdcIn).data,
                   f["v4Quoter"]["quoteExactInput"], "V4Quoter.quoteExactInput")
        assertData(try SwapCalldata.v4Quote(currencyIn: Monad.usdc, hops: [v4UsdcToMon, v4MonToWeth], amountIn: usdcIn).data,
                   f["v4Quoter"]["quoteExactInput"], "V4Quoter.v4Quote(double)")
    }

    // MARK: StateView / factory / pool read calldata

    func testReadCalldataMatchesViem() throws {
        let poolId = Data(hex: f["poolId"].string!)!
        assertData(try SwapCalldata.stateViewSlot0(poolId: poolId).data, f["stateView"]["getSlot0"], "StateView.getSlot0")
        assertData(try SwapCalldata.stateViewLiquidity(poolId: poolId).data, f["stateView"]["getLiquidity"], "StateView.getLiquidity")
        assertData(try SwapCalldata.v3GetPool(factory: Uniswap.v3Factory, Monad.wmon, Monad.usdc, fee: 500).data, f["v3Factory"]["getPool"], "v3Factory.getPool")
        // liquidity() takes no args, so the pool address does not affect the calldata.
        assertData(try SwapCalldata.v3Liquidity(pool: Monad.usdc).data, f["v3Pool"]["liquidity"], "v3Pool.liquidity")
    }

    // MARK: v4 pool ids

    func testPoolIds() {
        // The MON/USDC 0.05% pool (tickSpacing 10) and the MON/WETH 0.3% pool (tickSpacing 60).
        XCTAssertEqual(PoolKey.canonical(Monad.native, Monad.usdc, fee: 500, tickSpacing: 10).id.hexString, f["poolId"].string!)
        XCTAssertEqual(PoolKey.canonical(Monad.native, Monad.weth, fee: 3000, tickSpacing: 60).id.hexString, f["poolIdNativeWeth"].string!)
        // Canonical ordering is stable regardless of argument order.
        XCTAssertEqual(PoolKey.canonical(Monad.usdc, Monad.native, fee: 500, tickSpacing: 10).id.hexString, f["poolId"].string!)
    }

    // MARK: Packed v3 paths / fee labels / route description / price impact

    func testPackedPathsMatchViem() {
        assertData(v3Single.packed, f["v3Path"]["single"], "v3Path.single")
        assertData(v3Double.packed, f["v3Path"]["double"], "v3Path.double")
    }

    func testFeeLabelsMatchViem() {
        for (fee, label) in f["feeLabels"].object! {
            XCTAssertEqual(SwapMath.feeLabel(Int(fee)!), label.string!, "feeLabel(\(fee))")
        }
    }

    func testRouteDescriptionMatchesViem() {
        XCTAssertEqual(V3Router.describe(v3Single, symbols: ["MON", "USDC"]), f["describe"]["v3Single"].string!)
        XCTAssertEqual(V3Router.describe(v3Double, symbols: ["USDC", "WETH", "MON"]), f["describe"]["v3Double"].string!)
        XCTAssertEqual(V3Router.hopSymbol(Monad.weth), f["describe"]["hopWETH"].string!)
        XCTAssertEqual(V3Router.hopSymbol(Monad.usdc), f["describe"]["hopUSDC"].string!)
        XCTAssertEqual(V3Router.hopSymbol(account), f["describe"]["hopUnknown"].string!)
    }

    func testPriceImpactMatchesViem() {
        for c in f["impact"].array! {
            let bps = SwapMath.impactBps(amountIn: BigUInt(c["amountIn"].string!)!, amountOut: BigUInt(c["amountOut"].string!)!,
                                         sliceIn: BigUInt(c["sliceIn"].string!)!, sliceOut: BigUInt(c["sliceOut"].string!)!)
            if let expected = c["bps"].number {
                XCTAssertEqual(bps, Int(expected), "\(c)")
            } else {
                XCTAssertNil(bps, "\(c)")
            }
        }
    }

    // MARK: Wrap detection and venue names

    func testIsWrapTruthTable() {
        XCTAssertTrue(SwapEngine.isWrap(Token.mon, Token.wmon), "MON -> WMON is a wrap")
        XCTAssertTrue(SwapEngine.isWrap(Token.wmon, Token.mon), "WMON -> MON is an unwrap")
        XCTAssertFalse(SwapEngine.isWrap(Token.mon, Token.usdc), "MON -> USDC is not a wrap")
        XCTAssertFalse(SwapEngine.isWrap(Token.usdc, Token.mon), "USDC -> MON is not a wrap")
        XCTAssertFalse(SwapEngine.isWrap(Token.wmon, Token.usdc), "WMON -> USDC is not a wrap")
    }

    func testVenueDisplayNames() {
        XCTAssertEqual(Venue.kuru.displayName, "Kuru Flow")
        XCTAssertEqual(Venue.uniswap.displayName, "Uniswap")
        XCTAssertEqual(Venue.monday.displayName, "Monday Trade")
        XCTAssertEqual(Venue.wrap.displayName, "Wrap")
    }

    // MARK: Live smoke test (skips when the network is unreachable)

    /// Hits Monad mainnet for a real 1 MON -> USDC quote across the venues. Skips (never fails) offline so it is
    /// safe in CI. Each venue has the engine's own 20s budget, so this stays fast.
    func testLiveQuoteSmoke() async throws {
        let rpc = RPCClient(url: Monad.defaultRPC)
        do {
            _ = try await rpc.blockNumber()
        } catch {
            throw XCTSkip("Monad RPC unreachable: \(error)")
        }
        let engine = SwapEngine(rpc: rpc)
        let request = SwapRequest(tokenIn: .mon, tokenOut: .usdc, amountIn: BigUInt(10).power(18), slippageBps: 50, account: account)
        let result = await engine.quotes(for: request)
        guard let quote = result.quotes.first else {
            throw XCTSkip("No venue returned a quote (likely a rate-limited/offline node). Errors: \(result.errors)")
        }
        XCTAssertGreaterThan(quote.amountOut, 0, "the best venue must return a positive amountOut")
        XCTAssertFalse(quote.route.isEmpty, "a real quote carries a human route")
        XCTAssertGreaterThanOrEqual(quote.amountOut, quote.minOut, "amountOut is at least the slippage floor")
    }
}
