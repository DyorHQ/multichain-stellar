// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MomentsMarketBase} from "./MomentsMarketBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MomentTypes, IMomentsFactory, IPermit2} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentFeeHook} from "../../src/moments/MomentFeeHook.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

/// Phase 4 v1.1 hardening (L-3, L-4): mis-wiring and degenerate policies are rejected at construction.
contract ConstructorsTest is MomentsMarketBase {
    function test_module_constructors_reject_zero_addresses() public {
        vm.expectRevert(MomentCollect.ZeroAddress.selector);
        new MomentCollect(IERC20(address(0)), permit2, factory, vesting);
        vm.expectRevert(MomentCollect.ZeroAddress.selector);
        new MomentCollect(usdc, IPermit2(address(0)), factory, vesting);
        vm.expectRevert(MomentCollect.ZeroAddress.selector);
        new MomentCollect(usdc, permit2, IMomentsFactory(address(0)), vesting);
        vm.expectRevert(MomentCollect.ZeroAddress.selector);
        new MomentCollect(usdc, permit2, factory, MomentVesting(address(0)));
        vm.expectRevert(MomentVesting.ZeroAddress.selector);
        new MomentVesting(IMomentsFactory(address(0)));
        vm.expectRevert(MomentGraduation.ZeroAddress.selector);
        new MomentGraduation(IPoolManager(address(0)), factory, usdc);
        vm.expectRevert(MomentGraduation.ZeroAddress.selector);
        new MomentGraduation(manager, factory, IERC20(address(0)));
        vm.expectRevert(MomentLocker.ZeroAddress.selector);
        new MomentLocker(IPoolManager(address(0)), factory);
        vm.expectRevert(MomentLocker.ZeroAddress.selector);
        new MomentLocker(manager, IMomentsFactory(address(0)));
        vm.expectRevert(MomentFeeHook.ZeroAddress.selector);
        new MomentFeeHook(IPoolManager(address(0)), factory, usdc);
        vm.expectRevert(MomentBuyback.ZeroAddress.selector);
        new MomentBuyback(manager, IMomentsFactory(address(0)), usdc);
        vm.expectRevert(MomentBuyback.ZeroAddress.selector);
        new MomentBuyback(manager, factory, IERC20(address(0)));
        vm.expectRevert(MomentCoin.ZeroAddress.selector);
        new MomentCoin(1, "n", "s", address(0), address(1));
        vm.expectRevert(MomentCoin.ZeroAddress.selector);
        new MomentCoin(1, "n", "s", address(1), address(0));
        MomentTypes.Provenance memory prov = MomentTypes.Provenance("ipfs://x", keccak256("x"), "Accra", 1, "");
        vm.expectRevert(MomentNFT.ZeroAddress.selector);
        new MomentNFT(1, "n", "s", address(0), address(1), address(2), 500, prov, "");
        vm.expectRevert(MomentNFT.ZeroAddress.selector);
        new MomentNFT(1, "n", "s", address(1), address(0), address(2), 500, prov, "");
        vm.expectRevert(MomentNFT.ZeroAddress.selector);
        new MomentNFT(1, "n", "s", address(1), address(2), address(0), 500, prov, "");
        vm.expectRevert(MomentNFT.BadRoyalty.selector);
        new MomentNFT(1, "n", "s", address(1), address(2), address(3), 1_001, prov, "");
    }

    function test_policy_floors() public {
        MomentTypes.Policy memory bad = _policy(factory.MIN_THRESHOLD() - 1);
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
        bad = _policy(THRESHOLD);
        bad.minPrice = factory.MIN_MIN_PRICE() - 1;
        vm.prank(gov);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        factory.proposePolicy(bad);
        MomentTypes.Policy memory ok = _policy(factory.MIN_THRESHOLD());
        ok.minPrice = factory.MIN_MIN_PRICE();
        vm.prank(gov);
        factory.proposePolicy(ok); // the floors themselves are accepted
        assertGt(factory.pendingPolicyAt(), 0);
        vm.expectRevert(MomentsFactory.InvalidPolicy.selector);
        new MomentsFactory(gov, bad);
    }
}
