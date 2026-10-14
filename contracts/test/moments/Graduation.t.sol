// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsMarketBase} from "./MomentsMarketBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";
import {MomentPoolMath} from "../../src/moments/libraries/MomentPoolMath.sol";

/// Phase 2 gate: graduation accounting against the real PoolManager, in both currency orderings.
contract GraduationTest is MomentsMarketBase {
    using PoolIdLibrary for PoolKey;

    uint256 constant EXPECTED_POOL = 38571426000000000000000012; // EXPECTED.md: 14 collects at $1, 10% alloc
    uint256 constant EXPECTED_ENTS = 51428573999999999999999988;

    function _run(bool usdcIs0) internal returns (uint256 id, MomentCoin coin, MomentNFT nft, MomentGraduation.Record memory r) {
        (id, coin, nft) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, usdcIs0);
        assertEq(_completeWithSingles(id, alice), 14);
        r = executor.record(id);
    }

    function _checkGraduated(bool usdcIs0) internal {
        (uint256 id, MomentCoin coin, MomentNFT nft, MomentGraduation.Record memory r) = _run(usdcIs0);
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Graduated), "graduated inside the terminal collect");
        assertEq(l.stuckSince, 0);
        assertEq(l.reserve, 0);
        assertEq(r.reserve, THRESHOLD, "exactly the threshold seeded");
        assertEq(r.poolCoins, EXPECTED_POOL, "pool = S - creator - sum entitlements");
        assertEq(vesting.totalEntitlement(id), EXPECTED_ENTS);
        assertEq(r.poolCoins + vesting.totalEntitlement(id) + S * MAX_ALLOC_BPS / BPS, S, "conservation identity at graduation");
        assertEq(coin.totalSupply(), r.poolCoins, "only the pool seed exists at graduation");
        assertEq(usdc.balanceOf(address(collect)), l.creatorClaimable + l.platformClaimable, "collect keeps only the pull-able shares");
        // pool + position
        assertEq((address(usdc) < address(coin)), usdcIs0);
        assertEq(uint256(_sqrtPrice(r.key)), uint256(r.sqrtPriceX96));
        (uint256 a0, uint256 a1) = usdcIs0 ? (r.reserve, r.poolCoins) : (r.poolCoins, r.reserve);
        assertEq(r.sqrtPriceX96, MomentPoolMath.sqrtPriceX96(a0, a1), "opened at reserve/pool");
        assertGt(r.liquidity, 0);
        assertEq(_lockerPositionLiquidity(id, r.key), r.liquidity, "the locker owns the position");
        assertEq(_poolLiquidity(r.key), r.liquidity, "it is the only liquidity");
        assertEq(locker.liquidityOf(id), r.liquidity);
        // every asset went into the pool except integer dust, which is locked in the locker
        assertEq(usdc.balanceOf(address(manager)), r.usedUsdc);
        assertEq(coin.balanceOf(address(manager)), r.usedCoin);
        assertLe(r.reserve - r.usedUsdc, 2, "USDC dust");
        assertLe(r.poolCoins - r.usedCoin, 1e12, "coin dust (wei)");
        assertEq(usdc.balanceOf(address(locker)), r.reserve - r.usedUsdc);
        assertEq(coin.balanceOf(address(locker)), r.poolCoins - r.usedCoin);
        assertEq(usdc.balanceOf(address(executor)) + coin.balanceOf(address(executor)), 0, "executor holds nothing");
        // flips
        assertEq(vesting.graduatedAt(id), uint64(block.timestamp));
        assertTrue(nft.closed());
        assertEq(hook.momentOf(r.key.toId()), id, "pool registered with the hook");
        assertTrue(executor.isGraduated(id));
        assertEq(r.at, uint64(block.timestamp));
    }

    function test_graduation_usdc_is_currency0() public {
        _checkGraduated(true);
    }

    function test_graduation_coin_is_currency0() public {
        _checkGraduated(false);
    }

    /// Price continuity, in both orderings: (1) the pool opens EXACTLY at poolCoins/reserve; (2) that equals the
    /// collectors' bundle rate up to the terminal clamp's known shift (the last accepted gross is rounded up by
    /// < 1 USDC unit, so the pool is ~2.6 coins short of the ideal 38,571,428.57 => 6.7e-8 relative, in the
    /// collectors' favour). No other source of discontinuity exists.
    function test_opening_price_equals_the_bundle_rate() public {
        for (uint256 k = 0; k < 2; k++) {
            bool usdcIs0 = k == 0;
            (uint256 id,,, MomentGraduation.Record memory r) = _run(usdcIs0);
            MomentTypes.Moment memory m = factory.getMoment(id);
            uint256 sp = r.sqrtPriceX96;
            // coin per USDC unit, scaled by 2^96
            uint256 poolRateX96 = usdcIs0 ? FullMath.mulDiv(sp, sp, 1 << 96) : FullMath.mulDiv(1 << 192, 1 << 96, sp * sp); // 2^288 / sp^2, full precision
            uint256 seededRateX96 = FullMath.mulDiv(r.poolCoins, 1 << 96, r.reserve);
            uint256 bundleRateX96 = FullMath.mulDiv(m.rateNum, 1 << 96, m.rateDen);
            uint256 d1 = poolRateX96 > seededRateX96 ? poolRateX96 - seededRateX96 : seededRateX96 - poolRateX96;
            assertLt(d1 * 1e12, seededRateX96, "pool opened at poolCoins/reserve (sqrt rounding only)");
            uint256 d2 = bundleRateX96 > poolRateX96 ? bundleRateX96 - poolRateX96 : poolRateX96 - bundleRateX96;
            assertLt(d2 * 1e7, bundleRateX96, "within 1e-7 of the collectors' rate");
            assertGt(bundleRateX96, poolRateX96, "residual is in the collectors' favour (pool a hair deeper per coin)");
            // and the residual IS the clamp shift: (idealPool - poolCoins) / idealPool
            uint256 idealPool = FullMath.mulDiv(r.reserve, m.rateNum, m.rateDen);
            uint256 shiftX18 = FullMath.mulDiv(idealPool - r.poolCoins, 1e18, idealPool);
            uint256 residualX18 = FullMath.mulDiv(d2, 1e18, bundleRateX96);
            uint256 d3 = shiftX18 > residualX18 ? shiftX18 - residualX18 : residualX18 - shiftX18;
            assertLt(d3, 1e9, "residual == terminal clamp shift");
        }
    }

    /// A tiny buy right after open executes at the bundle rate (minus the 1% hook fee and the 0.5% LP fee):
    /// +0.00% price jump at open.
    function test_first_market_buy_gets_the_collectors_rate_minus_fees() public {
        (uint256 id, MomentCoin coin,, MomentGraduation.Record memory r) = _run(true);
        MomentTypes.Moment memory m = factory.getMoment(id);
        uint256 usdcIn = 1_000; // $0.001 -- negligible impact on a $10 pool
        uint256 before = coin.balanceOf(bob);
        _buyExactIn(bob, r.key, true, usdcIn);
        uint256 got = coin.balanceOf(bob) - before;
        uint256 net = usdcIn * (BPS - hook.FEE_BPS()) / BPS; // 990 after the hook
        net = net * (1_000_000 - executor.LP_FEE()) / 1_000_000; // 985 after the LP fee
        uint256 expected = FullMath.mulDiv(net, m.rateNum, m.rateDen);
        uint256 diff = got > expected ? got - expected : expected - got;
        assertLt(diff * 2_000, expected, "within 0.05% of the collectors' rate after both fees (integer + impact)");
    }

    function test_untaken_creator_allocation_deepens_the_pool() public {
        (uint256 id4,,) = _publishOrdered(creator, PRICE, 400, true);
        (uint256 id0,,) = _publishOrdered(creator, PRICE, 0, true);
        _completeWithSingles(id4, alice);
        _completeWithSingles(id0, alice);
        MomentGraduation.Record memory r4 = executor.record(id4);
        MomentGraduation.Record memory r0 = executor.record(id0);
        assertEq(r4.poolCoins + vesting.totalEntitlement(id4) + S * 400 / BPS, S);
        assertEq(r0.poolCoins + vesting.totalEntitlement(id0), S, "0% alloc: everything is collectors + pool");
        assertGt(r0.poolCoins, r4.poolCoins);
        assertGt(r4.poolCoins, EXPECTED_POOL);
        assertGt(r0.liquidity, r4.liquidity, "freed allocation shows up as pool depth");
    }

    function test_terminal_collect_including_graduation_fits_the_gas_budget() public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        vm.prank(bob);
        uint256 g = gasleft();
        collect.collect(id, 1);
        uint256 used = g - gasleft();
        emit log_named_uint("terminal collect + graduation gas", used);
        assertLt(used, collect.GRADUATION_GAS(), "whole terminal collect (a superset of the subcall) under the 3M subcall cap");
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));
    }

    function test_failed_graduation_is_stuck_then_retried_permissionlessly() public {
        (uint256 id, MomentCoin coin, MomentNFT nft) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, false);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        // Make the PoolManager refuse initialization for the terminal collect only.
        vm.mockCallRevert(address(manager), abi.encodeWithSelector(IPoolManager.initialize.selector), "pm down");
        _collect(id, bob, 1);
        vm.clearMockedCalls();
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.GraduationPending));
        assertGt(l.stuckSince, 0);
        assertEq(l.reserve, THRESHOLD, "reserve intact");
        assertEq(coin.totalSupply(), 0, "the failed attempt minted nothing");
        assertFalse(nft.closed());
        assertFalse(executor.isGraduated(id));
        assertEq(usdc.balanceOf(address(locker)), 0);

        vm.prank(carol);
        executor.graduate(id);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));
        MomentGraduation.Record memory r = executor.record(id);
        assertEq(r.reserve, THRESHOLD);
        assertEq(coin.totalSupply(), r.poolCoins);
        assertTrue(nft.closed());
        vm.prank(carol);
        vm.expectRevert(MomentGraduation.AlreadyGraduated.selector);
        executor.graduate(id);
    }

    function test_graduate_rejects_non_pending_moments() public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _collect(id, alice, 1);
        vm.expectRevert(MomentGraduation.NotPending.selector);
        executor.graduate(id);
        vm.expectRevert(); // unknown moment
        executor.graduate(999);
    }

    function test_claims_after_graduation_keep_the_supply_identity() public {
        (uint256 id, MomentCoin coin,, MomentGraduation.Record memory r) = _run(true);
        vm.prank(alice);
        vesting.claim(id);
        vm.prank(creator);
        vesting.claim(id);
        vm.warp(block.timestamp + 2 * MomentTypes.MONTH);
        vm.prank(alice);
        vesting.claim(id);
        assertEq(coin.balanceOf(alice), vesting.totalEntitlement(id), "collector fully vested at month 2");
        assertEq(coin.totalSupply(), r.poolCoins + vesting.totalMinted(id));
        assertLe(coin.totalSupply(), S);
        vm.warp(block.timestamp + 3 * MomentTypes.MONTH);
        vm.prank(creator);
        vesting.claim(id);
        assertEq(coin.totalSupply(), S, "everything minted once fully vested: pool + collectors + creator == S");
    }

    function test_preview_pool_key_matches_the_graduated_key() public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, false);
        PoolKey memory preview = executor.previewPoolKey(id);
        _completeWithSingles(id, alice);
        PoolKey memory actual = executor.poolKeyOf(id);
        assertEq(PoolId.unwrap(preview.toId()), PoolId.unwrap(actual.toId()));
    }
}
