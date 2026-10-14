// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsMarketBase} from "./MomentsMarketBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";

/// Phase 2 gate: buyback-and-LP increases the locked position, cannot be pointed anywhere else, is bounded in
/// price impact and frequency, and a sandwich around it loses money.
contract BuybackTest is MomentsMarketBase {
    uint256 id;
    MomentCoin coin;
    PoolKey key;
    bool usdcIs0;

    function setUp() public override {
        super.setUp();
        _init(true);
    }

    function _init(bool _usdcIs0) internal {
        usdcIs0 = _usdcIs0;
        (id, coin,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, usdcIs0);
        _completeWithSingles(id, alice);
        key = executor.poolKeyOf(id);
        _approveCoin(coin, bob);
        _approveCoin(coin, carol);
    }

    /// Round-trips $10 buys and full sells so the price mean-reverts while fees accrue.
    function _generateFees(uint256 rounds) internal {
        for (uint256 i = 0; i < rounds; i++) {
            uint256 c0 = coin.balanceOf(bob);
            _buyExactIn(bob, key, usdcIs0, 10_000_000);
            _sellExactIn(bob, key, usdcIs0, coin.balanceOf(bob) - c0);
        }
        // v2 (MO-2): a round runs in a later block than this burst of volume, like a keeper's would; within the
        // same block the burst's net drift (>2% on this tiny test pool) would trip the in-block price guard.
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// Coin price in USDC terms, scaled 1e18, from the pool's sqrt price (direction-aware).
    function _coinPriceX18() internal view returns (uint256) {
        uint256 sp = _sqrtPrice(key);
        uint256 ratioX96 = FullMath.mulDiv(sp, sp, 1 << 96); // currency1 per currency0, X96
        // USDC per coin: if usdc is 0, price = 1/ratio; else price = ratio
        return usdcIs0 ? FullMath.mulDiv(1e18, 1 << 96, ratioX96) : FullMath.mulDiv(ratioX96, 1e18, 1 << 96);
    }

    function test_execute_buys_coin_and_deepens_the_locked_position() public {
        _generateFees(12);
        uint256 accrued = hook.buybackAccrued(id);
        assertGe(accrued, buyback.MIN_AMOUNT(), "enough accrued for a round");
        uint128 liq0 = _lockerPositionLiquidity(id, key);
        uint256 pmCoin0 = coin.balanceOf(address(manager));
        uint256 lockerCoin0 = coin.balanceOf(address(locker));
        uint256 price0 = _coinPriceX18();
        uint256 callerUsdc = usdc.balanceOf(carol);

        vm.prank(carol);
        MomentBuyback.Round memory r = buyback.execute(id, 0);

        assertEq(r.budget, accrued);
        assertEq(hook.buybackAccrued(id), 0, "hook share pulled");
        assertGt(r.usdcSpent, 0);
        assertLe(r.usdcSpent, accrued / 2, "spends at most half the budget on coin");
        assertGt(r.coinBought, 0);
        assertGt(r.liquidityAdded, 0);
        assertEq(_lockerPositionLiquidity(id, key), liq0 + r.liquidityAdded, "locked position grew");
        assertEq(locker.liquidityOf(id), liq0 + r.liquidityAdded);
        assertEq(r.usdcSpent + r.usdcToPool + r.carried, accrued, "every unit of the budget accounted for");
        assertEq(buyback.carry(id), r.carried);
        assertEq(usdc.balanceOf(address(buyback)), r.carried, "buyback holds only the carry");
        assertEq(coin.balanceOf(address(buyback)), 0, "never holds coin");
        // v2 (sec2, MO-2): one round grows the position by at most MAX_INCREASE_BPS. The bought coin is either back in
        // the pool as liquidity or held for this Moment in the locker (to be added by later rounds): it only ever moves
        // between the PoolManager and the locker.
        assertLe(r.liquidityAdded, uint256(liq0) * locker.MAX_INCREASE_BPS() / BPS, "the add is capped");
        assertEq(coin.balanceOf(address(manager)) + coin.balanceOf(address(locker)), pmCoin0 + lockerCoin0, "bought coin stays in the pool or the locker");
        assertEq(coin.balanceOf(address(locker)), locker.heldOf(id, usdcIs0 ? key.currency1 : key.currency0), "and whatever the locker holds is this Moment's");
        assertEq(usdc.balanceOf(carol), callerUsdc, "caller gets nothing");
        // bounded impact: coin price moved up, but by at most ~1%
        uint256 price1 = _coinPriceX18();
        assertGe(price1, price0);
        assertLe(price1 * 10_000, price0 * 10_101, "price impact capped at 1%");
    }

    function test_execute_works_with_coin_as_currency0() public {
        _init(false);
        _generateFees(12);
        uint128 liq0 = _lockerPositionLiquidity(id, key);
        uint256 price0 = _coinPriceX18();
        MomentBuyback.Round memory r = buyback.execute(id, 0);
        assertGt(r.liquidityAdded, 0);
        assertEq(_lockerPositionLiquidity(id, key), liq0 + r.liquidityAdded);
        uint256 price1 = _coinPriceX18();
        assertGe(price1, price0);
        assertLe(price1 * 10_000, price0 * 10_101);
    }

    function test_interval_minimum_and_slippage_guards() public {
        vm.expectRevert(); // not graduated
        buyback.execute(999, 0);
        _generateFees(2); // ~0.2 USDC accrued
        vm.expectRevert(MomentBuyback.BelowMinimum.selector);
        buyback.execute(id, 0);
        assertGt(hook.buybackAccrued(id), 0, "a rejected round leaves the accrual in the hook");
        _generateFees(10);
        vm.expectRevert(MomentBuyback.Slippage.selector);
        buyback.execute(id, type(uint256).max);
        buyback.execute(id, 0);
        _generateFees(12);
        vm.expectRevert(MomentBuyback.TooSoon.selector);
        buyback.execute(id, 0);
        vm.warp(block.timestamp + buyback.MIN_INTERVAL());
        buyback.execute(id, 0);
    }

    function test_carry_is_used_in_the_next_round() public {
        _generateFees(12);
        MomentBuyback.Round memory r1 = buyback.execute(id, 0);
        vm.warp(block.timestamp + 1 hours);
        _generateFees(12);
        uint256 accrued2 = hook.buybackAccrued(id);
        MomentBuyback.Round memory r2 = buyback.execute(id, 0);
        assertEq(r2.budget, accrued2 + r1.carried, "carry folded into the next budget");
    }

    function test_buyback_swap_is_fee_exempt() public {
        _generateFees(12);
        uint256 cr = hook.creatorAccrued(id);
        uint256 pl = hook.platformAccrued(id);
        buyback.execute(id, 0);
        assertEq(hook.creatorAccrued(id), cr, "no fee charged on the buyback's own swap");
        assertEq(hook.platformAccrued(id), pl);
        assertEq(hook.buybackAccrued(id), 0);
    }

    function test_sandwiching_the_buyback_loses_money() public {
        _generateFees(12);
        vm.roll(vm.getBlockNumber() + 1); // a fresh block: its opening price is the undisturbed one
        uint256 attackerUsdc0 = usdc.balanceOf(carol);
        // front-run: attacker buys ahead of the buyback
        _buyExactIn(carol, key, usdcIs0, 2_000_000);
        uint256 got = coin.balanceOf(carol);
        // v2 (MO-2): the buyback refuses to run on a price moved >2% within this block
        vm.prank(carol);
        vm.expectRevert(MomentBuyback.PriceMoved.selector);
        buyback.execute(id, 0);
        // back-run: attacker sells everything
        _sellExactIn(carol, key, usdcIs0, got);
        assertLt(usdc.balanceOf(carol), attackerUsdc0, "attacker ends with less USDC than they started with");
        assertEq(coin.balanceOf(carol), 0);
    }

    function test_small_sandwich_within_the_block_tolerance_still_loses_money() public {
        _generateFees(12);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 attackerUsdc0 = usdc.balanceOf(carol);
        _buyExactIn(carol, key, usdcIs0, 20_000); // $0.02: under the 2% in-block tolerance
        uint256 got = coin.balanceOf(carol);
        vm.prank(carol);
        buyback.execute(id, 0); // lands
        _sellExactIn(carol, key, usdcIs0, got);
        assertLt(usdc.balanceOf(carol), attackerUsdc0, "attacker ends with less USDC than they started with");
    }

    function test_cannot_be_pointed_elsewhere() public {
        _generateFees(12);
        uint256 govUsdc = usdc.balanceOf(gov);
        vm.prank(gov);
        buyback.execute(id, 0);
        assertEq(usdc.balanceOf(gov), govUsdc);
        assertEq(coin.balanceOf(gov), 0);
        vm.expectRevert(MomentBuyback.NotPoolManager.selector);
        buyback.unlockCallback(abi.encode(key, usdcIs0, uint256(1), gov));
        // no ERC-20 of either kind ever sits anywhere but PoolManager / locker / carry
        uint256 dust = usdc.balanceOf(address(buyback));
        assertEq(dust, buyback.carry(id));
    }
}
