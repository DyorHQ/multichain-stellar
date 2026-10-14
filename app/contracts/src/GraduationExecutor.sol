// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ILaunchLocker} from "./interfaces/ILaunchpad.sol";
import {FullRangeLiquidity} from "./libraries/FullRangeLiquidity.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Turns a completed curve into a Uniswap v4 pool. The pool opens at the curve's final price: all raised
///         quote plus exactly the tokens that price implies go into a full-range position owned by the locker;
///         the rest of the reserved supply stays in the locker as well. Only the factory can call it.
contract GraduationExecutor {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable factory;
    address public immutable hook;
    address public immutable locker;

    event Graduated(bytes32 indexed poolId, address indexed token, uint160 sqrtPriceX96, uint128 liquidity, uint256 quoteToPool, uint256 tokensToPool);

    error NotFactory();
    error PriceOutOfRange();
    error NoLiquidity();

    constructor(IPoolManager _poolManager, address _factory, address _hook, address _locker) {
        poolManager = _poolManager;
        factory = _factory;
        hook = _hook;
        locker = _locker;
    }

    receive() external payable {}

    /// @param quoteAmount   Real quote swept from the curve (already held by this contract).
    /// @param tokenAmount   Tokens swept from the curve (already held by this contract).
    /// @param phantomQuote  The curve's phantom reserve, used to reproduce its final price.
    function graduate(address token, address pairToken, uint256 quoteAmount, uint256 tokenAmount, uint256 phantomQuote, int24 tickSpacing)
        external
        returns (bytes32 poolId, uint128 liquidity)
    {
        if (msg.sender != factory) revert NotFactory();

        // Curve price = (phantom + raised) / tokenReserve; the pool holds `quoteAmount` at that price.
        uint256 tokensToPool = FullMath.mulDiv(tokenAmount, quoteAmount, phantomQuote + quoteAmount);
        // Leave a hair of quote unused so rounding in the pool's amount math can never exceed the balance.
        uint256 quoteToPool = quoteAmount - quoteAmount / 1_000_000;

        bool tokenIs0 = token < pairToken;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? token : pairToken),
            currency1: Currency.wrap(tokenIs0 ? pairToken : token),
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        (uint256 amount0, uint256 amount1) = tokenIs0 ? (tokensToPool, quoteToPool) : (quoteToPool, tokensToPool);

        uint160 sqrtPriceX96 = FullRangeLiquidity.sqrtPriceX96(amount0, amount1);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert PriceOutOfRange();
        poolManager.initialize(key, sqrtPriceX96);

        liquidity = FullRangeLiquidity.liquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing)),
            amount0,
            amount1
        );
        if (liquidity == 0) revert NoLiquidity();

        TransferHelper.pay(pairToken, locker, quoteAmount);
        TransferHelper.safeTransfer(token, locker, tokenAmount);
        ILaunchLocker(locker).lock(key, liquidity);

        poolId = PoolId.unwrap(key.toId());
        emit Graduated(poolId, token, sqrtPriceX96, liquidity, quoteToPool, tokensToPool);
    }
}
