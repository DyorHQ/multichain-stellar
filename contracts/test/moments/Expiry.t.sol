// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

/// The collect window and the expiry wind-down (user ruling 2026-09-16): collecting ends at graduation or at the
/// creator-set deadline (<= 30 days); an un-graduated Moment past its deadline winds the reserve down 70% to the
/// creator / 30% to treasury (policy `expiryCreatorBps`, snapshotted at publish), all pull-based; no coin is ever minted.
contract ExpiryTest is MomentsBase {
    uint256 id;
    MomentCoin coin;
    MomentNFT nft;

    function setUp() public override {
        super.setUp();
        (id, coin, nft) = _publish(creator, PRICE, MAX_ALLOC_BPS, 1);
    }

    function test_window_bounds_are_enforced_at_publish() public {
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.BadWindow.selector);
        factory.publish(_paramsWindow(PRICE, 0, MomentTypes.MIN_COLLECT_WINDOW - 1, 9), terms);
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.BadWindow.selector);
        factory.publish(_paramsWindow(PRICE, 0, MomentTypes.MAX_COLLECT_WINDOW + 1, 9), terms);
        vm.prank(creator);
        (uint256 idMin,,) = factory.publish(_paramsWindow(PRICE, 0, MomentTypes.MIN_COLLECT_WINDOW, 9), terms);
        assertEq(factory.getMoment(idMin).deadline, block.timestamp + 1 hours);
        vm.prank(creator);
        (uint256 idMax,,) = factory.publish(_paramsWindow(PRICE, 0, MomentTypes.MAX_COLLECT_WINDOW, 10), terms);
        assertEq(factory.getMoment(idMax).deadline, block.timestamp + 30 days);
        assertEq(MomentTypes.MAX_COLLECT_WINDOW, 30 days, "maximum collect window is 30 days");
    }

    function test_collecting_stops_exactly_at_the_deadline() public {
        uint64 deadline = factory.getMoment(id).deadline;
        vm.warp(deadline - 1);
        _collect(id, alice, 1); // last second still collects
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(MomentCollect.CollectWindowClosed.selector);
        collect.collect(id, 1);
        vm.prank(alice);
        vm.expectRevert(MomentCollect.CollectWindowClosed.selector);
        collect.quote(id, 1);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Collecting), "state only changes through expire()");
        assertFalse(nft.closed());
    }

    function test_expire_before_deadline_reverts_and_after_deadline_winds_down_70_30() public {
        _collect(id, alice, 4); // reserve 3,000,000 / creator 800,000 / platform 200,000
        vm.prank(bob);
        vm.expectRevert(MomentCollect.NotExpirable.selector);
        collect.expire(id);

        vm.warp(factory.getMoment(id).deadline);
        uint256 held = usdc.balanceOf(address(collect));
        vm.prank(bob); // permissionless, nothing to the caller
        collect.expire(id);
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Expired));
        assertEq(l.reserve, 0);
        assertEq(l.creatorClaimable, 800_000 + 2_100_000, "creator: collect share + 70% of the reserve");
        assertEq(l.treasuryClaimable, 900_000, "treasury: 30% of the reserve");
        assertEq(l.platformClaimable, 200_000, "platform share untouched");
        assertEq(l.endedAt, block.timestamp);
        assertEq(usdc.balanceOf(address(collect)), held, "expiry moves no USDC by itself");
        assertEq(usdc.balanceOf(bob), 1_000_000_000_000, "caller received nothing");
        assertTrue(nft.closed(), "collection closed at expiry");
        assertEq(nft.totalMinted(), 4, "editions stay with their collectors");
        assertEq(nft.ownerOf(4), alice);
        assertEq(coin.totalSupply(), 0, "no coin ever minted");
        assertEq(vesting.graduatedAt(id), 0, "entitlements never vest");

        // Nothing else can happen to it.
        vm.prank(alice);
        vm.expectRevert(MomentCollect.NotCollecting.selector);
        collect.collect(id, 1);
        vm.prank(bob);
        vm.expectRevert(MomentCollect.WrongState.selector);
        collect.expire(id);
        vm.prank(address(graduation));
        vm.expectRevert(MomentCollect.WrongState.selector);
        collect.releaseReserve(id, address(graduation));
        vm.prank(alice);
        vm.expectRevert(); // NothingToClaim
        vesting.claim(id);

        // Pull-only withdrawals by the immutable beneficiaries.
        vm.prank(alice);
        vm.expectRevert(MomentCollect.NotBeneficiary.selector);
        collect.withdrawTreasury(id);
        vm.prank(platform);
        vm.expectRevert(MomentCollect.NotBeneficiary.selector);
        collect.withdrawTreasury(id);
        uint256 t0 = usdc.balanceOf(treasury);
        vm.prank(treasury);
        assertEq(collect.withdrawTreasury(id), 900_000);
        assertEq(usdc.balanceOf(treasury) - t0, 900_000);
        vm.prank(treasury);
        vm.expectRevert(MomentCollect.NothingToWithdraw.selector);
        collect.withdrawTreasury(id);
        uint256 c0 = usdc.balanceOf(creator);
        vm.prank(creator);
        assertEq(collect.withdrawCreator(id), 2_900_000);
        assertEq(usdc.balanceOf(creator) - c0, 2_900_000);
        vm.prank(platform);
        assertEq(collect.withdrawPlatform(id), 200_000);
        assertEq(usdc.balanceOf(address(collect)), 0, "every cent accounted for");
    }

    function test_expiry_with_nothing_collected_is_a_clean_close() public {
        vm.warp(factory.getMoment(id).deadline + 5 days);
        collect.expire(id);
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Expired));
        assertEq(l.creatorClaimable + l.treasuryClaimable, 0);
        assertTrue(nft.closed());
        assertEq(nft.totalMinted(), 0);
    }

    function test_expiry_split_uses_the_policy_share_snapshotted_at_publish() public {
        // Policy change to 0% creator share applies to FUTURE Moments only.
        MomentTypes.Policy memory next = _policy(THRESHOLD);
        next.expiryCreatorBps = 0;
        vm.prank(gov);
        factory.proposePolicy(next);
        vm.warp(block.timestamp + factory.POLICY_DELAY());
        factory.applyPolicy();
        (uint256 id2,,) = _publish(creator, PRICE, 0, 2);
        _collect(id, alice, 1); // old Moment: 70% share
        _collect(id2, alice, 1); // new Moment: 0% share
        vm.warp(factory.getMoment(id2).deadline);
        collect.expire(id);
        collect.expire(id2);
        assertEq(collect.ledger(id).creatorClaimable, 200_000 + 525_000);
        assertEq(collect.ledger(id).treasuryClaimable, 225_000);
        assertEq(collect.ledger(id2).creatorClaimable, 200_000);
        assertEq(collect.ledger(id2).treasuryClaimable, 750_000);
    }

    function test_completed_but_stuck_moment_expires_only_after_deadline_and_grace() public {
        uint64 deadline = factory.getMoment(id).deadline;
        graduation.setFail(true);
        vm.warp(deadline - 1 days); // completes late, so the 7-day grace runs past the deadline
        for (uint256 i = 0; i < 14; i++) _collect(id, alice, 1); // completes; graduation fails
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.GraduationPending));
        assertEq(l.stuckSince, deadline - 1 days);
        uint256 graceEnd = uint256(l.stuckSince) + MomentTypes.STUCK_GRACE; // deadline + 6 days

        // Before the deadline: never, even though it is stuck.
        vm.warp(deadline - 1);
        vm.expectRevert(MomentCollect.NotExpirable.selector);
        collect.expire(id);
        // At the deadline: grace not over -> still retriable only.
        vm.warp(deadline);
        vm.expectRevert(MomentCollect.NotExpirable.selector);
        collect.expire(id);
        vm.warp(graceEnd - 1);
        vm.expectRevert(MomentCollect.NotExpirable.selector);
        collect.expire(id);
        // Grace over (and past the deadline): anyone may wind it down.
        vm.warp(graceEnd);
        collect.expire(id);
        l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Expired));
        assertEq(l.creatorClaimable, 2_666_668 + 7_000_000, "creator: collect share + 70% of the $10 reserve");
        assertEq(l.treasuryClaimable, 3_000_000);
        assertEq(coin.totalSupply(), 0);
        assertTrue(nft.closed());
        // A late retry can no longer graduate it.
        graduation.setFail(false);
        vm.expectRevert(MomentCollect.WrongState.selector);
        graduation.graduate(id);
    }

    function test_stuck_moment_completed_early_expires_at_the_deadline() public {
        graduation.setFail(true);
        for (uint256 i = 0; i < 14; i++) _collect(id, alice, 1); // stuck on day 0: grace ends day 7, deadline day 30
        uint64 deadline = factory.getMoment(id).deadline;
        vm.warp(deadline - 1);
        vm.expectRevert(MomentCollect.NotExpirable.selector);
        collect.expire(id);
        vm.warp(deadline);
        collect.expire(id);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Expired));
    }

    function test_stuck_moment_that_recovers_before_expiry_graduates_normally() public {
        graduation.setFail(true);
        for (uint256 i = 0; i < 14; i++) _collect(id, alice, 1);
        vm.warp(factory.getMoment(id).deadline + MomentTypes.STUCK_GRACE);
        graduation.setFail(false);
        graduation.graduate(id); // permissionless retry wins the race if it lands first
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));
        vm.expectRevert(MomentCollect.WrongState.selector);
        collect.expire(id);
    }

    function test_graduated_moment_can_never_expire() public {
        _completeWithSingles(id, alice);
        vm.warp(factory.getMoment(id).deadline + 365 days);
        vm.expectRevert(MomentCollect.WrongState.selector);
        collect.expire(id);
    }
}
