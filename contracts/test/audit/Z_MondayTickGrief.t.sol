// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadBase} from "../LaunchpadBase.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {MondayGraduationExecutor} from "../../src/MondayGraduationExecutor.sol";
import {IMondayV3Factory, IMondayV3MintCallback, IMondayV3SwapCallback} from "../../src/interfaces/IMondayV3.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// A v3-style pool that models ONLY what matters for LP-1: a squatter initialized it at a wrong price and seeded
/// `dustTicks` initialized ticks with dust liquidity between that price and any realistic curve price. A swap
/// toward the curve price crosses every one of them, and a real v3 crossing writes the tick's fee-growth-outside
/// slots — modelled here as one fresh (zero -> nonzero, ~22k gas) storage write per crossed tick. With dust
/// liquidity the swap itself costs the swapper ~nothing (1 wei) and lands exactly on its price limit.
contract DustTickPool {
    address public immutable token0;
    address public immutable token1;
    int24 public constant tickSpacing = 200;
    uint24 public constant fee = 10_000;
    uint160 internal _sqrtP;
    uint256 public dustTicks;
    uint128 public liquidity;
    mapping(uint256 => uint256) internal _feeGrowthOutside; // written on every crossing

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function initialize(uint160 sqrtPriceX96) external {
        require(_sqrtP == 0, "AI");
        _sqrtP = sqrtPriceX96;
    }

    /// The squatter's setup: `n` dust positions, one per tick, across the whole range.
    function squat(uint256 n) external {
        dustTicks = n;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (_sqrtP, 0, 0, 1, 1, 0, true);
    }

    function swap(address, bool zeroForOne, int256, uint160 sqrtPriceLimitX96, bytes calldata data) external returns (int256 amount0, int256 amount1) {
        uint256 n = dustTicks;
        for (uint256 i = 0; i < n; i++) {
            _feeGrowthOutside[uint256(keccak256(abi.encode(block.number, i)))] = i + 1; // cross tick i
        }
        _sqrtP = sqrtPriceLimitX96;
        (amount0, amount1) = zeroForOne ? (int256(1), int256(0)) : (int256(0), int256(1));
        IMondayV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    }

    function mint(address, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data) external returns (uint256 amount0, uint256 amount1) {
        uint160 a = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 b = TickMath.getSqrtPriceAtTick(tickUpper);
        amount0 = SqrtPriceMath.getAmount0Delta(_sqrtP, b, amount, true);
        amount1 = SqrtPriceMath.getAmount1Delta(a, _sqrtP, amount, true);
        liquidity += amount;
        IMondayV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
    }
}

contract DustTickFactory is IMondayV3Factory {
    mapping(address => mapping(address => address)) internal _pools;

    function getPool(address a, address b, uint24) external view returns (address) {
        return _pools[a][b];
    }

    function createPool(address a, address b, uint24) public returns (address pool) {
        require(_pools[a][b] == address(0), "exists");
        pool = address(new DustTickPool(a, b));
        _pools[a][b] = pool;
        _pools[b][a] = pool;
    }

    function feeAmountTickSpacing(uint24 f) external pure returns (int24) {
        return f == 10_000 ? int24(200) : int24(0);
    }
}

/// LP-1 regression (v2 source): a squatted Monday pool packed with dust-liquidity ticks makes the Monday graduation
/// burn unbounded gas in its realign swap. In v1, `graduateFallback` forwarded 63/64 of all gas to that Monday retry,
/// so the v4 fallback starved on the last 1/64 and holders waited for the 7-day rescue. v2 caps the Monday retry at
/// GRADUATION_GAS and reserves a full GRADUATION_GAS for the v4 path, so the fallback always completes.
contract Z_MondayTickGriefTest is LaunchpadBase {
    DustTickFactory internal monday;
    MondayGraduationExecutor internal mondayExec;
    address internal squatter = makeAddr("squatter");

    function setUp() public override {
        super.setUp();
        monday = new DustTickFactory();
        mondayExec = new MondayGraduationExecutor(monday, address(factory), makeAddr("mondayVault"), makeAddr("wmon"));
        factory.setMondayExecutor(address(mondayExec));
    }

    /// A USD-quoted Monday launch whose Monday pool a squatter pre-created at a wrong price with `ticks` dust ticks;
    /// the curve is then completed, so the automatic graduation (2M gas) has already failed.
    function _squattedStuckLaunch(uint256 ticks, uint256 seed) internal returns (address t) {
        Types.TokenParams memory p = _params(address(usd), 0, false, seed);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address token, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(usd), new address[](0));
        vm.startPrank(squatter);
        DustTickPool pool = DustTickPool(monday.createPool(token, address(usd), 10_000));
        pool.initialize(TickMath.getSqrtPriceAtTick(600_000)); // absurd price, far from the curve's
        pool.squat(ticks);
        vm.stopPrank();
        vm.warp(block.timestamp + 5);
        _completeUsd(BondingCurve(c), alice);
        t = token;
    }

    function test_denseSquat_autoGraduationFails_and_uncappedMondayRetryCannotFinish() public {
        address t = _squattedStuckLaunch(1_500, 71);
        assertGt(factory.stuckSince(t), 0, "automatic graduation failed on the squatted pool");
        // The squat is real: even ~29M gas is not enough for a Monday graduation through 1,500 dust ticks.
        (bool ok,) = address(factory).call{gas: 29_000_000}(abi.encodeCall(LaunchpadFactory.graduate, (t)));
        assertFalse(ok, "Monday graduation through the dust ticks runs out of gas");
        assertEq(uint8(factory.getLaunchedToken(t).phase), uint8(Types.Phase.NotGraduated));
    }

    function test_denseSquat_fallbackStillGraduatesOnV4_within30M() public {
        address t = _squattedStuckLaunch(1_500, 72);
        uint256 g0 = gasleft();
        factory.graduateFallback{gas: 30_000_000}(t);
        uint256 used = g0 - gasleft();
        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "graduated");
        assertEq(uint8(l.graduationVenue), uint8(Types.GraduationVenue.UniswapV4), "fell back to v4");
        assertEq(factory.stuckSince(t), 0);
        // The Monday retry may burn everything above the reserved v4 budget (the caller chose to bring 30M); what
        // matters is that the reserve survives it and v4 still graduates within the call.
        assertLt(used, 30_000_000, "graduates on v4 within the gas the caller brought");
        emit log_named_uint("gas used by graduateFallback", used);
    }

    function test_fallback_withJustTheReservedGas_succeeds() public {
        address t = _squattedStuckLaunch(1_500, 73);
        // sec2: the Monday retry's floor is MONDAY_RETRY_GAS (was GRADUATION_GAS), so a low-gas caller cannot starve a
        // realignable retry and flip the venue (test/sec2/Sec2Launchpad.t.sol).
        uint256 need = factory.MONDAY_RETRY_GAS() + factory.GRADUATION_GAS() + factory.GRADUATION_GAS() / 32;
        factory.graduateFallback{gas: need + 50_000}(t); // + the call's own prologue
        assertEq(uint8(factory.getLaunchedToken(t).phase), uint8(Types.Phase.PoolCreated));
    }

    function test_fallback_rejectsTooLittleGas() public {
        address t = _squattedStuckLaunch(1_500, 74);
        vm.expectRevert(LaunchpadFactory.InsufficientGasForGraduation.selector);
        factory.graduateFallback{gas: 3_000_000}(t);
    }

    /// A light squat (a handful of dust ticks) is realignable within the budget, so the creator's Monday venue is
    /// still honoured by the fallback entry point.
    /// A heavy squat the automatic 2M budget cannot realign, but a caller bringing more gas can: the fallback's retry
    /// gets all the gas above the reserved v4 budget, so the creator's Monday venue still wins.
    function test_heavySquat_fallbackHonoursMondayWithMoreGas() public {
        address t = _squattedStuckLaunch(150, 76);
        assertGt(factory.stuckSince(t), 0, "the automatic 2M graduation could not realign it");
        factory.graduateFallback{gas: 30_000_000}(t);
        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "graduated");
        assertEq(uint8(l.graduationVenue), uint8(Types.GraduationVenue.Monday), "stayed on Monday");
    }

    function test_lightSquat_fallbackHonoursMonday() public {
        Types.TokenParams memory p = _params(address(usd), 0, false, 75);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(usd), new address[](0));
        vm.prank(squatter);
        DustTickPool pool = DustTickPool(monday.createPool(t, address(usd), 10_000));
        vm.prank(squatter);
        pool.initialize(TickMath.getSqrtPriceAtTick(600_000));
        vm.prank(squatter);
        pool.squat(5);
        vm.warp(block.timestamp + 5);
        _completeUsd(BondingCurve(c), alice); // light squat: the automatic graduation realigns and succeeds
        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "graduated automatically");
        assertEq(uint8(l.graduationVenue), uint8(Types.GraduationVenue.Monday), "on Monday, the creator's venue");
        assertEq(l.poolId, bytes32(uint256(uint160(address(pool)))), "into the (realigned) pre-existing pool");
        assertGt(pool.liquidity(), 0);
    }
}
