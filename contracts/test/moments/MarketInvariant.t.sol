// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MomentsMarketBase} from "./MomentsMarketBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentFeeHook} from "../../src/moments/MomentFeeHook.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Phase 4: stateful invariants over the WHOLE stack on a real (local) PoolManager — collects, graduations,
/// expiries, claims, swaps in both directions, buybacks, fee withdrawals and time — three Moments with different
/// prices, allocations and currency orderings.
contract MarketHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockUSDC public usdc;
    IPoolManager public manager;
    PoolSwapTest public swapRouter;
    MomentsFactory public factory;
    MomentCollect public collect;
    MomentVesting public vesting;
    MomentGraduation public executor;
    MomentLocker public locker;
    MomentFeeHook public hook;
    MomentBuyback public buyback;
    uint256[] public ids;
    address[] public actors;
    address public creator;
    address public platform;
    address public treasury;

    mapping(uint256 => uint256) public editionsMinted; // ghost
    mapping(uint256 => uint128) public maxLiquidity; // ghost: high-water mark of the locked position
    mapping(uint256 => uint256) public buybackRounds;
    mapping(address => bool) coinApproved;
    uint256 public swaps;

    constructor(MarketInvariantTest b, uint256[] memory _ids, address[] memory _actors, address _creator, address _platform, address _treasury) {
        (usdc, manager, swapRouter, factory, collect, vesting, executor, locker, hook, buyback) = b.refs();
        ids = _ids;
        actors = _actors;
        creator = _creator;
        platform = _platform;
        treasury = _treasury;
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return ids[seed % ids.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function collectRandom(uint256 momentSeed, uint256 actorSeed, uint256 qty) external {
        uint256 id = _id(momentSeed);
        if (collect.state(id) != MomentTypes.State.Collecting) return;
        if (block.timestamp >= factory.getMoment(id).deadline) return;
        qty = bound(qty, 1, MomentTypes.MAX_BATCH);
        vm.prank(_actor(actorSeed));
        MomentCollect.Quote memory q = collect.collect(id, qty);
        editionsMinted[id] += q.editions;
        _track(id);
    }

    function retryGraduation(uint256 momentSeed) external {
        uint256 id = _id(momentSeed);
        if (collect.state(id) != MomentTypes.State.GraduationPending) return;
        try executor.graduate(id) {} catch {}
        _track(id);
    }

    function expire(uint256 momentSeed) external {
        uint256 id = _id(momentSeed);
        MomentCollect.Ledger memory l = collect.ledger(id);
        uint64 deadline = factory.getMoment(id).deadline;
        if (l.state == MomentTypes.State.Collecting) {
            if (block.timestamp < deadline) return;
        } else if (l.state == MomentTypes.State.GraduationPending) {
            if (block.timestamp < deadline || block.timestamp < uint256(l.stuckSince) + MomentTypes.STUCK_GRACE) return;
        } else {
            return;
        }
        collect.expire(id);
    }

    function claim(uint256 momentSeed, uint256 actorSeed) external {
        uint256 id = _id(momentSeed);
        address who = actorSeed % (actors.length + 1) == actors.length ? creator : _actor(actorSeed);
        (uint256 c, uint256 cr) = vesting.claimable(id, who);
        if (c + cr == 0) return;
        vm.prank(who);
        vesting.claim(id);
    }

    function buy(uint256 momentSeed, uint256 actorSeed, uint256 usdcIn) external {
        uint256 id = _id(momentSeed);
        if (!executor.isGraduated(id)) return;
        usdcIn = bound(usdcIn, 1_000, 30_000_000); // $0.001 .. $30 (a $10 pool: big moves are part of the point)
        PoolKey memory key = executor.poolKeyOf(id);
        bool usdcIs0 = address(usdc) < factory.getMoment(id).coin;
        _swap(_actor(actorSeed), key, usdcIs0, -int256(usdcIn));
        _track(id);
    }

    function sell(uint256 momentSeed, uint256 actorSeed, uint256 fractionBps) external {
        uint256 id = _id(momentSeed);
        if (!executor.isGraduated(id)) return;
        address who = _actor(actorSeed);
        MomentCoin coin = MomentCoin(factory.getMoment(id).coin);
        uint256 bal = coin.balanceOf(who);
        if (bal == 0) return;
        uint256 amount = bal * bound(fractionBps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        if (!coinApproved[who]) {
            vm.prank(who);
            coin.approve(address(swapRouter), type(uint256).max);
        }
        PoolKey memory key = executor.poolKeyOf(id);
        bool usdcIs0 = address(usdc) < address(coin);
        _swap(who, key, !usdcIs0, -int256(amount));
        _track(id);
    }

    function runBuyback(uint256 momentSeed) external {
        uint256 id = _id(momentSeed);
        if (!executor.isGraduated(id)) return;
        if (block.timestamp < uint256(buyback.lastRun(id)) + buyback.MIN_INTERVAL()) return;
        if (hook.buybackAccrued(id) + buyback.carry(id) < buyback.MIN_AMOUNT()) return;
        buyback.execute(id, 0);
        buybackRounds[id]++;
        _track(id);
    }

    function withdrawFees(uint256 momentSeed, uint256 which) external {
        uint256 id = _id(momentSeed);
        which = which % 6;
        if (which == 0 && collect.ledger(id).creatorClaimable != 0) {
            vm.prank(creator);
            collect.withdrawCreator(id);
        } else if (which == 1 && collect.ledger(id).platformClaimable != 0) {
            vm.prank(platform);
            collect.withdrawPlatform(id);
        } else if (which == 2 && collect.ledger(id).treasuryClaimable != 0) {
            vm.prank(treasury);
            collect.withdrawTreasury(id);
        } else if (which == 3 && hook.creatorAccrued(id) != 0) {
            vm.prank(creator);
            hook.withdrawCreator(id);
        } else if (which == 4 && hook.platformAccrued(id) != 0) {
            vm.prank(platform);
            hook.withdrawPlatform(id);
        }
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 4 days));
    }

    function _swap(address who, PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(who);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        swaps++;
    }

    function _track(uint256 id) internal {
        if (!executor.isGraduated(id)) return;
        uint128 l = locker.liquidityOf(id);
        if (l > maxLiquidity[id]) maxLiquidity[id] = l;
    }
}

contract MarketInvariantTest is MomentsMarketBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MarketHandler handler;
    uint256[] ids;

    function refs()
        external
        view
        returns (MockUSDC, IPoolManager, PoolSwapTest, MomentsFactory, MomentCollect, MomentVesting, MomentGraduation, MomentLocker, MomentFeeHook, MomentBuyback)
    {
        return (usdc, manager, swapRouter, factory, collect, vesting, executor, locker, hook, buyback);
    }

    function setUp() public override {
        super.setUp();
        (uint256 a,,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true); // $1, 10%, USDC = currency0
        (uint256 b,,) = _publishOrdered(creator, 250_000, 400, false); // $0.25, 4%, coin = currency0
        (uint256 c,,) = _publishOrdered(creator, 5_000_000, 0, true); // $5, 0%
        ids.push(a);
        ids.push(b);
        ids.push(c);
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        handler = new MarketHandler(this, ids, actors, creator, platform, treasury);
        targetContract(address(handler));
    }

    /// Supply conservation in every state; nothing minted before graduation; never above S.
    function invariant_supply_identity() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            MomentTypes.Moment memory m = factory.getMoment(id);
            MomentCoin coin = MomentCoin(m.coin);
            uint256 alloc = S * m.creatorAllocBps / BPS;
            if (executor.isGraduated(id)) {
                MomentGraduation.Record memory r = executor.record(id);
                assertEq(r.poolCoins + vesting.totalEntitlement(id) + alloc, S, "pool + sum ent + creator == S");
                assertEq(coin.totalSupply(), r.poolCoins + vesting.totalMinted(id), "minted == seed + claims");
                assertLe(vesting.creatorClaimed(id), alloc);
                assertLe(vesting.totalMinted(id), vesting.totalEntitlement(id) + alloc);
            } else {
                assertEq(coin.totalSupply(), 0, "no coin before graduation / after expiry");
                (uint256 ents, uint256 alloc2, uint256 remainder,,) = collect.supplyCheck(id);
                assertEq(ents + alloc2 + remainder, S);
            }
            assertLe(coin.totalSupply(), S);
        }
    }

    /// Every contract holds exactly what it owes; nothing sits in the executor.
    function invariant_usdc_and_coin_solvency() public view {
        uint256 owedCollect;
        uint256 owedHook;
        uint256 owedBuyback;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            MomentCollect.Ledger memory l = collect.ledger(id);
            owedCollect += l.reserve + l.creatorClaimable + l.platformClaimable + l.treasuryClaimable;
            owedHook += hook.creatorAccrued(id) + hook.platformAccrued(id) + hook.buybackAccrued(id);
            owedBuyback += buyback.carry(id);
            MomentCoin coin = MomentCoin(factory.getMoment(id).coin);
            assertEq(coin.balanceOf(address(executor)), 0, "executor never holds coin");
            assertEq(coin.balanceOf(address(hook)), 0, "hook never holds coin");
            assertEq(coin.balanceOf(address(buyback)), 0, "buyback never holds coin");
            assertEq(coin.balanceOf(address(collect)), 0, "collect never holds coin");
        }
        assertEq(usdc.balanceOf(address(collect)), owedCollect, "collect solvency");
        assertEq(usdc.balanceOf(address(hook)), owedHook, "hook solvency");
        assertEq(usdc.balanceOf(address(buyback)), owedBuyback, "buyback holds only carry");
        assertEq(usdc.balanceOf(address(executor)), 0, "executor never holds USDC");
    }

    /// The locked position only ever grows, is owned by the locker, and is the pool's only liquidity.
    function invariant_locked_liquidity_monotone() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (!executor.isGraduated(id)) {
                assertEq(locker.liquidityOf(id), 0);
                continue;
            }
            PoolKey memory key = executor.poolKeyOf(id);
            uint128 l = locker.liquidityOf(id);
            assertGe(l, executor.record(id).liquidity, "never below the seed");
            assertGe(l, handler.maxLiquidity(id), "never below its own high-water mark");
            assertEq(_lockerPositionLiquidity(id, key), l, "PoolManager agrees with the locker's record");
            assertEq(_poolLiquidity(key), l, "the locked position is the whole pool");
            uint160 sp = _sqrtPrice(key);
            assertGt(sp, TickMath.MIN_SQRT_PRICE);
            assertLt(sp, TickMath.MAX_SQRT_PRICE);
        }
    }

    /// Collect ledger + NFT edition consistency; state machine; expiry booked exactly.
    function invariant_ledger_and_nft() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            MomentTypes.Moment memory m = factory.getMoment(id);
            MomentCollect.Ledger memory l = collect.ledger(id);
            MomentNFT nft = MomentNFT(m.nft);
            assertLe(l.reserve, m.threshold);
            if (l.state == MomentTypes.State.Collecting) assertLt(l.reserve, m.threshold);
            if (l.state == MomentTypes.State.GraduationPending) assertEq(l.reserve, m.threshold);
            if (l.state == MomentTypes.State.Graduated) {
                assertEq(l.reserve, 0);
                assertTrue(executor.isGraduated(id));
                assertGt(vesting.graduatedAt(id), 0);
            }
            if (l.state == MomentTypes.State.Expired) {
                assertEq(l.reserve, 0);
                assertGe(l.endedAt, m.deadline);
                assertEq(vesting.graduatedAt(id), 0);
                assertFalse(executor.isGraduated(id));
            }
            assertEq(nft.totalMinted(), handler.editionsMinted(id), "editions == ghost");
            assertEq(nft.totalSupply(), nft.totalMinted(), "no burns");
            assertEq(nft.closed(), l.state == MomentTypes.State.Graduated || l.state == MomentTypes.State.Expired, "closed iff ended");
            if (nft.totalMinted() > 0) assertEq(nft.ownerOf(1) != address(0), true);
        }
    }

    /// Per-account vesting never exceeds the entitlement; claimable is what the schedule says.
    function invariant_vesting_bounds() public view {
        address[4] memory accts = [alice, bob, carol, creator];
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            for (uint256 k = 0; k < accts.length; k++) {
                uint256 ent = vesting.entitlement(id, accts[k]);
                assertLe(vesting.claimed(id, accts[k]), ent, "claimed <= entitlement");
                (uint256 c, uint256 cr) = vesting.claimable(id, accts[k]);
                assertLe(vesting.claimed(id, accts[k]) + c, ent);
                if (accts[k] != creator) assertEq(cr, 0, "only the creator has a creator tranche");
            }
        }
    }
}
