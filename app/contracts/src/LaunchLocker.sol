// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Types, ILaunchpadFactory} from "./interfaces/ILaunchpad.sol";

/// @notice Holds every graduated pool position and the supply left over at graduation, forever. There is no
///         unlock, no owner and no withdrawal: the contract can only add liquidity, never remove it.
///
///         `locked[]` is keyed by the launch token for every pair, whichever way the pair sorts, and
///         `lockedLiquidity(token)` reads the live position straight from the PoolManager.
contract LaunchLocker is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public immutable factory;

    struct Locked {
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(address => Locked) public locked; // launch token => position

    event LiquidityLocked(bytes32 indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1);

    error NotExecutor();
    error NotPoolManager();

    constructor(IPoolManager _poolManager, address _factory) {
        poolManager = _poolManager;
        factory = _factory;
    }

    receive() external payable {}

    /// @notice Mints a full-range position funded from this contract's balances. Only the graduation executor
    ///         can call it, and only after it transferred the reserves in.
    function lock(PoolKey calldata key, uint128 liquidity) external {
        if (msg.sender != ILaunchpadFactory(factory).graduationExecutor()) revert NotExecutor();
        poolManager.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        uint256 amount0 = _settle(key.currency0, delta.amount0());
        uint256 amount1 = _settle(key.currency1, delta.amount1());
        address token = _launchToken(key);
        locked[token] = Locked({poolId: keccak256(abi.encode(key)), tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});
        emit LiquidityLocked(keccak256(abi.encode(key)), liquidity, amount0, amount1);
        return "";
    }

    /// @dev Pays what the pool is owed for `currency` (negative delta) from this contract's balance.
    function _settle(Currency currency, int128 amount) internal returns (uint256 paid) {
        if (amount >= 0) return 0;
        paid = uint256(uint128(-amount));
        if (currency.isAddressZero()) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), paid);
            poolManager.settle();
        }
    }

    /// @dev The launch token of a graduating pool, whichever way the pair sorts. A native quote is always
    ///      currency0; for two ERC-20s, currency0 is the launch token exactly when the factory's launch record for it
    ///      exists and names currency1 as its quote asset.
    function _launchToken(PoolKey memory key) internal view returns (address) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == address(0)) return c1;
        Types.LaunchedToken memory l = ILaunchpadFactory(factory).getLaunchedToken(c0);
        return l.exists && l.pairToken == c1 ? c0 : c1;
    }

    /// @notice The liquidity of `token`'s locked position as the PoolManager itself reports it (0 if the
    ///         token has no position here). Proof-of-lock that does not depend on this contract's own bookkeeping.
    function lockedLiquidity(address token) external view returns (uint128) {
        Locked storage l = locked[token];
        if (l.poolId == bytes32(0)) return 0;
        bytes32 positionKey = Position.calculatePositionKey(address(this), l.tickLower, l.tickUpper, bytes32(0));
        return poolManager.getPositionLiquidity(PoolId.wrap(l.poolId), positionKey);
    }

    /// @notice Launch tokens left in the locker beyond the pool position (excess supply) are visible here.
    function excessSupply(address token) external view returns (uint256) {
        return Currency.wrap(token).balanceOfSelf();
    }
}
