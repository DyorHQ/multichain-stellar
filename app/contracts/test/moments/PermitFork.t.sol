// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MomentTypes, IPermit2} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MockGraduation} from "./mocks/MockGraduation.sol";

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// Real USDC + real Permit2 on a Monad fork: the collector signs a Permit2 SignatureTransfer for MORE than the
/// clamped terminal collect needs, and the contract requests only the accepted amount. Also documents that this
/// USDC is paid through Permit2/approve - no reliance on native EIP-2612.
///   forge test --match-path test/moments/PermitFork.t.sol --fork-url monad
contract PermitForkTest is Test {
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256("PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)");

    MomentsFactory factory;
    MomentVesting vesting;
    MomentCollect collect;
    MockGraduation graduation;
    uint256 id;
    uint256 alicePk = 0xA11CE;
    address alice = vm.addr(0xA11CE);
    address gov = makeAddr("gov");

    function setUp() public {
        vm.createSelectFork("monad");
        factory = new MomentsFactory(gov, MomentTypes.Policy({threshold: 10_000_000, minPrice: 100_000, creatorBps: 2_000, platformBps: 500, reserveBps: 7_500, maxCreatorAllocBps: 1_000, expiryCreatorBps: 7_000, royaltyBps: 500, platform: makeAddr("platform"), treasury: makeAddr("treasury")}));
        vesting = new MomentVesting(factory);
        collect = new MomentCollect(IERC20(USDC), IPermit2(PERMIT2), factory, vesting);
        graduation = new MockGraduation(factory, collect, vesting);
        vm.prank(gov);
        factory.setModules(address(collect), address(vesting), address(graduation), makeAddr("locker"), makeAddr("hook"), makeAddr("buyback"));
        bytes32 terms = factory.termsHash();
        vm.prank(makeAddr("creator"));
        (id,,) = factory.publish(MomentsFactory.PublishParams({name: "Fork Moment", symbol: "FORK", provenance: MomentTypes.Provenance("ipfs://x", keccak256("x"), "Accra", 1_780_000_000, ""), price: 1_000_000, creatorAllocBps: 1_000, collectWindow: 30 days, salt: bytes32(0)}), terms);
        deal(USDC, alice, 100_000_000); // $100
        vm.prank(alice);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        assertEq(IERC20Metadata(USDC).decimals(), 6);
    }

    function _sign(uint256 amount, uint256 nonce, uint256 deadline) internal view returns (IPermit2.PermitTransferFrom memory permit, bytes memory sig) {
        permit = IPermit2.PermitTransferFrom({permitted: IPermit2.TokenPermissions({token: USDC, amount: amount}), nonce: nonce, deadline: deadline});
        bytes32 structHash = keccak256(abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, USDC, amount)), address(collect), nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_real_permit2_collect_pulls_exactly_the_gross() public {
        (IPermit2.PermitTransferFrom memory p, bytes memory sig) = _sign(5_000_000, 1, block.timestamp + 1 hours);
        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        MomentCollect.Quote memory q = collect.collectWithPermit2(id, 2, p, sig);
        assertEq(q.gross, 2_000_000);
        assertEq(before - IERC20(USDC).balanceOf(alice), 2_000_000, "requested 2 of the 5 permitted");
        assertEq(IERC20(USDC).balanceOf(address(collect)), 2_000_000);
        // the nonce is spent: replay fails inside Permit2
        vm.prank(alice);
        vm.expectRevert();
        collect.collectWithPermit2(id, 1, p, sig);
    }

    function test_real_permit2_terminal_clamp_requests_less_than_permitted() public {
        for (uint256 i = 0; i < 13; i++) {
            (IPermit2.PermitTransferFrom memory p, bytes memory sig) = _sign(1_000_000, 100 + i, block.timestamp + 1 hours);
            vm.prank(alice);
            collect.collectWithPermit2(id, 1, p, sig);
        }
        (IPermit2.PermitTransferFrom memory pt, bytes memory sigt) = _sign(5_000_000, 999, block.timestamp + 1 hours);
        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        MomentCollect.Quote memory q = collect.collectWithPermit2(id, 5, pt, sigt);
        assertTrue(q.terminal);
        assertEq(q.gross, 333_334);
        assertEq(before - IERC20(USDC).balanceOf(alice), 333_334, "only the clamped amount left the wallet");
        assertEq(uint8(collect.ledger(id).state), uint8(MomentTypes.State.Graduated));
        assertEq(graduation.poolUsdc(id), 10_000_000);
    }

    function test_this_usdc_is_not_relied_on_for_eip2612() public view {
        (bool hasDomain,) = USDC.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        (bool hasNonces,) = USDC.staticcall(abi.encodeWithSignature("nonces(address)", alice));
        // Informational: whatever this USDC exposes, Moments pays via Permit2 / approve only.
        console2.log("USDC exposes DOMAIN_SEPARATOR():", hasDomain);
        console2.log("USDC exposes nonces(address):", hasNonces);
    }
}
