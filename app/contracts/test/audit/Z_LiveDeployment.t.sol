// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {HolderFeeSharing} from "../../src/HolderFeeSharing.sol";
import {MemeHook} from "../../src/MemeHook.sol";
import {MondayFeeVault} from "../../src/MondayFeeVault.sol";
import {IMondayV3Factory, IMondayV3Pool} from "../../src/interfaces/IMondayV3.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

/// Smoke test of the LIVE launchpad on a Monad mainnet fork — the stack recorded in deployments/143.json (v2, deployed
/// 2026-09-28: factory 0x3B1f…0b5b, owned by the Owner Safe 0x6D2A…, treasury 0x5aDb…, fees 0x15ED…): the real
/// factory, curve, hook, executors, Monday pools, fee vault and the real aBIL token — end to end, exactly as users
/// will hit it. The addresses come from the record, so this follows whatever stack the apps are wired to. The stack it
/// replaced, 0x6B1C…, is Z_Relaunch.t.sol's.
///   forge test --code-size-limit 100000000 --match-path test/audit/Z_LiveDeployment.t.sol -vv
contract LiveDeploymentTest is Test {
    using PoolIdLibrary for PoolKey;

    LaunchpadFactory factory;
    HolderFeeSharing sharing;
    MemeHook hook;
    MondayFeeVault vault;
    address treasury;
    string json;
    IPoolManager constant PM = IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e);
    IMondayV3Factory constant MONDAY = IMondayV3Factory(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21);
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ABIL = 0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.createSelectFork("monad");
        json = vm.readFile("deployments/143.json");
        factory = LaunchpadFactory(vm.parseJsonAddress(json, ".factory"));
        sharing = HolderFeeSharing(vm.parseJsonAddress(json, ".holderFeeSharing"));
        hook = MemeHook(payable(vm.parseJsonAddress(json, ".hook")));
        vault = MondayFeeVault(vm.parseJsonAddress(json, ".feeVault"));
        treasury = vm.parseJsonAddress(json, ".treasury");
        vm.deal(creator, 100 ether);
        vm.deal(alice, 2_000_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    function _params(address pair, uint16 tax, bool share, Types.GraduationVenue venue, uint256 seed) internal view returns (Types.TokenParams memory p) {
        p.name = "Live Smoke";
        p.symbol = "SMOKE";
        p.logo = "ipfs://x";
        p.description = "smoke";
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

    function test_live_wiring_and_owner() public view {
        address owner = vm.parseJsonAddress(json, ".owner");
        assertEq(owner, 0x6D2A4D821e57b2B918B97CF575D81738bc16C100, "the Owner Safe (2-of-3)");
        assertEq(factory.owner(), owner, "the Safe owns the factory");
        assertEq(factory.pendingOwner(), address(0));
        assertTrue(factory.modulesSealed(), "no module can be swapped");
        assertEq(factory.hook(), address(hook));
        assertEq(factory.holderFeeSharing(), address(sharing));
        assertEq(factory.escrow(), vm.parseJsonAddress(json, ".escrow"));
        assertEq(factory.router(), vm.parseJsonAddress(json, ".launchAndBuyRouter"));
        assertEq(factory.graduationExecutor(), vm.parseJsonAddress(json, ".graduationExecutor"));
        assertEq(factory.mondayExecutor(), vm.parseJsonAddress(json, ".mondayExecutor"));
        assertEq(factory.protocolFeeRecipient(), treasury, "protocol fees go to the treasury");
        assertEq(factory.protocolFeeShareBps(), 5000);
        assertFalse(factory.whitelistEnabled(), "open to every creator");
        assertEq(vault.owner(), owner, "the Safe owns the Monday fee vault");
        assertEq(vault.lpFeeRecipient(), vm.parseJsonAddress(json, ".feesRecipient"));
    }

    function test_live_monday_native_launch_graduates_into_vault_position() public {
        uint256 fee = factory.launchFee();
        assertEq(fee, 5 ether);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(creator);
        (address t, address c) = factory.launchToken{value: fee}(_params(address(0), 100, true, Types.GraduationVenue.Monday, 1), 0, address(0), new address[](0));
        assertEq(treasury.balance - treasuryBefore, fee, "launch fee auto-pushed to the treasury");
        BondingCurve curve = BondingCurve(c);
        assertEq(curve.protocolShareBps(), 5000, "pinned 50/50 split");
        assertEq(curve.MAX_TOTAL_BPS(), 9_900);
        vm.warp(block.timestamp + 5);
        _completeNative(curve, alice);

        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "auto-graduated on Monday");
        address pool = address(uint160(uint256(l.poolId)));
        assertEq(pool, MONDAY.getPool(t, WMON, 10_000), "TOKEN/WMON pool on Monday");
        assertGt(IMondayV3Pool(pool).liquidity(), 0);
        int24 sp = IMondayV3Pool(pool).tickSpacing();
        bytes32 key = keccak256(abi.encodePacked(address(vault), TickMath.minUsableTick(sp), TickMath.maxUsableTick(sp)));
        (uint128 liq,,,,) = IMondayV3Pool(pool).positions(key);
        assertGt(liq, 0, "position is owned by the fee vault");
        assertTrue(sharing.excluded(t, pool), "Monday pool excluded from holder accounting");
        assertTrue(sharing.excluded(t, address(vault)), "fee vault excluded");

        // Curve-phase holder rewards are claimable one block later by the real holder.
        vm.roll(block.number + 1);
        assertGt(sharing.pendingRewards(t, alice), 0);
        vm.prank(alice);
        assertGt(sharing.claim(t), 0);
        // LP fee harvest is permissionless (pays the fixed fees address).
        vault.collectFees(pool);
    }

    function test_live_v4_native_launch_swaps_and_shares_fees() public {
        vm.prank(creator);
        (address t, address c) = factory.launchToken{value: 5 ether}(_params(address(0), 500, true, Types.GraduationVenue.UniswapV4, 2), 0, address(0), new address[](0));
        BondingCurve curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);
        _completeNative(curve, alice);

        Types.LaunchedToken memory l = factory.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "auto-graduated on Uniswap v4");
        PoolKey memory key = factory.poolKeyOf(t);
        assertEq(PoolId.unwrap(key.toId()), l.poolId);
        assertTrue(hook.launches(l.poolId).registered);
        assertEq(hook.launches(l.poolId).protocolShareBps, 5000, "hook carries the pinned split");

        // Buy through the REAL PoolManager with a test router: the hook charges the 1% fee and the 5% creator tax in
        // MON. With holder fee sharing, the holders' cut (half the fee, and the tax) is queued for them in the same
        // swap and the protocol's half waits in the hook for the sweep (LP-2).
        PoolSwapTest router = new PoolSwapTest(PM);
        (uint256 queued0,) = sharing.queuedRewards(t);
        vm.prank(carol);
        router.swap{value: 1_000 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1_000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(LaunchToken(t).balanceOf(carol), 0, "carol bought from the graduated pool");
        assertEq(hook.pendingProtocolFees(key.toId(), Currency.wrap(address(0))), 5 ether, "the protocol's half of the 1% fee on 1,000 MON");
        assertEq(hook.pendingFees(key.toId(), Currency.wrap(address(0))), 0, "no holder backlog in the hook");
        assertEq(hook.pendingCreatorTax(key.toId(), Currency.wrap(address(0))), 0);
        (uint256 queued1,) = sharing.queuedRewards(t);
        assertEq(queued1 - queued0, 55 ether, "the holders' half of the fee and the 5% tax, queued in the swap");
        hook.sweepPoolFees(l.poolId, Currency.wrap(address(0)));
        assertEq(hook.pendingProtocolFees(key.toId(), Currency.wrap(address(0))), 0, "the sweep pays the protocol");
        vm.roll(block.number + 1);
        assertGt(sharing.pendingRewards(t, alice), 0, "holders receive pool fees a block later");
    }

    function test_live_abil_monday_launch() public {
        deal(ABIL, alice, 10_000e18);
        vm.prank(creator);
        (address t, address c) = factory.launchToken{value: 5 ether}(_params(ABIL, 0, false, Types.GraduationVenue.Monday, 3), 0, ABIL, new address[](0));
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

    function test_live_abil_rejects_v4() public {
        // Build the params first: _params() makes an external view call, which would otherwise consume the
        // prank/expectRevert meant for launchToken.
        Types.TokenParams memory p = _params(ABIL, 0, false, Types.GraduationVenue.UniswapV4, 4);
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.PairRequiresMonday.selector);
        factory.launchToken{value: 5 ether}(p, 0, ABIL, new address[](0));
    }
}
