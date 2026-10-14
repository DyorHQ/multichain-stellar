// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsMarketBase} from "../moments/MomentsMarketBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

/// sec2 (2026-09-27 audit follow-up) on the v2 Moments stack: the cross-block buyback sandwich (MO-2 residual),
/// binding publish to the reviewed policy (MO-4), per-Moment external links (MO-8) and the price ceiling.
contract Sec2MomentsTest is MomentsMarketBase {
    // ---------------------------------------------------------------- MO-2: cross-block sandwich of a buyback round

    /// A graduated Moment with a buyback budget accrued from `roundTrips` $10 buy/sell round trips.
    function _feeMoment(uint256 roundTrips) internal returns (uint256 id, MomentCoin coin, PoolKey memory key) {
        (id, coin,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _completeWithSingles(id, alice);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));
        key = executor.poolKeyOf(id);
        _approveCoin(coin, bob);
        _approveCoin(coin, carol);
        for (uint256 i = 0; i < roundTrips; i++) {
            uint256 c0 = coin.balanceOf(bob);
            _buyExactIn(bob, key, true, 10_000_000);
            _sellExactIn(bob, key, true, coin.balanceOf(bob) - c0);
        }
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// Push the price in block N, run the (permissionless) round as the first swap of block N+1, where the in-block
    /// guard passes, and unwind. The round re-adds the Moment's folded LP fees and the USDC top-up at the pushed
    /// price; the attacker must not come out ahead.
    function _crossBlockSandwich(uint256 id, MomentCoin coin, PoolKey memory key, uint256 push) internal returns (int256 pnl) {
        uint256 u0 = usdc.balanceOf(carol);
        _buyExactIn(carol, key, true, push); // block N
        uint256 pushed = coin.balanceOf(carol);
        vm.roll(vm.getBlockNumber() + 1); // block N+1: the buyback's own swap is the first of the block
        MomentBuyback.Round memory r = buyback.execute(id, 0);
        _sellExactIn(carol, key, true, pushed);
        assertEq(coin.balanceOf(carol), 0, "the attacker holds no coin afterwards");
        pnl = int256(usdc.balanceOf(carol)) - int256(u0);
        emit log_named_uint("round budget", r.budget);
        emit log_named_uint("liquidity added", r.liquidityAdded);
        emit log_named_int("attacker PnL (USDC units)", pnl);
    }

    function test_MO2_crossBlockSandwich_ofABuybackRound_losesMoney() public {
        (uint256 id, MomentCoin coin, PoolKey memory key) = _feeMoment(20);
        assertLt(_crossBlockSandwich(id, coin, key, 10_000_000), 0, "cross-block sandwich of the buyback round profits");
    }

    function test_MO2_crossBlockSandwich_losesMoney_evenWithFourTimesTheFees() public {
        (uint256 id, MomentCoin coin, PoolKey memory key) = _feeMoment(80);
        assertLt(_crossBlockSandwich(id, coin, key, 15_000_000), 0, "profit scales with what the round adds");
    }

    /// The same sandwich run by `who`, counting the creator's 20% of the hook fee on the push as income.
    function _crossBlockSandwichBy(address who, uint256 id, MomentCoin coin, PoolKey memory key, uint256 push) internal returns (int256 pnl) {
        _approveCoin(coin, who);
        uint256 u0 = usdc.balanceOf(who);
        uint256 fees0 = hook.creatorAccrued(id);
        uint256 c0 = coin.balanceOf(who);
        _buyExactIn(who, key, true, push); // block N
        uint256 pushed = coin.balanceOf(who) - c0;
        vm.roll(vm.getBlockNumber() + 1); // block N+1: the round runs first
        buyback.execute(id, 0);
        _sellExactIn(who, key, true, pushed);
        int256 feesBack = who == creator ? int256(hook.creatorAccrued(id) - fees0) : int256(0);
        pnl = int256(usdc.balanceOf(who)) - int256(u0) + feesBack;
        emit log_named_int("PnL (USDC units)", pnl);
    }

    /// The add cap is in liquidity, so what one round hands a price pusher grows with the push. With 2% the creator
    /// (who gets 20% of the hook fee back) profited from pushes many times the pool's USDC side on a Moment with a
    /// large carried budget (the re-audit: +0.51, +1.56 and +3.31 USDC on 200, 500 and 1,000 USDC). At 0.5% every
    /// push loses more than 0.5% of its size, the creator's included.
    function test_MO2_creatorSandwich_ofPushesManyTimesThePool_losesMoney() public {
        (uint256 id, MomentCoin coin, PoolKey memory key) = _feeMoment(300);
        assertGt(hook.buybackAccrued(id), 25_000_000, "a large carried budget");
        uint256 poolUsdc = usdc.balanceOf(address(manager));
        uint256[3] memory pushes = [uint256(200_000_000), 500_000_000, 1_000_000_000];
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < pushes.length; i++) {
            assertGe(pushes[i], 5 * poolUsdc, "the push dwarfs the pool");
            int256 pnl = _crossBlockSandwichBy(creator, id, coin, key, pushes[i]);
            assertLt(pnl, -int256(pushes[i] / 200), "the creator's sandwich must lose more than 0.5% of the push");
            vm.revertToState(snap);
        }
    }

    function test_MO2_outsiderSandwich_ofALargePush_losesMore() public {
        (uint256 id, MomentCoin coin, PoolKey memory key) = _feeMoment(300);
        uint256 snap = vm.snapshotState();
        int256 byCreator = _crossBlockSandwichBy(creator, id, coin, key, 1_000_000_000);
        vm.revertToState(snap);
        int256 byOutsider = _crossBlockSandwichBy(carol, id, coin, key, 1_000_000_000);
        assertLt(byOutsider, byCreator, "an outsider gets no fee back");
        assertLt(byOutsider, -int256(uint256(1_000_000_000) / 100), "and loses more than 1% of the push");
    }

    /// The cap: one round grows the position by at most MAX_INCREASE_BPS; what it could not add stays held for the
    /// Moment (nothing is lost) and later rounds add it.
    function test_MO2_roundAdd_isCapped_andTheRestIsAddedLater() public {
        (uint256 id, MomentCoin coin, PoolKey memory key) = _feeMoment(80);
        uint128 before = locker.liquidityOf(id);
        MomentBuyback.Round memory r = buyback.execute(id, 0);
        assertEq(r.liquidityAdded, uint128(uint256(before) * locker.MAX_INCREASE_BPS() / BPS), "capped at 2% of the position");
        uint256 heldUsdc = locker.available(id, key.currency0);
        uint256 heldCoin = locker.available(id, key.currency1);
        assertGt(heldUsdc + heldCoin, 0, "the rest is held for this Moment");
        // later rounds keep pairing it (each needs its own budget; more trading refills it)
        for (uint256 i = 0; i < 20; i++) {
            uint256 c0 = coin.balanceOf(bob);
            _buyExactIn(bob, key, true, 10_000_000);
            _sellExactIn(bob, key, true, coin.balanceOf(bob) - c0);
        }
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 1);
        MomentBuyback.Round memory r2 = buyback.execute(id, 0);
        assertGt(r2.liquidityAdded, 0);
        assertLe(r2.liquidityAdded, uint128(uint256(locker.liquidityOf(id) - r2.liquidityAdded) * locker.MAX_INCREASE_BPS() / BPS));
    }

    // ---------------------------------------------------------------- MO-4: publish bound to the reviewed policy

    function _policyB() internal returns (MomentTypes.Policy memory p) {
        p = _policy(THRESHOLD);
        p.creatorBps = 0;
        p.platformBps = 2_500;
        p.expiryCreatorBps = 0;
        p.treasury = makeAddr("otherTreasury");
    }

    /// Once a proposal matures, anyone can apply it right in front of a creator's publish. The Moment must never be
    /// created under terms other than the ones the creator's app showed: publish is bound to the terms hash.
    function test_MO4_frontRunApply_cannotChangeTheTermsACreatorPublishesUnder() public {
        vm.prank(gov);
        factory.proposePolicy(_policyB());
        vm.warp(vm.getBlockTimestamp() + factory.POLICY_DELAY());
        (,, uint16 creatorBpsShown,,,,,,,) = factory.policy();
        assertEq(creatorBpsShown, CREATOR_BPS, "what the creator's app shows");
        bytes32 shown = factory.termsHash();
        vm.prank(makeAddr("anyone"));
        factory.applyPolicy();
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.TermsChanged.selector);
        factory.publish(_params(PRICE, 0, 1), shown);
        // The app re-reads and shows the new terms; publishing under those is the creator's informed choice.
        bytes32 now_ = factory.termsHash();
        vm.prank(creator);
        (uint256 id,,) = factory.publish(_params(PRICE, 0, 1), now_);
        assertEq(factory.getMoment(id).creatorBps, 0);
    }

    function test_MO4_baseChange_alsoInvalidatesTheShownTerms() public {
        bytes32 shown = factory.termsHash();
        vm.prank(gov);
        factory.setExternalBaseURI("https://elsewhere.example/");
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.TermsChanged.selector);
        factory.publish(_params(PRICE, 0, 1), shown);
    }

    /// A proposal nobody applied must lapse instead of staying applicable forever.
    function test_MO4_staleProposal_lapses() public {
        vm.prank(gov);
        factory.proposePolicy(_policyB());
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(MomentsFactory.PolicyLapsed.selector);
        factory.applyPolicy();
    }

    function test_MO4_proposal_appliesUntilTheEndOfItsWindow() public {
        vm.prank(gov);
        factory.proposePolicy(_policyB());
        uint256 at = factory.pendingPolicyAt();
        vm.warp(at + factory.POLICY_APPLY_WINDOW());
        factory.applyPolicy();
        (,, uint16 creatorBps,,,,,,,) = factory.policy();
        assertEq(creatorBps, 0);
    }

    /// Under a governance-key compromise (SEC-1: a plain EOA) the key proposes a policy that pays it 99.99% of every
    /// collect and takes over governance. The guardian, a different key, cancels the proposal and pauses publishing,
    /// and governance can neither lift that pause nor replace the guardian.
    function test_MO4_compromisedGovernance_isContainedByTheGuardian() public {
        address guardianKey = makeAddr("guardian");
        MomentsFactory f = _factoryWithGuardian(guardianKey);
        address attacker = makeAddr("attacker");
        MomentTypes.Policy memory evil = _policy(THRESHOLD);
        evil.creatorBps = 0;
        evil.reserveBps = 1;
        evil.platformBps = 9_999;
        evil.expiryCreatorBps = 0;
        evil.platform = attacker;
        evil.treasury = attacker;
        vm.startPrank(gov); // whoever holds the one hot key
        f.proposePolicy(evil);
        f.transferGovernance(attacker);
        vm.stopPrank();
        vm.prank(attacker);
        f.acceptGovernance();

        vm.startPrank(guardianKey);
        f.cancelPolicy();
        f.setGuardianPaused(true);
        vm.stopPrank();
        assertEq(f.pendingPolicyAt(), 0, "the proposal is gone");
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(MomentsFactory.NoPendingPolicy.selector);
        f.applyPolicy();

        vm.startPrank(attacker);
        f.setPublishingPaused(false); // governance's own switch: does not lift the guardian's
        vm.expectRevert(MomentsFactory.NotGuardian.selector);
        f.setGuardianPaused(false);
        vm.expectRevert(MomentsFactory.NotGuardian.selector);
        f.setGuardian(attacker);
        vm.stopPrank();
        bytes32 terms = f.termsHash();
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.Paused.selector);
        f.publish(_params(PRICE, 0, 1), terms);
    }

    function test_MO4_guardian_isSetWhileWiringThenOnlyHandedOnByItself() public {
        address g1 = makeAddr("guardian1");
        address g2 = makeAddr("guardian2");
        MomentsFactory f = _factoryWithGuardian(g1);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.NotGuardian.selector);
        f.setGuardian(g2); // modules are wired: governance can no longer name the guardian
        vm.prank(g1);
        f.setGuardian(g2);
        assertEq(f.guardian(), g2);
        vm.prank(g1);
        vm.expectRevert(MomentsFactory.NotGuardian.selector);
        f.setGuardianPaused(true);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MomentsFactory.NotGovernanceOrGuardian.selector);
        f.cancelPolicy();
    }

    /// Renouncing the guardian while its pause is on would make the pause permanent (nobody could lift it, and
    /// governance cannot name a new guardian), so it is refused; handing the role on, or unpausing first, still works.
    function test_MO4_guardianCannotRenounceWhilePaused() public {
        address g1 = makeAddr("guardian1");
        address g2 = makeAddr("guardian2");
        MomentsFactory f = _factoryWithGuardian(g1);
        vm.startPrank(g1);
        f.setGuardianPaused(true);
        vm.expectRevert(MomentsFactory.UnpauseFirst.selector);
        f.setGuardian(address(0));
        f.setGuardian(g2); // a successor can still lift the pause
        vm.stopPrank();
        vm.startPrank(g2);
        f.setGuardianPaused(false);
        f.setGuardian(address(0));
        vm.stopPrank();
        assertEq(f.guardian(), address(0));
        assertFalse(f.guardianPaused());
        bytes32 terms = f.termsHash();
        vm.prank(creator);
        f.publish(_params(PRICE, 0, 1), terms);
    }

    /// The same refusal while wiring: governance cannot drop a guardian that has already paused.
    function test_MO4_wiringCannotDropAPausedGuardian() public {
        address g1 = makeAddr("guardian1");
        MomentsFactory f = new MomentsFactory(gov, _policy(THRESHOLD));
        vm.prank(gov);
        f.setGuardian(g1);
        vm.prank(g1);
        f.setGuardianPaused(true);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.UnpauseFirst.selector);
        f.setGuardian(address(0));
    }

    /// A fresh factory wired the way script/moments/Deploy.s.sol wires it: guardian first, then the modules.
    function _factoryWithGuardian(address guardianKey) internal returns (MomentsFactory f) {
        f = new MomentsFactory(gov, _policy(THRESHOLD));
        vm.startPrank(gov);
        f.setGuardian(guardianKey);
        f.setModules(address(collect), address(vesting), address(executor), address(locker), address(hook), address(buyback));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- MO-8: external links

    /// Changing the base must not rewrite the links of NFTs that already exist (graduated ones included).
    function test_MO8_baseChange_doesNotRewriteExistingNFTs() public {
        vm.prank(gov);
        factory.setExternalBaseURI("https://dyorhq.fun/moments/");
        (uint256 id,, MomentNFT nft) = _publishOrdered(creator, PRICE, 0, true);
        _completeWithSingles(id, alice);
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated));
        string memory tokenBefore = nft.tokenURI(1);
        string memory contractBefore = nft.contractURI();
        vm.prank(gov);
        factory.setExternalBaseURI("https://dyorhq-claim.example/airdrop?m=");
        assertEq(nft.tokenURI(1), tokenBefore, "tokenURI of a graduated NFT changed");
        assertEq(nft.contractURI(), contractBefore, "contractURI changed");
    }

    function test_MO8_baseLength_isCapped() public {
        bytes memory big = new bytes(40_000);
        for (uint256 i = 0; i < big.length; i++) {
            big[i] = "a";
        }
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.BaseURITooLong.selector);
        factory.setExternalBaseURI(string(big));
        bytes memory max = new bytes(factory.MAX_EXTERNAL_BASE_URI_LENGTH());
        for (uint256 i = 0; i < max.length; i++) {
            max[i] = "a";
        }
        vm.prank(gov);
        factory.setExternalBaseURI(string(max));
    }

    // ---------------------------------------------------------------- price above the completion gross

    /// A listed price above the gross that completes the reserve would never be charged (the first collect is
    /// clamped to that gross), so publish refuses it; the completion gross itself is still allowed.
    function test_priceAboveTheCompletionGross_isRefused() public {
        uint256 completion = (THRESHOLD * BPS + RESERVE_BPS - 1) / RESERVE_BPS;
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.PriceTooHigh.selector);
        factory.publish(_params(completion + 1, 0, 1), terms);
        (uint256 id,,) = _publish(creator, completion, 0, 2);
        MomentsFactory.PublishParams memory p = _params(completion, 0, 2);
        assertEq(factory.getMoment(id).price, p.price);
        assertTrue(collect.quote(id, 1).terminal);
        assertEq(collect.quote(id, 1).gross, completion, "the only edition is charged its listed price");
    }

    /// A minimum price above the completion gross would make every publish revert (PriceTooLow below it, PriceTooHigh
    /// above the ceiling) until another 48h proposal, so no such policy is accepted; the ceiling itself is.
    function test_policyWithMinPriceAboveTheCompletionGross_isRefused() public {
        MomentTypes.Policy memory bad = _policy(1_000_000); // $1 threshold at 75%: completion gross $1.333334
        bad.minPrice = 2_000_000;
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        new MomentsFactory(gov, bad);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
        MomentTypes.Policy memory edge = _policy(1_000_000);
        edge.minPrice = (1_000_000 * BPS + RESERVE_BPS - 1) / RESERVE_BPS;
        vm.prank(gov);
        factory.proposePolicy(edge);
        vm.warp(vm.getBlockTimestamp() + factory.POLICY_DELAY());
        factory.applyPolicy();
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        factory.publish(_params(edge.minPrice, 0, 3), terms); // the one price both bounds allow
    }
}
