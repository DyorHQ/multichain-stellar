// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "./LaunchpadBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchLocker} from "../src/LaunchLocker.sol";
import {Types} from "../src/interfaces/ILaunchpad.sol";

contract PoolTest is LaunchpadBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    PoolSwapTest.TestSettings internal settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function _graduated(address pair, bool sharingOn) internal returns (LaunchToken token, BondingCurve curve, PoolKey memory key) {
        (token, curve) = _launch(alice, pair, 0, sharingOn, 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        if (pair == address(0)) _completeNative(curve, bob);
        else _completeUsd(curve, bob);
        key = factory.poolKeyOf(address(token));
    }

    function _swap(address who, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 value) internal {
        vm.prank(who);
        swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT}),
            settings,
            ""
        );
    }

    function test_graduation_opens_pool_at_curve_price_and_locks_it() public {
        (LaunchToken token, BondingCurve curve, PoolKey memory key) = _graduated(address(0), false);
        Types.LaunchedToken memory launch = factory.getLaunchedToken(address(token));
        PoolId id = key.toId();
        assertEq(uint8(launch.phase), uint8(Types.Phase.PoolCreated));
        assertEq(launch.poolId, PoolId.unwrap(id));
        assertEq(launch.sweptQuote, THRESHOLD);
        assertTrue(curve.swept());
        assertEq(curve.realQuoteReserve(), 0);
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(address(curve).balance, 0);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        assertGt(sqrtPriceX96, 0, "pool initialized");
        uint128 liquidity = manager.getLiquidity(id);
        assertGt(liquidity, 0, "pool has liquidity");
        (bytes32 lockedPool,,, uint128 lockedLiquidity) = locker.locked(address(token));
        assertEq(lockedPool, PoolId.unwrap(id));
        assertEq(lockedLiquidity, liquidity, "all liquidity belongs to the locker");
        assertGt(locker.excessSupply(address(token)), 0, "leftover supply locked");
        assertEq(token.balanceOf(address(executor)), 0);
        assertEq(address(executor).balance, 0);
        assertTrue(hook.launches(PoolId.unwrap(id)).registered);

        // Pool price (token per MON) matches the curve's final marginal price within 0.001%.
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96); // token (currency1) per MON (currency0)
        uint256 poolTokensPerQuote = FullMath.mulDiv(priceX96, 1e18, 1 << 96);
        uint256 curveTokensPerQuote = FullMath.mulDiv(launch.sweptTokens, 1e18, PHANTOM + THRESHOLD);
        assertApproxEqRel(poolTokensPerQuote, curveTokensPerQuote, 1e13);
    }

    function test_hook_charges_exact_input_buy_in_quote() public {
        (LaunchToken token,, PoolKey memory key) = _graduated(address(0), false);
        PoolId id = key.toId();
        uint256 before = token.balanceOf(carol);
        _swap(carol, key, true, -100 ether, 100 ether); // MON (currency0) -> token
        assertGt(token.balanceOf(carol), before);
        assertEq(hook.pendingFees(id, NATIVE), 1 ether, "1% of the MON spent");
        assertEq(hook.pendingCreatorTax(id, NATIVE), 0);
        assertEq(address(hook).balance, 1 ether);

        hook.sweepPoolFees(PoolId.unwrap(id), NATIVE);
        assertEq(hook.pendingFees(id, NATIVE), 0);
        assertEq(_protocolNative(), LAUNCH_FEE + 0.5 ether + _curveProtocolShare());
        assertEq(_creatorNative(), 0.5 ether + _curveCreatorShare());
    }

    function test_hook_charges_exact_input_sell_on_quote_received() public {
        (LaunchToken token,, PoolKey memory key) = _graduated(address(0), false);
        PoolId id = key.toId();
        _swap(carol, key, true, -100 ether, 100 ether);
        hook.sweepPoolFees(PoolId.unwrap(id), NATIVE);
        uint256 tokens = token.balanceOf(carol);
        vm.prank(carol);
        token.approve(address(swapRouter), tokens);
        uint256 monBefore = carol.balance;
        _swap(carol, key, false, -int256(tokens), 0); // token (currency1) -> MON
        uint256 received = carol.balance - monBefore;
        uint256 fee = hook.pendingFees(id, NATIVE);
        assertGt(fee, 0);
        // fee is 1% of the gross quote output, i.e. received = gross - fee
        assertApproxEqAbs(fee * 99, received, 100, "1% came off the quote received");
        assertEq(token.balanceOf(carol), 0);
    }

    function test_hook_charges_exact_output_buy_on_top_of_quote_paid() public {
        (LaunchToken token,, PoolKey memory key) = _graduated(address(usd), false);
        PoolId id = key.toId();
        bool usdIs0 = Currency.unwrap(key.currency0) == address(usd);
        uint256 want = 1_000_000e18;
        vm.prank(carol);
        usd.approve(address(swapRouter), type(uint256).max);
        uint256 usdBefore = usd.balanceOf(carol);
        _swap(carol, key, usdIs0, int256(want), 0); // exact tokens out, usd in
        uint256 paid = usdBefore - usd.balanceOf(carol);
        assertEq(token.balanceOf(carol), want);
        uint256 fee = hook.pendingFees(id, Currency.wrap(address(usd)));
        assertGt(fee, 0);
        assertApproxEqAbs(fee * 100, paid, 200, "fee equals 1% of the total spend");
    }

    function test_hook_charges_exact_output_sell_in_token() public {
        (LaunchToken token,, PoolKey memory key) = _graduated(address(usd), false);
        PoolId id = key.toId();
        bool usdIs0 = Currency.unwrap(key.currency0) == address(usd);
        vm.prank(carol);
        usd.approve(address(swapRouter), type(uint256).max);
        _swap(carol, key, usdIs0, int256(5_000_000e18), 0);
        uint256 held = token.balanceOf(carol);
        vm.prank(carol);
        token.approve(address(swapRouter), held);
        uint256 usdBefore = usd.balanceOf(carol);
        _swap(carol, key, !usdIs0, int256(10e6), 0); // exact 10 USDC out, tokens in
        assertEq(usd.balanceOf(carol) - usdBefore, 10e6);
        uint256 tokenFee = hook.pendingFees(id, Currency.wrap(address(token)));
        assertGt(tokenFee, 0, "exact-output sells pay the fee in the launch token");
        hook.sweepPoolFees(PoolId.unwrap(id), Currency.wrap(address(token)));
        assertGt(_creatorToken(address(token)), 0);
        assertGt(_protocolToken(address(token)), 0);
    }

    function test_holders_share_pool_fees_after_graduation() public {
        (LaunchToken token,, PoolKey memory key) = _graduated(address(0), true);
        PoolId id = key.toId();
        uint256 bobBefore = sharing.pendingRewards(address(token), bob);
        _swap(carol, key, true, -100 ether, 100 ether);
        hook.sweepPoolFees(PoolId.unwrap(id), NATIVE);
        vm.roll(vm.getBlockNumber() + 1); // queued fees release at the first touch of a later block
        assertGt(sharing.pendingRewards(address(token), bob), bobBefore, "curve buyers earn pool fees");
        assertGt(sharing.pendingRewards(address(token), carol), 0, "pool buyers earn too");
        assertEq(sharing.pendingRewards(address(token), address(manager)), 0, "the pool's own balance is excluded");
        assertEq(_creatorNative(), 0);
    }

    function test_nobody_can_initialize_a_hooked_pool_early() public {
        (LaunchToken token,) = _launch(alice, address(0), 0, false, 1);
        PoolKey memory key = factory.poolKeyOf(address(token));
        vm.expectRevert();
        manager.initialize(key, 2 ** 96);
        key.tickSpacing = 30;
        vm.expectRevert();
        manager.initialize(key, 2 ** 96);
    }

    function test_locker_rejects_everyone_but_the_executor() public {
        (LaunchToken token,,) = _graduated(address(0), false);
        PoolKey memory key = factory.poolKeyOf(address(token));
        vm.expectRevert(LaunchLocker.NotExecutor.selector);
        locker.lock(key, 1);
    }

    function _curveProtocolShare() internal view returns (uint256) {
        // Fees paid on the curve during the six 3,000 MON buys that completed it, excluding the launch fee and the pool swap.
        return _protocolNative() - LAUNCH_FEE - 0.5 ether;
    }

    function _curveCreatorShare() internal view returns (uint256) {
        return _creatorNative() - 0.5 ether;
    }
}
