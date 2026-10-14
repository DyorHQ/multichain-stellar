// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MomentsForkBase} from "./MomentsForkBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MomentTypes} from "../../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../../src/moments/MomentGraduation.sol";
import {MomentBuyback} from "../../../src/moments/MomentBuyback.sol";
import {MomentCoin} from "../../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../../src/moments/MomentNFT.sol";

/// Phase 3, part 1: the full $10 lifecycle on Monad mainnet state, reconciled to economics.py.
contract LifecycleForkTest is MomentsForkBase {
    uint256 constant E1 = 3857142857142857142857142; // entitlement of a $1 collect
    uint256 constant ET = 1285716857142857142857142; // entitlement of the clamped terminal collect (333,334)
    uint256 constant SUM_ENT = 51428573999999999999999988;
    uint256 constant POOL = 38571426000000000000000012;
    uint256 constant MODEL_COLLECTORS = 51428571428571428571428571; // 51,428,571.4286 coins
    uint256 constant MODEL_POOL = 38571428571428571428571429;
    uint256 constant MODEL_PRICE_X18 = 259259259259; // 2.5925926e-7 USDC/coin, x1e18

    function test_full_lifecycle_reconciles_with_the_model() public {
        // ---- publish (creator sets $1, 10% alloc, 30-day window)
        (uint256 id, MomentCoin coin, MomentNFT nft) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        bool usdcIs0 = true;
        _assertSupply(id);

        // ---- collect: 13 x $1 across three wallets, then a clamped terminal collect
        for (uint256 i = 0; i < 5; i++) _collect(id, alice, 1);
        for (uint256 i = 0; i < 5; i++) _collect(id, bob, 1);
        for (uint256 i = 0; i < 3; i++) _collect(id, carol, 1);
        _assertSupply(id);
        assertEq(collect.ledger(id).reserve, 9_750_000);
        uint256 daveBefore = usdc.balanceOf(dave);
        MomentCollect.Quote memory q = _collect(id, dave, 2); // asks $2, only 333,334 is accepted
        assertTrue(q.terminal);
        assertEq(q.gross, 333_334);
        assertEq(q.excess, 1_666_666);
        assertEq(daveBefore - usdc.balanceOf(dave), 333_334, "only the accepted amount left dave's wallet");
        assertEq(q.editions, 1);

        // ---- graduated inside that collect, on the real PoolManager
        MomentCollect.Ledger memory l = collect.ledger(id);
        assertEq(uint8(l.state), uint8(MomentTypes.State.Graduated));
        MomentGraduation.Record memory r = executor.record(id);
        assertEq(r.reserve, THRESHOLD);
        assertEq(vesting.totalEntitlement(id), SUM_ENT);
        assertEq(vesting.entitlement(id, alice), 5 * E1);
        assertEq(vesting.entitlement(id, dave), ET);
        assertEq(r.poolCoins, POOL);
        assertEq(r.poolCoins + SUM_ENT + 1e25, S, "conservation identity at graduation");
        assertEq(coin.totalSupply(), POOL, "only the pool seed exists");
        assertEq(nft.totalMinted(), 14);
        assertTrue(nft.closed());
        assertEq(vesting.graduatedAt(id), uint64(block.timestamp));
        _assertSupply(id);

        // ---- reconcile the emergent allocation with economics.py (differences == the terminal clamp shift)
        assertLt(_absDiff(SUM_ENT, MODEL_COLLECTORS), 3e18, "collectors within 3 coins of the model");
        assertLt(_absDiff(POOL, MODEL_POOL), 3e18, "pool within 3 coins of the model");
        assertEq(SUM_ENT - MODEL_COLLECTORS, MODEL_POOL - POOL, "what collectors gained the pool gave");
        // proceeds: $13.33 collected -> creator $2.67 / platform $0.67 / reserve $10.00
        assertEq(l.totalGross, 13_333_334);
        assertEq(l.creatorClaimable, 2_666_668);
        assertEq(l.platformClaimable, 666_666);
        // opening price vs the model's 2.5926e-7 USDC/coin
        uint256 priceX18 = _usdcPerCoinX18(r.key, usdcIs0);
        assertLt(_absDiff(priceX18, MODEL_PRICE_X18) * 1_000_000, MODEL_PRICE_X18, "opening price within 1e-6 of the model");
        console2.log("opening price (USDC/coin x1e18):", priceX18, " model:", MODEL_PRICE_X18);

        // ---- price continuity: a first tiny buy executes at the collectors' rate minus the two fees
        {
            MomentTypes.Moment memory m = factory.getMoment(id);
            uint256 before = coin.balanceOf(eve);
            _buyExactIn(eve, r.key, usdcIs0, 1_000);
            uint256 got = coin.balanceOf(eve) - before;
            uint256 net = 1_000 * (BPS - hook.FEE_BPS()) / BPS * (1_000_000 - executor.LP_FEE()) / 1_000_000;
            uint256 expected = FullMath.mulDiv(net, m.rateNum, m.rateDen);
            assertLt(_absDiff(got, expected) * 2_000, expected, "+0.00% jump: within 0.05% of the collectors' rate");
        }

        // ---- trading through the v4 test router and through the REAL Universal Router
        uint256 fee0 = hook.creatorAccrued(id) + hook.platformAccrued(id) + hook.buybackAccrued(id);
        _buyExactIn(bob, r.key, usdcIs0, 1_000_000); // $1 buy: 10,000 fee -> 2,000 / 3,000 / 5,000
        assertEq(hook.creatorAccrued(id) + hook.platformAccrued(id) + hook.buybackAccrued(id) - fee0, 10_000);
        // alice claims at graduation and sells 1M coins through the Universal Router (Permit2-funded)
        vm.prank(alice);
        vesting.claim(id);
        assertEq(coin.balanceOf(alice), FullMath.mulDiv(5 * E1, 6_000, BPS), "60% liquid at graduation");
        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 fee1 = hook.creatorAccrued(id) + hook.platformAccrued(id) + hook.buybackAccrued(id);
        _urSwapExactIn(alice, r.key, !usdcIs0, 1e24);
        uint256 received = usdc.balanceOf(alice) - aliceUsdc0;
        uint256 urFee = hook.creatorAccrued(id) + hook.platformAccrued(id) + hook.buybackAccrued(id) - fee1;
        assertGt(received, 0, "Universal Router sell paid out USDC");
        assertEq(urFee, (received + urFee) * hook.FEE_BPS() / BPS, "hook took 1% of the gross USDC out via the UR");
        _assertSupply(id);

        // ---- vesting cliffs: collectors 60/80/100, creator 20 + 16/month x5
        uint64 g = vesting.graduatedAt(id);
        vm.prank(creator);
        vesting.claim(id);
        assertEq(coin.balanceOf(creator), 2_000_000e18, "creator 20% at graduation");
        vm.warp(g + MomentTypes.MONTH);
        vm.prank(alice);
        vesting.claim(id);
        assertEq(vesting.claimed(id, alice), FullMath.mulDiv(5 * E1, 8_000, BPS), "80% after month 1");
        vm.prank(creator);
        vesting.claim(id);
        assertEq(vesting.creatorClaimed(id), 3_600_000e18, "creator 36% after month 1");
        vm.warp(g + 2 * MomentTypes.MONTH);
        vm.prank(alice);
        vesting.claim(id);
        assertEq(vesting.claimed(id, alice), 5 * E1, "100% after month 2");
        vm.prank(bob);
        vesting.claim(id);
        vm.prank(carol);
        vesting.claim(id);
        vm.prank(dave);
        vesting.claim(id);
        assertEq(vesting.totalMinted(id) - vesting.creatorClaimed(id), SUM_ENT, "every collector fully vested");
        vm.warp(g + 5 * MomentTypes.MONTH);
        vm.prank(creator);
        vesting.claim(id);
        assertEq(vesting.creatorClaimed(id), 10_000_000e18, "creator fully vested at month 5");
        assertEq(coin.totalSupply(), S, "pool + collectors + creator == S, everything minted");
        _assertSupply(id);

        // ---- fees -> buyback deepens the locked pool
        _approveCoin(coin, bob);
        for (uint256 i = 0; i < 12; i++) {
            uint256 c0 = coin.balanceOf(bob);
            _buyExactIn(bob, r.key, usdcIs0, 10_000_000);
            _sellExactIn(bob, r.key, usdcIs0, coin.balanceOf(bob) - c0);
        }
        // v2 (MO-2): the round runs in a later block than the burst, like a keeper's; within the burst's block its
        // drift (>2% on this small pool) trips the block-open price guard.
        vm.roll(vm.getBlockNumber() + 1);
        uint128 liq0 = _lockerPositionLiquidity(id, r.key);
        MomentBuyback.Round memory round = buyback.execute(id, 0);
        assertGt(round.liquidityAdded, 0);
        assertEq(_lockerPositionLiquidity(id, r.key), liq0 + round.liquidityAdded, "buyback deepened the locked position");
        assertEq(hook.buybackAccrued(id), 0);

        // ---- pull-only payouts: collect proceeds + trading fees
        uint256 creatorUsdc0 = usdc.balanceOf(creator);
        vm.startPrank(creator);
        collect.withdrawCreator(id);
        hook.withdrawCreator(id);
        vm.stopPrank();
        assertGt(usdc.balanceOf(creator) - creatorUsdc0, 2_666_668, "creator: $2.67 of collects plus 0.2% of trading");
        uint256 platformUsdc0 = usdc.balanceOf(platform);
        vm.startPrank(platform);
        collect.withdrawPlatform(id);
        hook.withdrawPlatform(id);
        vm.stopPrank();
        assertGt(usdc.balanceOf(platform) - platformUsdc0, 666_666, "platform: $0.67 of collects plus 0.3% of trading");
        assertEq(usdc.balanceOf(address(collect)), 0, "collect contract fully drained by its beneficiaries");
        assertEq(usdc.balanceOf(address(hook)), 0, "hook fully drained: creator + platform + buyback");
        assertEq(usdc.balanceOf(address(executor)), 0);
        _assertSupply(id);
    }

    /// Dump-impact figures from economics.py, each from the pool's opening state (snapshot/revert).
    function test_dump_impacts_reconcile_with_the_model() public {
        (uint256 id, MomentCoin coin,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        bool usdcIs0 = true;
        for (uint256 i = 0; i < 5; i++) _collect(id, alice, 1);
        for (uint256 i = 0; i < 5; i++) _collect(id, bob, 1);
        for (uint256 i = 0; i < 2; i++) _collect(id, carol, 1);
        _collect(id, dave, 1); // exactly one $1 bundle
        _collect(id, eve, 1); // terminal (clamped)
        MomentGraduation.Record memory r = executor.record(id);
        PoolKey memory key = r.key;
        _approveCoin(coin, alice);
        _approveCoin(coin, bob);
        _approveCoin(coin, carol);
        _approveCoin(coin, dave);
        _approveCoin(coin, eve);
        _approveCoin(coin, creator);
        uint256 x = r.usedCoin;
        uint256 y = r.usedUsdc;
        uint256 snap = vm.snapshotState();

        // 1. creator grad-day unlock (2M coins): model 9.62% (fee-adjusted 9.57%), nets ~0.49 USDC
        vm.prank(creator);
        vesting.claim(id);
        _checkDump(key, usdcIs0, x, y, creator, 2_000_000e18, 962e14, "creator grad-day 2M");
        vm.revertToState(snap);

        // 2. creator monthly unlock (1.6M coins): model 7.81%
        vm.warp(vesting.graduatedAt(id) + MomentTypes.MONTH);
        vm.prank(creator);
        vesting.claim(id);
        _checkDump(key, usdcIs0, x, y, creator, 1_600_000e18, 781e14, "creator monthly 1.6M");
        vm.revertToState(snap);

        // 3. a $1 collector's full bundle (3.857M coins, fully vested at month 2): model 17.36%
        vm.warp(vesting.graduatedAt(id) + 2 * MomentTypes.MONTH);
        vm.prank(dave);
        vesting.claim(id);
        assertEq(coin.balanceOf(dave), 3857142857142857142857142);
        _checkDump(key, usdcIs0, x, y, dave, coin.balanceOf(dave), 1736e14, "$1 bundle");
        vm.revertToState(snap);

        // 4. ALL liquid collectors dump at open (60% of every entitlement): model 69.14%
        address[5] memory cs = [alice, bob, carol, dave, eve];
        uint256 total;
        for (uint256 i = 0; i < cs.length; i++) {
            vm.prank(cs[i]);
            vesting.claim(id);
            total += coin.balanceOf(cs[i]);
        }
        assertLt(_absDiff(total, 30857142857142857142857143), 3e18, "liquid float == 60% of collectors (clamp shift only)");
        uint256 p0 = _usdcPerCoinX18(key, usdcIs0);
        uint256 pm0 = usdc.balanceOf(address(manager));
        for (uint256 i = 0; i < cs.length; i++) _sellExactIn(cs[i], key, usdcIs0, coin.balanceOf(cs[i]));
        {
            uint256 p1 = _usdcPerCoinX18(key, usdcIs0);
            uint256 drop = 1e18 - FullMath.mulDiv(p1, 1e18, p0);
            (uint256 expOut, uint256 expDrop) = _expectedSell(x, y, total);
            console2.log("all liquid dump: drop x1e18", drop, " out (USDC units)", pm0 - usdc.balanceOf(address(manager)));
            assertLt(_absDiff(drop, expDrop), 1e15, "matches fee-adjusted constant product within 0.1pp (sequential sells)");
            assertLt(_absDiff(drop, 6914e14), 3e15, "within 0.3pp of the model's 69.14%");
            assertLt(_absDiff(pm0 - usdc.balanceOf(address(manager)), expOut) * 100, expOut, "USDC out within 1%");
        }
        vm.revertToState(snap);

        // 5. 10% of the liquid float dumps: model 14.27%
        vm.prank(alice);
        vesting.claim(id);
        _checkDump(key, usdcIs0, x, y, alice, 3085714285714285714285714, 1427e14, "10% of liquid float");
    }

    function _checkDump(PoolKey memory key, bool usdcIs0, uint256 x, uint256 y, address who, uint256 coinsIn, uint256 modelDropX18, string memory label) internal {
        uint256 p0 = _usdcPerCoinX18(key, usdcIs0);
        uint256 pm0 = usdc.balanceOf(address(manager));
        _sellExactIn(who, key, usdcIs0, coinsIn);
        uint256 p1 = _usdcPerCoinX18(key, usdcIs0);
        uint256 drop = 1e18 - FullMath.mulDiv(p1, 1e18, p0);
        uint256 out = pm0 - usdc.balanceOf(address(manager));
        (uint256 expOut, uint256 expDrop) = _expectedSell(x, y, coinsIn);
        console2.log(label);
        console2.log("  price drop x1e18:", drop, " fee-adjusted expectation:", expDrop);
        console2.log("  USDC out (units):", out, " expectation:", expOut);
        assertLt(_absDiff(drop, expDrop), 1e14, "matches the fee-adjusted constant product within 0.01pp");
        assertLt(_absDiff(drop, modelDropX18), 2e15, "within 0.2pp of economics.py");
        assertLt(_absDiff(out, expOut) * 1000, expOut, "USDC out within 0.1%");
    }
}
