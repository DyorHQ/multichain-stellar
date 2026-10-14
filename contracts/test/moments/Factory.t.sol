// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

contract FactoryTest is MomentsBase {
    function test_modules_wired_once_and_publish_needs_them() public {
        MomentsFactory fresh = new MomentsFactory(gov, _policy(THRESHOLD));
        bytes32 terms = fresh.termsHash();
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.ModulesNotSet.selector);
        fresh.publish(_params(PRICE, 0, 1), terms);
        vm.prank(alice);
        vm.expectRevert(MomentsFactory.NotGovernance.selector);
        fresh.setModules(address(1), address(2), address(3), address(4), address(5), address(6));
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.ZeroAddress.selector);
        fresh.setModules(address(0), address(2), address(3), address(4), address(5), address(6));
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.ZeroAddress.selector);
        fresh.setModules(address(1), address(2), address(3), address(4), address(5), address(0));
        vm.prank(gov);
        fresh.setModules(address(1), address(2), address(3), address(4), address(5), address(6));
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.ModulesAlreadySet.selector);
        fresh.setModules(address(collect), address(vesting), address(graduation), address(4), address(5), address(6));
        assertTrue(fresh.modulesSet());
        assertEq(fresh.locker(), address(4));
        assertEq(fresh.feeHook(), address(5));
        assertEq(fresh.buyback(), address(6));
    }

    function test_publish_validates_and_snapshots() public {
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.PriceTooLow.selector);
        factory.publish(_params(MIN_PRICE - 1, 0, 1), terms);
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.AllocTooHigh.selector);
        factory.publish(_params(PRICE, MAX_ALLOC_BPS + 1, 1), terms);

        (uint256 id, MomentCoin coin, MomentNFT nft) = _publish(creator, PRICE, 700, 1);
        assertEq(id, 1, "ids are 1-based");
        assertEq(factory.momentCount(), 1);
        MomentTypes.Moment memory m = factory.getMoment(id);
        assertEq(m.creator, creator);
        assertEq(m.platform, platform);
        assertEq(m.treasury, treasury);
        assertEq(m.expiryCreatorBps, EXPIRY_CREATOR_BPS);
        assertEq(m.royaltyBps, ROYALTY_BPS);
        assertEq(nft.royaltyBps(), ROYALTY_BPS);
        assertEq(nft.factory(), address(factory));
        assertEq(m.deadline, uint64(block.timestamp + WINDOW));
        assertEq(factory.momentIdByCoin(address(coin)), id);
        assertEq(m.coin, address(coin));
        assertEq(m.nft, address(nft));
        assertEq(m.price, PRICE);
        assertEq(m.threshold, THRESHOLD);
        assertEq(m.creatorBps, CREATOR_BPS);
        assertEq(m.platformBps, PLATFORM_BPS);
        assertEq(m.reserveBps, RESERVE_BPS);
        assertEq(m.creatorAllocBps, 700);
        (uint256 n, uint256 d) = factory.bundleRate(THRESHOLD, RESERVE_BPS, 700);
        assertEq(m.rateNum, n);
        assertEq(m.rateDen, d);
        assertEq(m.publishedAt, uint64(block.timestamp));
        // token wiring is immutable and correct
        assertEq(coin.vesting(), address(vesting));
        assertEq(coin.graduation(), address(graduation));
        assertEq(coin.momentId(), id);
        assertEq(coin.decimals(), 18);
        assertEq(coin.SUPPLY(), S);
        assertEq(nft.collect(), address(collect));
        assertEq(nft.graduation(), address(graduation));
        assertEq(nft.creator(), creator);
        assertEq(nft.momentId(), id);
        assertEq(usdc.decimals(), 6);
        vm.expectRevert(MomentsFactory.UnknownMoment.selector);
        factory.getMoment(0);
        vm.expectRevert(MomentsFactory.UnknownMoment.selector);
        factory.getMoment(2);
    }

    function test_create2_addresses_are_deterministic() public {
        MomentsFactory.PublishParams memory p = _params(PRICE, 500, 42);
        uint256 nextId = factory.momentCount() + 1;
        bytes32 salt = keccak256(abi.encode(nextId, creator, p.salt));
        address predictedCoin = vm.computeCreate2Address(
            salt,
            keccak256(abi.encodePacked(type(MomentCoin).creationCode, abi.encode(nextId, p.name, p.symbol, address(vesting), address(graduation)))),
            address(factory)
        );
        address predictedNft = vm.computeCreate2Address(
            salt,
            keccak256(abi.encodePacked(type(MomentNFT).creationCode, abi.encode(nextId, p.name, p.symbol, creator, address(collect), address(graduation), ROYALTY_BPS, p.provenance, factory.externalBaseURI()))),
            address(factory)
        );
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        (uint256 id, address coin, address nft) = factory.publish(p, terms);
        assertEq(id, nextId);
        assertEq(coin, predictedCoin, "coin address predictable ahead of publish (pool key can be precomputed)");
        assertEq(nft, predictedNft);
    }

    function test_policy_timelock_only_affects_future_moments() public {
        (uint256 id1,,) = _publish(creator, PRICE, MAX_ALLOC_BPS, 1);
        MomentTypes.Policy memory next = _policy(1_000_000_000); // $1,000
        vm.prank(alice);
        vm.expectRevert(MomentsFactory.NotGovernance.selector);
        factory.proposePolicy(next);
        vm.expectRevert(MomentsFactory.NoPendingPolicy.selector);
        factory.applyPolicy();
        vm.prank(gov);
        factory.proposePolicy(next);
        vm.expectRevert(MomentsFactory.TimelockNotElapsed.selector);
        factory.applyPolicy();
        vm.warp(block.timestamp + factory.POLICY_DELAY() - 1);
        vm.expectRevert(MomentsFactory.TimelockNotElapsed.selector);
        factory.applyPolicy();
        vm.warp(block.timestamp + 1);
        factory.applyPolicy(); // anyone may apply a proposal once ripe
        (uint256 threshold,,,,,,,,,) = factory.policy();
        assertEq(threshold, 1_000_000_000);
        (uint256 id2,,) = _publish(creator, PRICE, MAX_ALLOC_BPS, 2);
        assertEq(factory.getMoment(id2).threshold, 1_000_000_000, "new moment takes the new policy");
        assertEq(factory.getMoment(id1).threshold, THRESHOLD, "existing moment's snapshot untouched");
        assertEq(factory.getMoment(id1).rateDen, 1750000000000000);
        assertEq(factory.getMoment(id2).rateDen, 175000000000000000);

        // cancel path
        vm.prank(gov);
        factory.proposePolicy(_policy(5_000_000_000));
        vm.prank(gov);
        factory.cancelPolicy();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(MomentsFactory.NoPendingPolicy.selector);
        factory.applyPolicy();
    }

    function test_policy_validation() public {
        MomentTypes.Policy memory bad = _policy(THRESHOLD);
        bad.reserveBps = 7_000; // sum != 10000
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
        bad = _policy(THRESHOLD);
        bad.maxCreatorAllocBps = 1_001; // above the hard 10% cap
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
        bad = _policy(THRESHOLD);
        bad.platform = address(0);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.ZeroAddress.selector);
        factory.proposePolicy(bad);
        bad = _policy(THRESHOLD);
        bad.treasury = address(0);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.ZeroAddress.selector);
        factory.proposePolicy(bad);
        bad = _policy(THRESHOLD);
        bad.royaltyBps = MomentTypes.MAX_ROYALTY_BPS + 1;
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
        bad = _policy(THRESHOLD);
        bad.expiryCreatorBps = 10_001;
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
        bad = _policy(0);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
    }

    function test_publishing_pause_and_governance_handoff() public {
        vm.prank(gov);
        factory.setPublishingPaused(true);
        bytes32 terms = factory.termsHash();
        vm.prank(creator);
        vm.expectRevert(MomentsFactory.Paused.selector);
        factory.publish(_params(PRICE, 0, 1), terms);
        vm.prank(gov);
        factory.setPublishingPaused(false);
        _publish(creator, PRICE, 0, 1);

        address newGov = makeAddr("newGov");
        vm.prank(gov);
        factory.transferGovernance(newGov);
        assertEq(factory.governance(), gov, "not yet");
        vm.prank(alice);
        vm.expectRevert(MomentsFactory.NotPendingGovernance.selector);
        factory.acceptGovernance();
        vm.prank(newGov);
        factory.acceptGovernance();
        assertEq(factory.governance(), newGov);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.NotGovernance.selector);
        factory.setPublishingPaused(true);
    }

    function test_external_base_uri_is_governance_only_and_metadata_only() public {
        vm.prank(alice);
        vm.expectRevert(MomentsFactory.NotGovernance.selector);
        factory.setExternalBaseURI("https://dyorhq.fun/moments/");
        vm.prank(gov);
        factory.setExternalBaseURI("https://dyorhq.fun/moments/");
        assertEq(factory.externalBaseURI(), "https://dyorhq.fun/moments/");
    }

    function test_factory_holds_no_money_and_has_no_money_functions() public {
        (uint256 id,,) = _publish(creator, PRICE, 0, 1);
        _completeWithSingles(id, alice);
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(MomentCoin(factory.getMoment(id).coin).balanceOf(address(factory)), 0);
    }
}
