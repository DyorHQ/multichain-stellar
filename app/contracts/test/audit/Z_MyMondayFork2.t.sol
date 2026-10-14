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
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

/// Audit PoCs against the REAL Monday Trade factory on a Monad mainnet fork, driven through the launchpad
/// factory exactly as production does (automatic graduation from the completing buy, 2,000,000-gas cap).
///   forge test --code-size-limit 100000000 --match-path test/audit/Z_MyMondayFork.t.sol --fork-url monad -vv
contract AuditMondayFork2Test is LaunchpadBase {
    IMondayV3Factory constant MONDAY = IMondayV3Factory(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21);
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ABIL = 0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f;
    uint24 constant FEE = 10_000;

    MondayGraduationExecutor internal monday;
    MondayFeeVault internal vault;

    function setUp() public override {
        vm.createSelectFork("monad");
        uint256 forkTime = block.timestamp;
        super.setUp();
        vm.warp(forkTime + 1); // keep pool observations monotonic
        vault = new MondayFeeVault(address(this), makeAddr("fees"));
        monday = new MondayGraduationExecutor(MONDAY, address(factory), address(vault), WMON);
        factory.setMondayExecutor(address(monday));
        // aBIL economics as deployed: $2,000 launch FDV at ~$91.74 -> phantom 21.8 aBIL, threshold x2.162
        factory.setPairEconomics(ABIL, 21_801_284_000_000_000_000, 47_140_500_000_000_000_000, 18, true);
        factory.setPairMondayOnly(ABIL, true);
    }

    function _launchMonday(address pair, uint16 tax, bool sharingOn, uint256 seed) internal returns (LaunchToken token, BondingCurve curve) {
        Types.TokenParams memory p = _params(pair, tax, sharingOn, seed);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, pair, new address[](0));
        token = LaunchToken(t);
        curve = BondingCurve(c);
        vm.warp(block.timestamp + 5); // past the snipe window
    }

    // F5. Real aBIL quote, Monday venue, holder sharing ON: buys, completion, graduation into an aBIL/TOKEN pool,
    //     and a fee harvest by the vault - all with the real compliance-gated token.
    function test_F5_real_abil_end_to_end() public {
        deal(ABIL, alice, 1_000e18);
        (LaunchToken token, BondingCurve curve) = _launchMonday(ABIL, 500, true, 32);
        vm.startPrank(alice);
        while (!curve.completed()) {
            IERC20(ABIL).approve(address(curve), 10e18);
            curve.buy(10e18, 0, alice);
        }
        vm.stopPrank();
        Types.LaunchedToken memory l = factory.getLaunchedToken(address(token));
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated));
        address pool = address(uint160(uint256(l.poolId)));
        assertEq(pool, MONDAY.getPool(address(token), ABIL, FEE));
        vault.collectFees(pool);
        assertGt(IERC20(ABIL).balanceOf(address(vault)), 0, "quote hair swept to vault");
    }

    // F6. Real aBIL: transfers between fresh addresses are allowed (denylist model, not an allowlist).
    function test_F6_real_abil_fresh_addresses_can_transfer() public {
        address a = makeAddr("fresh-a");
        address b = makeAddr("fresh-b");
        deal(ABIL, a, 100e18);
        vm.prank(a);
        IERC20(ABIL).transfer(b, 1e18);
        assertEq(IERC20(ABIL).balanceOf(b), 1e18);
    }
}
