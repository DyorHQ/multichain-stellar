// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Test double for a graduation venue. It records the reserves swept to it and returns a synthetic pool id,
///         so the factory's per-launch venue routing (e.g. Monday Trade) can be exercised without a live AMM.
///         Matches `IGraduationExecutor.graduate`'s selector so the factory can call it through the interface.
contract MockGraduationExecutor {
    address public lastToken;
    address public lastPairToken;
    uint256 public lastQuote;
    uint256 public lastTokens;
    uint256 public calls;

    receive() external payable {}

    /// The real Monday executor parks the position in a vault; the mock keeps everything itself.
    function locker() external view returns (address) {
        return address(this);
    }

    function graduate(address token, address pairToken, uint256 quoteAmount, uint256 tokenAmount, uint256, int24)
        external
        returns (bytes32 poolId, uint128 liquidity)
    {
        lastToken = token;
        lastPairToken = pairToken;
        lastQuote = quoteAmount;
        lastTokens = tokenAmount;
        calls += 1;
        poolId = keccak256(abi.encodePacked("mock-monday", token));
        liquidity = 1;
    }
}
