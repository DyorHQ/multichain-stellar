// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes, IPermit2} from "../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";
import {MaliciousCollector} from "./mocks/MaliciousCollector.sol";

contract CollectTest is MomentsBase {
    uint256 id;
    MomentCoin coin;
    MomentNFT nft;

    function setUp() public override {
        super.setUp();
        (id, coin, nft) = _publish(creator, PRICE, MAX_ALLOC_BPS, 1);
    }

    function test_collect_splits_mints_and_accrues_without_minting_coin() public {
        uint256 before = usdc.balanceOf(alice);
        MomentCollect.Quote memory q = _collect(id, alice, 2);
        assertEq(q.gross, 2 * PRICE);
        assertEq(q.editions, 2);
        assertEq(q.reserveIn, 1_500_000);
        assertEq(q.platformIn, 100_000);
        assertEq(q.creatorIn, 400_000);
        assertEq(q.excess, 0);
        assertFalse(q.terminal);
        assertEq(before - usdc.balanceOf(alice), 2 * PRICE, "exactly the gross was pulled");
        assertEq(usdc.balanceOf(address(collect)), 2 * PRICE, "collect holds every cent");
        assertEq(nft.balanceOf(alice), 2);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
        assertEq(nft.totalMinted(), 2);
        assertEq(vesting.entitlement(id, alice), q.entitlement);
        assertEq(vesting.totalEntitlement(id), q.entitlement);
        assertEq(coin.totalSupply(), 0, "no coin exists before graduation");
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(l.reserve, 1_500_000);
        assertEq(l.creatorClaimable, 400_000);
        assertEq(l.platformClaimable, 100_000);
        assertEq(l.totalGross, 2 * PRICE);
        assertEq(l.collects, 1);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Collecting));
    }

    function test_quantity_bounds() public {
        vm.prank(alice);
        vm.expectRevert(MomentCollect.BadQuantity.selector);
        collect.collect(id, 0);
        vm.prank(alice);
        vm.expectRevert(MomentCollect.BadQuantity.selector);
        collect.collect(id, MomentTypes.MAX_BATCH + 1);
        _collect(id, alice, MomentTypes.MAX_BATCH); // 20 x $1 = $20 -> completes the $10 threshold (terminal clamp)
        assertTrue(nft.totalMinted() <= MomentTypes.MAX_BATCH);
    }

    function test_ranks_are_sequential_across_collectors() public {
        _collect(id, alice, 1);
        _collect(id, bob, 3);
        _collect(id, carol, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), bob);
        assertEq(nft.ownerOf(4), bob);
        assertEq(nft.ownerOf(5), carol);
        uint256[] memory page = nft.tokensOfOwner(bob, 1, 10);
        assertEq(page.length, 2);
        assertEq(page[0], 3);
        assertEq(page[1], 4);
    }

    function test_terminal_collect_is_clamped_only_accepted_pulled_and_state_locks() public {
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        assertEq(collect.ledger(id).reserve, 9_750_000);
        uint256 before = usdc.balanceOf(bob);
        MomentCollect.Quote memory q = _collect(id, bob, 5); // asks $5, only the remainder is accepted
        assertTrue(q.terminal);
        assertEq(q.gross, 333_334);
        assertEq(q.reserveIn, 250_000);
        assertEq(q.editions, 1, "paid editions only");
        assertEq(q.excess, 5 * PRICE - 333_334);
        assertEq(before - usdc.balanceOf(bob), 333_334, "only the accepted amount was pulled");
        assertEq(nft.balanceOf(bob), 1);
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(l.reserve, 0, "reserve released to the executor at graduation");
        assertEq(graduation.poolUsdc(id), THRESHOLD, "executor received exactly the threshold");
        assertEq(uint8(l.state), uint8(MomentTypes.State.Graduated));
        assertGt(l.completedAt, 0);
        assertEq(l.stuckSince, 0);
        assertTrue(nft.closed(), "collection closed at graduation");
        vm.prank(carol);
        vm.expectRevert(MomentCollect.NotCollecting.selector);
        collect.collect(id, 1);
        vm.prank(carol);
        vm.expectRevert(MomentCollect.NotCollecting.selector);
        collect.quote(id, 1);
    }

    function test_exact_threshold_hit_without_overshoot_is_terminal_too() public {
        // 13 x $1 = 9.75; a 20-edition ask overshoots, but a price that lands exactly is terminal with no excess.
        (uint256 id2,,) = _publish(creator, 250_000, 0, 2); // $0.25 collects: reserve 187,500 each
        for (uint256 i = 0; i < 53; i++) _collect(id2, alice, 1); // 53 x 187,500 = 9,937,500
        MomentCollect.Quote memory q = _collect(id2, bob, 1); // remaining 62,500; $0.25 -> reserveIn 187,500 >= remaining -> clamp
        assertTrue(q.terminal);
        assertEq(q.reserveIn, 62_500);
        assertEq(q.gross, 83_334); // ceil(62,500 / 0.75)
        assertEq(q.editions, 1);
    }

    function test_permit2_path_requests_only_the_accepted_amount() public {
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom({permitted: IPermit2.TokenPermissions({token: address(usdc), amount: 5 * PRICE}), nonce: 1, deadline: block.timestamp + 1 hours});
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        MomentCollect.Quote memory q = collect.collectWithPermit2(id, 5, p, "");
        assertTrue(q.terminal);
        assertEq(permit2.lastRequested(), 333_334, "requested only the clamped gross from the permit");
        assertEq(before - usdc.balanceOf(bob), 333_334);
    }

    function test_permit2_rejects_wrong_token() public {
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom({permitted: IPermit2.TokenPermissions({token: address(0xBEEF), amount: PRICE}), nonce: 1, deadline: block.timestamp + 1 hours});
        vm.prank(bob);
        vm.expectRevert(MomentCollect.WrongToken.selector);
        collect.collectWithPermit2(id, 1, p, "");
    }

    function test_withdrawals_are_pull_only_by_immutable_beneficiaries() public {
        _collect(id, alice, 4); // creator 800,000 / platform 200,000
        vm.prank(alice);
        vm.expectRevert(MomentCollect.NotBeneficiary.selector);
        collect.withdrawCreator(id);
        vm.prank(creator);
        vm.expectRevert(MomentCollect.NotBeneficiary.selector);
        collect.withdrawPlatform(id);
        vm.prank(gov);
        vm.expectRevert(MomentCollect.NotBeneficiary.selector);
        collect.withdrawCreator(id);

        uint256 c0 = usdc.balanceOf(creator);
        vm.prank(creator);
        assertEq(collect.withdrawCreator(id), 800_000);
        assertEq(usdc.balanceOf(creator) - c0, 800_000);
        vm.prank(creator);
        vm.expectRevert(MomentCollect.NothingToWithdraw.selector);
        collect.withdrawCreator(id);

        uint256 p0 = usdc.balanceOf(platform);
        vm.prank(platform);
        assertEq(collect.withdrawPlatform(id), 200_000);
        assertEq(usdc.balanceOf(platform) - p0, 200_000);
        assertEq(usdc.balanceOf(address(collect)), 3_000_000, "only the reserve remains");
    }

    function test_reserve_can_only_leave_to_the_graduation_executor() public {
        _collect(id, alice, 1);
        vm.prank(gov);
        vm.expectRevert(MomentCollect.NotGraduation.selector);
        collect.releaseReserve(id, gov);
        vm.prank(creator);
        vm.expectRevert(MomentCollect.NotGraduation.selector);
        collect.releaseReserve(id, creator);
        vm.prank(address(graduation));
        vm.expectRevert(MomentCollect.WrongState.selector); // still Collecting
        collect.releaseReserve(id, address(graduation));
        vm.prank(address(graduation));
        vm.expectRevert(MomentCollect.WrongState.selector);
        collect.markGraduated(id);
    }

    function test_stuck_graduation_keeps_funds_and_is_retriable() public {
        graduation.setFail(true);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        uint256 collectUsdc = usdc.balanceOf(address(collect));
        MomentCollect.Quote memory q = _collect(id, bob, 1);
        assertTrue(q.terminal);
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.GraduationPending), "completed but not graduated");
        assertGt(l.stuckSince, 0, "stuck clock started");
        assertEq(l.reserve, THRESHOLD, "reserve intact");
        assertEq(usdc.balanceOf(address(collect)), collectUsdc + 333_334, "no funds left the contract");
        assertEq(coin.totalSupply(), 0, "still no coin");
        assertFalse(nft.closed());
        uint64 stuck = l.stuckSince;

        // Collect path is locked while pending.
        vm.prank(carol);
        vm.expectRevert(MomentCollect.NotCollecting.selector);
        collect.collect(id, 1);

        // Retry while still failing: clock is not reset.
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        vm.expectRevert(bytes("graduation down"));
        graduation.graduate(id);
        assertEq(collect.ledger(id).stuckSince, stuck);

        // Executor recovers: permissionless retry graduates.
        graduation.setFail(false);
        vm.prank(carol);
        graduation.graduate(id);
        l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Graduated));
        assertEq(l.stuckSince, 0);
        assertEq(l.reserve, 0);
        assertTrue(nft.closed());
        assertEq(coin.totalSupply() + vesting.totalEntitlement(id) + S * MAX_ALLOC_BPS / BPS, S, "supply identity at graduation");
    }

    function test_reentrancy_from_nft_receive_hook_is_blocked() public {
        MaliciousCollector attacker = new MaliciousCollector(collect);
        usdc.mint(address(attacker), 10 * PRICE);
        vm.prank(address(attacker));
        usdc.approve(address(collect), type(uint256).max);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.attack(id);
        assertEq(nft.totalMinted(), 0, "nothing minted");
        assertEq(collect.ledger(id).reserve, 0, "nothing booked");
        assertEq(usdc.balanceOf(address(attacker)), 10 * PRICE, "nothing pulled");
    }

    function test_no_coin_is_ever_minted_during_collecting() public {
        for (uint256 i = 0; i < 12; i++) _collect(id, i % 2 == 0 ? alice : bob, 1);
        assertEq(coin.totalSupply(), 0);
        assertEq(coin.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(); // NothingToClaim (not graduated)
        vesting.claim(id);
        assertEq(coin.totalSupply(), 0);
    }

    function test_coin_and_nft_minters_are_locked_down() public {
        vm.prank(gov);
        vm.expectRevert(MomentCoin.NotMinter.selector);
        coin.mint(gov, 1);
        vm.prank(creator);
        vm.expectRevert(MomentCoin.NotMinter.selector);
        coin.mint(creator, 1);
        vm.prank(address(collect)); // even the collect contract cannot mint coin
        vm.expectRevert(MomentCoin.NotMinter.selector);
        coin.mint(alice, 1);
        vm.prank(gov);
        vm.expectRevert(MomentNFT.NotCollect.selector);
        nft.mint(gov, 1);
        vm.prank(gov);
        vm.expectRevert(MomentNFT.NotCloser.selector);
        nft.close();
    }

    function test_nft_metadata_is_onchain_and_provenance_immutable() public {
        _collect(id, alice, 1);
        string memory uri = nft.tokenURI(1);
        assertEq(bytes(uri).length > 60, true);
        assertEq(bytes(nft.provenance().place), bytes("Labadi Beach, Accra"));
        assertEq(nft.provenance().mediaHash, keccak256("labadi.jpg"));
        assertEq(nft.creator(), creator);
    }
}
