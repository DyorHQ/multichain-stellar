// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "../LaunchpadBase.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockGraduationExecutor} from "../../src/mocks/MockGraduationExecutor.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

/// Regression tests for the 2026-09-15 audit fixes (unit, no fork). Each test previously demonstrated a bug and
/// now asserts the fixed behaviour.
contract AuditUnitTest is LaunchpadBase {
    // L-1. Second-0 with the max creator tax (10%): 1% + 10% + 98% = 109% would panic (or 100% -> zero tokens).
    //      The snipe portion is now clamped to keep the total < 100%, so the buy always returns tokens.
    function test_U1_second0_max_tax_buy_is_clamped_not_reverting() public {
        (, BondingCurve curve) = _launch(bob, address(0), MAX_TAX, false, 11);
        vm.prank(alice);
        uint256 out = curve.buy{value: 1 ether}(1 ether, 0, alice);
        assertGt(out, 0, "buyer still receives tokens instead of an arithmetic revert");
        (uint256 q,,,,,) = curve.quoteBuy(1 ether, alice);
        assertGt(q, 0, "quoteBuy no longer panics");
    }

    // L-1. Second-0 with a 1% creator tax previously totalled exactly 100% and handed out ZERO tokens.
    function test_U2_second0_buy_returns_tokens_not_zero() public {
        (LaunchToken token, BondingCurve curve) = _launch(bob, address(0), 100, false, 12);
        vm.prank(alice);
        uint256 out = curve.buy{value: 1 ether}(1 ether, 0, alice);
        assertGt(out, 0, "buyer receives tokens; no 100%-tax zero-token buy");
        assertEq(token.balanceOf(alice), out);
    }

    // M-1. The protocol fee share is pinned at launch. The owner cannot rewrite an existing launch's split.
    function test_U3_owner_cannot_change_fee_split_of_existing_launch() public {
        (, BondingCurve curve) = _launch(bob, address(0), 0, false, 13);
        vm.warp(block.timestamp + 5);
        factory.setFeePolicy(protocol, 10_000); // owner tries to grab 100% of the base fee, after the fact
        uint256 p0 = _protocolNative();
        uint256 c0 = _creatorNative();
        _buy(curve, alice, 100 ether);
        assertEq(_creatorNative() - c0, 0.5 ether, "creator still receives its launch-pinned half of the 1% base fee");
        assertEq(_protocolNative() - p0, 0.5 ether, "protocol cannot retroactively take the whole base fee");
    }

    // L-2. The router now exempts the dev-buy recipient from the snipe tax, like the deployer.
    function test_U4_router_recipient_is_snipe_exempt() public {
        Types.TokenParams memory p = _params(address(0), 0, false, 14);
        vm.prank(bob);
        (,, uint256 outCarol) = router.launchAndBuy{value: LAUNCH_FEE + 10 ether}(p, 0, address(0), 10 ether, 0, carol, new address[](0));
        Types.TokenParams memory p2 = _params(address(0), 0, false, 15);
        vm.prank(bob);
        (,, uint256 outBob) = router.launchAndBuy{value: LAUNCH_FEE + 10 ether}(p2, 0, address(0), 10 ether, 0, bob, new address[](0));
        assertApproxEqRel(outCarol, outBob, 1e15, "recipient no longer pays the 98% snipe tax");
    }

    // Gas: auto-graduation still fits the 2M cap for the worst v4 config (ERC-20 pair + sharing + max tax).
    function test_U5_auto_graduation_fits_gas_cap_usd_sharing() public {
        (LaunchToken token, BondingCurve curve) = _launch(bob, address(usd), MAX_TAX, true, 16);
        vm.warp(block.timestamp + 5);
        _completeUsd(curve, alice);
        assertEq(uint8(factory.getLaunchedToken(address(token)).phase), uint8(Types.Phase.PoolCreated), "auto-graduated");
        assertEq(factory.stuckSince(address(token)), 0);
    }

    function test_U5b_auto_graduation_fits_gas_cap_native_sharing() public {
        (LaunchToken token, BondingCurve curve) = _launch(bob, address(0), MAX_TAX, true, 17);
        vm.warp(block.timestamp + 5);
        _completeNative(curve, alice);
        assertEq(uint8(factory.getLaunchedToken(address(token)).phase), uint8(Types.Phase.PoolCreated), "auto-graduated");
    }

    // L-4. The Monday executor (and its position owner) are now excluded from holder-fee accounting.
    function test_U6_monday_executor_excluded_from_holder_accounting() public {
        MockGraduationExecutor mock = new MockGraduationExecutor();
        factory.setMondayExecutor(address(mock));
        Types.TokenParams memory p = _params(address(0), 0, true, 18);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        vm.warp(block.timestamp + 5);
        _completeNative(BondingCurve(c), alice);
        (,,, uint256 eligible,,) = sharing.pools(t);
        assertGt(LaunchToken(t).balanceOf(address(mock)), 0, "executor holds the reserved supply");
        assertTrue(sharing.excluded(t, address(mock)), "executor is excluded");
        assertEq(eligible, LaunchToken(t).balanceOf(alice), "only real holders are eligible");
    }

    // L-3. Pointing the creator fee recipient at address(0) (which would burn the fees) is now rejected.
    function test_U7_fee_recipient_zero_is_rejected() public {
        (LaunchToken token,) = _launch(bob, address(0), MAX_TAX, false, 19);
        vm.warp(block.timestamp + 5);
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.ZeroAddress.selector);
        factory.transferCreatorFeeRecipient(address(token), address(0));
        // The community-takeover proposal path rejects it too.
        vm.expectRevert(LaunchpadFactory.ZeroAddress.selector);
        factory.proposeCreatorFeeRecipient(address(token), address(0));
    }

    // Hardening: an approved quote asset with a zero phantom reserve or zero graduation threshold is rejected
    // (a zero phantom would sell the whole supply for 1 wei; a zero threshold would complete on the first buy).
    function test_U8_zero_pair_economics_rejected() public {
        vm.expectRevert(LaunchpadFactory.InvalidEconomics.selector);
        factory.setPairEconomics(address(0xBEEF), 0, THRESHOLD, 18, true);
        vm.expectRevert(LaunchpadFactory.InvalidEconomics.selector);
        factory.setPairEconomics(address(0xBEEF), PHANTOM, 0, 18, true);
        // Unapproving with zeros is fine (it just disables the pair).
        factory.setPairEconomics(address(0xBEEF), 0, 0, 18, false);
    }

    // Hardening: fee bounds hold per launch regardless of the order the owner changed things in. A pool fee that
    // could reach 100% with the max creator tax is rejected at config time (it would brick every v4 swap and lock
    // holders in), and raising the max creator tax later cannot smuggle a >= 100% base or pool fee into a launch.
    function test_U9_fee_bounds_are_enforced_per_launch() public {
        uint16[] memory schedule = new uint16[](0);
        vm.expectRevert(LaunchpadFactory.InvalidBps.selector);
        factory.addLaunchConfig(
            Types.LaunchConfig({supply: SUPPLY, curveFeeBps: 100, poolFeeBps: 9_000, tickSpacing: 60, snipeTaxSchedule: schedule, enabled: true})
        );
        factory.setMaxCreatorTaxBps(9_950);
        Types.TokenParams memory p = _params(address(0), 9_950, false, 61);
        vm.prank(bob);
        vm.expectRevert(LaunchpadFactory.InvalidBps.selector);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
    }
}
