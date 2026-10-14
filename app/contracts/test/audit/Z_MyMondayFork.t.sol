// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {LaunchpadBase} from "../LaunchpadBase.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MondayGraduationExecutor} from "../../src/MondayGraduationExecutor.sol";
import {MondayFeeVault} from "../../src/MondayFeeVault.sol";
import {IMondayV3Factory, IMondayV3Pool} from "../../src/interfaces/IMondayV3.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

/// H-3 regression on the REAL Monday Trade factory (Monad fork). The bounded realign defeats the cheap
/// empty-pool squat that used to permanently brick a graduation.
///   forge test --code-size-limit 100000000 --match-path test/audit/Z_MyMondayFork.t.sol --fork-url monad -vv
contract AuditMondayForkTest is LaunchpadBase {
    IMondayV3Factory constant MONDAY = IMondayV3Factory(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21);
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    uint24 constant FEE = 10_000;

    MondayGraduationExecutor internal monday;
    MondayFeeVault internal vault;

    function setUp() public override {
        vm.createSelectFork("monad");
        uint256 forkTime = block.timestamp;
        super.setUp();
        vm.warp(forkTime + 1);
        vault = new MondayFeeVault(address(this), makeAddr("fees"));
        monday = new MondayGraduationExecutor(MONDAY, address(factory), address(vault), WMON);
        factory.setMondayExecutor(address(monday));
    }

    function _launchMonday(address pair, uint16 tax, bool sharingOn, uint256 seed) internal returns (LaunchToken token, BondingCurve curve) {
        Types.TokenParams memory p = _params(pair, tax, sharingOn, seed);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, pair, new address[](0));
        token = LaunchToken(t);
        curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);
    }

    // F1. Normal Monday auto-graduation still succeeds within the 2M gas cap.
    function test_F1_monday_auto_graduation_within_gas_cap() public {
        (LaunchToken token, BondingCurve curve) = _launchMonday(address(0), 0, false, 21);
        _completeNative(curve, alice);
        assertEq(uint8(factory.getLaunchedToken(address(token)).phase), uint8(Types.Phase.PoolCreated), "auto-graduated");
        assertEq(factory.stuckSince(address(token)), 0);
    }

    // F2a. The empty-pool squat that used to brick graduation (~555k gas) is now REALIGNED: the graduation
    //      moves the squatted price to the curve price for free (an empty pool has no liquidity to resist) and
    //      succeeds on Monday. Holders are never locked.
    function test_F2a_empty_pool_squat_is_realigned() public {
        (LaunchToken token, BondingCurve curve) = _launchMonday(address(0), 0, false, 22);
        address griefer = makeAddr("griefer");
        vm.startPrank(griefer);
        address pool = MONDAY.createPool(address(token), WMON, FEE);
        IMondayV3Pool(pool).initialize(uint160(2 ** 96)); // 1:1, nowhere near the curve price
        vm.stopPrank();

        _completeNative(curve, alice);
        Types.LaunchedToken memory l = factory.getLaunchedToken(address(token));
        // The realign fits inside the AUTOMATIC graduation (2M gas cap): no stuck state, no manual call needed.
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "auto-graduated on Monday despite the squat");
        assertEq(factory.stuckSince(address(token)), 0, "never stuck");
        (uint160 opened,,,,,,) = IMondayV3Pool(pool).slot0();
        assertTrue(opened != uint160(2 ** 96), "squat price was overridden");
        assertGt(IMondayV3Pool(pool).liquidity(), 0, "liquidity minted at the realigned price");
    }

    // F4. Native pair + holder fee sharing ON, Monday venue: auto graduation within the 2M cap.
    function test_F4_monday_auto_graduation_native_sharing_on() public {
        (LaunchToken token, BondingCurve curve) = _launchMonday(address(0), 100, true, 31);
        _completeNative(curve, alice);
        assertEq(uint8(factory.getLaunchedToken(address(token)).phase), uint8(Types.Phase.PoolCreated), "auto-graduated within the 2M cap");
    }
}
