// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice Phase 2 (market) interfaces. Kept apart from IMoments.sol so the core stays free of v4 types.
interface IMomentLocker {
    function seed(uint256 momentId, PoolKey calldata key) external returns (uint128 liquidity, uint256 used0, uint256 used1);
    function increase(uint256 momentId) external returns (uint128 liquidityAdded, uint256 used0, uint256 used1);
    function liquidityOf(uint256 momentId) external view returns (uint128);
    /// The Moment's own balance of `currency` in the locker plus any untracked balance.
    function available(uint256 momentId, Currency currency) external view returns (uint256);
}

interface IMomentFeeHook {
    function register(PoolKey calldata key, uint256 momentId) external;
    function pullBuyback(uint256 momentId) external returns (uint256 amount);
    function buybackAccrued(uint256 momentId) external view returns (uint256);
    /// The pool's sqrt price before the first swap of the current block (the live price if none yet).
    function blockOpenSqrtPrice(uint256 momentId) external view returns (uint160);
}

interface IMomentGraduationRegistry {
    function poolKeyOf(uint256 momentId) external view returns (PoolKey memory);
    function isGraduated(uint256 momentId) external view returns (bool);
}
