import BigInt
import XCTest
@testable import DyorKit

/// Fixtures/prices.json holds real live reads captured against Monad mainnet: the Uniswap v3 WMON/USDC pool
/// (getPool + slot0 + liquidity + token0) and the Uniswap v4 MON/USDC pool through StateView (getSlot0 +
/// getLiquidity). This suite runs the recorded return data through `PriceService`'s own decode/price math and
/// checks the derived MON/USD spot is sane. A separate live smoke test hits the node and skips when offline.
final class PriceTests: XCTestCase {
    private static let fixture: JSON = {
        let url = Bundle.module.url(forResource: "prices", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }()

    private var f: JSON { Self.fixture }

    private func hex(_ s: String) -> Data { Data(hex: s)! }
    private func decodeAddress(_ hexData: String) throws -> Address { try ABI.decode(hex(hexData), "address")[0].address }
    private func decodeUint(_ hexData: String, _ type: String) throws -> BigUInt { try ABI.decode(hex(hexData), type)[0].uint }

    // MARK: Deriving MON/USD from recorded reads

    func testDerivedMonPriceFromRecordedReads() throws {
        // --- v3: WMON/USDC pool. Decode the discovery reads exactly as PriceService.discover does. ---
        let poolFromFactory = try decodeAddress(f["v3"]["getPool"].string!)
        XCTAssertEqual(poolFromFactory, Address(f["v3"]["pool"].string!)!, "getPool decodes to the recorded pool address")
        let liquidity = try decodeUint(f["v3"]["liquidity"].string!, "uint128")
        XCTAssertGreaterThan(liquidity, 0, "the v3 pool has liquidity")
        let token0 = try decodeAddress(f["v3"]["token0"].string!)
        XCTAssertEqual(token0, Monad.wmon, "token0 of the WMON/USDC pool is WMON")

        // MON is priced through its wrapped form against USDC on this v3 pool.
        let v3Source = PriceService.Source.v3(pool: poolFromFactory, token: Monad.wmon, quote: Monad.usdc, token0: token0)
        let v3Sqrt = try XCTUnwrap(PriceService.sqrtPrice(hex(f["v3"]["slot0"].string!)), "slot0 yields a sqrtPriceX96")
        XCTAssertGreaterThan(v3Sqrt, 0)
        let monV3 = PriceService.usd(sqrtPriceX96: v3Sqrt, source: v3Source, tokenDecimals: Token.mon.decimals)
        XCTAssertGreaterThan(monV3, 0.01, "MON/USD from v3 is above the sanity floor")
        XCTAssertLessThan(monV3, 1000, "MON/USD from v3 is below the sanity ceiling")

        // --- v4: MON/USDC pool through StateView. ---
        let poolId = hex(f["v4"]["poolId"].string!)
        XCTAssertEqual(poolId.hexString, PoolKey.canonical(Monad.native, Monad.usdc, fee: 500, tickSpacing: 10).id.hexString,
                       "the recorded v4 pool id is the canonical MON/USDC 0.05% pool")
        let v4Liquidity = try decodeUint(f["v4"]["getLiquidity"].string!, "uint128")
        XCTAssertGreaterThan(v4Liquidity, 0, "the v4 pool has liquidity")
        let v4Source = PriceService.Source.v4(poolId: poolId)
        let v4Sqrt = try XCTUnwrap(PriceService.sqrtPrice(hex(f["v4"]["getSlot0"].string!)), "getSlot0 yields a sqrtPriceX96")
        let monV4 = PriceService.usd(sqrtPriceX96: v4Sqrt, source: v4Source, tokenDecimals: Token.mon.decimals)
        XCTAssertGreaterThan(monV4, 0.01, "MON/USD from v4 is above the sanity floor")
        XCTAssertLessThan(monV4, 1000, "MON/USD from v4 is below the sanity ceiling")

        // Both venues price the same asset at the same block, so they agree closely.
        XCTAssertEqual(monV3, monV4, accuracy: 0.01, "v3 and v4 MON/USD agree")

        // USDC is one dollar by definition; MON is not a USD token.
        XCTAssertTrue(PriceService.isUSD(Token.usdc))
        XCTAssertFalse(PriceService.isUSD(Token.mon))
    }

    // MARK: Live smoke test (skips when the network is unreachable)

    /// Reads live MON and USDC prices and a short MON history off Monad mainnet. Skips (never fails) offline.
    func testLivePricesSmoke() async throws {
        let rpc = RPCClient(url: Monad.defaultRPC)
        do {
            _ = try await rpc.blockNumber()
        } catch {
            throw XCTSkip("Monad RPC unreachable: \(error)")
        }
        let service = PriceService(rpc: rpc)

        let prices: [Address: PriceInfo]
        do {
            prices = try await service.prices(for: [.mon, .usdc])
        } catch {
            throw XCTSkip("prices() failed against the live node: \(error)")
        }
        guard let usdc = prices[Monad.usdc] else { throw XCTSkip("no USDC price came back") }
        XCTAssertEqual(usdc.usd, 1, accuracy: 1e-9, "USDC is one dollar by definition")
        guard let mon = prices[Monad.native] else { throw XCTSkip("no MON price came back (node/pool unavailable)") }
        XCTAssertGreaterThan(mon.usd, 0, "MON has a positive USD price")

        let history: [PricePoint]
        do {
            history = try await service.history(for: .mon, points: 8)
        } catch {
            throw XCTSkip("history() failed against the live node: \(error)")
        }
        guard history.count >= 4 else { throw XCTSkip("archive history unavailable: only \(history.count) point(s)") }
        XCTAssertTrue(history.allSatisfy { $0.usd > 0 }, "every history sample is a positive price")
    }
}
