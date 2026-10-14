// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";
import {MockGraduation} from "./mocks/MockGraduation.sol";

/// Exact-value tests. Every literal below comes from the independent Python oracle in test/moments/EXPECTED.md
/// (S = 1e26 coin wei, USDC in 6-dp units), which reconciles with
/// DyorHQ/internal: ios-app/docs/moments-analysis/economics.py.
contract EconomicsTest is MomentsBase {
    uint256 constant RATE_NUM_10PCT = 6750000000000000000000000000000000; // S*9000*7500
    uint256 constant RATE_DEN_10USD = 1750000000000000; // 10000*1e7*17500
    uint256 constant ENT_1USD = 3857142857142857142857142; // 3.857142857M coins
    uint256 constant ENT_10C = 385714285714285714285714;
    uint256 constant ENT_10USD = 38571428571428571428571428;
    uint256 constant TERMINAL_ENT = 1285716857142857142857142; // entitlement of the 333,334-unit terminal collect
    uint256 constant SUM_ENT_10USD = 51428573999999999999999988;
    uint256 constant POOL_10USD = 38571426000000000000000012;
    uint256 constant CREATOR_10PCT = 10000000000000000000000000;
    uint256 constant MODEL_COLLECTORS = 51_428_571_429e15; // 51,428,571.429 coins (economics.py)
    uint256 constant MODEL_POOL = 38_571_428_571e15; // 38,571,428.571 coins

    function test_bundle_rate_is_exact_fraction() public view {
        (uint256 n, uint256 d) = factory.bundleRate(THRESHOLD, RESERVE_BPS, MAX_ALLOC_BPS);
        assertEq(n, RATE_NUM_10PCT);
        assertEq(d, RATE_DEN_10USD);
        (n, d) = factory.bundleRate(1_000_000_000, RESERVE_BPS, MAX_ALLOC_BPS);
        assertEq(n, RATE_NUM_10PCT);
        assertEq(d, 175000000000000000);
        (n, d) = factory.bundleRate(10_000_000_000, RESERVE_BPS, MAX_ALLOC_BPS);
        assertEq(d, 1750000000000000000);
        (n, d) = factory.bundleRate(THRESHOLD, RESERVE_BPS, 400); // 4% creator allocation
        assertEq(n, 7200000000000000000000000000000000);
        assertEq(d, RATE_DEN_10USD);
    }

    function test_entitlements_and_split_exact_at_6_and_18_decimals() public {
        (uint256 id,,) = _publish(creator, MIN_PRICE, MAX_ALLOC_BPS, 1); // $0.10 collects
        MomentCollect.Quote memory q = collect.quote(id, 1);
        assertEq(q.entitlement, ENT_10C, "$0.10 -> 385,714.285714... coins");
        assertEq(q.reserveIn, 75_000);
        assertEq(q.platformIn, 5_000);
        assertEq(q.creatorIn, 20_000);
        q = collect.quote(id, 10); // $1.00
        assertEq(q.entitlement, ENT_1USD, "$1 -> 3,857,142.857142... coins");
        assertEq(q.reserveIn, 750_000);
        assertEq(q.platformIn, 50_000);
        assertEq(q.creatorIn, 200_000);
        (uint256 id2,,) = _publish(creator, 10_000_000, MAX_ALLOC_BPS, 2); // $10 collects
        q = collect.quote(id2, 1);
        assertEq(q.entitlement, ENT_10USD);
        // Decimal scaling sanity: $1 of entitlement ? 1e18 is ~3.857M coins, i.e. rate ~ 3.857e18 coin wei per USDC unit.
        assertEq(ENT_1USD / 1e18, 3_857_142);
    }

    function test_terminal_clamp_and_graduation_identity_exact_at_10usd() public {
        (uint256 id, MomentCoin coin,) = _publish(creator, PRICE, MAX_ALLOC_BPS, 3);
        for (uint256 i = 0; i < 13; i++) {
            MomentCollect.Quote memory qi = _collect(id, alice, 1);
            assertEq(qi.entitlement, ENT_1USD);
            assertFalse(qi.terminal);
        }
        assertEq(collect.ledger(id).reserve, 9_750_000);
        MomentCollect.Quote memory q = _collect(id, bob, 1);
        assertTrue(q.terminal);
        assertEq(q.gross, 333_334);
        assertEq(q.reserveIn, 250_000);
        assertEq(q.platformIn, 16_666);
        assertEq(q.creatorIn, 66_668);
        assertEq(q.editions, 1);
        assertEq(q.excess, 666_666);
        assertEq(q.entitlement, TERMINAL_ENT);

        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(l.collects, 14);
        assertEq(l.totalGross, 13_333_334, "~ $13.33 collected (model 13.3)");
        assertEq(graduation.poolUsdc(id), 10_000_000, "reserve seeded exactly at the $10 threshold");
        assertEq(l.creatorClaimable, 13 * 200_000 + 66_668, "creator $2.666668 (model $2.67)");
        assertEq(l.platformClaimable, 13 * 50_000 + 16_666, "platform $0.666666 (model $0.67)");

        uint256 sumEnt = vesting.totalEntitlement(id);
        uint256 pool = graduation.poolCoins(id);
        assertEq(sumEnt, SUM_ENT_10USD);
        assertEq(pool, POOL_10USD);
        assertEq(pool + sumEnt + CREATOR_10PCT, S, "pool + sum entitlements + creator == S, exactly");
        assertEq(coin.totalSupply(), pool, "only the pool seed exists at graduation");
        _assertReconcilesWithModel(id);
    }

    function test_reconciles_with_model_at_1000_and_10000_thresholds() public {
        // Fresh factories with the higher policies; $100 / $1,000 collects reach the threshold quickly.
        _reconcile(1_000_000_000, 100_000_000, 25_000_000, 33_333_334);
        _reconcile(10_000_000_000, 1_000_000_000, 250_000_000, 333_333_334);
    }

    function _reconcile(uint256 threshold, uint256 price, uint256 expectedTerminalReserve, uint256 expectedTerminalGross) internal {
        MomentsFactory f = new MomentsFactory(gov, _policy(threshold));
        MomentVesting v = new MomentVesting(f);
        MomentCollect c = new MomentCollect(usdc, permit2, f, v);
        MockGraduation g = new MockGraduation(f, c, v);
        vm.prank(gov);
        f.setModules(address(c), address(v), address(g), makeAddr("locker-x"), makeAddr("hook-x"), makeAddr("buyback-x"));
        vm.prank(alice);
        usdc.approve(address(c), type(uint256).max);
        bytes32 terms = f.termsHash();
        vm.prank(creator);
        (uint256 id, address coin,) = f.publish(_params(price, MAX_ALLOC_BPS, 9), terms);
        uint256 n;
        while (c.ledger(id).state == MomentTypes.State.Collecting) {
            vm.prank(alice);
            MomentCollect.Quote memory q = c.collect(id, 1);
            n++;
            if (q.terminal) {
                assertEq(q.reserveIn, expectedTerminalReserve);
                assertEq(q.gross, expectedTerminalGross);
            }
        }
        assertEq(n, 14, "13 full collects + the clamped terminal one");
        uint256 sumEnt = v.totalEntitlement(id);
        uint256 pool = g.poolCoins(id);
        assertEq(pool + sumEnt + CREATOR_10PCT, S);
        assertEq(MomentCoin(coin).totalSupply(), pool);
        assertEq(g.poolUsdc(id), threshold);
        // allocation is threshold-independent (model): collectors ~ 51.43M, pool ~ 38.57M within 1e-6 relative
        assertApproxEqRel(sumEnt, MODEL_COLLECTORS, 1e12);
        assertApproxEqRel(pool, MODEL_POOL, 1e12);
        // price continuity: reserve/pool == 1/rate  <=>  reserve*rateNum == pool*rateDen (within 1e-6 relative)
        MomentTypes.Moment memory m = f.getMoment(id);
        assertApproxEqRel(threshold * m.rateNum, pool * m.rateDen, 1e12);
    }

    function test_untaken_creator_allocation_deepens_the_pool_and_still_sums_to_S() public {
        (uint256 idFull,,) = _publish(creator, PRICE, MAX_ALLOC_BPS, 4); // 10%
        (uint256 idPart,,) = _publish(creator, PRICE, 400, 5); // 4%
        (uint256 idNone,,) = _publish(creator, PRICE, 0, 6); // 0%
        MomentCollect.Quote memory q = collect.quote(idPart, 1);
        assertEq(q.entitlement, 4114285714285714285714285, "rate re-derived from the 4% allocation");
        _completeWithSingles(idFull, alice);
        _completeWithSingles(idPart, alice);
        _completeWithSingles(idNone, alice);
        uint256 poolFull = graduation.poolCoins(idFull);
        uint256 poolPart = graduation.poolCoins(idPart);
        uint256 poolNone = graduation.poolCoins(idNone);
        assertGt(poolPart, poolFull, "freed allocation deepens the pool");
        assertGt(poolNone, poolPart);
        assertEq(poolFull + vesting.totalEntitlement(idFull) + S * 1000 / BPS, S);
        assertEq(poolPart + vesting.totalEntitlement(idPart) + S * 400 / BPS, S);
        assertEq(poolNone + vesting.totalEntitlement(idNone) + 0, S);
        assertEq(vesting.creatorAllocation(idPart), 4000000000000000000000000);
        // model: pool = S*(1-alloc)*reserveFrac/(1+reserveFrac) -> 4%: 41,142,857.14; 0%: 42,857,142.86
        assertApproxEqRel(poolPart, 41_142_857_143e15, 1e12);
        assertApproxEqRel(poolNone, 42_857_142_857e15, 1e12);
        _assertReconcilesWithModel(idPart);
    }

    function test_min_price_granularity_matches_model() public {
        (uint256 id,,) = _publish(creator, MIN_PRICE, MAX_ALLOC_BPS, 7); // $0.10 collects at $10
        uint256 n = _completeWithSingles(id, alice);
        assertEq(n, 134, "133.3 model collects -> 133 full + 1 clamped");
        assertEq(vesting.totalEntitlement(id), 51428573999999999999999962);
        assertEq(graduation.poolCoins(id) + vesting.totalEntitlement(id) + CREATOR_10PCT, S);
    }

    function test_supply_invariant_holds_through_collecting_and_is_exact_at_graduation() public {
        (uint256 id, MomentCoin coin,) = _publish(creator, PRICE, MAX_ALLOC_BPS, 8);
        for (uint256 i = 0; i < 13; i++) {
            _collect(id, i % 3 == 0 ? alice : (i % 3 == 1 ? bob : carol), 1);
            (uint256 ents, uint256 alloc, uint256 remainderPool, uint256 implied, uint256 collects) = collect.supplyCheck(id);
            assertEq(ents + alloc + remainderPool, S, "exact identity at every step");
            assertLe(implied, remainderPool, "before the terminal clamp the implied pool never exceeds the remainder");
            assertEq(alloc, CREATOR_10PCT);
            assertEq(coin.totalSupply(), 0);
            assertLt(collect.ledger(id).reserve, THRESHOLD);
            collects;
        }
        _collect(id, alice, 1); // terminal -> graduates
        assertEq(graduation.poolCoins(id) + vesting.totalEntitlement(id) + CREATOR_10PCT, S, "== S only after graduation");
    }

    /// Price continuity: the pool opens at exactly the collectors' price (reserve/pool == 1/rate) up to the
    /// terminal-clamp rounding, which is <= 1e-6 relative.
    function _assertReconcilesWithModel(uint256 id) internal view {
        MomentTypes.Moment memory m = factory.getMoment(id);
        uint256 pool = graduation.poolCoins(id);
        assertApproxEqRel(graduation.poolUsdc(id) * m.rateNum, pool * m.rateDen, 1e12, "collector price == opening price");
    }
}
