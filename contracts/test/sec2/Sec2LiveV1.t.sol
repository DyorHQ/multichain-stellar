// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {V1LaunchpadFactory} from "./V1LaunchpadFactory.sol";
import {KeepEverythingExecutor} from "./Sec2Launchpad.t.sol";
import {DustTickFactory, DustTickPool} from "../audit/Z_MondayTickGrief.t.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {FeeEscrow} from "../../src/FeeEscrow.sol";
import {HolderFeeSharing} from "../../src/HolderFeeSharing.sol";
import {LaunchLocker} from "../../src/LaunchLocker.sol";
import {MemeHook} from "../../src/MemeHook.sol";
import {GraduationExecutor} from "../../src/GraduationExecutor.sol";
import {MondayGraduationExecutor} from "../../src/MondayGraduationExecutor.sol";
import {LaunchAndBuyRouter} from "../../src/LaunchAndBuyRouter.sol";
import {LaunchDeployer} from "../../src/LaunchDeployer.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Types, ILaunchpadFactory} from "../../src/interfaces/ILaunchpad.sol";
import {HookAddress} from "../../src/libraries/HookAddress.sol";

/// sec2: what the LIVE (v1) launchpad factory does, on a copy of its deployed source (V1LaunchpadFactory.sol) wired to
/// the same module contracts as the unit suites. These tests document live behaviour that the keepers and the owner
/// runbook rely on; the v2 fixes are covered in Sec2Launchpad.t.sol.
contract Sec2LiveV1Test is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SUPPLY = 1_000_000_000e18;

    V1LaunchpadFactory internal v1;
    DustTickFactory internal monday;
    MockERC20 internal usd;
    MockERC20 internal abil;
    MemeHook internal hook;
    GraduationExecutor internal executor;
    LaunchLocker internal locker;
    FeeEscrow internal escrow;
    HolderFeeSharing internal sharing;
    LaunchAndBuyRouter internal router;
    LaunchDeployer internal launchDeployer;

    address internal protocol = makeAddr("protocol");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal squatter = makeAddr("squatter");

    function setUp() public {
        vm.warp(1_780_000_000);
        deployFreshManagerAndRouters();
        v1 = new V1LaunchpadFactory(manager, protocol, 1 ether, 5000, 1000);
        escrow = new FeeEscrow();
        sharing = new HolderFeeSharing(address(v1));
        locker = new LaunchLocker(manager, address(v1));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(MemeHook).creationCode, abi.encode(manager, address(v1))));
        (, bytes32 salt) = HookAddress.mine(address(this), flags, initCodeHash, 500_000);
        hook = new MemeHook{salt: salt}(manager, address(v1));
        executor = new GraduationExecutor(manager, address(v1), address(hook), address(locker));
        router = new LaunchAndBuyRouter(ILaunchpadFactory(address(v1)));
        launchDeployer = new LaunchDeployer(address(v1));
        v1.setModules(address(hook), address(executor), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));
        monday = new DustTickFactory();
        v1.setMondayExecutor(address(new MondayGraduationExecutor(monday, address(v1), makeAddr("mondayVault"), makeAddr("wmon"))));

        uint16[] memory schedule = new uint16[](0);
        v1.addLaunchConfig(Types.LaunchConfig({supply: SUPPLY, curveFeeBps: 100, poolFeeBps: 100, tickSpacing: 60, snipeTaxSchedule: schedule, enabled: true}));
        v1.setPairEconomics(address(0), 4_000e18, 16_000e18, 18, true);
        usd = new MockERC20("USD Coin", "USDC", 6);
        v1.setPairEconomics(address(usd), 1_000e6, 4_000e6, 6, true);
        abil = new MockERC20("aStock 1-3M T-Bill", "aBIL", 18);
        v1.setPairEconomics(address(abil), 4_000e18, 16_000e18, 18, true);
        v1.setPairMondayOnly(address(abil), true);

        vm.deal(creator, 100 ether);
        vm.deal(buyer, 1_000_000 ether);
        usd.mint(buyer, 1_000_000_000e6);
        abil.mint(buyer, 1_000_000 ether);
    }

    function _launch(address pair, Types.GraduationVenue venue, uint256 seed) internal returns (address token, BondingCurve curve) {
        Types.TokenParams memory p;
        p.name = "Live";
        p.symbol = "LIVE";
        p.creatorFeeRecipient = creator;
        p.graduationVenue = venue;
        p.expectedEconomics = v1.previewLaunchEconomics(0, pair);
        p.salt = bytes32(seed);
        vm.prank(creator);
        address c;
        (token, c) = v1.launchToken{value: 1 ether}(p, 0, pair, new address[](0));
        curve = BondingCurve(c);
    }

    function _complete(BondingCurve curve, address pair) internal {
        vm.startPrank(buyer);
        if (pair == address(0)) {
            while (!curve.completed()) curve.buy{value: 3_000 ether}(3_000 ether, 0, buyer);
        } else {
            MockERC20(pair).approve(address(curve), type(uint256).max);
            uint256 step = pair == address(usd) ? 800e6 : 3_000 ether;
            while (!curve.completed()) curve.buy(step, 0, buyer);
        }
        vm.stopPrank();
    }

    function _squattedStuck(address pair, uint256 ticks, uint256 seed) internal returns (address token, BondingCurve curve) {
        (token, curve) = _launch(pair, Types.GraduationVenue.Monday, seed);
        vm.startPrank(squatter);
        DustTickPool pool = DustTickPool(monday.createPool(token, pair, 10_000));
        pool.initialize(TickMath.getSqrtPriceAtTick(600_000));
        pool.squat(ticks);
        vm.stopPrank();
        _complete(curve, pair);
        assertGt(v1.stuckSince(token), 0, "the automatic 2M-gas graduation failed");
    }

    /// LP-1 as reported ("the v4 path starves on the last 1/64") is overstated for the live factory: the out-of-gas
    /// happens frames below graduateFallback, each reverted frame hands back the 1/64 it kept, and with enough caller
    /// gas the fallback graduates a densely squatted Monday launch on Uniswap v4. Below that it reverts as a whole.
    /// Where exactly it starts working depends on the v4 path's cost (the audit measured ~12M for a native quote with
    /// holder sharing on real Monday bytecode); for this USDC-quoted launch on the mock pool it is between 12M and 16M.
    function test_v1_LP1_fallbackRecoversADenseSquat_withEnoughGas() public {
        (address t,) = _squattedStuck(address(usd), 1_500, 1);
        (bool retried,) = address(v1).call{gas: 29_900_000}(abi.encodeCall(V1LaunchpadFactory.graduate, (t)));
        assertFalse(retried, "the Monday retry through 1,500 dust ticks cannot finish in one transaction");

        uint256[7] memory limits = [uint256(4_000_000), 8_000_000, 12_000_000, 14_000_000, 16_000_000, 20_000_000, 29_900_000];
        for (uint256 i = 0; i < limits.length; i++) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(v1).call{gas: limits[i]}(abi.encodeCall(V1LaunchpadFactory.graduateFallback, (t)));
            emit log_named_uint(ok ? "v1 graduateFallback OK   at gas" : "v1 graduateFallback FAIL at gas", limits[i]);
            if (limits[i] <= 8_000_000) assertFalse(ok, "too little gas reverts the whole call");
            if (limits[i] >= 16_000_000) {
                assertTrue(ok, "the live fallback recovers with enough gas (the keeper sends 29.9M)");
                assertEq(uint8(v1.getLaunchedToken(t).graduationVenue), uint8(Types.GraduationVenue.UniswapV4));
                assertEq(uint8(v1.getLaunchedToken(t).phase), uint8(Types.Phase.PoolCreated));
            }
            vm.revertToState(snap);
        }
    }

    /// Why the keeper sends 29.9M: the live fallback gives its Monday retry 63/64 of the gas, so a squat that ~29.9M
    /// realigns (1,100 and 1,200 dust ticks here) graduates on Monday at 29.9M but moves to Uniswap v4 at 25M, and the
    /// creator loses the venue. Measured on the EVM gas schedule with the mock pool, not on Monad's.
    function test_v1_LP1_aSquatJustBelowOneTransaction_keepsMondayOnlyWithFullGas() public {
        uint256[2] memory densities = [uint256(1_100), 1_200];
        for (uint256 i = 0; i < densities.length; i++) {
            (address t,) = _squattedStuck(address(usd), densities[i], 10 + i);
            uint256 snap = vm.snapshotState();
            v1.graduateFallback{gas: 25_000_000}(t);
            assertEq(uint8(v1.getLaunchedToken(t).graduationVenue), uint8(Types.GraduationVenue.UniswapV4), "25M: moved to v4");
            vm.revertToState(snap);
            v1.graduateFallback{gas: 29_900_000}(t);
            assertEq(uint8(v1.getLaunchedToken(t).graduationVenue), uint8(Types.GraduationVenue.Monday), "29.9M: the creator's venue");
            assertEq(uint8(v1.getLaunchedToken(t).phase), uint8(Types.Phase.PoolCreated));
        }
    }

    /// LP-1 residual on the live factory: a Monday-only pair (aBIL) has no permissionless way out of a dense squat.
    /// Holders cannot sell, the Monday retry cannot finish, the fallback reverts PairRequiresMonday however long the
    /// launch has been stuck, and only the owner (allowV4Fallback now, or rescue after 7 days) can unfreeze it.
    function test_v1_LP1_mondayOnlyPair_isFrozenUntilTheOwnerActs() public {
        (address t, BondingCurve curve) = _squattedStuck(address(abil), 1_500, 2);
        (bool retried,) = address(v1).call{gas: 29_900_000}(abi.encodeCall(V1LaunchpadFactory.graduate, (t)));
        assertFalse(retried);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.expectRevert(V1LaunchpadFactory.PairRequiresMonday.selector);
        v1.graduateFallback{gas: 29_900_000}(t);
        vm.prank(buyer);
        vm.expectRevert(BondingCurve.CurveNotTrading.selector);
        curve.sell(1e18, 0, buyer);
        vm.expectRevert(V1LaunchpadFactory.NotStuck.selector);
        v1.rescue(t);

        v1.allowV4Fallback(t); // the owner
        v1.graduateFallback{gas: 29_900_000}(t);
        assertEq(uint8(v1.getLaunchedToken(t).phase), uint8(Types.Phase.PoolCreated));
    }

    /// The live factory freezes its modules only at the first launch (launchCount() == 0 on 0x6B1C). Until then the
    /// owner key can swap the graduation executor, the next ordinary launch freezes the swap in for good, and every
    /// graduation after that hands its whole raise to the swapped executor while the factory reports PoolCreated.
    function test_v1_moduleWindow_ownerSwapIsFrozenInByTheFirstLaunch() public {
        assertEq(v1.launchCount(), 0);
        KeepEverythingExecutor evil = new KeepEverythingExecutor();
        v1.setModules(address(hook), address(evil), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));

        (address t, BondingCurve curve) = _launch(address(0), Types.GraduationVenue.UniswapV4, 3);
        vm.expectRevert(V1LaunchpadFactory.ModulesLocked.selector);
        v1.setModules(address(hook), address(executor), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));

        vm.warp(vm.getBlockTimestamp() + 10);
        _complete(curve, address(0));
        Types.LaunchedToken memory l = v1.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "the factory reports a graduation");
        assertEq(address(evil).balance, l.sweptQuote, "the swapped executor kept the whole raise");
        (uint160 sqrtP,,,) = manager.getSlot0(v1.poolKeyOf(t).toId());
        assertEq(sqrtP, 0, "no Uniswap v4 pool exists");
    }
}
