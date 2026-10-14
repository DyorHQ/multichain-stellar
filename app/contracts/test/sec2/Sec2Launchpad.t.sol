// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "../LaunchpadBase.sol";
import {DustTickFactory, DustTickPool} from "../audit/Z_MondayTickGrief.t.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {MondayGraduationExecutor} from "../../src/MondayGraduationExecutor.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// A graduation executor that keeps whatever the factory sweeps into it and reports success.
contract KeepEverythingExecutor {
    receive() external payable {}

    function graduate(address, address, uint256, uint256, uint256, int24) external pure returns (bytes32, uint128) {
        return (bytes32(uint256(1)), 1);
    }
}

/// A quote asset that burns 1% of every transfer (fee-on-transfer).
contract FeeOnTransferToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
    }
}

/// sec2 (2026-09-27 audit follow-up) on the v2 LaunchpadFactory: the LP-1 venue override and Monday-only freeze, the
/// module window before the first launch, the snipe-tax exemption on a recipient change, and LP-6 owner-config gaps.
contract Sec2LaunchpadTest is LaunchpadBase {
    DustTickFactory internal monday;
    MondayGraduationExecutor internal mondayExec;
    MockERC20 internal abil;
    address internal squatter = makeAddr("squatter");

    function setUp() public override {
        super.setUp();
        monday = new DustTickFactory();
        mondayExec = new MondayGraduationExecutor(monday, address(factory), makeAddr("mondayVault"), makeAddr("wmon"));
        factory.setMondayExecutor(address(mondayExec));
        abil = new MockERC20("aStock 1-3M T-Bill", "aBIL", 18);
        factory.setPairEconomics(address(abil), PHANTOM, THRESHOLD, 18, true);
        factory.setPairMondayOnly(address(abil), true);
        abil.mint(alice, 1_000_000 ether);
    }

    /// A Monday launch quoted in `pair` (usd or abil) whose Monday pool a squatter pre-created at an absurd price with
    /// `ticks` dust ticks; the curve is then completed, so the automatic 2M-gas graduation has already failed.
    function _squattedStuckLaunch(address pair, uint256 ticks, uint256 seed) internal returns (address t) {
        Types.TokenParams memory p = _params(pair, 0, false, seed);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address token, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, pair, new address[](0));
        vm.startPrank(squatter);
        DustTickPool pool = DustTickPool(monday.createPool(token, pair, 10_000));
        pool.initialize(TickMath.getSqrtPriceAtTick(600_000));
        pool.squat(ticks);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 5);
        BondingCurve curve = BondingCurve(c);
        if (pair == address(usd)) {
            _completeUsd(curve, alice);
        } else {
            vm.startPrank(alice);
            abil.approve(c, type(uint256).max);
            while (!curve.completed()) curve.buy(3_000 ether, 0, alice);
            vm.stopPrank();
        }
        assertGt(factory.stuckSince(token), 0, "the automatic graduation failed on the squatted pool");
        t = token;
    }

    function _venue(address t) internal view returns (Types.GraduationVenue) {
        return factory.getLaunchedToken(t).graduationVenue;
    }

    function _phase(address t) internal view returns (Types.Phase) {
        return factory.getLaunchedToken(t).phase;
    }

    // ---------------------------------------------------------------- LP-1 (v2): low-gas venue override

    /// A heavy squat (150 dust ticks, ~3.4M gas to realign) that a well-funded retry realigns on Monday. Whoever calls
    /// `graduateFallback` must not be able to flip the creator's venue to Uniswap v4 just by sending little gas:
    /// every gas limit the call accepts has to leave the Monday retry enough to finish.
    function test_LP1_lowGasCaller_cannotOverrideARealignableMondayVenue() public {
        address t = _squattedStuckLaunch(address(usd), 150, 201);
        uint256[6] memory limits = [uint256(4_150_000), 6_000_000, 10_000_000, 16_000_000, 22_200_000, 30_000_000];
        bool graduated;
        for (uint256 i = 0; i < limits.length; i++) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(factory).call{gas: limits[i]}(abi.encodeCall(LaunchpadFactory.graduateFallback, (t)));
            if (ok) {
                graduated = true;
                assertEq(uint8(_phase(t)), uint8(Types.Phase.PoolCreated));
                assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.Monday), "a low-gas caller flipped the venue to v4");
            }
            vm.revertToState(snap);
        }
        assertTrue(graduated, "some gas limit graduates it");
    }

    /// A genuinely blocking squat (1,500 dust ticks) still falls back to Uniswap v4 within one 30M transaction.
    function test_LP1_blockingSquat_stillFallsBackToV4_within30M() public {
        address t = _squattedStuckLaunch(address(usd), 1_500, 202);
        factory.graduateFallback{gas: 30_000_000}(t);
        assertEq(uint8(_phase(t)), uint8(Types.Phase.PoolCreated));
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.UniswapV4));
    }

    // ---------------------------------------------------------------- LP-1: Monday-only quote asset liveness

    /// A dust-tick squat on a Monday-only pair (aBIL) must not freeze holders until the owner acts: once the launch
    /// has been stuck for a public delay, anyone can take the Uniswap v4 fallback.
    function test_LP1_mondayOnlyPair_hasAPublicValveAfterTheDelay() public {
        address t = _squattedStuckLaunch(address(abil), 1_500, 203);
        (bool ok,) = address(factory).call{gas: 29_900_000}(abi.encodeCall(LaunchpadFactory.graduate, (t)));
        assertFalse(ok, "the Monday retry cannot finish in one transaction");
        vm.expectRevert(LaunchpadFactory.PairRequiresMonday.selector);
        factory.graduateFallback{gas: 29_900_000}(t); // right away: the creator's (and the pair's) venue rule holds

        vm.warp(factory.stuckSince(t) + 1 days);
        vm.prank(makeAddr("anyone"));
        factory.graduateFallback{gas: 29_900_000}(t);
        assertEq(uint8(_phase(t)), uint8(Types.Phase.PoolCreated), "graduated without the owner");
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.UniswapV4));
    }

    // ---------------------------------------------------------------- module window before the first launch

    /// Once the factory is wired the way Deploy.s.sol wires it, the owner key can no longer swap a module, even
    /// though no launch exists yet. Otherwise a swapped executor would be frozen in by the first launch and keep
    /// every later graduation's raise.
    function test_modules_areSealedByTheDeployWiring_beforeAnyLaunch() public {
        vm.expectEmit(address(factory));
        emit LaunchpadFactory.ModulesSealed();
        factory.sealModules(); // Deploy.s.sol's last wiring step
        assertTrue(factory.modulesSealed());
        assertEq(factory.launchCount(), 0);
        KeepEverythingExecutor evil = new KeepEverythingExecutor();
        vm.expectRevert(LaunchpadFactory.ModulesLocked.selector);
        factory.setModules(address(hook), address(evil), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));
        vm.expectRevert(LaunchpadFactory.ModulesLocked.selector);
        factory.setMondayExecutor(address(evil));
    }

    function test_seal_needsTheModules_andIsOwnerOnly_andTheFirstLaunchSealsToo() public {
        LaunchpadFactory fresh = new LaunchpadFactory(manager, protocol, LAUNCH_FEE, PROTOCOL_SHARE, MAX_TAX);
        vm.expectRevert(LaunchpadFactory.ModulesNotSet.selector);
        fresh.sealModules();
        vm.prank(alice);
        vm.expectRevert(LaunchpadFactory.NotOwner.selector);
        factory.sealModules();
        assertFalse(factory.modulesSealed(), "a hand-wired factory is open until its first launch...");
        _launch(alice, address(0), 0, false, 207);
        assertTrue(factory.modulesSealed(), "...which seals it, as before");
        vm.expectRevert(LaunchpadFactory.ModulesLocked.selector);
        factory.setMondayExecutor(address(0));
    }

    // ---------------------------------------------------------------- LP-1 (v2) regressions

    function test_LP1_fallback_needsTheMondayRetryFloorPlusTheReserve() public {
        address t = _squattedStuckLaunch(address(usd), 1_500, 208);
        uint256 need = factory.MONDAY_RETRY_GAS() + factory.GRADUATION_GAS() + factory.GRADUATION_GAS() / 32;
        vm.expectRevert(LaunchpadFactory.InsufficientGasForGraduation.selector);
        factory.graduateFallback{gas: need - 100_000}(t);
        factory.graduateFallback{gas: need + 50_000}(t); // + the call's own prologue
        assertEq(uint8(_phase(t)), uint8(Types.Phase.PoolCreated));
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.UniswapV4), "a blocking squat still falls back on the floor alone");
    }

    /// The retry floor is a floor, not the whole budget: a squat that needs more than MONDAY_RETRY_GAS to realign
    /// (1,100 dust ticks here, between the floor and one transaction) keeps its Monday venue only when the caller
    /// sends more. At the minimum the fallback accepts it moves to Uniswap v4 (holders still get a locked pool); at
    /// 29.9M, what the keeper and the apps send, it graduates on Monday. The floor stays at 20M so the fallback is
    /// always callable under Monad's 30M per-transaction cap with room for calldata and smart-wallet overhead.
    function test_LP1_squatAboveTheRetryFloor_keepsMondayOnlyWithNearFullGas() public {
        address t = _squattedStuckLaunch(address(usd), 1_100, 211);
        uint256 floor = factory.MONDAY_RETRY_GAS() + factory.GRADUATION_GAS() + factory.GRADUATION_GAS() / 32 + 50_000;
        uint256 snap = vm.snapshotState();
        factory.graduateFallback{gas: floor}(t);
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.UniswapV4), "the minimum gas moves it to v4");
        vm.revertToState(snap);
        factory.graduateFallback{gas: 29_900_000}(t);
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.Monday), "near-full gas keeps the creator's venue");
        assertEq(uint8(_phase(t)), uint8(Types.Phase.PoolCreated));
    }

    function test_LP1_heavySquat_minimumGasFallback_keepsMonday() public {
        address t = _squattedStuckLaunch(address(usd), 150, 209);
        factory.graduateFallback{gas: factory.MONDAY_RETRY_GAS() + factory.GRADUATION_GAS() + factory.GRADUATION_GAS() / 32 + 50_000}(t);
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.Monday), "the creator's venue");
    }

    function test_LP1_mondayOnlyPair_valveOpensOnlyAfterTheFullDelay_ownerStillCanAtOnce() public {
        address t = _squattedStuckLaunch(address(abil), 1_500, 210);
        vm.warp(factory.stuckSince(t) + factory.MONDAY_ONLY_FALLBACK_DELAY() - 1);
        vm.expectRevert(LaunchpadFactory.PairRequiresMonday.selector);
        factory.graduateFallback{gas: 29_900_000}(t);
        factory.allowV4Fallback(t); // the owner does not have to wait
        factory.graduateFallback{gas: 29_900_000}(t);
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.UniswapV4));
        assertTrue(factory.launchMondayOnly(t));
    }

    // ---------------------------------------------------------------- snipe-tax exemption on a recipient change

    /// Handing the creator fee stream to a new recipient inside the snipe window must not exempt that recipient
    /// (a chain of hand-offs would otherwise exempt any number of wallets past MAX_EXEMPTIONS).
    function test_recipientChange_grantsNoSnipeTaxExemption() public {
        (, BondingCurve curve) = _launch(alice, address(0), 0, false, 204);
        address token = curve.token();
        address r2 = makeAddr("r2");
        address r3 = makeAddr("r3");
        vm.prank(creator);
        factory.transferCreatorFeeRecipient(token, r2);
        vm.prank(r2);
        factory.transferCreatorFeeRecipient(token, r3);
        assertFalse(curve.snipeTaxExempt(r2), "old hand-off target exempt");
        assertFalse(curve.snipeTaxExempt(r3), "new recipient exempt");
        assertEq(curve.currentSnipeTaxBps(r3), 9_800, "pays the opening-second snipe tax like anyone else");
        assertTrue(curve.snipeTaxExempt(creator), "the launch-time exemptions are unchanged");
    }

    // ---------------------------------------------------------------- LP-6: owner-config validation

    function test_LP6_feePolicy_rejectsTheZeroRecipient() public {
        vm.expectRevert(LaunchpadFactory.ZeroAddress.selector);
        factory.setFeePolicy(address(0), PROTOCOL_SHARE);
        vm.expectRevert(LaunchpadFactory.ZeroAddress.selector);
        new LaunchpadFactory(manager, address(0), LAUNCH_FEE, PROTOCOL_SHARE, MAX_TAX);
    }

    function test_LP6_launchConfig_rejectsATickSpacingV4CannotUse() public {
        uint16[] memory schedule = new uint16[](0);
        int24[3] memory bad = [int24(0), int24(-60), int24(32_768)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(LaunchpadFactory.InvalidTickSpacing.selector);
            factory.addLaunchConfig(
                Types.LaunchConfig({supply: SUPPLY, curveFeeBps: CURVE_FEE, poolFeeBps: POOL_FEE, tickSpacing: bad[i], snipeTaxSchedule: schedule, enabled: true})
            );
        }
    }

    /// A fee-on-transfer quote asset would book more quote than the curve received and leave it insolvent: the buy
    /// must be refused instead.
    function test_LP6_feeOnTransferQuote_isRefusedAtTheCurve() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        factory.setPairEconomics(address(fot), USD_PHANTOM, USD_THRESHOLD, 6, true);
        (, BondingCurve curve) = _launch(alice, address(fot), 0, false, 205);
        vm.warp(vm.getBlockTimestamp() + 10);
        fot.mint(bob, 1_000e6);
        vm.startPrank(bob);
        fot.approve(address(curve), type(uint256).max);
        vm.expectRevert(BondingCurve.UnsupportedQuoteToken.selector);
        curve.buy(100e6, 0, bob);
        vm.stopPrank();
    }

    /// Flagging a pair Monday-only later must not take the v4 fallback away from a Monday launch made before it.
    function test_LP6_mondayOnlyToggle_doesNotBlockAnEarlierLaunchesFallback() public {
        address t = _squattedStuckLaunch(address(usd), 1_500, 206);
        factory.setPairMondayOnly(address(usd), true);
        factory.graduateFallback{gas: 30_000_000}(t);
        assertEq(uint8(_phase(t)), uint8(Types.Phase.PoolCreated));
        assertEq(uint8(_venue(t)), uint8(Types.GraduationVenue.UniswapV4));
    }
}
