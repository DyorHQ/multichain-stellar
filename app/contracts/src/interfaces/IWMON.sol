// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";

/// @notice WETH9-style wrapped native token (WMON on Monad).
interface IWMON is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
