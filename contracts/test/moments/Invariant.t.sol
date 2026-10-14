// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockGraduation} from "./mocks/MockGraduation.sol";

/// Random collects / graduations / expiries / claims / withdrawals across three differently-priced Moments.
contract MomentsHandler is Test {
    MockUSDC public usdc;
    MomentCollect public collect;
    MomentVesting public vesting;
    MockGraduation public graduation;
    uint256[] public ids;
    address[] public actors;
    address public creator;
    address public platform;
    address public treasury;

    mapping(uint256 => uint256) public editionsMinted; // ghost: sum editions per moment
    mapping(uint256 => uint256) public reserveAtExpiry; // ghost: reserve wound down per moment
    uint256 public withdrawnCreator;
    uint256 public withdrawnPlatform;
    uint256 public withdrawnTreasury;

    constructor(
        MockUSDC u,
        MomentCollect c,
        MomentVesting v,
        MockGraduation g,
        uint256[] memory _ids,
        address[] memory _actors,
        address _creator,
        address _platform,
        address _treasury
    ) {
        usdc = u;
        collect = c;
        vesting = v;
        graduation = g;
        ids = _ids;
        actors = _actors;
        creator = _creator;
        platform = _platform;
        treasury = _treasury;
    }

    function collectRandom(uint256 momentSeed, uint256 actorSeed, uint256 qty) external {
        uint256 id = ids[momentSeed % ids.length];
        address who = actors[actorSeed % actors.length];
        qty = bound(qty, 1, MomentTypes.MAX_BATCH);
        if (collect.ledger(id).state != MomentTypes.State.Collecting) return;
        if (block.timestamp >= _deadline(id)) return;
        vm.prank(who);
        MomentCollect.Quote memory q = collect.collect(id, qty);
        editionsMinted[id] += q.editions;
    }

    function toggleGraduationFailure(bool fail) external {
        graduation.setFail(fail);
    }

    function retryGraduation(uint256 momentSeed) external {
        uint256 id = ids[momentSeed % ids.length];
        if (collect.ledger(id).state != MomentTypes.State.GraduationPending) return;
        if (graduation.failNext()) return;
        graduation.graduate(id);
    }

    function expire(uint256 momentSeed) external {
        uint256 id = ids[momentSeed % ids.length];
        MomentCollect.Ledger memory l = collect.ledger(id);
        if (l.state == MomentTypes.State.Collecting) {
            if (block.timestamp < _deadline(id)) return;
        } else if (l.state == MomentTypes.State.GraduationPending) {
            if (block.timestamp < _deadline(id) || block.timestamp < uint256(l.stuckSince) + MomentTypes.STUCK_GRACE) return;
        } else {
            return;
        }
        reserveAtExpiry[id] = l.reserve;
        collect.expire(id);
    }

    function claimRandom(uint256 momentSeed, uint256 actorSeed) external {
        uint256 id = ids[momentSeed % ids.length];
        address who = actorSeed % (actors.length + 1) == actors.length ? creator : actors[actorSeed % actors.length];
        (uint256 c, uint256 cr) = vesting.claimable(id, who);
        if (c + cr == 0) return;
        vm.prank(who);
        vesting.claim(id);
    }

    function warp(uint256 daysAhead) external {
        vm.warp(block.timestamp + bound(daysAhead, 1, 12) * 1 days);
    }

    function withdrawCreator(uint256 momentSeed) external {
        uint256 id = ids[momentSeed % ids.length];
        if (collect.ledger(id).creatorClaimable == 0) return;
        vm.prank(creator);
        withdrawnCreator += collect.withdrawCreator(id);
    }

    function withdrawPlatform(uint256 momentSeed) external {
        uint256 id = ids[momentSeed % ids.length];
        if (collect.ledger(id).platformClaimable == 0) return;
        vm.prank(platform);
        withdrawnPlatform += collect.withdrawPlatform(id);
    }

    function withdrawTreasury(uint256 momentSeed) external {
        uint256 id = ids[momentSeed % ids.length];
        if (collect.ledger(id).treasuryClaimable == 0) return;
        vm.prank(treasury);
        withdrawnTreasury += collect.withdrawTreasury(id);
    }

    function _deadline(uint256 id) internal view returns (uint64) {
        return collect.factory().getMoment(id).deadline;
    }
}

contract MomentsInvariantTest is MomentsBase {
    MomentsHandler handler;
    uint256[] ids;

    function setUp() public override {
        super.setUp();
        (uint256 a,,) = _publish(creator, MIN_PRICE, MAX_ALLOC_BPS, 1); // $0.10, 10%
        (uint256 b,,) = _publish(creator, PRICE, 400, 2); // $1, 4%
        (uint256 c,,) = _publish(creator, 5_000_000, 0, 3); // $5, 0%
        ids.push(a);
        ids.push(b);
        ids.push(c);
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        handler = new MomentsHandler(usdc, collect, vesting, graduation, ids, actors, creator, platform, treasury);
        targetContract(address(handler));
    }

    /// Supply: never over-promised while collecting; exactly S at/after graduation; zero forever after expiry.
    function invariant_supply() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            MomentTypes.Moment memory m = factory.getMoment(id);
            MomentCoin coin = MomentCoin(m.coin);
            MomentTypes.State st = collect.ledger(id).state;
            uint256 alloc = S * m.creatorAllocBps / BPS;
            if (st == MomentTypes.State.Graduated) {
                assertEq(graduation.poolCoins(id) + vesting.totalEntitlement(id) + alloc, S, "graduated: pool + sum ent + creator == S");
                assertEq(coin.totalSupply(), graduation.poolCoins(id) + vesting.totalMinted(id), "minted == pool seed + claims");
                assertLe(vesting.totalMinted(id), vesting.totalEntitlement(id) + alloc);
            } else {
                assertEq(coin.totalSupply(), 0, "no coin before graduation / ever after expiry");
                (uint256 ents, uint256 alloc2, uint256 remainderPool, uint256 impliedPool, uint256 collects) = collect.supplyCheck(id);
                assertEq(ents + alloc2 + remainderPool, S, "remainder pool closes the identity at every step");
                assertGt(remainderPool, 0, "the pool is never over-promised away");
                // the rate-implied pool can exceed the remainder only by integer rounding: < 1 USDC unit of reserve
                // flooring per collect, recovered by the clamp with up to BPS/reserveBps units of extra gross
                uint256 slack = collects * ((m.rateNum * BPS + m.rateDen * m.reserveBps - 1) / (m.rateDen * m.reserveBps) + 1);
                assertLe(impliedPool, remainderPool + slack, "implied pool within rounding slack of the remainder");
            }
            assertLe(coin.totalSupply(), S);
        }
    }

    /// Solvency: the collect contract holds exactly what it owes.
    function invariant_usdc_solvency() public view {
        uint256 owed;
        for (uint256 i = 0; i < ids.length; i++) {
            MomentCollect.Ledger memory l = collect.ledger(ids[i]);
            owed += l.reserve + l.creatorClaimable + l.platformClaimable + l.treasuryClaimable;
        }
        assertEq(usdc.balanceOf(address(collect)), owed);
    }

    /// Reserve never exceeds the threshold; Collecting implies strictly below it; the NFT closes exactly at
    /// graduation or expiry; an expired reserve is fully booked to creator + treasury and nothing else moves.
    function invariant_reserve_and_edition_bounds() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            MomentCollect.Ledger memory l = collect.ledger(id);
            MomentTypes.Moment memory m = factory.getMoment(id);
            MomentNFT nft = MomentNFT(m.nft);
            assertLe(l.reserve, m.threshold);
            if (l.state == MomentTypes.State.Collecting) assertLt(l.reserve, m.threshold);
            if (l.state == MomentTypes.State.GraduationPending) assertEq(l.reserve, m.threshold);
            if (l.state == MomentTypes.State.Expired) {
                assertEq(l.reserve, 0, "expired reserve fully wound down");
                assertGe(l.endedAt, m.deadline, "expiry never before the deadline");
                assertEq(vesting.graduatedAt(id), 0, "expired never vests");
            }
            assertEq(nft.totalMinted(), handler.editionsMinted(id));
            assertEq(nft.closed(), l.state == MomentTypes.State.Graduated || l.state == MomentTypes.State.Expired);
        }
    }
}
