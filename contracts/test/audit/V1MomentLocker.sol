// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IMomentsFactory} from "../../src/moments/interfaces/IMoments.sol";
import {MomentPoolMath} from "../../src/moments/libraries/MomentPoolMath.sol";

/// @dev TEST FIXTURE: a verbatim copy of the DEPLOYED (v1) MomentLocker — source at commit 3fc1f47, last changed in
///      ac33952 — renamed and detached from the v2 IMomentLocker interface, so the MO-1 proof of concept
///      (Z_MomentsUnlockGrief.t.sol) keeps demonstrating the bug the live contracts have. Never deploy this.
///
/// @notice Owns every Moment's full-range coin/USDC position, forever. The only liquidity operation this
///         contract can perform is an INCREASE funded from its own balances: `seed` (graduation executor, once)
///         and `increase` (buyback module). The pool's LP fees accrue to this position and are folded back into
///         it on every increase. There is no function that removes liquidity, no `take` to any address but
///         itself, no token transfer except paying the PoolManager what a position add costs, and no owner.
contract V1MomentLocker is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IMomentsFactory public immutable factory;

    struct Position {
        PoolKey key;
        uint128 liquidity;
        bool exists;
    }

    mapping(uint256 => Position) private _positions;

    event Seeded(uint256 indexed momentId, PoolId indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Increased(uint256 indexed momentId, PoolId indexed poolId, uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    error NotGraduation();
    error NotBuyback();
    error NotPoolManager();
    error AlreadySeeded();
    error NotSeeded();
    error NoLiquidity();
    error ZeroAddress();

    constructor(IPoolManager _poolManager, IMomentsFactory _factory) {
        if (address(_poolManager) == address(0) || address(_factory) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        factory = _factory;
    }

    /// @notice Mints the initial full-range position from the reserve USDC + pool coins the executor placed here.
    function seed(uint256 momentId, PoolKey calldata key) external returns (uint128 liquidity, uint256 used0, uint256 used1) {
        if (msg.sender != factory.graduation()) revert NotGraduation();
        if (_positions[momentId].exists) revert AlreadySeeded();
        _positions[momentId] = Position({key: key, liquidity: 0, exists: true});
        (liquidity, used0, used1) = _add(momentId, key);
        if (liquidity == 0) revert NoLiquidity();
        emit Seeded(momentId, key.toId(), liquidity, used0, used1);
    }

    /// @notice Adds whatever coin + USDC this contract currently holds for the Moment to its position (buyback-LP).
    function increase(uint256 momentId) external returns (uint128 liquidityAdded, uint256 used0, uint256 used1) {
        if (msg.sender != factory.buyback()) revert NotBuyback();
        Position storage p = _positions[momentId];
        if (!p.exists) revert NotSeeded();
        PoolKey memory key = p.key;
        (liquidityAdded, used0, used1) = _add(momentId, key);
        emit Increased(momentId, key.toId(), liquidityAdded, used0, used1);
    }

    function _add(uint256 momentId, PoolKey memory key) private returns (uint128 liquidity, uint256 used0, uint256 used1) {
        bytes memory result = poolManager.unlock(abi.encode(momentId, key));
        (liquidity, used0, used1) = abi.decode(result, (uint128, uint256, uint256));
    }

    /// @dev Only ever adds liquidity. First folds the LP fees the position has earned back into this contract's
    ///      balances (a zero-delta position update credits them; they are taken to THIS contract, never to an
    ///      external address), then sizes the largest full-range add both balances can fund and pays for it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 momentId, PoolKey memory key) = abi.decode(data, (uint256, PoolKey));
        Position storage p = _positions[momentId];
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        if (p.liquidity != 0) {
            (BalanceDelta fees,) = poolManager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(momentId)}), ""
            );
            _settle(key.currency0, fees.amount0());
            _settle(key.currency1, fees.amount1());
        }
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = MomentPoolMath.liquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            key.currency0.balanceOfSelf(),
            key.currency1.balanceOfSelf()
        );
        if (liquidity == 0) return abi.encode(uint128(0), uint256(0), uint256(0));
        p.liquidity += liquidity; // effect before the position update
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(momentId)
            }),
            ""
        );
        uint256 used0 = _settle(key.currency0, delta.amount0());
        uint256 used1 = _settle(key.currency1, delta.amount1());
        return abi.encode(liquidity, used0, used1);
    }

    function _settle(Currency currency, int128 amount) private returns (uint256 paid) {
        if (amount < 0) {
            paid = uint256(uint128(-amount));
            poolManager.sync(currency);
            currency.transfer(address(poolManager), paid);
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    // ------------------------------------------------------------------ views

    function positionOf(uint256 momentId) external view returns (PoolKey memory key, uint128 liquidity) {
        Position storage p = _positions[momentId];
        return (p.key, p.liquidity);
    }

    function liquidityOf(uint256 momentId) external view returns (uint128) {
        return _positions[momentId].liquidity;
    }

    function tickRange(int24 tickSpacing) external pure returns (int24 tickLower, int24 tickUpper) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }
}
