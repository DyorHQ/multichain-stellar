// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// @notice Price and full-range liquidity math for the Moments coin/USDC pools (owned clean-room copy; only
///         v4-core and OpenZeppelin are referenced). All inputs are raw token units: USDC 6 dp, coin 18 dp — the
///         decimal gap is carried entirely by the amounts, never assumed here.
library MomentPoolMath {
    /// @dev sqrt(amount1 / amount0) · 2^96: the v4 opening price for a pool seeded with (amount0, amount1).
    ///      Exact route while amount1/amount0 < 2^63 (no overflow of amount1·2^192); otherwise a 2^96-scaled
    ///      route with 48 bits of headroom.
    function sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 root;
        if (amount1 / amount0 < (1 << 63)) {
            root = Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0));
        } else {
            root = Math.sqrt(FullMath.mulDiv(amount1, 1 << 96, amount0)) << 48;
        }
        require(root <= type(uint160).max, "MomentPoolMath: price overflow");
        return uint160(root);
    }

    function liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
    }

    function liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA);
    }

    /// @dev The largest liquidity fundable by both amounts at price sqrtP inside [sqrtA, sqrtB].
    function liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 liquidity;
        if (sqrtP <= sqrtA) {
            liquidity = liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint256 l0 = liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint256 l1 = liquidityForAmount1(sqrtA, sqrtP, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
        require(liquidity <= type(uint128).max, "MomentPoolMath: liquidity overflow");
        return uint128(liquidity);
    }

    /// @dev Token0 needed (rounded up) to hold `liquidity` between sqrtA and sqrtB.
    function amount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true);
    }

    /// @dev Token1 needed (rounded up) to hold `liquidity` between sqrtA and sqrtB.
    function amount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
    }
}
