// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice CREATE2 helpers for landing a v4 hook on an address whose low 14 bits encode its permissions.
///         Owned copy for Moments (used by tests and the deploy script; not by any live money path).
library MomentHookAddress {
    uint160 internal constant FLAG_MASK = 0x3FFF;
    /// @dev The deterministic deployer proxy forge scripts use for `new X{salt: ...}` (also live on Monad).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function compute(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @dev Finds a salt so that the deployed address has exactly `flags` in its low 14 bits. The 85-byte
    ///      preimage (0xff ++ deployer ++ salt ++ initCodeHash) is built once and rewritten in place, so the
    ///      search runs in constant memory (a naive loop allocates per iteration and runs out of memory gas).
    function mine(address deployer, uint160 flags, bytes32 initCodeHash, uint256 maxIterations)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes memory preimage = abi.encodePacked(bytes1(0xff), deployer, bytes32(0), initCodeHash); // 85 bytes
        for (uint256 i = 0; i < maxIterations; i++) {
            assembly ("memory-safe") {
                mstore(add(preimage, 53), i) // salt lives at data offset 21 (= 32 + 21 from the length word)
                hook := and(keccak256(add(preimage, 32), 85), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if (uint160(hook) & FLAG_MASK == flags) return (hook, bytes32(i));
        }
        revert("MomentHookAddress: no salt found");
    }
}
