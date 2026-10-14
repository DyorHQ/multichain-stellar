// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    MomentTypes, IMomentsFactory, IMomentCollect, IMomentVesting, IMomentCoin, IMomentNFT, IMomentGraduation
} from "../../../src/moments/interfaces/IMoments.sol";

/// Stand-in for the Phase 2 executor with the SAME accounting contract: takes the reserve, activates vesting,
/// closes the NFT, mints the pool seed = S - creatorAlloc - sum entitlements to itself (the "pool"), asserts the
/// supply identity, and marks the Moment graduated. `failNext` simulates a stuck graduation.
contract MockGraduation is IMomentGraduation {
    IMomentsFactory public immutable factory;
    IMomentCollect public immutable collect;
    IMomentVesting public immutable vesting;

    bool public failNext;
    mapping(uint256 => uint256) public poolCoins;
    mapping(uint256 => uint256) public poolUsdc;
    uint256 public calls;

    constructor(IMomentsFactory f, IMomentCollect c, IMomentVesting v) {
        factory = f;
        collect = c;
        vesting = v;
    }

    function setFail(bool f) external {
        failNext = f;
    }

    /// Permissionless (retry) like the real executor.
    function graduate(uint256 momentId) external {
        calls += 1;
        if (failNext) revert("graduation down");
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        uint256 usdc = collect.releaseReserve(momentId, address(this));
        vesting.activate(momentId);
        IMomentNFT(m.nft).close();
        uint256 alloc = MomentTypes.SUPPLY * m.creatorAllocBps / MomentTypes.BPS;
        uint256 seed = MomentTypes.SUPPLY - alloc - vesting.totalEntitlement(momentId);
        IMomentCoin(m.coin).mint(address(this), seed);
        // The identity the real executor asserts at graduation.
        require(IMomentCoin(m.coin).totalSupply() + vesting.totalEntitlement(momentId) + alloc == MomentTypes.SUPPLY, "supply identity");
        collect.markGraduated(momentId);
        poolCoins[momentId] = seed;
        poolUsdc[momentId] = usdc;
    }
}
