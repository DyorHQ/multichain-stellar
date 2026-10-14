// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "../LaunchpadBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

interface IHookSweep {
    function sweepPoolFees(bytes32 poolId, Currency currency) external;
}

interface ISharing {
    function claim(address token) external returns (uint256);
    function pendingRewards(address token, address account) external view returns (uint256);
}

/// H-1 regression. The zero-capital flash-take reward-snipe (take the launch token out of the v4 pool inside one
/// `unlock`, trigger the permissionless sweep, be paid a "holder's" share, repay) now yields nothing, because
/// HolderFeeSharing queues the reward and releases it only at the first touch of a LATER block — a flash balance
/// cannot span blocks.
contract FlashSniper is IUnlockCallback {
    IPoolManager public pm;
    address public token;
    address public hook;
    address public sharing;
    bytes32 public poolId;
    uint256 public flashAmount;
    uint256 public claimed;

    constructor(IPoolManager _pm, address _token, address _hook, address _sharing, bytes32 _poolId) {
        pm = _pm;
        token = _token;
        hook = _hook;
        sharing = _sharing;
        poolId = _poolId;
    }

    receive() external payable {}

    function attack(uint256 _flash) external {
        flashAmount = _flash;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        Currency tc = Currency.wrap(token);
        pm.take(tc, address(this), flashAmount);
        IHookSweep(hook).sweepPoolFees(poolId, Currency.wrap(address(0)));
        uint256 before = address(this).balance;
        try ISharing(sharing).claim(token) {} catch {} // reverts NothingToClaim now; swallow it
        claimed = address(this).balance - before;
        pm.sync(tc);
        IERC20(token).transfer(address(pm), flashAmount);
        pm.settle();
        return "";
    }
}

contract AuditFlashSnipeTest is LaunchpadBase {
    using PoolIdLibrary for PoolKey;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    PoolSwapTest.TestSettings internal settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function _swap(address who, PoolKey memory key, bool zeroForOne, int256 amt, uint256 value) internal {
        vm.prank(who);
        swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT}),
            settings,
            ""
        );
    }

    function test_C5_flash_snipe_is_defeated() public {
        (LaunchToken token, BondingCurve curve) = _launch(bob, address(0), 0, true, 1);
        vm.warp(block.timestamp + 10);
        _completeNative(curve, alice);
        PoolKey memory key = factory.poolKeyOf(address(token));
        bytes32 pid = PoolId.unwrap(key.toId());

        _swap(carol, key, true, -100 ether, 100 ether); // 1 MON fee accrues; 0.5 would go to holders on sweep
        uint256 pmBal = token.balanceOf(address(manager));

        FlashSniper sniper = new FlashSniper(manager, address(token), address(hook), address(sharing), pid);
        sniper.attack(pmBal - 1);

        // Zero capital in, and now zero out: the flash-inflated balance captured nothing.
        assertEq(sniper.claimed(), 0, "flash sniper captured zero");
        assertEq(token.balanceOf(address(sniper)), 0, "flash repaid, net token position zero");

        // The queued reward is intact for the real holders once a block passes.
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(ISharing(address(sharing)).pendingRewards(address(token), alice), 0, "honest holder keeps the reward");
    }
}
