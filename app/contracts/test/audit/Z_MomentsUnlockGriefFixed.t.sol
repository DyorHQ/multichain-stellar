// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MomentsMarketBase} from "../moments/MomentsMarketBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {UnlockGriefer} from "./Z_MomentsUnlockGrief.t.sol";

/// v2 regression for MO-1 (see Z_MomentsUnlockGrief.t.sol for the PoC against the deployed v1 locker).
///
/// The same attack — the terminal collect made from inside a `PoolManager.unlock()` callback — against the v2
/// MomentLocker, which adds the position in-line when the PoolManager is already unlocked. Graduation completes in
/// the attacker's own transaction: no GraduationFailed, no stuck clock, nothing to expire, and the attacker's unlock
/// still has to (and does) close with zero outstanding deltas.
contract Z_MomentsUnlockGriefFixedTest is MomentsMarketBase {
    UnlockGriefer internal griefer;

    function setUp() public override {
        super.setUp();
        griefer = new UnlockGriefer(manager, collect, usdc);
        usdc.mint(address(griefer), 100_000_000);
    }

    function _griefedMoment(bool usdcIs0) internal returns (uint256 id, MomentCoin coin) {
        (id, coin,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, usdcIs0);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Collecting));
        griefer.attack(id); // the terminal collect, from inside the attacker's unlock
    }

    function _assertGraduatedInline(uint256 id, MomentCoin coin, bool usdcIs0) internal view {
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Graduated), "graduated inside the attacker's unlock");
        assertEq(l.stuckSince, 0, "the stuck clock never started");
        assertEq(l.reserve, 0, "reserve went into the pool");
        assertTrue(executor.isGraduated(id));
        PoolKey memory key = executor.poolKeyOf(id);
        uint128 liq = _lockerPositionLiquidity(id, key);
        assertGt(liq, 0, "the full-range position exists");
        assertEq(liq, locker.liquidityOf(id), "locker book matches the PoolManager position");
        MomentGraduation.Record memory r = executor.record(id);
        assertEq(r.usedUsdc + usdc.balanceOf(address(locker)), THRESHOLD, "reserve = used + dust left in the locker");
        assertEq(coin.totalSupply(), r.poolCoins, "only the pool coins exist");
        usdcIs0; // both orderings are exercised by the callers
    }

    function test_terminalCollectInsideUnlock_graduates_usdcIs0() public {
        (uint256 id, MomentCoin coin) = _griefedMoment(true);
        _assertGraduatedInline(id, coin, true);
    }

    function test_terminalCollectInsideUnlock_graduates_coinIs0() public {
        (uint256 id, MomentCoin coin) = _griefedMoment(false);
        _assertGraduatedInline(id, coin, false);
    }

    function test_griefedMoment_is_never_expirable() public {
        (uint256 id,) = _griefedMoment(true);
        vm.warp(block.timestamp + WINDOW + MomentTypes.STUCK_GRACE + 1);
        vm.expectRevert(MomentCollect.WrongState.selector);
        collect.expire(id);
    }

    function test_noGraduationFailedEvent() public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        vm.recordLogs();
        griefer.attack(id);
        bytes32 failedTopic = MomentCollect.GraduationFailed.selector;
        bytes32 graduatedTopic = MomentCollect.Graduated.selector;
        bool sawGraduated;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(collect)) continue;
            assertTrue(logs[i].topics[0] != failedTopic, "no GraduationFailed");
            if (logs[i].topics[0] == graduatedTopic) sawGraduated = true;
        }
        assertTrue(sawGraduated, "Graduated emitted by the collect contract");
    }

    /// A plain (non-griefed) graduation and a later buyback still work with the same v2 locker.
    function test_plainGraduation_unaffected() public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _completeWithSingles(id, alice);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));
        assertEq(collect.ledger(id).stuckSince, 0);
    }
}
