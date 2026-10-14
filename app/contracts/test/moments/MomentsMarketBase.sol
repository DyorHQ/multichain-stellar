// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsBase} from "./MomentsBase.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";
import {MomentFeeHook} from "../../src/moments/MomentFeeHook.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentHookAddress} from "../../src/moments/libraries/HookAddress.sol";

/// The full Phase 2 stack on a fresh, real Uniswap v4 PoolManager: hook at a mined address, locker, executor,
/// buyback, plus the v4 test swap router as the "trader". Moments can be published with either currency ordering.
abstract contract MomentsMarketBase is MomentsBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    MomentFeeHook internal hook;
    MomentLocker internal locker;
    MomentGraduation internal executor;
    MomentBuyback internal buyback;

    function setUp() public virtual override {
        super.setUp();
        address[4] memory users = [alice, bob, carol, creator];
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            usdc.approve(address(swapRouter), type(uint256).max);
        }
    }

    function _deployMarket() internal virtual override returns (address, address, address, address) {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        locker = new MomentLocker(manager, factory);
        executor = new MomentGraduation(manager, factory, usdc);
        buyback = new MomentBuyback(manager, factory, usdc);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(MomentFeeHook).creationCode, abi.encode(manager, factory, usdc)));
        (address predicted, bytes32 salt) = MomentHookAddress.mine(address(this), flags, initCodeHash, 500_000);
        hook = new MomentFeeHook{salt: salt}(manager, factory, usdc);
        require(address(hook) == predicted, "hook address");
        return (address(executor), address(locker), address(hook), address(buyback));
    }

    /// Publishes with a salt chosen so that `usdcIs0` matches (USDC below / above the CREATE2 coin address).
    function _publishOrdered(address who, uint256 price, uint16 allocBps, bool usdcIs0) internal returns (uint256 id, MomentCoin coin, MomentNFT nft) {
        for (uint256 seed = 1000; seed < 1600; seed++) {
            uint256 nextId = factory.momentCount() + 1;
            MomentsFactory.PublishParams memory p = _params(price, allocBps, seed);
            bytes32 salt = keccak256(abi.encode(nextId, who, p.salt));
            address predicted = vm.computeCreate2Address(
                salt,
                keccak256(abi.encodePacked(type(MomentCoin).creationCode, abi.encode(nextId, p.name, p.symbol, address(vesting), address(executor)))),
                address(factory)
            );
            if ((address(usdc) < predicted) == usdcIs0) {
                bytes32 terms = factory.termsHash();
                vm.prank(who);
                (uint256 i, address c, address n) = factory.publish(p, terms);
                require((address(usdc) < c) == usdcIs0, "ordering");
                return (i, MomentCoin(c), MomentNFT(n));
            }
        }
        revert("no ordering seed found");
    }

    function _approveCoin(MomentCoin coin, address who) internal {
        vm.prank(who);
        coin.approve(address(swapRouter), type(uint256).max);
    }

    function _swap(address who, PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // Buys: USDC in. Sells: coin in. `usdcIs0` decides the swap direction.
    function _buyExactIn(address who, PoolKey memory key, bool usdcIs0, uint256 usdcIn) internal returns (BalanceDelta) {
        return _swap(who, key, usdcIs0, -int256(usdcIn));
    }

    function _buyExactOut(address who, PoolKey memory key, bool usdcIs0, uint256 coinOut) internal returns (BalanceDelta) {
        return _swap(who, key, usdcIs0, int256(coinOut));
    }

    function _sellExactIn(address who, PoolKey memory key, bool usdcIs0, uint256 coinIn) internal returns (BalanceDelta) {
        return _swap(who, key, !usdcIs0, -int256(coinIn));
    }

    function _sellExactOut(address who, PoolKey memory key, bool usdcIs0, uint256 usdcOut) internal returns (BalanceDelta) {
        return _swap(who, key, !usdcIs0, int256(usdcOut));
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(key.toId());
    }

    function _poolLiquidity(PoolKey memory key) internal view returns (uint128) {
        return manager.getLiquidity(key.toId());
    }

    function _lockerPositionLiquidity(uint256 id, PoolKey memory key) internal view returns (uint128) {
        bytes32 posKey = Position.calculatePositionKey(address(locker), TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bytes32(id));
        return manager.getPositionLiquidity(key.toId(), posKey);
    }

    function _usdcOf(BalanceDelta d, bool usdcIs0) internal pure returns (int128) {
        return usdcIs0 ? d.amount0() : d.amount1();
    }

    function _coinOf(BalanceDelta d, bool usdcIs0) internal pure returns (int128) {
        return usdcIs0 ? d.amount1() : d.amount0();
    }
}
