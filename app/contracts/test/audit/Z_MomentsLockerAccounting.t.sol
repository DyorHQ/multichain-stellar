// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsMarketBase} from "../moments/MomentsMarketBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";

/// MO-2 regression (v2 source):
///  (a) per-Moment accounting — the shared locker never spends one Moment's idle USDC on another Moment's position;
///  (b) the buyback refuses to add liquidity at a price moved by more than 2% within the current block.
contract Z_MomentsLockerAccountingTest is MomentsMarketBase {
    uint256 internal a;
    uint256 internal b;
    MomentCoin internal coinA;
    MomentCoin internal coinB;
    PoolKey internal keyA;
    Currency internal USDC_C;

    function setUp() public override {
        super.setUp();
        USDC_C = Currency.wrap(address(usdc));
        (a, coinA,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _completeWithSingles(a, alice);
        (b, coinB,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, false);
        _completeWithSingles(b, alice);
        keyA = executor.poolKeyOf(a);
        _approveCoin(coinA, bob);
    }

    function _feesOnA(uint256 rounds) internal {
        for (uint256 i = 0; i < rounds; i++) {
            uint256 c0 = coinA.balanceOf(bob);
            _buyExactIn(bob, keyA, true, 10_000_000);
            _sellExactIn(bob, keyA, true, coinA.balanceOf(bob) - c0);
        }
        vm.roll(vm.getBlockNumber() + 1); // the round runs in a later block than the burst of volume
    }

    /// The burst of volume itself trips the guard when the round runs in the same block.
    function test_sameBlockVolumeBurst_blocksTheRound() public {
        uint256 c0 = coinA.balanceOf(bob);
        for (uint256 i = 0; i < 12; i++) {
            _buyExactIn(bob, keyA, true, 10_000_000);
            _sellExactIn(bob, keyA, true, coinA.balanceOf(bob) - c0);
        }
        vm.expectRevert(MomentBuyback.PriceMoved.selector);
        buyback.execute(a, 0);
    }

    function test_seedDust_isBookedPerMoment() public view {
        uint256 total = locker.heldOf(a, USDC_C) + locker.heldOf(b, USDC_C);
        assertEq(total, locker.tracked(USDC_C), "tracked = sum of per-Moment balances");
        assertEq(usdc.balanceOf(address(locker)), total, "nothing untracked after the seeds");
    }

    function test_buybackOnA_neverSpendsBsIdleUsdc() public {
        // B ends up owning idle USDC in the locker (e.g. a top-up its coin side could not pair).
        deal(address(usdc), address(locker), usdc.balanceOf(address(locker)) + 50_000_000);
        vm.prank(address(buyback));
        locker.increase(b); // the untracked 50 USDC is credited to B; B's coin dust can pair almost none of it
        uint256 bIdle = locker.heldOf(b, USDC_C);
        assertGt(bIdle, 49_000_000, "B owns the idle USDC");

        _feesOnA(12);
        MomentBuyback.Round memory r = buyback.execute(a, 0);
        assertGt(r.liquidityAdded, 0, "A's buyback still deepens A's position");
        assertEq(locker.heldOf(b, USDC_C), bIdle, "B's USDC untouched by A's round");
        assertEq(locker.available(a, USDC_C) + locker.heldOf(b, USDC_C), usdc.balanceOf(address(locker)), "books balance");
    }

    function test_priceMovedInBlock_blocksTheRound_untilNextBlock() public {
        _feesOnA(12);
        vm.roll(vm.getBlockNumber() + 1);
        _buyExactIn(bob, keyA, true, 3_000_000); // moves the price by well over 2% within this block
        vm.expectRevert(MomentBuyback.PriceMoved.selector);
        buyback.execute(a, 0);
        vm.roll(vm.getBlockNumber() + 1); // a new block opens at the moved price: no in-block move any more
        MomentBuyback.Round memory r = buyback.execute(a, 0);
        assertGt(r.liquidityAdded, 0);
    }

    function test_smallInBlockMove_isTolerated() public {
        _feesOnA(12);
        vm.roll(vm.getBlockNumber() + 1);
        _buyExactIn(bob, keyA, true, 20_000); // a $0.02 trade: well under 2%
        buyback.execute(a, 0);
    }

    function test_blockOpenPrice_view() public {
        vm.roll(vm.getBlockNumber() + 1);
        uint160 open = hook.blockOpenSqrtPrice(a);
        assertEq(open, _sqrtPrice(keyA), "no swap yet in this block: open = live");
        _buyExactIn(bob, keyA, true, 3_000_000);
        assertEq(hook.blockOpenSqrtPrice(a), open, "still the price the block opened at");
        assertTrue(_sqrtPrice(keyA) != open);
    }
}
