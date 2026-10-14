// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Constant-product bonding curve math with a phantom (virtual) quote reserve.
///         The curve holds the whole supply; the reserve left when `threshold` quote has been raised is the
///         share that becomes pool liquidity: supply * phantom / (phantom + threshold).
library CurveMath {
    uint256 internal constant BPS = 10_000;

    /// @dev Tokens (or quote) received for `amountIn` against reserves (reserveIn, reserveOut).
    function amountOut(uint256 inAmount, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        return FullMath.mulDiv(inAmount, reserveOut, reserveIn + inAmount);
    }

    /// @dev Input needed to receive exactly `out` (rounded up).
    function amountIn(uint256 out, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        return FullMath.mulDiv(out, reserveIn, reserveOut - out) + 1;
    }

    function reservedSupply(uint256 supply, uint256 phantomQuote, uint256 threshold) internal pure returns (uint256) {
        return FullMath.mulDiv(supply, phantomQuote, phantomQuote + threshold);
    }

    function feeOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, bps, BPS);
    }

    /// @dev Gross amount whose net (after `totalBps` of fees) is at least `net`, rounded up.
    function grossForNet(uint256 net, uint256 totalBps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(net, BPS, BPS - totalBps);
    }
}
