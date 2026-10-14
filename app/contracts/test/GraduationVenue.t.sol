// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "./LaunchpadBase.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockGraduationExecutor} from "../src/mocks/MockGraduationExecutor.sol";
import {Types} from "../src/interfaces/ILaunchpad.sol";

/// @notice Covers the creator-chosen graduation venue (Uniswap v4 vs Monday Trade) and the aBIL Monday-only rule.
///         The Monday venue is exercised with a recording mock executor so no live Monad fork is needed; the real
///         Monday executor is proven separately in MondayGraduation.t.sol (fork test).
contract GraduationVenueTest is LaunchpadBase {
    MockGraduationExecutor internal mockMonday;
    MockERC20 internal abil; // stand-in for the 18-decimal RWA quote asset aBIL

    uint256 internal constant ABIL_PHANTOM = 2_000e18;
    uint256 internal constant ABIL_THRESHOLD = 4_324e18;

    function setUp() public override {
        super.setUp();
        // Wire a Monday venue (recording mock) and register aBIL as an 18-dec, Monday-only quote asset.
        mockMonday = new MockGraduationExecutor();
        factory.setMondayExecutor(address(mockMonday));

        abil = new MockERC20("SPDR 1-3M T-Bill aStock", "aBIL", 18);
        factory.setPairEconomics(address(abil), ABIL_PHANTOM, ABIL_THRESHOLD, 18, true);
        factory.setPairMondayOnly(address(abil), true);
        abil.mint(bob, 1_000_000e18);
    }

    function _paramsVenue(address pair, Types.GraduationVenue venue, uint256 saltSeed)
        internal
        view
        returns (Types.TokenParams memory p)
    {
        p = _params(pair, 0, false, saltSeed);
        p.graduationVenue = venue;
    }

    // Default venue is Uniswap v4: the launch graduates through the v4 executor, not Monday.
    function test_defaultVenueIsUniswapV4() public {
        Types.TokenParams memory p = _paramsVenue(address(0), Types.GraduationVenue.UniswapV4, 1);
        vm.prank(bob);
        (address token, address curveAddr) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        BondingCurve curve = BondingCurve(curveAddr);

        vm.warp(block.timestamp + 5); // past the 4s snipe-tax window so a non-exempt buyer can complete cheaply
        _completeNative(curve, alice);

        Types.LaunchedToken memory launch = factory.getLaunchedToken(token);
        assertEq(uint8(launch.graduationVenue), uint8(Types.GraduationVenue.UniswapV4), "venue stored as v4");
        assertEq(uint8(launch.phase), uint8(Types.Phase.PoolCreated), "graduated to a v4 pool");
        assertEq(mockMonday.calls(), 0, "Monday executor must not be called for a v4 launch");
    }

    // Monday venue: the launch routes to the Monday executor and never registers with the v4 hook.
    function test_mondayVenueRoutesToMondayExecutor() public {
        Types.TokenParams memory p = _paramsVenue(address(0), Types.GraduationVenue.Monday, 2);
        vm.prank(bob);
        (address token, address curveAddr) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        BondingCurve curve = BondingCurve(curveAddr);

        vm.warp(block.timestamp + 5); // past the 4s snipe-tax window so a non-exempt buyer can complete cheaply
        _completeNative(curve, alice);

        Types.LaunchedToken memory launch = factory.getLaunchedToken(token);
        assertEq(uint8(launch.graduationVenue), uint8(Types.GraduationVenue.Monday), "venue stored as Monday");
        assertEq(uint8(launch.phase), uint8(Types.Phase.PoolCreated), "graduated via Monday");
        assertEq(mockMonday.calls(), 1, "Monday executor called exactly once");
        assertEq(mockMonday.lastToken(), token, "swept the right token");
        assertGt(mockMonday.lastQuote(), 0, "quote swept to Monday executor");
        assertGt(mockMonday.lastTokens(), 0, "reserved tokens swept to Monday executor");
        // The v4 hook has no record of a Monday launch.
        assertFalse(hook.launches(launch.poolId).registered, "Monday launch must not register with the v4 hook");
    }

    // aBIL is Monday-only: choosing Uniswap v4 with an aBIL quote reverts at launch.
    function test_abilRejectsUniswapV4() public {
        Types.TokenParams memory p = _paramsVenue(address(abil), Types.GraduationVenue.UniswapV4, 3);
        vm.prank(bob);
        vm.expectRevert(bytes4(keccak256("PairRequiresMonday()")));
        factory.launchToken{value: LAUNCH_FEE}(p, 0, address(abil), new address[](0));
    }

    // aBIL with the Monday venue launches and graduates via the Monday executor.
    function test_abilMondayGraduates() public {
        Types.TokenParams memory p = _paramsVenue(address(abil), Types.GraduationVenue.Monday, 4);
        vm.prank(bob);
        (address token, address curveAddr) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(abil), new address[](0));
        BondingCurve curve = BondingCurve(curveAddr);

        // Complete the aBIL-quoted curve (ERC-20 pair: approve then buy).
        vm.startPrank(bob);
        while (!curve.completed()) {
            abil.approve(curveAddr, 1_000e18);
            curve.buy(1_000e18, 0, bob);
        }
        vm.stopPrank();

        Types.LaunchedToken memory launch = factory.getLaunchedToken(token);
        assertEq(uint8(launch.phase), uint8(Types.Phase.PoolCreated), "aBIL launch graduated");
        assertEq(mockMonday.calls(), 1, "aBIL graduated via Monday");
        assertEq(mockMonday.lastPairToken(), address(abil), "swept aBIL as the quote");
    }
}
