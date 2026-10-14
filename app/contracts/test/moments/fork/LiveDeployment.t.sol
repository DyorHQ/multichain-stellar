// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MomentsForkBase} from "./MomentsForkBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MomentTypes} from "../../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../../src/moments/MomentGraduation.sol";
import {MomentBuyback} from "../../../src/moments/MomentBuyback.sol";
import {MomentFeeHook} from "../../../src/moments/MomentFeeHook.sol";
import {MomentLocker} from "../../../src/moments/MomentLocker.sol";
import {MomentCoin} from "../../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../../src/moments/MomentNFT.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";

/// Smoke test of the LIVE Monad mainnet deployment (deployments/moments-143.json — v2, cohort 4, deployed 2026-09-28:
/// factory 0x95eb…0840, governed by the Owner Safe 0x6D2A…, guardian 0x686C…, platform 0x15ED…, treasury 0x5aDb…):
/// nothing of ours is redeployed; the whole $2,000-FDV lifecycle (threshold 771.428571 USDC: 10 collects of $100 + a
/// clamped terminal one) runs through the deployed factory / collect / vesting / graduation / locker / hook / buyback
/// against the real PoolManager, USDC, Permit2 and Universal Router, on a fresh fork. The addresses come from the
/// record, so this follows whatever stack the app is wired to. Cohort3DeploymentTest below runs the same on cohort 3
/// (deployments/moments-143-cohort3.json: the 2026-09-23 relaunch, factory 0x0FD4…7E26, retired in the app by v2 and
/// still open on chain).
///   forge test --code-size-limit 100000000 --match-path test/moments/fork/LiveDeployment.t.sol -vv
/// Cohort 3 runs the v1 factory, whose publish takes no terms hash (v2 adds it: sec2, MO-4).
interface IMomentsFactoryV1Publish {
    function publish(MomentsFactory.PublishParams calldata p) external returns (uint256 momentId, address coin, address nft);
}

contract LiveDeploymentTest is MomentsForkBase {
    using PoolIdLibrary for PoolKey;

    uint256 constant COLLECT_PRICE = 100_000_000; // $100 per edition: 10 full collects + the terminal remainder

    address liveGovernance;
    address livePlatform;
    address liveTreasury;
    uint256 liveThreshold;

    /// The deployment record under test.
    function _record() internal pure virtual returns (string memory) {
        return "deployments/moments-143.json";
    }

    /// Who governs it: the Owner Safe (2-of-3) since v2.
    function _governance() internal pure virtual returns (address) {
        return 0x6D2A4D821e57b2B918B97CF575D81738bc16C100;
    }

    /// v2's guardian, link base and terms, bound into every publish (sec2, MO-4).
    function _assertTerms(string memory json) internal view virtual {
        assertEq(factory.guardian(), vm.parseJsonAddress(json, ".guardian"));
        assertEq(factory.guardian(), 0x686C7A2886608082e698E0062EA3E4C408d43845, "the recorded guardian");
        assertFalse(factory.guardianPaused());
        assertEq(factory.externalBaseURI(), "https://dyorhq.fun/moments/c4/", "c4 link base");
        assertEq(factory.termsHash(), 0x3d9ff80b17a4f23544485081f1d595532c4f1d7932b3deea682e0b1e1fb2fa03, "the terms the app shows");
    }

    function setUp() public override {
        vm.createSelectFork("monad");
        string memory json = vm.readFile(_record());
        factory = MomentsFactory(vm.parseJsonAddress(json, ".factory"));
        collect = MomentCollect(vm.parseJsonAddress(json, ".collect"));
        vesting = MomentVesting(vm.parseJsonAddress(json, ".vesting"));
        executor = MomentGraduation(vm.parseJsonAddress(json, ".graduation"));
        locker = MomentLocker(vm.parseJsonAddress(json, ".locker"));
        hook = MomentFeeHook(vm.parseJsonAddress(json, ".hook"));
        buyback = MomentBuyback(vm.parseJsonAddress(json, ".buyback"));
        liveGovernance = vm.parseJsonAddress(json, ".governance");
        livePlatform = vm.parseJsonAddress(json, ".platform");
        liveTreasury = vm.parseJsonAddress(json, ".treasury");
        liveThreshold = vm.parseJsonUint(json, ".thresholdUsdc");
        manager = IPoolManager(PM_ADDR);
        usdc = MockUSDC(USDC_ADDR);
        permit2 = MockPermit2(PERMIT2_ADDR);
        swapRouter = new PoolSwapTest(manager); // test-only trade router; production trades go through the UR
        address[5] memory users = [alice, bob, carol, dave, creator];
        for (uint256 i = 0; i < users.length; i++) {
            deal(USDC_ADDR, users[i], 1_000_000_000_000);
            vm.startPrank(users[i]);
            usdc.approve(address(collect), type(uint256).max);
            usdc.approve(PERMIT2_ADDR, type(uint256).max);
            usdc.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_live_wiring_and_policy() public view {
        assertEq(factory.governance(), liveGovernance);
        assertEq(factory.governance(), _governance(), "owner governs");
        _assertTerms(vm.readFile(_record()));
        assertEq(factory.pendingGovernance(), address(0));
        assertTrue(factory.modulesSet());
        assertEq(factory.collect(), address(collect));
        assertEq(factory.vesting(), address(vesting));
        assertEq(factory.graduation(), address(executor));
        assertEq(factory.locker(), address(locker));
        assertEq(factory.feeHook(), address(hook));
        assertEq(factory.buyback(), address(buyback));
        assertFalse(factory.publishingPaused());
        assertEq(factory.pendingPolicyAt(), 0);
        (uint256 threshold, uint256 minPrice, uint16 cBps, uint16 pBps, uint16 rBps, uint16 maxAlloc, uint16 expBps, uint16 royBps, address plat, address treas) = factory.policy();
        assertEq(threshold, liveThreshold);
        assertEq(threshold, 771_428_571, "$2,000 FDV at the default 10% creator allocation");
        assertEq(minPrice, 100_000);
        assertEq(cBps, 2_000);
        assertEq(pBps, 500);
        assertEq(rBps, 7_500);
        assertEq(maxAlloc, 1_000);
        assertEq(expBps, 7_000);
        assertEq(royBps, 500, "v1.1: ERC-2981 creator royalty policy");
        assertEq(factory.MIN_THRESHOLD(), 1_000_000, "v1.1 policy floors");
        assertEq(factory.MIN_MIN_PRICE(), 10_000);
        assertEq(plat, livePlatform);
        assertEq(plat, 0x15ED3bb488231213b141A2f78b62358D52235Cd7, "platform = the new fees wallet");
        assertEq(treas, liveTreasury);
        assertEq(treas, 0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371, "treasury = the new treasury");
        assertEq(address(collect.USDC()), USDC_ADDR);
        assertEq(address(collect.PERMIT2()), PERMIT2_ADDR);
        assertEq(address(collect.factory()), address(factory));
        assertEq(address(collect.vesting()), address(vesting));
        assertEq(address(vesting.factory()), address(factory));
        assertEq(address(executor.factory()), address(factory));
        assertEq(address(executor.poolManager()), PM_ADDR);
        assertEq(address(executor.USDC()), USDC_ADDR);
        assertEq(executor.LP_FEE(), 5_000);
        assertEq(executor.TICK_SPACING(), 60);
        assertEq(address(locker.factory()), address(factory));
        assertEq(address(locker.poolManager()), PM_ADDR);
        assertEq(address(hook.factory()), address(factory));
        assertEq(address(hook.poolManager()), PM_ADDR);
        assertEq(Currency.unwrap(hook.usdc()), USDC_ADDR);
        assertEq(uint160(address(hook)) & 0x3FFF, uint160(0x20CC), "hook permission bits");
        assertEq(address(buyback.factory()), address(factory));
        assertEq(address(buyback.poolManager()), PM_ADDR);
        assertEq(address(buyback.USDC()), USDC_ADDR);
    }

    /// Publishes through the LIVE factory, so the coin address (and therefore the currency ordering) comes from the
    /// deployed creation code, not from a local prediction: v1.1 changed the coin bytecode.
    function test_live_lifecycle_through_the_deployed_contracts() public {
        uint256 nextId = factory.momentCount() + 1;
        (uint256 id, MomentCoin coin, MomentNFT nft) = _publish(creator, COLLECT_PRICE, MAX_ALLOC_BPS, 1001);
        bool usdcIs0 = address(usdc) < address(coin);
        assertEq(id, nextId);
        assertEq(coin.graduation(), address(executor));
        assertEq(coin.vesting(), address(vesting));
        assertEq(nft.collect(), address(collect));
        _assertSupply(id);

        for (uint256 i = 0; i < 10; i++) _collect(id, alice, 1);
        vm.prank(bob);
        uint256 g = gasleft();
        MomentCollect.Quote memory q = collect.collect(id, 1);
        console2.log("live terminal collect + graduation gas:", g - gasleft());
        assertTrue(q.terminal);
        assertEq(q.gross, 28_571_428, "clamped: its 75% reserve share is exactly the remaining 21.428571 USDC");
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated), "graduated on the live executor");
        MomentGraduation.Record memory r = executor.record(id);
        assertEq(r.reserve, liveThreshold, "graduates at exactly the $2,000-FDV reserve");
        assertEq(r.poolCoins, 38571428571428571428571436);
        assertEq(r.poolCoins + vesting.totalEntitlement(id) + 1e25, S);
        assertEq(address(r.key.hooks), address(hook));
        assertEq(r.key.fee, 5_000);
        assertEq(hook.momentOf(r.key.toId()), id);
        assertEq(_lockerPositionLiquidity(id, r.key), r.liquidity, "live locker owns the position");
        assertTrue(nft.closed());
        _assertSupply(id);

        // trade: v4 router buy + real Universal Router sell, both fee-charged by the live hook
        uint256 f0 = hook.creatorAccrued(id) + hook.platformAccrued(id) + hook.buybackAccrued(id);
        _buyExactIn(bob, r.key, usdcIs0, 1_000_000);
        assertEq(hook.creatorAccrued(id) + hook.platformAccrued(id) + hook.buybackAccrued(id) - f0, 10_000);
        vm.prank(alice);
        vesting.claim(id);
        uint256 a0 = usdc.balanceOf(alice);
        _urSwapExactIn(alice, r.key, !usdcIs0, 1e24);
        assertGt(usdc.balanceOf(alice) - a0, 0, "Universal Router sell paid out");

        // vesting + payouts to the live beneficiaries
        vm.prank(creator);
        vesting.claim(id);
        assertEq(coin.balanceOf(creator), 2_000_000e18);
        uint256 p0 = usdc.balanceOf(livePlatform);
        assertEq(collect.ledger(id).platformClaimable, 51_428_571, "5% of the 1,028.571428 USDC collected");
        vm.startPrank(livePlatform);
        collect.withdrawPlatform(id);
        hook.withdrawPlatform(id);
        vm.stopPrank();
        assertGt(usdc.balanceOf(livePlatform) - p0, 51_428_571, "live platform address received its collect + hook shares");

        // fees -> buyback through the live module
        _approveCoin(coin, bob);
        for (uint256 i = 0; i < 12; i++) {
            uint256 c0 = coin.balanceOf(bob);
            _buyExactIn(bob, r.key, usdcIs0, 10_000_000);
            _sellExactIn(bob, r.key, usdcIs0, coin.balanceOf(bob) - c0);
        }
        // v2 (MO-2): the round runs in a later block than the burst, like a keeper's; within the burst's block its
        // drift trips the block-open price guard. Cohort 3's v1 module has no guard, and a new block changes nothing.
        vm.roll(vm.getBlockNumber() + 1);
        uint128 liq0 = _lockerPositionLiquidity(id, r.key);
        MomentBuyback.Round memory round = buyback.execute(id, 0);
        assertGt(round.liquidityAdded, 0);
        assertEq(_lockerPositionLiquidity(id, r.key), liq0 + round.liquidityAdded);
        _assertSupply(id);

        // a second Moment expires: 70% creator / 30% to the live treasury
        (uint256 id2,, MomentNFT nft2) = _publish(creator, PRICE, 0, 1002);
        _collect(id2, carol, 2);
        vm.warp(factory.getMoment(id2).deadline);
        collect.expire(id2);
        assertTrue(nft2.closed());
        assertEq(collect.ledger(id2).treasuryClaimable, 1_500_000 * 3_000 / 10_000);
        uint256 t0 = usdc.balanceOf(liveTreasury);
        vm.prank(liveTreasury);
        collect.withdrawTreasury(id2);
        assertEq(usdc.balanceOf(liveTreasury) - t0, 450_000, "live treasury received 30% of the expired reserve");
        _assertSupply(id2);
    }
}

/// The same smoke on cohort 3, the 2026-09-23 relaunch (retired in the app by v2, still open on chain): owner-governed,
/// v1 publish without a terms hash, no guardian.
contract Cohort3DeploymentTest is LiveDeploymentTest {
    function _record() internal pure override returns (string memory) {
        return "deployments/moments-143-cohort3.json";
    }

    function _governance() internal pure override returns (address) {
        return 0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10;
    }

    function _assertTerms(string memory) internal view override {}

    function _publish(address who, uint256 price, uint16 allocBps, uint256 seed) internal override returns (uint256 id, MomentCoin coin, MomentNFT nft) {
        vm.prank(who);
        (uint256 i, address c, address n) = IMomentsFactoryV1Publish(address(factory)).publish(_params(price, allocBps, seed));
        return (i, MomentCoin(c), MomentNFT(n));
    }
}
