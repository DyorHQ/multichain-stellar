// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal Uniswap-v3-style interfaces for Monday Trade's spot AMM (concentrated liquidity). Only the
///         subset the graduation executor needs: create/read a pool and mint a full-range position. Monday Trade's
///         book is embedded in the same pool contract, so LP provision uses the vanilla v3 shape — the fork test
///         `MondayGraduation.t.sol` verifies this against the live factory before anything reaches mainnet.
interface IMondayV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface IMondayV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    /// @notice Removes `amount` liquidity from the caller's position and credits the owed tokens (principal +
    ///         earned fees) to its `tokensOwed`. Called with `amount == 0` it only realizes accrued fees — it
    ///         removes no liquidity — which is how a fee vault harvests fees without ever touching the principal.
    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256 amount0, uint256 amount1);
    /// @notice Pays out up to the requested amounts from the caller's position's `tokensOwed` to `recipient`.
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1);
    /// @notice Standard v3 swap; used by the graduation fork test to accrue real fees before collecting them.
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
    function positions(bytes32 key)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1);
}

/// @notice The callback a v3 pool fires on the minter to collect the owed tokens.
interface IMondayV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

/// @notice The callback a v3 pool fires on the swapper to collect the input token.
interface IMondayV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
