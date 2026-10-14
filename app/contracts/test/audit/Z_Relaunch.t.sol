// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {HolderFeeSharing} from "../../src/HolderFeeSharing.sol";
import {MemeHook} from "../../src/MemeHook.sol";
import {MondayFeeVault} from "../../src/MondayFeeVault.sol";
import {IMondayV3Factory, IMondayV3Pool} from "../../src/interfaces/IMondayV3.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

interface IOldFactory {
    function owner() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function protocolFeeShareBps() external view returns (uint16);
    function whitelistEnabled() external view returns (bool);
    function canLaunch(address) external view returns (bool);
    function launchConfigCount() external view returns (uint256);
}

/// Minimal Monday (Uniswap-v3-style) swapper: accrues real LP fees on a pool so a vault harvest moves real tokens.
contract MondaySwapper {
    function swapIn(address pool, address tokenIn, int256 amountIn) external {
        bool zeroForOne = tokenIn == IMondayV3Pool(pool).token0();
        IMondayV3Pool(pool).swap(address(this), zeroForOne, amountIn, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) IERC20(IMondayV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IMondayV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
    }
}

interface IEscrowCredits {
    function balanceOf(address) external view returns (uint256);
    function balanceOfToken(address, address) external view returns (uint256);
}

interface IOldFactoryConfig {
    function getLaunchConfig(uint256 id) external view returns (Types.LaunchConfig memory);
}

/// The 2026-09-23 relaunch with the rotated wallets (treasury 0x5aDb…, fees 0x15ED…), end to end on a Monad fork:
/// the NEW stack recorded in deployments/143-retired-0x6B1C.json (factory 0x6B1C…, retired in the app by v2 on
/// 2026-09-28 and still open on chain; Z_LiveDeployment.t.sol runs the live record) is checked field by field and
/// exercised through every venue and quote asset, and the three RETIRED factories + their Monday fee vaults are checked
/// to be closed to new launches and to pay nothing more to the leaked treasury 0x5282… or the old fees wallet 0xf4D4….
///
///   Rehearsal (anvil fork after the relaunch script ran against it):
///     RELAUNCH_RPC=http://127.0.0.1:8545 forge test --code-size-limit 100000000 --match-path test/audit/Z_Relaunch.t.sol -vv
///   After the real mainnet run (read-only fork of mainnet):
///     forge test --code-size-limit 100000000 --match-path test/audit/Z_Relaunch.t.sol -vv
///   Optional exact price checks: EXPECT_MON_USD_E8 / EXPECT_ABIL_USD_E8 (the values the script deployed with).
contract RelaunchTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant GOVERNANCE = 0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10;
    address constant NEW_TREASURY = 0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371;
    address constant NEW_FEES = 0x15ED3bb488231213b141A2f78b62358D52235Cd7;
    address constant LEAKED_TREASURY = 0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045;
    address constant OLD_FEES = 0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48;

    address constant PM_ADDR = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address constant MONDAY_FACTORY = 0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant ABIL = 0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f;

    uint256 constant GRAD_MULT_E8 = 216_227_766;
    uint256 constant LAUNCH_FDV_USD = 2_000;

    LaunchpadFactory factory;
    HolderFeeSharing sharing;
    MemeHook hook;
    MondayFeeVault vault;
    IPoolManager constant PM = IPoolManager(PM_ADDR);
    IMondayV3Factory constant MONDAY = IMondayV3Factory(MONDAY_FACTORY);
    string json;

    address creator = makeAddr("relaunch-creator");
    address alice = makeAddr("relaunch-alice");
    address carol = makeAddr("relaunch-carol");

    function _oldFactories() internal pure returns (address[3] memory) {
        return [
            0x10F34A174d9C393a90aFf94BDED7E1Db185446D7, // 2026-09-16 audited stack (retired by this relaunch)
            0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4, // pre-audit stack
            0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea // first stack
        ];
    }

    function _oldVaults() internal pure returns (address[3] memory) {
        return [
            0x42a1C1c1d6BC2544d3f478E4d42F5b5ec75888De,
            0x97B80811036306838e48C409543F7C50bb6e494B,
            0xC154C85e8a2A73B99676C31dcE8627D67A9F376A
        ];
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("RELAUNCH_RPC", string("monad")));
        json = vm.readFile("deployments/143-retired-0x6B1C.json");
        factory = LaunchpadFactory(vm.parseJsonAddress(json, ".factory"));
        sharing = HolderFeeSharing(vm.parseJsonAddress(json, ".holderFeeSharing"));
        hook = MemeHook(payable(vm.parseJsonAddress(json, ".hook")));
        vault = MondayFeeVault(vm.parseJsonAddress(json, ".feeVault"));
        vm.deal(creator, 100 ether);
        vm.deal(alice, 5_000_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    // ------------------------------------------------------------------ the new stack, field by field

    function test_new_stack_is_the_relaunch_not_a_retired_one() public view {
        address[3] memory old = _oldFactories();
        for (uint256 i = 0; i < old.length; i++) assertTrue(address(factory) != old[i], "the relaunch record names a factory it retired");
        assertGt(address(factory).code.length, 0, "no code at the new factory");
        assertEq(vm.parseJsonUint(json, ".chainId"), 143);
        assertEq(vm.parseJsonAddress(json, ".owner"), GOVERNANCE);
        assertEq(vm.parseJsonAddress(json, ".treasury"), NEW_TREASURY);
        assertEq(vm.parseJsonAddress(json, ".feesRecipient"), NEW_FEES);
        assertEq(vm.parseJsonAddress(json, ".poolManager"), PM_ADDR);
    }

    function test_new_stack_wiring() public view {
        assertEq(factory.owner(), GOVERNANCE, "governance owns the factory");
        assertEq(factory.pendingOwner(), address(0));
        assertEq(address(factory.poolManager()), PM_ADDR);
        assertEq(factory.hook(), address(hook));
        assertEq(factory.graduationExecutor(), vm.parseJsonAddress(json, ".graduationExecutor"));
        assertEq(factory.mondayExecutor(), vm.parseJsonAddress(json, ".mondayExecutor"));
        assertEq(factory.locker(), vm.parseJsonAddress(json, ".locker"));
        assertEq(factory.escrow(), vm.parseJsonAddress(json, ".escrow"));
        assertEq(factory.holderFeeSharing(), address(sharing));
        assertEq(factory.router(), vm.parseJsonAddress(json, ".launchAndBuyRouter"));
        assertEq(factory.launchDeployer(), vm.parseJsonAddress(json, ".launchDeployer"));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "hook permission bits");
        assertEq(vault.owner(), GOVERNANCE, "governance owns the Monday fee vault");
        assertEq(vault.lpFeeRecipient(), NEW_FEES, "Monday LP fees go to the new fees wallet");
    }

    function test_new_stack_fee_policy() public view {
        assertEq(factory.protocolFeeRecipient(), NEW_TREASURY, "protocol fees go to the NEW treasury");
        assertEq(factory.protocolFeeShareBps(), 5000);
        assertEq(factory.launchFee(), 5 ether, "5 MON launch fee");
        assertEq(factory.maxCreatorTaxBps(), 1000);
        assertFalse(factory.whitelistEnabled(), "open to every creator");
        assertTrue(factory.canLaunch(creator));
    }

    function test_new_stack_launch_config() public view {
        assertEq(factory.launchConfigCount(), 1);
        Types.LaunchConfig memory c = factory.getLaunchConfig(0);
        assertEq(c.supply, 1_000_000_000e18);
        assertEq(c.curveFeeBps, 100);
        assertEq(c.poolFeeBps, 100);
        assertEq(c.tickSpacing, 60);
        assertTrue(c.enabled);
        assertEq(c.snipeTaxSchedule.length, 4);
        assertEq(c.snipeTaxSchedule[0], 9800);
        assertEq(c.snipeTaxSchedule[1], 2500);
        assertEq(c.snipeTaxSchedule[2], 300);
        assertEq(c.snipeTaxSchedule[3], 30);
    }

    function test_new_stack_pair_economics() public view {
        // $1 stables: exactly $2,000 launch FDV and the sqrt(10)-1 graduation multiple.
        _assertPair(USDC, 6, 2_000e6, false);
        _assertPair(AUSD, 6, 2_000e6, false);
        // Volatile / RWA assets: priced at deploy time. The graduation multiple must be exact; the implied USD
        // price must match the value the script deployed with (when given) or at least sit in a sane band.
        (uint256 monPhantom,,,) = factory.pairTokenEconomics(address(0));
        (uint256 abilPhantom,,,) = factory.pairTokenEconomics(ABIL);
        _assertPair(address(0), 18, monPhantom, false);
        _assertPair(ABIL, 18, abilPhantom, true);
        uint256 monE8 = vm.envOr("EXPECT_MON_USD_E8", uint256(0));
        uint256 abilE8 = vm.envOr("EXPECT_ABIL_USD_E8", uint256(0));
        if (monE8 != 0) assertEq(monPhantom, LAUNCH_FDV_USD * 1e18 * 1e8 / monE8, "MON phantom = $2,000 at the deployed price");
        if (abilE8 != 0) assertEq(abilPhantom, LAUNCH_FDV_USD * 1e18 * 1e8 / abilE8, "aBIL phantom = $2,000 at the deployed price");
        // Sanity band on the implied price, independent of the env: MON $0.005–$0.20, aBIL $50–$150.
        uint256 impliedMonE8 = LAUNCH_FDV_USD * 1e18 * 1e8 / monPhantom;
        uint256 impliedAbilE8 = LAUNCH_FDV_USD * 1e18 * 1e8 / abilPhantom;
        assertGt(impliedMonE8, 500_000);
        assertLt(impliedMonE8, 20_000_000);
        assertGt(impliedAbilE8, 5_000_000_000);
        assertLt(impliedAbilE8, 15_000_000_000);
    }

    function _assertPair(address pair, uint8 decimals, uint256 phantom, bool mondayOnly) internal view {
        (uint256 p, uint256 threshold, uint8 d, bool approved) = factory.pairTokenEconomics(pair);
        assertTrue(approved, "pair approved");
        assertEq(d, decimals, "pair decimals");
        assertEq(p, phantom, "phantom quote");
        assertEq(threshold, p * GRAD_MULT_E8 / 1e8, "graduation threshold = phantom * (sqrt(10) - 1)");
        assertEq(factory.pairMondayOnly(pair), mondayOnly, "monday-only flag");
    }

    // ------------------------------------------------------------------ the new stack, exercised

    function _params(address pair, uint16 tax, bool share, Types.GraduationVenue venue, uint256 seed) internal view returns (Types.TokenParams memory p) {
        p.name = "Relaunch Smoke";
        p.symbol = "RLS";
        p.logo = "ipfs://x";
        p.description = "relaunch smoke";
        p.socials = Types.Socials("", "", "", "", "");
        p.creatorFeeRecipient = creator;
        p.creatorTaxBps = tax;
        p.holderFeeSharing = share;
        p.graduationVenue = venue;
        p.expectedEconomics = factory.previewLaunchEconomics(0, pair);
        p.salt = bytes32(seed);
    }

    function _completeNative(BondingCurve curve, address who) internal {
        while (!curve.completed()) {
            vm.prank(who);
            curve.buy{value: 50_000 ether}(50_000 ether, 0, who);
        }
    }

    function test_monday_native_launch_pays_the_new_wallets() public {
        uint256 leaked0 = LEAKED_TREASURY.balance;
        uint256 oldFees0 = OLD_FEES.balance;
        uint256 t0 = NEW_TREASURY.balance;
        vm.prank(creator);
        (address t, address c) = factory.launchToken{value: 5 ether}(_params(address(0), 100, true, Types.GraduationVenue.Monday, 11), 0, address(0), new address[](0));
        assertEq(NEW_TREASURY.balance - t0, 5 ether, "launch fee pushed to the NEW treasury");
        BondingCurve curve = BondingCurve(c);
        assertEq(curve.protocolShareBps(), 5000);
        vm.warp(block.timestamp + 5);
        uint256 t1 = NEW_TREASURY.balance;
        _completeNative(curve, alice);
        assertGt(NEW_TREASURY.balance, t1, "curve protocol fees reach the NEW treasury");

        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "auto-graduated on Monday");
        address pool = address(uint160(uint256(l.poolId)));
        assertEq(pool, MONDAY.getPool(t, WMON, 10_000));
        int24 sp = IMondayV3Pool(pool).tickSpacing();
        bytes32 key = keccak256(abi.encodePacked(address(vault), TickMath.minUsableTick(sp), TickMath.maxUsableTick(sp)));
        (uint128 liq,,,,) = IMondayV3Pool(pool).positions(key);
        assertGt(liq, 0, "the new fee vault owns the Monday position");
        // Real trading on the graduated pool, then a harvest: the 1% LP fee (in WMON) must land on the new fees wallet.
        assertApproxEqRel(_harvestPaysNewFees(vault, pool, 1_000 ether), 10 ether, 0.01e18, "1% of 1,000 WMON harvested");
        assertEq(LEAKED_TREASURY.balance, leaked0, "nothing to the leaked treasury");
        assertEq(OLD_FEES.balance, oldFees0, "nothing to the old fees wallet");
    }

    function test_v4_native_launch_pays_the_new_treasury() public {
        vm.prank(creator);
        (address t, address c) = factory.launchToken{value: 5 ether}(_params(address(0), 500, true, Types.GraduationVenue.UniswapV4, 12), 0, address(0), new address[](0));
        vm.warp(block.timestamp + 5);
        _completeNative(BondingCurve(c), alice);
        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "auto-graduated on Uniswap v4");
        PoolKey memory key = factory.poolKeyOf(t);
        assertTrue(hook.launches(l.poolId).registered);
        PoolSwapTest router = new PoolSwapTest(PM);
        vm.prank(carol);
        router.swap{value: 1_000 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1_000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.pendingFees(key.toId(), Currency.wrap(address(0))), 10 ether, "1% hook fee");
        uint256 t0 = NEW_TREASURY.balance;
        uint256 leaked0 = LEAKED_TREASURY.balance;
        hook.sweepPoolFees(l.poolId, Currency.wrap(address(0)));
        assertGt(NEW_TREASURY.balance, t0, "pool protocol fees reach the NEW treasury");
        assertEq(LEAKED_TREASURY.balance, leaked0);
    }

    function test_usdc_v4_launch_graduates() public {
        deal(USDC, alice, 10_000e6);
        vm.prank(creator);
        (address t, address c) = factory.launchToken{value: 5 ether}(_params(USDC, 0, false, Types.GraduationVenue.UniswapV4, 13), 0, USDC, new address[](0));
        BondingCurve curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);
        uint256 t0 = IERC20(USDC).balanceOf(NEW_TREASURY);
        vm.startPrank(alice);
        while (!curve.completed()) {
            IERC20(USDC).approve(c, 1_000e6);
            curve.buy(1_000e6, 0, alice);
        }
        vm.stopPrank();
        assertEq(uint8(factory.getLaunchedToken(t).phase), uint8(Types.Phase.PoolCreated), "USDC launch graduated");
        assertGt(IERC20(USDC).balanceOf(NEW_TREASURY), t0, "USDC protocol fees reach the NEW treasury");
    }

    function test_abil_monday_launch_graduates() public {
        deal(ABIL, alice, 10_000e18);
        vm.prank(creator);
        (address t, address c) = factory.launchToken{value: 5 ether}(_params(ABIL, 0, false, Types.GraduationVenue.Monday, 14), 0, ABIL, new address[](0));
        BondingCurve curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);
        vm.startPrank(alice);
        while (!curve.completed()) {
            IERC20(ABIL).approve(c, 10e18);
            curve.buy(10e18, 0, alice);
        }
        vm.stopPrank();
        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "aBIL launch graduated on Monday");
        assertEq(address(uint160(uint256(l.poolId))), MONDAY.getPool(t, ABIL, 10_000));
    }

    function test_abil_rejects_v4() public {
        Types.TokenParams memory p = _params(ABIL, 0, false, Types.GraduationVenue.UniswapV4, 15);
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.PairRequiresMonday.selector);
        factory.launchToken{value: 5 ether}(p, 0, ABIL, new address[](0));
    }

    // ------------------------------------------------------------------ the retired stacks

    function test_retired_factories_are_closed_and_repointed() public view {
        address[3] memory old = _oldFactories();
        for (uint256 i = 0; i < old.length; i++) {
            IOldFactory f = IOldFactory(old[i]);
            assertEq(f.owner(), GOVERNANCE);
            assertEq(f.protocolFeeRecipient(), NEW_TREASURY, "retired factory still pays the old treasury");
            assertEq(f.protocolFeeShareBps(), 5000, "share unchanged");
            assertTrue(f.whitelistEnabled(), "retired factory is closed to new launches");
            assertFalse(f.canLaunch(creator));
            assertFalse(f.canLaunch(GOVERNANCE));
            assertEq(f.launchConfigCount(), 1);
            assertFalse(IOldFactoryConfig(old[i]).getLaunchConfig(0).enabled, "retired factory's launch config disabled");
        }
    }

    function test_retired_monday_vaults_pay_the_new_fees_wallet() public view {
        address[3] memory v = _oldVaults();
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(MondayFeeVault(v[i]).owner(), GOVERNANCE);
            assertEq(MondayFeeVault(v[i]).lpFeeRecipient(), NEW_FEES, "retired vault still pays the old fees wallet");
        }
    }

    /// The only graduated old Monday position (0xad3d's first launch, owned by vault 0xC154): trading on it after the
    /// relaunch must pay its LP fees to the NEW fees wallet on harvest.
    function test_retired_vault_harvest_pays_the_new_fees_wallet() public {
        MondayFeeVault oldVault = MondayFeeVault(0xC154C85e8a2A73B99676C31dcE8627D67A9F376A);
        address pool = 0x72484c6C9f2A41DD9F34c61584bcD2b72eeEf325;
        oldVault.collectFees(pool); // anything accrued before this test
        assertGt(_harvestPaysNewFees(oldVault, pool, 100 ether), 0, "the swap accrued LP fees");
    }

    /// Swaps `amountIn` WMON into `pool`, harvests `v`'s position, and checks every harvested WMON went to the NEW
    /// fees wallet and none to the old one. Returns the WMON harvested.
    function _harvestPaysNewFees(MondayFeeVault v, address pool, uint256 amountIn) internal returns (uint256 wmonFee) {
        uint256 feesW0 = IERC20(WMON).balanceOf(NEW_FEES);
        uint256 oldFeesW0 = IERC20(WMON).balanceOf(OLD_FEES);
        MondaySwapper swapper = new MondaySwapper();
        deal(WMON, address(swapper), amountIn);
        swapper.swapIn(pool, WMON, int256(amountIn));
        (uint128 a0, uint128 a1) = v.collectFees(pool);
        wmonFee = IMondayV3Pool(pool).token0() == WMON ? a0 : a1;
        assertEq(IERC20(WMON).balanceOf(NEW_FEES) - feesW0, wmonFee, "Monday LP fees reach the NEW fees wallet");
        assertEq(IERC20(WMON).balanceOf(OLD_FEES), oldFeesW0, "no LP fees to the old fees wallet");
    }

    /// Every still-trading curve on the retired factories reads `protocolFeeRecipient()` live, so after the relaunch a
    /// buy on each of them must pay the protocol share to the NEW treasury (pushed, or credited in that stack's
    /// escrow) and nothing to the leaked one. Curves found from the factories' TokenLaunched events on 2026-09-23.
    function test_retired_curves_pay_the_new_treasury() public {
        address[6] memory curves = [
            0xbe36BD571e1f4d7E25f4Fc891fC8407460fEb9e6, // 0x10F3 · MON
            0xCD88738a3dD6677930d3881a51219AE93aF3BAD3, // 0x2F02 · MON
            0x804b420E636b88d23559764a34CC8c420984E3cD, // 0x2F02 · MON
            0x9D8452763000a673de749Bd0730F16FeB228ec65, // 0xad3d · aBIL
            0x0f8A9C03E3c2877b3efEB31648430fC335B8eb8d, // 0xad3d · aBIL
            0x6750b5058E092D74E2Ca3B6dD1bA7B8468A4aE8D // 0xad3d · aBIL
        ];
        address[6] memory escrows = [
            0xbc70ba9D66F761FFb7647D6B52C8Cf65a49E47fc,
            0xeDC73b06BE454714b6Bd0C1c742e51e605664B2A,
            0xeDC73b06BE454714b6Bd0C1c742e51e605664B2A,
            0x1253b18077E8b52FC2522F5B62Ebd2B176383231,
            0x1253b18077E8b52FC2522F5B62Ebd2B176383231,
            0x1253b18077E8b52FC2522F5B62Ebd2B176383231
        ];
        bool[6] memory isAbil = [false, false, false, true, true, true];
        deal(ABIL, alice, 1_000e18);
        uint256 tested;
        for (uint256 i = 0; i < curves.length; i++) {
            if (BondingCurve(curves[i]).completed()) continue;
            uint256 newBefore = _protocolTake(NEW_TREASURY, escrows[i], isAbil[i]);
            uint256 leakedBefore = _protocolTake(LEAKED_TREASURY, escrows[i], isAbil[i]);
            vm.startPrank(alice);
            if (isAbil[i]) {
                IERC20(ABIL).approve(curves[i], 1e18);
                BondingCurve(curves[i]).buy(1e18, 0, alice);
            } else {
                BondingCurve(curves[i]).buy{value: 1_000 ether}(1_000 ether, 0, alice);
            }
            vm.stopPrank();
            assertGt(_protocolTake(NEW_TREASURY, escrows[i], isAbil[i]), newBefore, "retired curve's protocol fee reached the NEW treasury");
            assertEq(_protocolTake(LEAKED_TREASURY, escrows[i], isAbil[i]), leakedBefore, "retired curve paid the leaked treasury");
            tested++;
        }
        assertGt(tested, 0, "no still-trading retired curve was exercised");
    }

    /// What a recipient has received from a stack: its wallet balance plus anything credited to it in that escrow.
    function _protocolTake(address who, address escrow, bool abil) internal view returns (uint256) {
        if (abil) return IERC20(ABIL).balanceOf(who) + IEscrowCredits(escrow).balanceOfToken(who, ABIL);
        return who.balance + IEscrowCredits(escrow).balanceOf(who);
    }

    function test_latest_retired_factory_rejects_new_launches() public {
        LaunchpadFactory old = LaunchpadFactory(_oldFactories()[0]); // same source as the new stack
        Types.TokenParams memory p = _params(address(0), 0, false, Types.GraduationVenue.UniswapV4, 16);
        p.expectedEconomics = old.previewLaunchEconomics(0, address(0));
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.NotWhitelisted.selector);
        old.launchToken{value: 5 ether}(p, 0, address(0), new address[](0));
    }
}
