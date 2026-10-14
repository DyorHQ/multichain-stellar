// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IGraduationExecutor} from "./interfaces/ILaunchpad.sol";
import {IMondayV3Factory, IMondayV3Pool, IMondayV3MintCallback, IMondayV3SwapCallback} from "./interfaces/IMondayV3.sol";
import {FullRangeLiquidity} from "./libraries/FullRangeLiquidity.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

interface IWMON {
    function deposit() external payable;
}

/// @notice Graduation venue: instead of a Uniswap v4 pool, turns a completed curve into a Monday Trade spot pool
///         (a Uniswap-v3-style concentrated-liquidity AMM). The pool opens at the curve's final price; a full-range
///         position is minted to the locker (the fee vault) and never withdrawn, so the liquidity is permanently
///         locked. Only the launchpad factory can call `graduate`.
///
///         Monday's factory is permissionless, so anyone can pre-create this pool and initialize it at a price of
///         their choosing before graduation. Minting into such a pool would hand the graduating reserves to the
///         squatter at their price, and simply refusing would let a ~500k-gas squat lock every holder up until the
///         factory's 7-day rescue. So a mispriced pre-existing pool is REALIGNED first: a bounded swap (at most
///         `MAX_ALIGN_BPS` of the executor's reserve of the input asset) with the curve price as its limit. Through
///         an empty or dust-liquidity pool that costs nothing — the price simply moves to the limit — and against
///         real liquidity it trades toward the fair price, i.e. in the executor's favour. If the price still does
///         not land exactly on the curve price the graduation reverts (`PoolPreInitialized`) and the factory's
///         venue fallback takes over.
contract MondayGraduationExecutor is IGraduationExecutor, IMondayV3MintCallback, IMondayV3SwapCallback {
    IMondayV3Factory public immutable factory;
    address public immutable launchpadFactory;
    address public immutable locker;
    /// Wrapped MON. A launch paired with native MON graduates into a TOKEN/WMON pool, since Monday pools are ERC-20/ERC-20.
    address public immutable wmon;
    /// The graduated pool's fee tier. 1% suits a freshly graduated token; Monday supports it (tiers 100/300/500/3000/10000).
    uint24 public constant FEE = 10_000;
    /// At most this share of the executor's reserve of the input asset may be traded to realign a squatted pool.
    uint256 public constant MAX_ALIGN_BPS = 100;

    event Graduated(address indexed pool, address indexed token, uint160 sqrtPriceX96, uint128 liquidity, uint256 quoteToPool, uint256 tokensToPool);
    event PoolRealigned(address indexed pool, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96, address inputAsset, uint256 spent);

    error NotFactory();
    error PriceOutOfRange();
    error NoLiquidity();
    error UnsupportedFee();
    error WrongPool();
    error PoolPreInitialized();

    address private transientPool; // set for the duration of a mint/swap so the callback can trust the caller

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
            IWMON(wmon).deposit{value: quoteAmount}();
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

        (uint160 current,,,,,,) = IMondayV3Pool(pool).slot0();
        if (current == 0) {
            IMondayV3Pool(pool).initialize(sqrtPriceX96);
        } else if (current != sqrtPriceX96) {
            _realign(pool, token, quote, tokenIs0, current, sqrtPriceX96);
            (current,,,,,,) = IMondayV3Pool(pool).slot0();
            if (current != sqrtPriceX96) revert PoolPreInitialized();
        }

        int24 lower = TickMath.minUsableTick(tickSpacing);
        int24 upper = TickMath.maxUsableTick(tickSpacing);
        // Fund the position from what this contract actually holds now (a realignment may have traded a sliver),
        // at the curve price. The quote side binds; the reserved supply always leaves token slack.
        {
            uint256 tokenBal = _balance(token);
            uint256 quoteBal = _balance(quote);
            (amount0, amount1) = tokenIs0 ? (tokenBal, quoteBal - quoteBal / 1_000_000) : (quoteBal - quoteBal / 1_000_000, tokenBal);
        }
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
        (address token0, address token1) = _sorted(data);
        if (amount0Owed > 0) TransferHelper.safeTransfer(token0, msg.sender, amount0Owed);
        if (amount1Owed > 0) TransferHelper.safeTransfer(token1, msg.sender, amount1Owed);
    }

    /// @notice v3 swap callback for the realignment swap: pay the pool the input it is owed. Same guard.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        if (msg.sender != transientPool) revert WrongPool();
        (address token0, address token1) = _sorted(data);
        if (amount0Delta > 0) TransferHelper.safeTransfer(token0, msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) TransferHelper.safeTransfer(token1, msg.sender, uint256(amount1Delta));
    }

    /// @dev Moves a squatted pool's price to the curve price with a bounded swap. In v3, selling currency0
    ///      (`zeroForOne`) moves the price down, so the direction follows the sign of the gap; the swap stops
    ///      exactly at `target` (its price limit) or when the bounded input is exhausted.
    function _realign(address pool, address token, address quote, bool tokenIs0, uint160 current, uint160 target) private {
        bool zeroForOne = current > target;
        address input = zeroForOne == tokenIs0 ? token : quote;
        uint256 budget = _balance(input) * MAX_ALIGN_BPS / 10_000;
        if (budget == 0) return;
        transientPool = pool;
        (int256 amount0, int256 amount1) = IMondayV3Pool(pool).swap(address(this), zeroForOne, int256(budget), target, abi.encode(token, quote));
        transientPool = address(0);
        int256 inputDelta = zeroForOne ? amount0 : amount1;
        emit PoolRealigned(pool, current, target, input, inputDelta > 0 ? uint256(inputDelta) : 0);
    }

    function _sorted(bytes calldata data) private pure returns (address token0, address token1) {
        (address token, address pairToken) = abi.decode(data, (address, address));
        (token0, token1) = token < pairToken ? (token, pairToken) : (pairToken, token);
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
