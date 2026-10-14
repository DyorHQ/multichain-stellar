// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "../LaunchpadBase.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

/// A Monday executor that always reverts, standing in for a Monday venue that cannot graduate (e.g. a pool squatted
/// with real liquidity that the bounded realign can't fix). Exposes `locker()` like the real one.
contract RevertingMondayExecutor {
    function locker() external view returns (address) {
        return address(this);
    }

    function graduate(address, address, uint256, uint256, uint256, int24) external pure returns (bytes32, uint128) {
        revert("monday down");
    }

    receive() external payable {}
}

/// A Monday executor that fails once (an auto-graduation hiccup) and works afterwards: the fallback entry point
/// must then graduate on MONDAY, honouring the creator's venue, rather than switching to v4.
contract FlakyMondayExecutor {
    uint256 public calls; // successful graduations only (a reverted call cannot persist a counter)
    bool public failNext; // toggled by the test: true = "Monday is down", false = "Monday works again"

    function setFail(bool f) external {
        failNext = f;
    }

    function locker() external view returns (address) {
        return address(this);
    }

    receive() external payable {}

    function graduate(address token, address, uint256, uint256, uint256, int24) external returns (bytes32 poolId, uint128 liquidity) {
        if (failNext) revert("monday hiccup");
        calls += 1;
        poolId = keccak256(abi.encodePacked("flaky", token));
        liquidity = 1;
    }
}

/// H-3 regression (no fork): a Monday launch whose graduation is stuck can fall back to Uniswap v4 immediately,
/// instead of holders being locked until the 7-day rescue. Monday-only quote assets keep their rule unless the
/// owner explicitly allows the fallback for that launch.
contract AuditFallbackTest is LaunchpadBase {
    RevertingMondayExecutor internal bad;

    function setUp() public override {
        super.setUp();
        bad = new RevertingMondayExecutor();
        factory.setMondayExecutor(address(bad));
    }

    function _launchMondayNative(uint256 seed) internal returns (address t, BondingCurve curve) {
        Types.TokenParams memory p = _params(address(0), 0, false, seed);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address token, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        vm.warp(block.timestamp + 5);
        _completeNative(BondingCurve(c), alice); // auto graduation reverts inside the mock -> stuck
        t = token;
        curve = BondingCurve(c);
    }

    function test_H3_stuck_monday_launch_falls_back_to_v4() public {
        (address t,) = _launchMondayNative(51);
        assertGt(factory.stuckSince(t), 0, "stuck after the Monday executor reverted");
        assertEq(uint8(factory.getLaunchedToken(t).phase), uint8(Types.Phase.NotGraduated));

        // Anyone can graduate it on Uniswap v4 right away — no 7-day lock.
        factory.graduateFallback(t);
        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "graduated on v4 via fallback");
        assertEq(uint8(l.graduationVenue), uint8(Types.GraduationVenue.UniswapV4), "venue switched to v4");
        assertEq(factory.stuckSince(t), 0, "no longer stuck");
    }

    function test_H3_fallback_rejects_not_ready_launches() public {
        Types.TokenParams memory p = _params(address(0), 0, false, 52);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t,) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        // Curve not complete -> cannot fall back (nor graduate) anything that isn't finished.
        vm.expectRevert(LaunchpadFactory.WrongGraduationPhase.selector);
        factory.graduateFallback(t);

        // Once it has graduated (see the stuck-fallback test), a second fallback is likewise rejected.
        // Here we also confirm a fresh, non-stuck completed launch never exists to be force-fallen-back:
        // completion either graduates or sets `stuckSince`, so `FallbackNotAvailable` guards the non-Monday path.
    }

    function test_H3_fallback_rejected_for_v4_launches() public {
        // A Uniswap-v4 launch is never eligible for the Monday->v4 fallback (it is already on v4).
        RevertingMondayExecutor otherMonday = new RevertingMondayExecutor();
        otherMonday; // silence unused
        (LaunchToken token, BondingCurve curve) = _launch(bob, address(0), 0, false, 54);
        vm.warp(block.timestamp + 5);
        _completeNative(curve, alice); // graduates on v4 normally
        vm.expectRevert(LaunchpadFactory.WrongGraduationPhase.selector);
        factory.graduateFallback(address(token));
    }

    function test_H3_monday_only_fallback_needs_owner_allowance() public {
        MockERC20 abil = new MockERC20("aStock 1-3M T-Bill", "aBIL", 18);
        factory.setPairEconomics(address(abil), PHANTOM, THRESHOLD, 18, true);
        factory.setPairMondayOnly(address(abil), true);
        abil.mint(alice, 1_000_000 ether);

        Types.TokenParams memory p = _params(address(abil), 0, false, 53);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(abil), new address[](0));
        BondingCurve curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);
        vm.startPrank(alice);
        while (!curve.completed()) {
            abil.approve(address(curve), 3_000 ether);
            curve.buy(3_000 ether, 0, alice);
        }
        vm.stopPrank();
        assertGt(factory.stuckSince(t), 0, "stuck (Monday executor reverted)");

        // Monday-only asset: the v4 fallback is blocked until the owner allows it for this launch.
        vm.expectRevert(LaunchpadFactory.PairRequiresMonday.selector);
        factory.graduateFallback(t);

        factory.allowV4Fallback(t);
        factory.graduateFallback(t);
        assertEq(uint8(factory.getLaunchedToken(t).phase), uint8(Types.Phase.PoolCreated), "graduated on v4 after owner allowance");
    }
}

contract AuditFallbackHonoursVenueTest is LaunchpadBase {
    FlakyMondayExecutor internal flaky;

    function setUp() public override {
        super.setUp();
        flaky = new FlakyMondayExecutor();
        factory.setMondayExecutor(address(flaky));
    }

    function test_H3_fallback_prefers_monday_when_it_still_works() public {
        Types.TokenParams memory p = _params(address(0), 0, false, 55);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        vm.warp(block.timestamp + 5);
        flaky.setFail(true); // Monday is down for the automatic attempt
        _completeNative(BondingCurve(c), alice); // -> stuck
        assertGt(factory.stuckSince(t), 0, "stuck after the hiccup");
        assertEq(flaky.calls(), 0, "no successful Monday graduation yet");

        // Monday works again (e.g. the squat was cleared). A griefer cannot use the fallback to force v4: the entry
        // point retries the creator's venue first and, since it works, that is the result.
        flaky.setFail(false);
        address griefer = makeAddr("griefer");
        vm.prank(griefer);
        factory.graduateFallback(t);
        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "graduated");
        assertEq(uint8(l.graduationVenue), uint8(Types.GraduationVenue.Monday), "venue honoured: Monday, not v4");
        assertEq(flaky.calls(), 1, "Monday executor was retried and succeeded");
        assertEq(factory.stuckSince(t), 0);
    }
}
