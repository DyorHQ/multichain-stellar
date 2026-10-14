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
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IMomentsFactory} from "./interfaces/IMoments.sol";
import {IMomentLocker} from "./interfaces/IMomentsMarket.sol";
import {MomentPoolMath} from "./libraries/MomentPoolMath.sol";

/// @notice Owns every Moment's full-range coin/USDC position, forever. The only liquidity operation this
///         contract can perform is an INCREASE funded from its own balances: `seed` (graduation executor, once)
///         and `increase` (buyback module). The pool's LP fees accrue to this position and are folded back into
///         it on every increase. There is no function that removes liquidity, no `take` to any address but
///         itself, no token transfer except paying the PoolManager what a position add costs, and no owner.
///
///         - An add requested while the PoolManager is already unlocked (graduation reached from inside someone
///           else's `unlock` callback, e.g. a terminal collect made by a contract holding the lock) runs in-line,
///           without calling `unlock` again. This is safe because v4 books deltas per caller: every delta this
///           contract creates is settled to zero within the same call (sync → transfer → settle, or take), so the
///           outer unlocker's accounting is untouched and it cannot make ours non-zero.
///         - Balances are attributed per Moment. USDC is shared by every Moment's pool, so an add for one
///           Moment may only spend what that Moment owns here (its dust, its folded LP fees, and whatever arrived
///           untracked just before the add — the reserve at seed, the buyback's top-up at increase), never another
///           Moment's idle USDC.
///         - MO-2 (sec2): one `increase` grows the position by at most `MAX_INCREASE_BPS` (0.5%) of its liquidity; the
///           rest stays held for the Moment and is added by later rounds. An add is priced at the live pool price, and
///           someone who pushed that price in an earlier block (the block-open guard cannot see it) takes the
///           impermanent loss of whatever is added. The cap is in liquidity, so that loss grows with the push: about
///           0.5% of it from the add, plus up to about 0.5% from the buyback's own swap. A one-round sandwich pays more
///           in fees than that (about 2.1% even for the Moment's creator, who gets 20% of the hook fee back). A push
///           held across several hourly rounds can still spend the Moment's held balance at that price, one capped
///           add per round.
contract MomentLocker is IMomentLocker, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice v2 (sec2, MO-2): the most one `increase` may add, in basis points of the position's liquidity.
    uint256 public constant MAX_INCREASE_BPS = 50;

    IPoolManager public immutable poolManager;
    IMomentsFactory public immutable factory;

    struct Position {
        PoolKey key;
        uint128 liquidity;
        bool exists;
    }

    mapping(uint256 => Position) private _positions;
    /// @notice The balance of each currency this contract holds on behalf of each Moment.
    mapping(uint256 => mapping(Currency => uint256)) public heldOf;
    /// @notice Σ heldOf over all Moments, per currency. Anything above it is untracked (it just arrived)
    ///         and is credited to the next Moment whose position is added to.
    mapping(Currency => uint256) public tracked;

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
        // Already inside an unlock (someone else's) -> modify in-line; our deltas net to zero here.
        if (poolManager.isUnlocked()) return _modify(momentId, key);
        bytes memory result = poolManager.unlock(abi.encode(momentId, key));
        (liquidity, used0, used1) = abi.decode(result, (uint128, uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 momentId, PoolKey memory key) = abi.decode(data, (uint256, PoolKey));
        (uint128 liquidity, uint256 used0, uint256 used1) = _modify(momentId, key);
        return abi.encode(liquidity, used0, used1);
    }

    /// @dev Only ever adds liquidity, and only while the PoolManager is unlocked. First credits the Moment with
    ///      whatever arrived untracked, then folds the LP fees the position has earned back into its balances (a
    ///      zero-delta position update credits them; they are taken to THIS contract, never to an external
    ///      address), then sizes the largest full-range add the Moment's OWN balances can fund and pays for it.
    function _modify(uint256 momentId, PoolKey memory key) private returns (uint128 liquidity, uint256 used0, uint256 used1) {
        Position storage p = _positions[momentId];
        _creditUntracked(momentId, key.currency0);
        _creditUntracked(momentId, key.currency1);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        if (p.liquidity != 0) {
            (BalanceDelta fees,) = poolManager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(momentId)}), ""
            );
            _settle(momentId, key.currency0, fees.amount0());
            _settle(momentId, key.currency1, fees.amount1());
        }
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        liquidity = MomentPoolMath.liquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            heldOf[momentId][key.currency0],
            heldOf[momentId][key.currency1]
        );
        if (p.liquidity != 0) {
            // v2 (sec2, MO-2): an increase (never the seed) adds at most MAX_INCREASE_BPS of the position.
            uint256 cap = uint256(p.liquidity) * MAX_INCREASE_BPS / 10_000;
            if (liquidity > cap) liquidity = uint128(cap);
        }
        if (liquidity == 0) return (0, 0, 0);
        p.liquidity += liquidity; // effect before the position update
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(momentId)
            }),
            ""
        );
        used0 = _settle(momentId, key.currency0, delta.amount0());
        used1 = _settle(momentId, key.currency1, delta.amount1());
    }

    /// @dev Attributes a currency's untracked balance (what arrived since the last add) to `momentId`.
    function _creditUntracked(uint256 momentId, Currency currency) private {
        uint256 bal = currency.balanceOfSelf();
        uint256 t = tracked[currency];
        if (bal > t) {
            heldOf[momentId][currency] += bal - t;
            tracked[currency] = bal;
        }
    }

    /// @dev Pays the PoolManager out of the Moment's own balance (negative delta) or takes what it is owed to this
    ///      contract, crediting the Moment (positive delta: folded LP fees).
    function _settle(uint256 momentId, Currency currency, int128 amount) private returns (uint256 paid) {
        if (amount < 0) {
            paid = uint256(uint128(-amount));
            heldOf[momentId][currency] -= paid; // checked: never spends another Moment's balance
            tracked[currency] -= paid;
            poolManager.sync(currency);
            currency.transfer(address(poolManager), paid);
            poolManager.settle();
        } else if (amount > 0) {
            uint256 got = uint256(uint128(amount));
            heldOf[momentId][currency] += got;
            tracked[currency] += got;
            poolManager.take(currency, address(this), got);
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

    /// @notice What the next add for `momentId` could spend of `currency` — its own balance here plus
    ///         the untracked balance that the add would credit to it first.
    function available(uint256 momentId, Currency currency) external view returns (uint256) {
        uint256 bal = currency.balanceOfSelf();
        uint256 t = tracked[currency];
        return heldOf[momentId][currency] + (bal > t ? bal - t : 0);
    }

    function tickRange(int24 tickSpacing) external pure returns (int24 tickLower, int24 tickUpper) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }
}
