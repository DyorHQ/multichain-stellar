// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "./LaunchpadBase.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {RevertingExecutor} from "../src/mocks/RevertingExecutor.sol";
import {Types} from "../src/interfaces/ILaunchpad.sol";

contract LaunchpadTest is LaunchpadBase {
    function test_launch_setsUpTokenAndCurve() public {
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(curve)), SUPPLY);
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(q, PHANTOM);
        assertEq(t, SUPPLY);
        assertEq(curve.reservedTokens(), (SUPPLY * PHANTOM) / (PHANTOM + THRESHOLD));
        assertEq(curve.sellableTokens(), SUPPLY - curve.reservedTokens());
        assertTrue(curve.isNativeQuote());

        Types.LaunchedToken memory launch = factory.getLaunchedToken(address(token));
        assertTrue(launch.exists);
        assertEq(launch.curve, address(curve));
        assertEq(launch.deployer, alice);
        assertEq(launch.creatorFeeRecipient, creator);
        assertEq(uint8(launch.phase), uint8(Types.Phase.NotGraduated));
        assertEq(_protocolNative(), LAUNCH_FEE, "launch fee sent to protocol");

        (address deployer, string memory logo, string memory description, Types.Socials memory socials) = token.getTokenInfo();
        assertEq(deployer, alice);
        assertEq(logo, "ipfs://logo");
        assertEq(description, "Blackwell demand keeps surprising.");
        assertEq(socials.twitter, "x.com/jensen");
        assertEq(factory.launchCount(), 1);
        assertEq(factory.tokenAt(0), address(token));
        assertEq(factory.curveToToken(address(curve)), address(token));
        assertTrue(curve.snipeTaxExempt(alice));
        assertTrue(curve.snipeTaxExempt(creator));
    }

    function test_launch_reverts() public {
        Types.TokenParams memory p = _params(address(0), 0, false, 7);

        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.LaunchFeeNotPaid.selector);
        factory.launchToken{value: LAUNCH_FEE - 1}(p, 0, address(0), new address[](0));

        p.creatorTaxBps = MAX_TAX + 1;
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.CreatorTaxTooHigh.selector);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        p.creatorTaxBps = 0;

        p.expectedEconomics = bytes32(0);
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.LaunchEconomicsMismatch.selector);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        p.expectedEconomics = factory.previewLaunchEconomics(0, address(0));

        // The owner changing terms after the quote invalidates the pinned economics.
        factory.setPairEconomics(address(0), PHANTOM + 1, THRESHOLD, 18, true);
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.LaunchEconomicsMismatch.selector);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        factory.setPairEconomics(address(0), PHANTOM, THRESHOLD, 18, true);

        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        Types.TokenParams memory po = _params(address(other), 0, false, 7);
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.PairTokenNotApproved.selector);
        factory.launchToken{value: LAUNCH_FEE}(po, 0, address(other), new address[](0));

        address[] memory tooMany = new address[](33);
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.ExemptionListTooLong.selector);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), tooMany);

        factory.setWhitelistEnabled(true);
        assertFalse(factory.canLaunch(alice));
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.NotWhitelisted.selector);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        address[] memory allow = new address[](1);
        allow[0] = alice;
        factory.setWhitelisted(allow, true);
        assertTrue(factory.canLaunch(alice));
        vm.prank(alice);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        factory.setWhitelistEnabled(false);

        factory.setLaunchConfigEnabled(0, false);
        p.salt = bytes32(uint256(8));
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.LaunchConfigDisabled.selector);
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
    }

    function test_buy_and_sell_fees_and_reserves() public {
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        vm.warp(vm.getBlockTimestamp() + 10); // past the snipe window

        uint256 amount = 100 ether;
        (uint256 expectedOut, uint256 used, uint256 fee, uint256 tax, uint256 snipe, uint256 refund) = curve.quoteBuy(amount, bob);
        assertEq(used, amount);
        assertEq(fee, 1 ether);
        assertEq(tax, 0);
        assertEq(snipe, 0);
        assertEq(refund, 0);

        uint256 out = _buy(curve, bob, amount);
        assertEq(out, expectedOut);
        assertEq(out, (99 ether * SUPPLY) / (PHANTOM + 99 ether), "constant product on the net amount");
        assertEq(token.balanceOf(bob), out);
        assertEq(curve.realQuoteReserve(), 99 ether);
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(q, PHANTOM + 99 ether);
        assertEq(t, SUPPLY - out);
        assertEq(_protocolNative(), LAUNCH_FEE + 0.5 ether, "protocol keeps half the base fee");
        assertEq(_creatorNative(), 0.5 ether, "creator gets the other half");
        assertGt(curve.price(), (PHANTOM * 1e18) / SUPPLY, "price rose");

        vm.startPrank(bob);
        token.approve(address(curve), type(uint256).max);
        (uint256 quoteOut, uint256 sellFee, uint256 sellTax) = curve.quoteSell(out / 2);
        uint256 before = bob.balance;
        uint256 got = curve.sell(out / 2, 0, bob);
        vm.stopPrank();
        assertEq(got, quoteOut);
        assertEq(bob.balance - before, got);
        assertEq(sellTax, 0);
        assertGt(sellFee, 0);
        (q,) = curve.getReserves();
        assertEq(q, PHANTOM + curve.realQuoteReserve(), "quote reserve is phantom plus real");

        // Fees were auto-pushed to the creator across the buy and sell — nothing sits in escrow to claim.
        assertEq(_creatorNative(), 0.5 ether + (sellFee - sellFee / 2), "creator's half of the sell fee rounds up");
        assertEq(escrow.balanceOf(creator), 0, "auto-sent, so the escrow holds nothing");
        vm.prank(creator);
        vm.expectRevert();
        escrow.claim();
    }

    function test_snipe_tax_schedule() public {
        (, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        assertEq(curve.currentSnipeTaxBps(bob), 9800);
        assertEq(curve.currentSnipeTaxBps(alice), 0, "deployer is exempt");
        assertEq(curve.currentSnipeTaxBps(creator), 0, "fee recipient is exempt");

        (uint256 sniped,,,, uint256 snipe,) = curve.quoteBuy(100 ether, bob);
        assertEq(snipe, 98 ether);
        (uint256 clean,,,,,) = curve.quoteBuy(100 ether, alice);
        assertGt(clean, sniped * 50, "a sniper gets almost nothing");

        uint256 protocolBefore = _protocolNative();
        _buy(curve, bob, 100 ether);
        assertEq(_protocolNative() - protocolBefore, 49.5 ether, "snipe tax joins the base fee split");

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(curve.currentSnipeTaxBps(bob), 2500);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(curve.currentSnipeTaxBps(bob), 300);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(curve.currentSnipeTaxBps(bob), 30);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(curve.currentSnipeTaxBps(bob), 0);
    }

    function test_snipe_exemptions_list() public {
        address[] memory exempt = new address[](1);
        exempt[0] = carol;
        Types.TokenParams memory p = _params(address(0), 0, false, 3);
        vm.prank(alice);
        (, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), exempt);
        assertEq(BondingCurve(c).currentSnipeTaxBps(carol), 0);
        assertEq(BondingCurve(c).currentSnipeTaxBps(bob), 9800);
    }

    function test_creator_tax() public {
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(0), 500, false, 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 out = _buy(curve, bob, 100 ether);
        assertEq(_creatorNative(), 0.5 ether + 5 ether, "creator tax is on top of the base fee");
        assertEq(curve.realQuoteReserve(), 94 ether);

        vm.startPrank(bob);
        token.approve(address(curve), type(uint256).max);
        (uint256 quoteOut, uint256 fee, uint256 tax) = curve.quoteSell(out);
        uint256 got = curve.sell(out, 0, bob);
        vm.stopPrank();
        assertEq(got, quoteOut);
        assertApproxEqAbs(tax, fee * 5, 5, "5% tax next to the 1% fee");
    }

    function test_final_buy_is_clamped_and_refunded() public {
        (, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buy(curve, bob, 15_000 ether);
        assertEq(curve.realQuoteReserve(), 14_850 ether);
        uint256 remaining = THRESHOLD - 14_850 ether;
        (, uint256 used,,,, uint256 refund) = curve.quoteBuy(5_000 ether, bob);
        assertEq(used + refund, 5_000 ether);
        assertEq(used, (remaining * 10_000 + 9_899) / 9_900, "gross rounded up so the net covers the gap");

        uint256 before = bob.balance;
        vm.prank(bob);
        curve.buy{value: 5_000 ether}(5_000 ether, 0, bob);
        assertEq(before - bob.balance, used, "unused quote refunded");
        assertTrue(curve.completed());
        assertTrue(curve.swept(), "graduated in the same transaction");
        assertEq(uint8(factory.getLaunchedToken(factory.tokenAt(0)).phase), uint8(Types.Phase.PoolCreated));
        vm.prank(bob);
        vm.expectRevert(BondingCurve.CurveNotTrading.selector);
        curve.buy{value: 1 ether}(1 ether, 0, bob);
    }

    function test_holder_fee_sharing_accounting() public {
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(0), 0, true, 1);
        assertEq(token.holderFeeSharing(), address(sharing));
        vm.warp(vm.getBlockTimestamp() + 10);

        uint256 bobTokens = _buy(curve, bob, 100 ether);
        // Rewards are queued and released at the first touch of a LATER block (flash-loan-resistant, see
        // HolderFeeSharing); advancing one block makes bob's own 0.5 MON of creator fees claimable.
        vm.roll(vm.getBlockNumber() + 1);
        assertApproxEqAbs(sharing.pendingRewards(address(token), bob), 0.5 ether, 1);
        assertEq(_creatorNative(), 0, "creator wallet receives nothing when sharing is on");

        uint256 carolTokens = _buy(curve, carol, 100 ether);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 total = sharing.pendingRewards(address(token), bob) + sharing.pendingRewards(address(token), carol);
        assertApproxEqAbs(total, 1 ether, 2);
        // second reward split pro-rata by holdings at the time
        uint256 carolExpected = (0.5 ether * carolTokens) / (bobTokens + carolTokens);
        assertApproxEqAbs(sharing.pendingRewards(address(token), carol), carolExpected, 1e6);
        assertEq(sharing.pendingRewards(address(token), address(curve)), 0, "the curve is excluded");

        // moving tokens moves future rewards, not past ones
        vm.prank(bob);
        token.transfer(dave, bobTokens / 2);
        uint256 bobBefore = sharing.pendingRewards(address(token), bob);
        _buy(curve, alice, 100 ether);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(sharing.pendingRewards(address(token), dave), 0);
        assertGt(sharing.pendingRewards(address(token), bob), bobBefore);

        uint256 pending = sharing.pendingRewards(address(token), bob);
        uint256 balBefore = bob.balance;
        vm.prank(bob);
        uint256 claimed = sharing.claim(address(token));
        assertEq(claimed, pending);
        assertEq(bob.balance - balBefore, pending);
        assertEq(sharing.pendingRewards(address(token), bob), 0);
    }

    function test_takeover_timelock_and_creator_transfer() public {
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        address community = makeAddr("community");

        vm.prank(bob);
        vm.expectRevert(LaunchpadFactory.NotOwner.selector);
        factory.proposeCreatorFeeRecipient(address(token), community);

        factory.proposeCreatorFeeRecipient(address(token), community);
        vm.expectRevert(LaunchpadFactory.TimelockNotElapsed.selector);
        factory.executeCreatorFeeRecipientChange(address(token));
        vm.warp(vm.getBlockTimestamp() + 3 days);
        factory.executeCreatorFeeRecipientChange(address(token));
        assertEq(curve.creatorFeeRecipient(), community);
        assertEq(factory.getLaunchedToken(address(token)).creatorFeeRecipient, community);

        factory.proposeCreatorFeeRecipient(address(token), creator);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(LaunchpadFactory.TimelockExpired.selector);
        factory.executeCreatorFeeRecipientChange(address(token));

        vm.prank(bob);
        vm.expectRevert(LaunchpadFactory.NotCreatorFeeRecipient.selector);
        factory.transferCreatorFeeRecipient(address(token), bob);
        vm.prank(community);
        factory.transferCreatorFeeRecipient(address(token), creator);
        assertEq(curve.creatorFeeRecipient(), creator);
        assertTrue(curve.snipeTaxExempt(creator));
    }

    function test_completing_buy_needs_gas_for_graduation() public {
        (, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        _buy(curve, bob, 15_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.prank(bob);
        vm.expectRevert(LaunchpadFactory.InsufficientGasForGraduation.selector);
        curve.buy{value: 5_000 ether, gas: 1_500_000}(5_000 ether, 0, bob);
        assertFalse(curve.completed(), "an under-gassed final buy is rejected instead of stranding the launch");
        _buy(curve, bob, 5_000 ether);
        assertEq(uint8(factory.getLaunchedToken(address(curve.token())).phase), uint8(Types.Phase.PoolCreated));
    }

    function test_rescue_after_failed_graduation() public {
        // Executors are frozen after the first launch, so swap in the reverting executor BEFORE launching
        // (modules are still mutable while zero launches exist) to induce a failed graduation.
        RevertingExecutor broken = new RevertingExecutor();
        factory.setModules(address(hook), address(broken), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        vm.warp(vm.getBlockTimestamp() + 10);

        _buy(curve, bob, 15_000 ether);
        vm.expectEmit(true, false, false, false, address(factory));
        emit LaunchpadFactory.AutoGraduationFailed(address(token));
        _buy(curve, bob, 5_000 ether);
        assertTrue(curve.completed());
        assertFalse(curve.swept(), "funds stayed in the curve");
        assertEq(curve.realQuoteReserve(), THRESHOLD);
        assertGt(factory.stuckSince(address(token)), 0);

        vm.expectRevert(LaunchpadFactory.NotStuck.selector);
        factory.rescue(address(token));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        factory.rescue(address(token));
        assertEq(uint8(factory.getLaunchedToken(address(token)).phase), uint8(Types.Phase.Rescued));
        assertTrue(curve.rescued());

        vm.prank(bob);
        vm.expectRevert(BondingCurve.CurveNotTrading.selector);
        curve.buy{value: 1 ether}(1 ether, 0, bob);

        uint256 held = token.balanceOf(bob);
        (uint256 quoteOut, uint256 fee, uint256 tax) = curve.quoteSell(held);
        assertEq(fee + tax, 0, "rescue sells are fee-free");
        vm.startPrank(bob);
        token.approve(address(curve), held);
        uint256 got = curve.sell(held, 0, bob);
        vm.stopPrank();
        assertEq(got, quoteOut);
        assertApproxEqAbs(got, THRESHOLD, 1e6, "everyone can exit at the curve price");

        // Executors are locked once a launch exists: even the owner cannot swap the (broken) executor back out.
        vm.expectRevert(LaunchpadFactory.ModulesLocked.selector);
        factory.setModules(address(hook), address(executor), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));
        // And a rescued launch can never graduate regardless.
        vm.expectRevert(LaunchpadFactory.WrongGraduationPhase.selector);
        factory.graduate(address(token));
    }

    function test_router_launchAndBuy_native() public {
        Types.TokenParams memory p = _params(address(0), 0, false, 1);
        address[] memory none;
        vm.prank(bob);
        (address t, address c, uint256 out) = router.launchAndBuy{value: LAUNCH_FEE + 100 ether}(p, 0, address(0), 100 ether, 0, bob, none);
        assertGt(out, 0);
        assertEq(LaunchToken(t).balanceOf(bob), out);
        assertEq(out, (99 ether * SUPPLY) / (PHANTOM + 99 ether), "no snipe tax for the deployer at second zero");
        assertEq(factory.getLaunchedToken(t).deployer, bob);
        assertEq(BondingCurve(c).realQuoteReserve(), 99 ether);
        assertEq(address(router).balance, 0);
    }

    function test_router_launchAndBuy_over_threshold_refunds_and_graduates() public {
        Types.TokenParams memory p = _params(address(0), 0, false, 2);
        address[] memory none;
        uint256 before = bob.balance;
        vm.prank(bob);
        (address t,,) = router.launchAndBuy{value: LAUNCH_FEE + 20_000 ether}(p, 0, address(0), 20_000 ether, 0, bob, none);
        uint256 used = (THRESHOLD * 10_000 + 9_899) / 9_900;
        assertEq(before - bob.balance, LAUNCH_FEE + used, "only the clamped amount was kept");
        assertEq(uint8(factory.getLaunchedToken(t).phase), uint8(Types.Phase.PoolCreated));
    }

    function test_router_launchAndBuy_erc20_pair() public {
        Types.TokenParams memory p = _params(address(usd), 0, false, 1);
        address[] memory none;
        vm.startPrank(alice);
        usd.approve(address(router), 100e6);
        (address t,, uint256 out) = router.launchAndBuy{value: LAUNCH_FEE}(p, 0, address(usd), 100e6, 0, alice, none);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(LaunchToken(t).balanceOf(alice), out);
        assertEq(usd.balanceOf(address(router)), 0);
    }

    function test_custom_pair_trading_and_claims() public {
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(usd), 200, false, 1);
        assertFalse(curve.isNativeQuote());
        vm.warp(vm.getBlockTimestamp() + 10);

        uint256 out = _buyUsd(curve, bob, 100e6);
        assertGt(out, 0);
        assertEq(curve.realQuoteReserve(), 97e6);
        assertEq(_protocolToken(address(usd)), 0.5e6);
        assertEq(_creatorToken(address(usd)), 2.5e6);

        vm.startPrank(bob);
        token.approve(address(curve), out);
        uint256 usdBefore = usd.balanceOf(bob);
        uint256 got = curve.sell(out, 0, bob);
        vm.stopPrank();
        assertEq(usd.balanceOf(bob) - usdBefore, got);

        // usd fees auto-pushed to the creator across the buy and sell — nothing to claim.
        assertGt(_creatorToken(address(usd)), 2.5e6);
        vm.prank(creator);
        vm.expectRevert();
        escrow.claimToken(address(usd));
        vm.prank(bob);
        vm.expectRevert(BondingCurve.UnexpectedNativeValue.selector);
        curve.buy{value: 1}(100e6, 0, bob);
    }

    function testFuzz_roundtrip_never_profits(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1e9, 10_000 ether);
        (LaunchToken token, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 before = bob.balance;
        uint256 out = _buy(curve, bob, amount);
        vm.startPrank(bob);
        token.approve(address(curve), out);
        curve.sell(out, 0, bob);
        vm.stopPrank();
        assertLe(bob.balance, before, "round trip pays fees, never profits");
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(q, PHANTOM + curve.realQuoteReserve());
        assertEq(t + token.balanceOf(bob), SUPPLY);
    }

    function test_getLaunches_paging() public {
        _launch(alice, address(0), 0, false, 1);
        _launch(bob, address(0), 0, false, 1);
        _launch(carol, address(usd), 0, false, 1);
        address[] memory page = factory.getLaunches(1, 5);
        assertEq(page.length, 2);
        assertEq(factory.getLaunchedToken(page[0]).deployer, bob);
        assertEq(factory.getLaunchedToken(page[1]).pairToken, address(usd));
        assertEq(page[1], factory.tokenAt(2));
        assertEq(factory.getLaunches(3, 5).length, 0);
    }

    function test_fee_push_falls_back_to_escrow_on_a_reverting_recipient() public {
        // Point protocol fees at a contract that reverts on receiving native.
        RejectNative bad = new RejectNative();
        factory.setFeePolicy(address(bad), PROTOCOL_SHARE);

        // The launch still succeeds; its fee could not be pushed, so it is safely booked as claimable in the escrow.
        (, BondingCurve curve) = _launch(alice, address(0), 0, false, 1);
        assertEq(escrow.balanceOf(address(bad)), LAUNCH_FEE, "unpushable launch fee fell back to escrow, launch not bricked");

        // A trade also succeeds even though the protocol fee cannot be pushed to `bad`.
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 out = _buy(curve, bob, 100 ether);
        assertGt(out, 0, "buyer still received tokens");
        assertEq(escrow.balanceOf(address(bad)), LAUNCH_FEE + 0.5 ether, "protocol share fell back too; trade not DoS'd");
    }
}

/// Rejects any native transfer, to prove fee pushes fall back to the escrow instead of bricking the payer's tx.
contract RejectNative {
    receive() external payable {
        revert("no native");
    }
}
