// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice CREATE2 helpers for landing the hook on an address whose low 14 bits encode its permissions.
library HookAddress {
    uint160 internal constant FLAG_MASK = 0x3FFF;
    /// @dev The deterministic deployer proxy forge scripts use for `new X{salt: ...}` (also live on Monad).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function compute(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @dev Finds a salt so that the deployed address has exactly `flags` in its low 14 bits.
    function mine(address deployer, uint160 flags, bytes32 initCodeHash, uint256 maxIterations)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            hook = compute(deployer, salt, initCodeHash);
            if (uint160(hook) & FLAG_MASK == flags) return (hook, salt);
        }
        revert("HookAddress: no salt found");
    }
}
