// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Test-only executor that always fails, to exercise the stuck-launch path.
contract RevertingExecutor {
    receive() external payable {}

    function graduate(address, address, uint256, uint256, uint256, int24) external pure returns (bytes32, uint128) {
        revert("graduation venue unavailable");
    }
}
