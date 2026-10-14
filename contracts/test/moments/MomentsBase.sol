// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockGraduation} from "./mocks/MockGraduation.sol";

/// Deploys the core with the spec's $10 validation policy, wired the way the deploy script will wire it.
/// Phase 1 suites use the accounting-equivalent MockGraduation; the market suites override `_deployMarket`.
abstract contract MomentsBase is Test {
    uint256 internal constant S = MomentTypes.SUPPLY;
    uint256 internal constant BPS = MomentTypes.BPS;
    uint256 internal constant THRESHOLD = 10_000_000; // $10 in USDC units
    uint256 internal constant MIN_PRICE = 100_000; // $0.10
    uint256 internal constant PRICE = 1_000_000; // $1 default collect price
    uint16 internal constant CREATOR_BPS = 2_000;
    uint16 internal constant PLATFORM_BPS = 500;
    uint16 internal constant RESERVE_BPS = 7_500;
    uint16 internal constant MAX_ALLOC_BPS = 1_000;
    uint16 internal constant EXPIRY_CREATOR_BPS = 7_000; // creator may claim 70% of an expired reserve (rest -> treasury)
    uint16 internal constant ROYALTY_BPS = 500; // ERC-2981 creator royalty suggested to marketplaces
    uint32 internal constant WINDOW = 30 days; // default (maximum) collect window

    MockUSDC internal usdc;
    MockPermit2 internal permit2;
    MomentsFactory internal factory;
    MomentVesting internal vesting;
    MomentCollect internal collect;
    MockGraduation internal graduation; // only meaningful in Phase 1 suites

    address internal gov = makeAddr("gov");
    address internal platform = makeAddr("platform");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        vm.warp(1_780_000_000);
        usdc = new MockUSDC();
        permit2 = new MockPermit2();
        factory = new MomentsFactory(gov, _policy(THRESHOLD));
        vesting = new MomentVesting(factory);
        collect = new MomentCollect(usdc, permit2, factory, vesting);
        (address grad, address locker, address hook, address buyback) = _deployMarket();
        vm.prank(gov);
        factory.setModules(address(collect), address(vesting), grad, locker, hook, buyback);
        address[4] memory users = [alice, bob, carol, creator];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000_000_000); // $1,000,000
            vm.startPrank(users[i]);
            usdc.approve(address(collect), type(uint256).max);
            usdc.approve(address(permit2), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// Phase 1 default: the accounting mock stands in for the executor; market modules are inert placeholders.
    function _deployMarket() internal virtual returns (address grad, address locker, address hook, address buyback) {
        graduation = new MockGraduation(factory, collect, vesting);
        return (address(graduation), makeAddr("locker-placeholder"), makeAddr("hook-placeholder"), makeAddr("buyback-placeholder"));
    }

    function _policy(uint256 threshold) internal view returns (MomentTypes.Policy memory) {
        return MomentTypes.Policy({
            threshold: threshold,
            minPrice: MIN_PRICE,
            creatorBps: CREATOR_BPS,
            platformBps: PLATFORM_BPS,
            reserveBps: RESERVE_BPS,
            maxCreatorAllocBps: MAX_ALLOC_BPS,
            expiryCreatorBps: EXPIRY_CREATOR_BPS,
            royaltyBps: ROYALTY_BPS,
            platform: platform,
            treasury: treasury
        });
    }

    function _params(uint256 price, uint16 allocBps, uint256 seed) internal pure returns (MomentsFactory.PublishParams memory) {
        return _paramsWindow(price, allocBps, WINDOW, seed);
    }

    function _paramsWindow(uint256 price, uint16 allocBps, uint32 window, uint256 seed) internal pure returns (MomentsFactory.PublishParams memory) {
        return MomentsFactory.PublishParams({
            name: "Sunrise over Labadi",
            symbol: "LABADI",
            provenance: MomentTypes.Provenance({mediaURI: "ipfs://bafy-labadi", mediaHash: keccak256("labadi.jpg"), place: "Labadi Beach, Accra", date: 1_779_900_000, animationURI: ""}),
            price: price,
            creatorAllocBps: allocBps,
            collectWindow: window,
            salt: bytes32(seed)
        });
    }

    function _publish(address who, uint256 price, uint16 allocBps, uint256 seed) internal virtual returns (uint256 id, MomentCoin coin, MomentNFT nft) {
        bytes32 terms = factory.termsHash(); // v2 (sec2, MO-4): publish is bound to the terms shown
        vm.prank(who);
        (uint256 i, address c, address n) = factory.publish(_params(price, allocBps, seed), terms);
        return (i, MomentCoin(c), MomentNFT(n));
    }

    function _collect(uint256 id, address who, uint256 quantity) internal returns (MomentCollect.Quote memory q) {
        vm.prank(who);
        q = collect.collect(id, quantity);
    }

    function _state(uint256 id) internal view returns (MomentTypes.State) {
        return collect.ledger(id).state;
    }

    /// Collects one edition at a time with `who` until the Moment completes (and graduates).
    function _completeWithSingles(uint256 id, address who) internal returns (uint256 collects) {
        while (_state(id) == MomentTypes.State.Collecting) {
            _collect(id, who, 1);
            collects++;
        }
    }
}
