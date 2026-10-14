// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MomentsMarketBase} from "./MomentsMarketBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentPoolMath} from "../../src/moments/libraries/MomentPoolMath.sol";

/// Phase 4: property fuzzing of the arithmetic the money paths depend on.
contract FuzzTest is MomentsMarketBase {
    /// The terminal clamp lands the reserve EXACTLY on the threshold for any remaining amount and any reserve share.
    function testFuzz_terminal_clamp_is_exact(uint256 remaining, uint16 reserveBps) public pure {
        remaining = bound(remaining, 1, 1e15);
        reserveBps = uint16(bound(reserveBps, 1, 9_999));
        uint256 gross = Math.ceilDiv(remaining * MomentTypes.BPS, reserveBps);
        assertEq(gross * reserveBps / MomentTypes.BPS, remaining, "floor(ceil(R*B/a)*a/B) == R");
        assertGe(gross, remaining);
    }

    /// The three-way split always sums to the gross (the creator absorbs the rounding) and never underflows.
    function testFuzz_split_sums_to_gross(uint256 gross, uint16 platformBps, uint16 reserveBps) public pure {
        gross = bound(gross, 1, 1e18);
        platformBps = uint16(bound(platformBps, 0, 5_000));
        reserveBps = uint16(bound(reserveBps, 1, 9_999 - platformBps));
        uint256 reserveIn = gross * reserveBps / MomentTypes.BPS;
        uint256 platformIn = gross * platformBps / MomentTypes.BPS;
        uint256 creatorIn = gross - reserveIn - platformIn;
        assertEq(reserveIn + platformIn + creatorIn, gross);
        assertLe(reserveIn + platformIn, gross);
    }

    /// The bundle-rate identity: for any threshold/reserve share/allocation, collecting exactly threshold/reserveFrac
    /// of USDC at the rate leaves pool = S*(1-alloc)*r/(1+r) up to per-collect rounding, so pool + ents + alloc == S.
    function testFuzz_bundle_rate_conserves_supply(uint256 threshold, uint16 reserveBps, uint16 allocBps, uint256 price) public view {
        threshold = bound(threshold, 1_000_000, 1e13); // $1 .. $10M
        reserveBps = uint16(bound(reserveBps, 1_000, 9_500));
        allocBps = uint16(bound(allocBps, 0, MomentTypes.MAX_CREATOR_ALLOC_BPS));
        price = bound(price, 100_000, threshold); // collects that stay at or below one threshold each
        (uint256 rateNum, uint256 rateDen) = factory.bundleRate(threshold, reserveBps, allocBps);
        // simulate the collect loop's accounting exactly (same integer math as MomentCollect)
        uint256 reserve;
        uint256 ents;
        uint256 collects;
        while (reserve < threshold && collects < 200) {
            uint256 remaining = threshold - reserve;
            uint256 gross = price;
            uint256 reserveIn = gross * reserveBps / MomentTypes.BPS;
            if (reserveIn >= remaining) {
                gross = Math.ceilDiv(remaining * MomentTypes.BPS, reserveBps);
                reserveIn = gross * reserveBps / MomentTypes.BPS;
            }
            reserve += reserveIn;
            ents += Math.mulDiv(gross, rateNum, rateDen);
            collects++;
        }
        vm.assume(reserve == threshold); // loops that need > 200 collects are simply not exercised here
        uint256 alloc = MomentTypes.SUPPLY * allocBps / MomentTypes.BPS;
        uint256 pool = MomentTypes.SUPPLY - alloc - ents; // must not underflow
        assertGt(pool, 0);
        assertEq(pool + ents + alloc, MomentTypes.SUPPLY);
        // the rate-implied pool for the exact threshold is within per-collect rounding of the remainder: each
        // collect can lose < 1 USDC unit of reserve to flooring, which the clamp recovers with up to BPS/reserveBps
        // units of extra gross (=> extra entitlement), plus < 1 wei of entitlement flooring per collect
        uint256 implied = Math.mulDiv(threshold, rateNum, rateDen);
        uint256 slack = collects * (Math.ceilDiv(rateNum * MomentTypes.BPS, rateDen * reserveBps) + 1);
        assertLe(implied, pool + slack);
        assertLe(pool, implied + slack);
    }

    /// sqrtPriceX96 stays inside v4's bounds and reproduces amount1/amount0 to 1e-9 for realistic seeds.
    function testFuzz_sqrt_price_accuracy(uint256 usdcAmount, uint256 coinAmount, bool usdcIs0) public pure {
        usdcAmount = bound(usdcAmount, 1_000_000, 1e13); // $1 .. $10M
        coinAmount = bound(coinAmount, 1e24, MomentTypes.SUPPLY); // 1M .. 100M coins
        (uint256 a0, uint256 a1) = usdcIs0 ? (usdcAmount, coinAmount) : (coinAmount, usdcAmount);
        uint160 sp = MomentPoolMath.sqrtPriceX96(a0, a1);
        assertGt(sp, TickMath.MIN_SQRT_PRICE);
        assertLt(sp, TickMath.MAX_SQRT_PRICE);
        // (sp/2^96)^2 == a1/a0  <=>  sp^2 * a0 == a1 * 2^192 (compare at 1e-9 relative precision)
        uint256 lhs = FullMath.mulDiv(FullMath.mulDiv(sp, sp, 1 << 96), a0, 1 << 96); // ~ a1
        uint256 diff = lhs > a1 ? lhs - a1 : a1 - lhs;
        assertLe(diff * 1e9, a1 + 1e9, "price accurate to 1e-9");
    }

    /// Hook fee, exact-input buy: fee is exactly 1% of the input for any amount; the pool gets the other 99%.
    function testFuzz_hook_fee_exact_in_buy(uint256 usdcIn, bool usdcIs0) public {
        usdcIn = bound(usdcIn, 100, 5_000_000);
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, usdcIs0);
        _completeWithSingles(id, alice);
        PoolKey memory key = executor.poolKeyOf(id);
        uint256 pm0 = usdc.balanceOf(address(manager));
        uint256 h0 = usdc.balanceOf(address(hook));
        _buyExactIn(bob, key, usdcIs0, usdcIn);
        assertEq(usdc.balanceOf(address(hook)) - h0, usdcIn * 100 / 10_000);
        assertEq(usdc.balanceOf(address(manager)) - pm0, usdcIn - usdcIn * 100 / 10_000);
    }

    /// Hook fee, exact-input sell: fee is exactly 1% of the gross USDC out for any coin amount.
    function testFuzz_hook_fee_exact_in_sell(uint256 coinIn, bool usdcIs0) public {
        (uint256 id, MomentCoin coin,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, usdcIs0);
        _completeWithSingles(id, alice);
        PoolKey memory key = executor.poolKeyOf(id);
        vm.prank(alice);
        vesting.claim(id);
        coinIn = bound(coinIn, 1e15, coin.balanceOf(alice));
        _approveCoin(coin, alice);
        uint256 pm0 = usdc.balanceOf(address(manager));
        uint256 h0 = usdc.balanceOf(address(hook));
        uint256 a0 = usdc.balanceOf(alice);
        _sellExactIn(alice, key, usdcIs0, coinIn);
        uint256 grossOut = pm0 - usdc.balanceOf(address(manager));
        uint256 fee = usdc.balanceOf(address(hook)) - h0;
        assertEq(fee, grossOut * 100 / 10_000);
        assertEq(usdc.balanceOf(alice) - a0, grossOut - fee);
    }

    /// Vesting is monotone in time and bounded by the entitlement, for any two instants after graduation.
    function testFuzz_vesting_monotone(uint256 t1, uint256 t2) public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _completeWithSingles(id, alice);
        uint64 g = vesting.graduatedAt(id);
        t1 = bound(t1, 0, 400 days);
        t2 = bound(t2, t1, 400 days);
        uint256 ent = vesting.entitlement(id, alice);
        vm.warp(g + t1);
        (uint256 c1,) = vesting.claimable(id, alice);
        (, uint256 cr1) = vesting.claimable(id, creator);
        vm.warp(g + t2);
        (uint256 c2,) = vesting.claimable(id, alice);
        (, uint256 cr2) = vesting.claimable(id, creator);
        assertGe(c2, c1);
        assertGe(cr2, cr1);
        assertLe(c2, ent);
        assertLe(cr2, 1e25);
        assertGe(c1, FullMath.mulDiv(ent, 6_000, BPS), "never below 60% after graduation");
        assertGe(cr1, 2_000_000e18, "creator never below 20% after graduation");
    }
}
