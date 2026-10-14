// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IGraduationExecutor} from "../../src/interfaces/ILaunchpad.sol";
import {IMondayV3Factory, IMondayV3Pool, IMondayV3MintCallback} from "../../src/interfaces/IMondayV3.sol";
import {FullRangeLiquidity} from "../../src/libraries/FullRangeLiquidity.sol";
import {TransferHelper} from "../../src/libraries/TransferHelper.sol";

interface IWMONOld {
    function deposit() external payable;
}

/// @notice Graduation venue: instead of a Uniswap v4 pool, turns a completed curve into a Monday Trade spot pool
///         (a Uniswap-v3-style concentrated-liquidity AMM). The pool opens at the curve's final price; a full-range
///         position is minted to the locker and never withdrawn, so the liquidity is permanently locked. Only the
///         launchpad factory can call `graduate`. Drop-in for `GraduationExecutor` via `LaunchpadFactory.setModules`.
contract OldMondayGraduationExecutor is IGraduationExecutor, IMondayV3MintCallback {
    IMondayV3Factory public immutable factory;
    address public immutable launchpadFactory;
    address public immutable locker;
    /// Wrapped MON. A launch paired with native MON graduates into a TOKEN/WMON pool, since Monday pools are ERC-20/ERC-20.
    address public immutable wmon;
    /// The graduated pool's fee tier. 1% suits a freshly graduated token; Monday supports it (tiers 100/300/500/3000/10000).
    uint24 public constant FEE = 10_000;

    event Graduated(address indexed pool, address indexed token, uint160 sqrtPriceX96, uint128 liquidity, uint256 quoteToPool, uint256 tokensToPool);

    error NotFactory();
    error PriceOutOfRange();
    error NoLiquidity();
    error UnsupportedFee();
    error WrongPool();

    address private transientPool; // set for the duration of a mint so the callback can trust the caller

    constructor(IMondayV3Factory _factory, address _launchpadFactory, address _locker, address _wmon) {
        factory = _factory;
        launchpadFactory = _launchpadFactory;
        locker = _locker;
        wmon = _wmon;
    }

    /// @notice Native MON is swept here for native-paired launches; it is wrapped to WMON before the pool is built.
    receive() external payable {}

    /// @inheritdoc IGraduationExecutor
    /// @dev `tickSpacing` from the launch config is ignored — the Monday pool uses the fee tier's own spacing.
    function graduate(address token, address pairToken, uint256 quoteAmount, uint256 tokenAmount, uint256 phantomQuote, int24)
        external
        returns (bytes32 poolId, uint128 liquidity)
    {
        if (msg.sender != launchpadFactory) revert NotFactory();

        // Native-paired launches sweep native MON here; wrap it and build a TOKEN/WMON pool.
        address quote = pairToken;
        if (pairToken == address(0)) {
            IWMONOld(wmon).deposit{value: quoteAmount}();
            quote = wmon;
        }

        // Reproduce the curve's final price: the pool holds `quoteAmount` at price (phantom + raised) / tokenReserve.
        uint256 tokensToPool = FullMath.mulDiv(tokenAmount, quoteAmount, phantomQuote + quoteAmount);
        // Leave a hair of quote unused so rounding in the pool's amount math can never exceed the balance.
        uint256 quoteToPool = quoteAmount - quoteAmount / 1_000_000;

        bool tokenIs0 = token < quote;
        (uint256 amount0, uint256 amount1) = tokenIs0 ? (tokensToPool, quoteToPool) : (quoteToPool, tokensToPool);

        int24 tickSpacing = factory.feeAmountTickSpacing(FEE);
        if (tickSpacing == 0) revert UnsupportedFee();

        address pool = factory.getPool(token, quote, FEE);
        if (pool == address(0)) pool = factory.createPool(token, quote, FEE);

        uint160 sqrtPriceX96 = FullRangeLiquidity.sqrtPriceX96(amount0, amount1);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert PriceOutOfRange();

        // A freshly graduated token has no pool yet; initialize only if it hasn't been.
        (uint160 current,,,,,,) = IMondayV3Pool(pool).slot0();
        if (current == 0) IMondayV3Pool(pool).initialize(sqrtPriceX96);

        int24 lower = TickMath.minUsableTick(tickSpacing);
        int24 upper = TickMath.maxUsableTick(tickSpacing);
        liquidity = FullRangeLiquidity.liquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        if (liquidity == 0) revert NoLiquidity();

        transientPool = pool;
        // Position is owned by the locker, which has no burn/collect path — so it can never be withdrawn.
        IMondayV3Pool(pool).mint(locker, lower, upper, liquidity, abi.encode(token, quote));
        transientPool = address(0);

        // Sweep any leftover (the reserved supply and unused quote) into the locker as well.
        _sweepRemainder(token, quote);

        poolId = bytes32(uint256(uint160(pool)));
        emit Graduated(pool, token, sqrtPriceX96, liquidity, quoteToPool, tokensToPool);
    }

    /// @notice v3 mint callback: pay the pool the tokens it is owed. Guarded to the pool we are actively minting into.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        if (msg.sender != transientPool) revert WrongPool();
        (address token, address pairToken) = abi.decode(data, (address, address));
        (address token0, address token1) = token < pairToken ? (token, pairToken) : (pairToken, token);
        if (amount0Owed > 0) TransferHelper.safeTransfer(token0, msg.sender, amount0Owed);
        if (amount1Owed > 0) TransferHelper.safeTransfer(token1, msg.sender, amount1Owed);
    }

    function _sweepRemainder(address token, address pairToken) private {
        uint256 tokenLeft = _balance(token);
        uint256 quoteLeft = _balance(pairToken);
        if (tokenLeft > 0) TransferHelper.safeTransfer(token, locker, tokenLeft);
        if (quoteLeft > 0) TransferHelper.safeTransfer(pairToken, locker, quoteLeft);
    }

    function _balance(address asset) private view returns (uint256) {
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }
}
