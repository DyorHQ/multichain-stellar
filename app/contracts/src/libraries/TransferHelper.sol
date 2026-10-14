// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Safe ERC-20 and native transfers (tolerates tokens that return nothing).
library TransferHelper {
    error TransferFailed();
    error NativeTransferFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @dev Pays `amount` of `asset` (address(0) = native) to `to`.
    function pay(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == address(0)) sendNative(to, amount);
        else safeTransfer(asset, to, amount);
    }
}
