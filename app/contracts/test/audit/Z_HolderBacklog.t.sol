// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "../LaunchpadBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

/// LP-2 regression (v2 source): holder rewards can no longer be captured by a one-block holder. In v1 the hook
/// kept the holders' cut of every pool fee until someone called the permissionless `sweepPoolFees`; with a large
/// unswept backlog, an attacker could buy, sweep, hold across one block boundary and sell, collecting a pro-rata
/// share of fees earned long before they held. v2 forwards the holders' cut inside the swap that earned it, so
/// there is never a backlog to capture.
contract Z_HolderBacklogTest is LaunchpadBase {
    using PoolIdLibrary for PoolKey;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    PoolSwapTest.TestSettings internal settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    LaunchToken internal token;
    PoolKey internal pkey;
    PoolId internal pid;

    function setUp() public override {
        super.setUp();
        BondingCurve curve;
        (token, curve) = _launch(alice, address(0), 0, true, 91);
        vm.warp(vm.getBlockTimestamp() + 10);
        _completeNative(curve, bob); // bob is the long-term holder
        pkey = factory.poolKeyOf(address(token));
        pid = pkey.toId();
        vm.prank(carol);
        token.approve(address(swapRouter), type(uint256).max);
        vm.prank(dave);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _buy(address who, uint256 mon) internal {
        vm.prank(who);
        swapRouter.swap{value: mon}(
            pkey, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(mon), sqrtPriceLimitX96: MIN_PRICE_LIMIT}), settings, ""
        );
    }

    function _sellAll(address who) internal {
        uint256 bal = token.balanceOf(who);
        vm.prank(who);
        swapRouter.swap(pkey, IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(bal), sqrtPriceLimitX96: MAX_PRICE_LIMIT}), settings, "");
    }

    function test_holdersCut_isForwardedInTheSwap_noBacklogInHook() public {
        (uint256 q0,) = sharing.queuedRewards(address(token));
        _buy(carol, 100 ether); // 1% fee = 1 MON: 0.5 protocol, 0.5 holders
        assertEq(hook.pendingFees(pid, NATIVE), 0, "no holder backlog in the hook");
        assertEq(hook.pendingCreatorTax(pid, NATIVE), 0);
        assertEq(hook.pendingProtocolFees(pid, NATIVE), 0.5 ether, "the protocol's cut waits for the sweep");
        (uint256 q1,) = sharing.queuedRewards(address(token));
        assertEq(q1 - q0, 0.5 ether, "the holders' cut was queued in the same swap");

        uint256 protocolBefore = _protocolNative();
        hook.sweepPoolFees(PoolId.unwrap(pid), NATIVE);
        assertEq(_protocolNative() - protocolBefore, 0.5 ether, "sweep pays the protocol its cut");
        assertEq(hook.pendingProtocolFees(pid, NATIVE), 0);
        assertEq(address(hook).balance, 0, "hook holds nothing afterwards");
    }

    function test_oneBlockHolder_cannotCaptureEarlierFees() public {
        // A long stretch of organic volume (carol round-trips), never swept by anyone.
        for (uint256 i = 0; i < 10; i++) {
            _buy(carol, 1_000 ether);
            _sellAll(carol);
            vm.roll(vm.getBlockNumber() + 1);
        }
        // v1 would now hold ~10+ MON of holder fees in the hook, waiting for a sweep.
        assertEq(hook.pendingFees(pid, NATIVE), 0, "nothing accumulates in the hook");

        // The one-block attack: buy big, sweep, hold across one block boundary, sell.
        uint256 attackBuy = 5_000 ether;
        uint256 daveStart = dave.balance;
        _buy(dave, attackBuy);
        hook.sweepPoolFees(PoolId.unwrap(pid), NATIVE);
        vm.roll(vm.getBlockNumber() + 1);
        _sellAll(dave);
        uint256 reward = sharing.pendingRewards(address(token), dave);

        // Dave can only share in fees queued in blocks he actually held through: at most the holders' cut of the
        // fee on his own buy (0.5% of it) — none of the earlier volume's fees.
        assertLe(reward, attackBuy * 50 / 10_000, "no share of the pre-existing fees");
        assertLt(dave.balance + reward, daveStart, "the attack loses money");
        assertGt(sharing.pendingRewards(address(token), bob), 0, "the long-term holder earned the organic fees");
    }
}
