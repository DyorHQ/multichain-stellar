// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MomentsForkBase} from "./MomentsForkBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MomentTypes} from "../../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../../src/moments/MomentGraduation.sol";
import {MomentVesting} from "../../../src/moments/MomentVesting.sol";
import {MomentBuyback} from "../../../src/moments/MomentBuyback.sol";
import {MomentCoin} from "../../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../../src/moments/MomentNFT.sol";
import {MaliciousCollector} from "../mocks/MaliciousCollector.sol";

/// Phase 3, part 2: the adversarial matrix on Monad mainnet state.
contract AdversarialForkTest is MomentsForkBase {
    using PoolIdLibrary for PoolKey;

    uint256 constant E1 = 3857142857142857142857142;
    uint256 constant SUM_ENT = 51428573999999999999999988;

    // 1. Self-graduation: one wallet publishes and self-collects to $10, then extracts everything liquid.
    //    Accepted UI-contained risk; the accounting must be exact and the extraction documented.
    function test_self_graduation_extraction_is_exact_and_loss_making() public {
        (uint256 id, MomentCoin coin,) = _publishOrdered(mallory, PRICE, MAX_ALLOC_BPS, true);
        uint256 paid0 = usdc.balanceOf(mallory);
        assertEq(_completeWithSingles(id, mallory), 14);
        uint256 paid = paid0 - usdc.balanceOf(mallory);
        assertEq(paid, 13_333_334, "paid exactly the gross");
        MomentGraduation.Record memory r = executor.record(id);
        _assertSupply(id);
        // creator share of collects + everything liquid at open: 60% of all entitlements + 20% of the creator bag
        vm.startPrank(mallory);
        collect.withdrawCreator(id);
        vesting.claim(id);
        vm.stopPrank();
        _approveCoin(coin, mallory);
        uint256 liquid = coin.balanceOf(mallory);
        assertEq(liquid, FullMath.mulDiv(SUM_ENT, 6_000, BPS) + 2_000_000e18, "60% collectors + 20% creator");
        uint256 pm0 = usdc.balanceOf(address(manager));
        _sellExactIn(mallory, r.key, true, liquid);
        uint256 grossOut = pm0 - usdc.balanceOf(address(manager));
        uint256 recovered = usdc.balanceOf(mallory) - (paid0 - paid);
        (uint256 expOut,) = _expectedSell(r.usedCoin, r.usedUsdc, liquid);
        console2.log("self-graduation: paid", paid, " recovered", recovered);
        console2.log("  dump gross out", grossOut, " expected", expOut);
        assertLt(_absDiff(grossOut, expOut) * 1000, expOut, "dump proceeds match the model within 0.1%");
        assertEq(recovered, 2_666_668 + grossOut - grossOut * hook.FEE_BPS() / BPS, "creator share + net dump proceeds");
        assertLt(recovered, paid, "self-graduation loses money without outside buyers");
        assertGt(paid - recovered, 6_000_000, "loses more than $6 of the $13.33");
        // nobody else was harmed: platform share + 0.3% of the dump are intact and pull-only
        assertEq(collect.ledger(id).platformClaimable, 666_666);
        assertEq(hook.platformAccrued(id), grossOut * hook.FEE_BPS() / BPS * 3_000 / BPS);
        assertGt(usdc.balanceOf(address(manager)), pm0 - grossOut - 1, "the pool keeps the rest, locked");
        assertEq(coin.balanceOf(mallory), 0);
        _assertSupply(id);
    }

    // 2. High collect price -> graduation with a single holder; whale takes the majority at $1.
    function test_high_price_single_holder_and_whale_majority() public {
        (uint256 id, MomentCoin coin, MomentNFT nft) = _publishOrdered(creator, 10_000_000, MAX_ALLOC_BPS, false);
        _collect(id, alice, 1); // $10: reserve 7.5, not terminal
        MomentCollect.Quote memory q = _collect(id, alice, 1); // clamp: gross 3,333,334, 1 edition
        assertTrue(q.terminal);
        assertEq(q.gross, 3_333_334);
        assertEq(nft.totalMinted(), 2);
        assertEq(vesting.entitlement(id, alice), vesting.totalEntitlement(id), "one holder owns 100% of collector coins");
        assertEq(executor.record(id).poolCoins + vesting.totalEntitlement(id) + 1e25, S);
        assertEq(coin.totalSupply(), executor.record(id).poolCoins);
        _assertSupply(id);

        (uint256 id2,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        for (uint256 i = 0; i < 10; i++) _collect(id2, bob, 1);
        for (uint256 i = 0; i < 3; i++) _collect(id2, carol, 1);
        _collect(id2, dave, 1);
        uint256 topBps = vesting.entitlement(id2, bob) * BPS / vesting.totalEntitlement(id2);
        console2.log("whale top-holder bps:", topBps);
        assertGt(topBps, 7_000, "whale holds > 70% of collector coins (UI must surface this)");
        _assertSupply(id2);
    }

    // 3. Terminal overshoot + two collects racing the graduation block; the collect path stays locked while pending.
    function test_race_at_the_threshold_and_locked_collect_path() public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        // same block: bob's overshooting collect wins (clamped, graduates), carol's identical collect reverts
        MomentCollect.Quote memory q = _collect(id, bob, 20);
        assertTrue(q.terminal);
        assertEq(q.gross, 333_334);
        assertEq(q.editions, 1, "no rank grab: paid editions only");
        vm.prank(carol);
        vm.expectRevert(MomentCollect.NotCollecting.selector);
        collect.collect(id, 1);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));

        // stuck variant: PoolManager refuses -> pending -> collects locked -> retry graduates
        (uint256 id2,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, false);
        for (uint256 i = 0; i < 13; i++) _collect(id2, alice, 1);
        vm.mockCallRevert(PM_ADDR, abi.encodeWithSelector(IPoolManager.initialize.selector), "pm down");
        _collect(id2, bob, 1);
        vm.clearMockedCalls();
        assertEq(uint8(_state(id2)), uint8(MomentTypes.State.GraduationPending));
        vm.prank(carol);
        vm.expectRevert(MomentCollect.NotCollecting.selector);
        collect.collect(id2, 1);
        _assertSupply(id2);
        vm.prank(dave);
        executor.graduate(id2);
        assertEq(uint8(_state(id2)), uint8(MomentTypes.State.Graduated));
        _assertSupply(id2);
    }

    // 4. Dead Moment: never reaches the threshold -> no coin, no pool, NFTs remain, wind-down after the deadline.
    function test_dead_moment_never_mints_and_winds_down() public {
        (uint256 id, MomentCoin coin, MomentNFT nft) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _collect(id, alice, 2);
        _collect(id, bob, 1);
        PoolKey memory preview = executor.previewPoolKey(id);
        vm.warp(factory.getMoment(id).deadline + 1);
        vm.prank(alice);
        vm.expectRevert(MomentCollect.CollectWindowClosed.selector);
        collect.collect(id, 1);
        collect.expire(id);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Expired));
        assertEq(coin.totalSupply(), 0, "no coin ever");
        assertFalse(executor.isGraduated(id));
        assertEq(_sqrtPrice(preview), 0, "no pool was ever initialized on the real PoolManager");
        assertEq(nft.totalMinted(), 3);
        assertEq(nft.ownerOf(1), alice);
        assertTrue(nft.closed());
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(l.creatorClaimable, 600_000 + 2_250_000 * 7_000 / 10_000, "20% of collects + 70% of the reserve");
        assertEq(l.treasuryClaimable, 2_250_000 * 3_000 / 10_000);
        vm.prank(alice);
        vm.expectRevert(); // nothing vests
        vesting.claim(id);
        _assertSupply(id);
    }

    // 5. Vesting boundaries: exactly at, one second before and after each cliff.
    function test_claims_exactly_at_vesting_boundaries() public {
        (uint256 id,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        for (uint256 i = 0; i < 13; i++) _collect(id, alice, 1);
        _collect(id, bob, 1);
        uint64 g = vesting.graduatedAt(id);
        uint256 ent = vesting.entitlement(id, alice);
        (uint256 c,) = vesting.claimable(id, alice);
        assertEq(c, FullMath.mulDiv(ent, 6_000, BPS), "60% at graduation");
        vm.warp(g + MomentTypes.MONTH - 1);
        (c,) = vesting.claimable(id, alice);
        assertEq(c, FullMath.mulDiv(ent, 6_000, BPS), "still 60% one second before month 1");
        vm.warp(g + MomentTypes.MONTH);
        (c,) = vesting.claimable(id, alice);
        assertEq(c, FullMath.mulDiv(ent, 8_000, BPS), "80% at month 1");
        vm.warp(g + 2 * MomentTypes.MONTH - 1);
        (c,) = vesting.claimable(id, alice);
        assertEq(c, FullMath.mulDiv(ent, 8_000, BPS));
        vm.warp(g + 2 * MomentTypes.MONTH);
        (c,) = vesting.claimable(id, alice);
        assertEq(c, ent, "100% at month 2");
        vm.warp(g + 24 * MomentTypes.MONTH);
        (c,) = vesting.claimable(id, alice);
        assertEq(c, ent, "never more than the entitlement");
        // creator: 20% + 16%/month, capped at month 5
        uint16[7] memory creatorBps = [uint16(2_000), 3_600, 5_200, 6_800, 8_400, 10_000, 10_000];
        for (uint256 mth = 0; mth <= 6; mth++) {
            vm.warp(g + mth * MomentTypes.MONTH);
            (, uint256 cr) = vesting.claimable(id, creator);
            assertEq(cr, uint256(creatorBps[mth]) * 1e25 / BPS);
            if (mth > 0) {
                vm.warp(g + mth * MomentTypes.MONTH - 1);
                (, uint256 crBefore) = vesting.claimable(id, creator);
                assertEq(crBefore, uint256(creatorBps[mth - 1]) * 1e25 / BPS, "one second before a cliff nothing new vests");
            }
        }
        // claiming in pieces never exceeds the schedule
        vm.warp(g + MomentTypes.MONTH);
        vm.prank(alice);
        vesting.claim(id);
        vm.prank(alice);
        vm.expectRevert(MomentVesting.NothingToClaim.selector);
        vesting.claim(id);
        assertEq(vesting.claimed(id, alice), FullMath.mulDiv(ent, 8_000, BPS));
        _assertSupply(id);
    }

    // 6. Un-taken creator allocation (4%): freed coins deepen the pool; supply still sums to S.
    function test_untaken_creator_allocation_deepens_the_pool_on_mainnet_state() public {
        (uint256 id4,,) = _publishOrdered(creator, PRICE, 400, true);
        (uint256 id10,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _completeWithSingles(id4, alice);
        _completeWithSingles(id10, alice);
        MomentGraduation.Record memory r4 = executor.record(id4);
        MomentGraduation.Record memory r10 = executor.record(id10);
        assertEq(r4.poolCoins + vesting.totalEntitlement(id4) + 4_000_000e18, S);
        assertGt(r4.poolCoins, r10.poolCoins, "freed allocation went to the pool");
        assertGt(r4.liquidity, r10.liquidity);
        assertGt(vesting.totalEntitlement(id4), vesting.totalEntitlement(id10), "and collectors got more per USDC too");
        _assertSupply(id4);
        _assertSupply(id10);
    }

    // 7. Reentrancy: collect (NFT receive hook), claim (double call), buyback sandwich on the real PoolManager.
    function test_reentrancy_and_sandwich_on_mainnet_state() public {
        (uint256 id, MomentCoin coin, MomentNFT nft) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        MaliciousCollector attacker = new MaliciousCollector(collect);
        deal(USDC_ADDR, address(attacker), 10 * PRICE);
        vm.prank(address(attacker));
        usdc.approve(address(collect), type(uint256).max);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.attack(id);
        assertEq(nft.totalMinted(), 0);
        assertEq(collect.ledger(id).reserve, 0);

        _completeWithSingles(id, alice);
        PoolKey memory key = executor.poolKeyOf(id);
        vm.prank(alice);
        vesting.claim(id);
        vm.prank(alice);
        vm.expectRevert(MomentVesting.NothingToClaim.selector);
        vesting.claim(id); // nothing to re-claim
        // sandwich the buyback on the real PoolManager
        _approveCoin(coin, bob);
        _approveCoin(coin, carol);
        for (uint256 i = 0; i < 12; i++) {
            uint256 c0 = coin.balanceOf(bob);
            _buyExactIn(bob, key, true, 10_000_000);
            _sellExactIn(bob, key, true, coin.balanceOf(bob) - c0);
        }
        // v2 (MO-2): the sandwich runs in a block of its own; its push (>2%) trips the block-open price guard, so the
        // round refuses to run and the attacker is left with the fees of the round trip.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 carol0 = usdc.balanceOf(carol);
        _buyExactIn(carol, key, true, 2_000_000);
        vm.prank(carol);
        vm.expectRevert(MomentBuyback.PriceMoved.selector);
        buyback.execute(id, 0);
        _sellExactIn(carol, key, true, coin.balanceOf(carol));
        assertLt(usdc.balanceOf(carol), carol0, "sandwiching the buyback loses money");
        _assertSupply(id);
    }

    // 8. Decimal edges: the $0.10 minimum price, an odd price, the smallest terminal clamp.
    function test_decimal_edge_cases() public {
        // min price: 134 collects to graduate; the 134th is clamped to 33,334 units
        (uint256 id,,) = _publishOrdered(creator, MIN_PRICE, MAX_ALLOC_BPS, true);
        MomentCollect.Quote memory q = _collect(id, alice, 1);
        assertEq(q.reserveIn, 75_000);
        assertEq(q.platformIn, 5_000);
        assertEq(q.creatorIn, 20_000);
        assertEq(q.entitlement, 385714285714285714285714);
        for (uint256 i = 0; i < 132; i++) _collect(id, i % 2 == 0 ? alice : bob, 1);
        assertEq(collect.ledger(id).reserve, 9_975_000);
        q = _collect(id, carol, 1);
        assertTrue(q.terminal);
        assertEq(q.gross, 33_334);
        assertEq(q.reserveIn, 25_000);
        assertEq(q.editions, 1);
        assertEq(collect.ledger(id).collects, 134);
        assertEq(vesting.totalEntitlement(id), 51428573999999999999999962);
        _assertSupply(id);

        // an odd price: every split sums exactly, entitlements floor, identity holds
        (uint256 id2,,) = _publishOrdered(creator, 123_457, 777, false);
        uint256 sumGross;
        while (_state(id2) == MomentTypes.State.Collecting) {
            MomentCollect.Quote memory qq = _collect(id2, alice, 3);
            assertEq(qq.reserveIn + qq.creatorIn + qq.platformIn, qq.gross, "split sums exactly");
            sumGross += qq.gross;
        }
        assertEq(collect.ledger(id2).totalGross, sumGross);
        MomentGraduation.Record memory r2 = executor.record(id2);
        assertEq(r2.reserve, THRESHOLD, "reserve lands exactly on the threshold");
        assertEq(r2.poolCoins + vesting.totalEntitlement(id2) + S * 777 / BPS, S);
        _assertSupply(id2);
    }
}
