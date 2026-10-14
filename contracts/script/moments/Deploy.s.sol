// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {MainnetGuard} from "../lib/MainnetGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {MomentTypes, IPermit2} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentFeeHook} from "../../src/moments/MomentFeeHook.sol";
import {MomentHookAddress} from "../../src/moments/libraries/HookAddress.sol";

/// @notice Deploys the Moments stack on Monad mainnet against the canonical Uniswap v4 PoolManager, USDC and
///         Permit2. The broadcasting key wires the modules (once) and then hands governance to GOVERNANCE
///         (two-step: that address must call `acceptGovernance()`).
///
///         Dry run (no transactions):
///           forge script script/moments/Deploy.s.sol:DeployMoments --rpc-url monad
///         Real deployment, from the owner's hardware wallet or keystore (never a raw key): script/deploy-v2.sh
///           (or: forge script ... --broadcast --ledger | --account <keystore>)
///         Every parameter below can be overridden with an environment variable of the same name. On Monad mainnet
///         (chain 143) GOVERNANCE, GUARDIAN, PLATFORM, TREASURY and THRESHOLD_USDC have no default (security audit
///         2026-09-26, LP-7), and platform, treasury and guardian must differ from the deployer and each other.
///         Writes deployments/dryrun-|pending-moments-<chainId>.json (see MainnetGuard._recordPath); it never
///         touches a live record.
contract DeployMoments is MainnetGuard {
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function run() external {
        _refuseRawKeyOnMainnet();
        address poolManager = vm.envOr("POOL_MANAGER", address(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e));
        address usdc = vm.envOr("USDC", address(0x754704Bc059F8C67012fEd69BC8A327a5aafb603));
        address permit2 = vm.envOr("PERMIT2", address(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        address governance = _addr("GOVERNANCE", msg.sender);
        // v2 (sec2, MO-4): a second key that can cancel a pending policy and pause publishing; none if unset off-mainnet.
        address guardian = _addr("GUARDIAN", address(0));
        address platform = _addr("PLATFORM", msg.sender);
        address treasury = _addr("TREASURY", msg.sender);
        string memory base = vm.envOr("EXTERNAL_BASE_URI", string("https://dyorhq.fun/moments/"));
        MomentTypes.Policy memory policy = MomentTypes.Policy({
            threshold: _uint("THRESHOLD_USDC", 10_000_000), // off mainnet: the $10 validation launch
            minPrice: vm.envOr("MIN_PRICE_USDC", uint256(100_000)), // $0.10
            creatorBps: uint16(vm.envOr("CREATOR_BPS", uint256(2_000))),
            platformBps: uint16(vm.envOr("PLATFORM_BPS", uint256(500))),
            reserveBps: uint16(vm.envOr("RESERVE_BPS", uint256(7_500))),
            maxCreatorAllocBps: uint16(vm.envOr("MAX_CREATOR_ALLOC_BPS", uint256(1_000))),
            expiryCreatorBps: uint16(vm.envOr("EXPIRY_CREATOR_BPS", uint256(7_000))),
            royaltyBps: uint16(vm.envOr("ROYALTY_BPS", uint256(500))), // ERC-2981 creator royalty, 5%
            platform: platform,
            treasury: treasury
        });

        require(poolManager.code.length > 0, "PoolManager has no code on this chain");
        require(usdc.code.length > 0, "USDC has no code on this chain");
        require(permit2.code.length > 0, "Permit2 has no code on this chain");
        if (block.chainid == MONAD_MAINNET) {
            require(
                platform != msg.sender && treasury != msg.sender && guardian != msg.sender && platform != treasury && guardian != platform
                    && guardian != treasury && guardian != governance,
                "platform, treasury and guardian must be distinct from each other, the deployer and governance"
            );
        }

        vm.startBroadcast();
        MomentsFactory factory = new MomentsFactory(msg.sender, policy); // deployer governs only for the wiring
        MomentVesting vesting = new MomentVesting(factory);
        MomentCollect collect = new MomentCollect(IERC20(usdc), IPermit2(permit2), factory, vesting);
        MomentLocker locker = new MomentLocker(IPoolManager(poolManager), factory);
        MomentGraduation graduation = new MomentGraduation(IPoolManager(poolManager), factory, IERC20(usdc));
        MomentBuyback buyback = new MomentBuyback(IPoolManager(poolManager), factory, IERC20(usdc));

        // The hook must live at an address whose low 14 bits encode its permissions. forge routes `new X{salt}`
        // through the deterministic CREATE2 deployer (0x4e59...956C, live on Monad): mine the salt against it.
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(MomentFeeHook).creationCode, abi.encode(poolManager, address(factory), usdc)));
        (address predictedHook, bytes32 salt) = MomentHookAddress.mine(MomentHookAddress.CREATE2_DEPLOYER, HOOK_FLAGS, initCodeHash, 10_000_000);
        MomentFeeHook hook = new MomentFeeHook{salt: salt}(IPoolManager(poolManager), factory, IERC20(usdc));
        require(address(hook) == predictedHook, "hook landed on an unexpected address");

        if (guardian != address(0)) factory.setGuardian(guardian); // only possible before setModules
        if (bytes(base).length != 0) factory.setExternalBaseURI(base);
        factory.setModules(address(collect), address(vesting), address(graduation), address(locker), address(hook), address(buyback));
        if (governance != msg.sender) factory.transferGovernance(governance);
        vm.stopBroadcast();

        string memory json = "moments";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "deployer", msg.sender);
        vm.serializeAddress(json, "governance", governance);
        vm.serializeAddress(json, "guardian", guardian);
        vm.serializeAddress(json, "platform", platform);
        vm.serializeAddress(json, "treasury", treasury);
        vm.serializeAddress(json, "poolManager", poolManager);
        vm.serializeAddress(json, "usdc", usdc);
        vm.serializeAddress(json, "permit2", permit2);
        vm.serializeAddress(json, "factory", address(factory));
        vm.serializeAddress(json, "vesting", address(vesting));
        vm.serializeAddress(json, "collect", address(collect));
        vm.serializeAddress(json, "locker", address(locker));
        vm.serializeAddress(json, "graduation", address(graduation));
        vm.serializeAddress(json, "buyback", address(buyback));
        vm.serializeAddress(json, "hook", address(hook));
        vm.serializeBytes32(json, "hookSalt", salt);
        vm.serializeUint(json, "thresholdUsdc", policy.threshold);
        vm.serializeUint(json, "minPriceUsdc", policy.minPrice);
        vm.serializeUint(json, "lpFee", uint256(graduation.LP_FEE()));
        vm.serializeUint(json, "expiryCreatorBps", policy.expiryCreatorBps);
        string memory out = vm.serializeUint(json, "royaltyBps", policy.royaltyBps);
        vm.createDir("deployments", true);
        string memory path = _recordPath(string.concat("moments-", vm.toString(block.chainid), ".json"));
        vm.writeJson(out, path);
        console2.log("factory   ", address(factory));
        console2.log("collect   ", address(collect));
        console2.log("vesting   ", address(vesting));
        console2.log("graduation", address(graduation));
        console2.log("locker    ", address(locker));
        console2.log("hook      ", address(hook));
        console2.log("buyback   ", address(buyback));
        console2.log("governance (pending accept):", governance);
        console2.log("wrote", path);
    }
}
