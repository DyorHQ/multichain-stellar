// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

contract VestingTest is MomentsBase {
    uint256 id;
    MomentCoin coin;
    MomentNFT nft;
    uint256 aliceEnt;

    function setUp() public override {
        super.setUp();
        (id, coin, nft) = _publish(creator, PRICE, MAX_ALLOC_BPS, 1);
        for (uint256 i = 0; i < 10; i++) _collect(id, alice, 1);
        aliceEnt = vesting.entitlement(id, alice);
        assertGt(aliceEnt, 0);
    }

    function _graduate() internal {
        _completeWithSingles(id, bob);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));
    }

    function test_only_collect_can_accrue_and_only_graduation_can_activate() public {
        vm.prank(alice);
        vm.expectRevert(MomentVesting.NotCollect.selector);
        vesting.accrue(id, alice, 1);
        vm.prank(gov);
        vm.expectRevert(MomentVesting.NotGraduation.selector);
        vesting.activate(id);
        _graduate();
        vm.prank(address(graduation));
        vm.expectRevert(MomentVesting.AlreadyGraduated.selector);
        vesting.activate(id);
        vm.prank(address(collect));
        vm.expectRevert(MomentVesting.AlreadyGraduated.selector);
        vesting.accrue(id, alice, 1);
    }

    function test_nothing_claimable_before_graduation() public {
        (uint256 c, uint256 cr) = vesting.claimable(id, alice);
        assertEq(c + cr, 0);
        vm.prank(alice);
        vm.expectRevert(MomentVesting.NothingToClaim.selector);
        vesting.claim(id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        assertEq(vesting.claimAll(ids), 0);
        assertEq(coin.totalSupply(), 0);
    }

    function test_collector_schedule_60_80_100_exact_boundaries() public {
        _graduate();
        uint64 g = vesting.graduatedAt(id);
        assertEq(g, uint64(block.timestamp));
        assertEq(vesting.collectorVestedBps(id), 6_000);
        (uint256 c,) = vesting.claimable(id, alice);
        assertEq(c, aliceEnt * 6_000 / BPS);
        vm.prank(alice);
        assertEq(vesting.claim(id), aliceEnt * 6_000 / BPS);
        assertEq(coin.balanceOf(alice), aliceEnt * 6_000 / BPS);
        vm.prank(alice);
        vm.expectRevert(MomentVesting.NothingToClaim.selector);
        vesting.claim(id);

        vm.warp(g + MomentTypes.MONTH - 1);
        assertEq(vesting.collectorVestedBps(id), 6_000, "just before month 1: still 60%");
        (c,) = vesting.claimable(id, alice);
        assertEq(c, 0);

        vm.warp(g + MomentTypes.MONTH);
        assertEq(vesting.collectorVestedBps(id), 8_000);
        (c,) = vesting.claimable(id, alice);
        assertEq(c, aliceEnt * 8_000 / BPS - aliceEnt * 6_000 / BPS);
        vm.prank(alice);
        vesting.claim(id);

        vm.warp(g + 2 * MomentTypes.MONTH);
        assertEq(vesting.collectorVestedBps(id), BPS);
        vm.prank(alice);
        vesting.claim(id);
        assertEq(coin.balanceOf(alice), aliceEnt, "the full entitlement, no dust stranded");
        assertEq(vesting.claimed(id, alice), aliceEnt);

        vm.warp(g + 365 days);
        (c,) = vesting.claimable(id, alice);
        assertEq(c, 0, "nothing more, ever");
    }

    function test_creator_schedule_20_plus_16_per_month_capped_at_5() public {
        _graduate();
        uint64 g = vesting.graduatedAt(id);
        uint256 alloc = vesting.creatorAllocation(id);
        assertEq(alloc, S / 10);
        (, uint256 cr) = vesting.claimable(id, creator);
        assertEq(cr, alloc * 2_000 / BPS);
        uint256 expectedTotal = alloc * 2_000 / BPS;
        vm.prank(creator);
        assertEq(vesting.claim(id), expectedTotal);
        for (uint256 m = 1; m <= 5; m++) {
            vm.warp(g + m * MomentTypes.MONTH - 1);
            (, cr) = vesting.claimable(id, creator);
            assertEq(cr, 0, "cliff not reached");
            vm.warp(g + m * MomentTypes.MONTH);
            assertEq(vesting.creatorVestedBps(id), 2_000 + 1_600 * m);
            (, cr) = vesting.claimable(id, creator);
            assertEq(cr, alloc * (2_000 + 1_600 * m) / BPS - expectedTotal);
            vm.prank(creator);
            expectedTotal += vesting.claim(id);
        }
        assertEq(expectedTotal, alloc, "100% at month 5");
        assertEq(coin.balanceOf(creator), alloc);
        vm.warp(g + 24 * MomentTypes.MONTH);
        assertEq(vesting.creatorVestedBps(id), BPS, "capped");
        (, cr) = vesting.claimable(id, creator);
        assertEq(cr, 0);
    }

    function test_creator_who_also_collected_claims_both_tranches() public {
        _collect(id, creator, 2);
        uint256 creatorEnt = vesting.entitlement(id, creator);
        assertGt(creatorEnt, 0);
        _graduate();
        (uint256 c, uint256 cr) = vesting.claimable(id, creator);
        assertEq(c, creatorEnt * 6_000 / BPS);
        assertEq(cr, vesting.creatorAllocation(id) * 2_000 / BPS);
        vm.prank(creator);
        assertEq(vesting.claim(id), c + cr);
    }

    function test_claimAll_sweeps_across_moments_and_skips_ungraduated() public {
        (uint256 id2,,) = _publish(creator, PRICE, MAX_ALLOC_BPS, 2);
        (uint256 id3,,) = _publish(creator, PRICE, 0, 3);
        _collect(id2, alice, 3);
        _collect(id3, alice, 1);
        _graduate(); // id
        _completeWithSingles(id2, bob); // id2 graduates; id3 stays collecting
        uint256[] memory ids = new uint256[](3);
        ids[0] = id;
        ids[1] = id2;
        ids[2] = id3;
        uint256 expected = vesting.entitlement(id, alice) * 6_000 / BPS + vesting.entitlement(id2, alice) * 6_000 / BPS;
        vm.prank(alice);
        assertEq(vesting.claimAll(ids), expected);
        assertEq(coin.balanceOf(alice), vesting.entitlement(id, alice) * 6_000 / BPS);
        assertEq(vesting.claimed(id3, alice), 0, "ungraduated moment untouched");
    }

    function test_full_distribution_ends_exactly_at_S() public {
        _collect(id, carol, 2); // $2 -> reserve 9.0 of 10; bob's singles then complete it
        _graduate();
        vm.warp(block.timestamp + 6 * MomentTypes.MONTH);
        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(who[i]);
            vesting.claim(id);
        }
        vm.prank(creator);
        vesting.claim(id);
        assertEq(coin.totalSupply(), S, "pool seed + every entitlement + creator allocation == S");
        assertEq(vesting.totalMinted(id), vesting.totalEntitlement(id) + vesting.creatorAllocation(id));
        assertEq(coin.totalSupply(), graduation.poolCoins(id) + vesting.totalMinted(id));
    }
}
