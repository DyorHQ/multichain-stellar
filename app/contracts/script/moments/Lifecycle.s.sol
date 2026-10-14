// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentBuyback} from "../../src/moments/MomentBuyback.sol";
import {MomentFeeHook} from "../../src/moments/MomentFeeHook.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// The deployed (v1) cohorts' publish, which predates the terms hash that v2 binds publish to (sec2, MO-4).
interface IMomentsFactoryV1Publish {
    function publish(MomentsFactory.PublishParams calldata p) external returns (uint256 momentId, address coin, address nft);
}

/// @notice FORK-ONLY rehearsal of the $10 lifecycle, for app development against `anvil --fork-url monad`
///         (chain id 143 on the fork too). It is NOT a mainnet procedure: the live lifecycle is exercised through
///         the DyorHQ app by ordinary, low-value wallets (see
///         DyorHQ/internal: ios-app/docs/moments-mainnet-runbook.md). Never run this with
///         a real key: it publishes, collects and trades from whatever key broadcasts it. The `FORK_REHEARSAL=1`
///         guard exists so a mainnet RPC + real key cannot run it by accident.
///
///           anvil --fork-url https://rpc.monad.xyz --chain-id 143   # in another shell
///           cast wallet new ~/.foundry/keystores fork-rehearsal   # once: a fresh key used only on forks
///           export FORK_REHEARSAL=1 RPC=http://127.0.0.1:8545
///           forge script script/moments/Lifecycle.s.sol:MomentsLifecycle --rpc-url $RPC --broadcast --account fork-rehearsal --sig "publish()"
///           MOMENT_ID=1 forge script ... --sig "collectUntilGraduated()"   # fund that account with MON and USDC first (anvil_setBalance / anvil_setStorageAt)
///           MOMENT_ID=1 forge script ... --sig "trade()"                   # $1 buy through the real Universal Router
///           MOMENT_ID=1 forge script ... --sig "claim()" | "withdraw()" | "buyback()" | "status()"
contract MomentsLifecycle is Script {
    address internal constant UR = 0x0D97Dc33264bfC1c226207428A79b26757fb9dc3;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    MomentsFactory factory;
    MomentCollect collect;
    MomentVesting vesting;
    MomentGraduation graduation;
    MomentBuyback buybackModule;
    MomentFeeHook hook;
    MomentLocker locker;
    IERC20 usdc;
    address permit2;

    function _load() internal {
        require(vm.envOr("FORK_REHEARSAL", false), "fork-only rehearsal: set FORK_REHEARSAL=1 on an anvil fork; never on mainnet with a real key");
        string memory json = vm.readFile(string.concat("deployments/moments-", vm.toString(block.chainid), ".json"));
        factory = MomentsFactory(vm.parseJsonAddress(json, ".factory"));
        collect = MomentCollect(vm.parseJsonAddress(json, ".collect"));
        vesting = MomentVesting(vm.parseJsonAddress(json, ".vesting"));
        graduation = MomentGraduation(vm.parseJsonAddress(json, ".graduation"));
        buybackModule = MomentBuyback(vm.parseJsonAddress(json, ".buyback"));
        hook = MomentFeeHook(vm.parseJsonAddress(json, ".hook"));
        locker = MomentLocker(vm.parseJsonAddress(json, ".locker"));
        usdc = IERC20(vm.parseJsonAddress(json, ".usdc"));
        permit2 = vm.parseJsonAddress(json, ".permit2");
    }

    function _id() internal view returns (uint256 id) {
        id = vm.envUint("MOMENT_ID");
        require(id != 0, "set MOMENT_ID");
    }

    /// Publishes the validation Moment: $1 collects (COLLECT_PRICE_USDC), 10% creator allocation, 30-day window.
    function publish() external {
        _load();
        MomentsFactory.PublishParams memory p = MomentsFactory.PublishParams({
            name: vm.envOr("MOMENT_NAME", string("DyorHQ Moment #1")),
            symbol: vm.envOr("MOMENT_SYMBOL", string("MOMENT1")),
            provenance: MomentTypes.Provenance({
                mediaURI: vm.envOr("MEDIA_URI", string("ipfs://validation-launch")),
                mediaHash: keccak256(bytes(vm.envOr("MEDIA_URI", string("ipfs://validation-launch")))),
                place: vm.envOr("PLACE", string("Accra")),
                date: uint64(block.timestamp),
                animationURI: vm.envOr("ANIMATION_URI", string(""))
            }),
            price: vm.envOr("COLLECT_PRICE_USDC", uint256(1_000_000)),
            creatorAllocBps: uint16(vm.envOr("CREATOR_ALLOC_BPS", uint256(1_000))),
            collectWindow: uint32(vm.envOr("COLLECT_WINDOW", uint256(30 days))),
            salt: bytes32(vm.envOr("SALT", uint256(1)))
        });
        // A v2 factory binds publish to the terms it shows (termsHash); the deployed v1 cohorts have neither.
        (bool v2, bytes memory terms) = address(factory).staticcall(abi.encodeCall(MomentsFactory.termsHash, ()));
        vm.startBroadcast();
        (uint256 id, address coin, address nft) =
            v2 ? factory.publish(p, abi.decode(terms, (bytes32))) : IMomentsFactoryV1Publish(address(factory)).publish(p);
        vm.stopBroadcast();
        console2.log("momentId", id);
        console2.log("coin", coin);
        console2.log("nft", nft);
        console2.log("deadline", factory.getMoment(id).deadline);
    }

    /// Collects one edition at a time from the broadcaster until the Moment graduates (14 x $1 at the $10 policy:
    /// 13 full collects and one clamped to 0.333334 USDC). Needs ~13.34 USDC + gas in the wallet.
    function collectUntilGraduated() external {
        _load();
        uint256 id = _id();
        MomentTypes.Moment memory m = factory.getMoment(id);
        uint256 maxCollects = vm.envOr("MAX_COLLECTS", uint256(20));
        vm.startBroadcast();
        if (usdc.allowance(msg.sender, address(collect)) < m.price * maxCollects) usdc.approve(address(collect), m.price * maxCollects); // exact, never unlimited
        for (uint256 i = 0; i < maxCollects && collect.state(id) == MomentTypes.State.Collecting; i++) {
            MomentCollect.Quote memory q = collect.collect(id, 1);
            console2.log("collect", i + 1, "gross", q.gross);
            if (q.terminal) console2.log("  terminal collect; excess not pulled:", q.excess);
        }
        vm.stopBroadcast();
        _print(id);
    }

    /// Buys with $1 (TRADE_USDC) through the real Universal Router, funded through Permit2 like the app.
    function trade() external {
        _load();
        uint256 id = _id();
        PoolKey memory key = graduation.poolKeyOf(id);
        bool usdcIs0 = Currency.unwrap(key.currency0) == address(usdc);
        uint128 amountIn = uint128(vm.envOr("TRADE_USDC", uint256(1_000_000)));
        vm.startBroadcast();
        if (usdc.allowance(msg.sender, permit2) < amountIn) usdc.approve(permit2, amountIn);
        IPermit2Allowance(permit2).approve(address(usdc), UR, uint160(amountIn), uint48(block.timestamp + 1 hours));
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams({poolKey: key, zeroForOne: usdcIs0, amountIn: amountIn, amountOutMinimum: 0, hookData: ""}));
        params[1] = abi.encode(usdcIs0 ? key.currency0 : key.currency1, uint256(amountIn));
        params[2] = abi.encode(usdcIs0 ? key.currency1 : key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        IUniversalRouter(UR).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 300);
        vm.stopBroadcast();
        _print(id);
    }

    function claim() external {
        _load();
        uint256 id = _id();
        (uint256 c, uint256 cr) = vesting.claimable(id, msg.sender);
        console2.log("claimable collector", c, "creator", cr);
        vm.startBroadcast();
        vesting.claim(id);
        vm.stopBroadcast();
        _print(id);
    }

    function withdraw() external {
        _load();
        uint256 id = _id();
        MomentTypes.Moment memory m = factory.getMoment(id);
        vm.startBroadcast();
        if (msg.sender == m.creator) {
            if (collect.ledger(id).creatorClaimable != 0) collect.withdrawCreator(id);
            if (hook.creatorAccrued(id) != 0) hook.withdrawCreator(id);
        }
        if (msg.sender == m.platform) {
            if (collect.ledger(id).platformClaimable != 0) collect.withdrawPlatform(id);
            if (hook.platformAccrued(id) != 0) hook.withdrawPlatform(id);
        }
        if (msg.sender == m.treasury && collect.ledger(id).treasuryClaimable != 0) collect.withdrawTreasury(id);
        vm.stopBroadcast();
        _print(id);
    }

    function buyback() external {
        _load();
        uint256 id = _id();
        vm.startBroadcast();
        MomentBuyback.Round memory r = buybackModule.execute(id, 0);
        vm.stopBroadcast();
        console2.log("buyback spent", r.usdcSpent, "coin", r.coinBought);
        console2.log("liquidity added", r.liquidityAdded, "carried", r.carried);
        _print(id);
    }

    function status() external {
        _load();
        _print(_id());
    }

    function _print(uint256 id) internal view {
        MomentTypes.Moment memory m = factory.getMoment(id);
        MomentCollect.Ledger memory l = collect.ledger(id);
        console2.log("--- moment", id, "state", uint8(l.state));
        console2.log("reserve", l.reserve, "totalGross", l.totalGross);
        console2.log("creatorClaimable", l.creatorClaimable, "platformClaimable", l.platformClaimable);
        console2.log("editions", MomentNFT(m.nft).totalMinted(), "closed", MomentNFT(m.nft).closed());
        console2.log("sum entitlements", vesting.totalEntitlement(id), "coin supply", MomentCoin(m.coin).totalSupply());
        if (graduation.isGraduated(id)) {
            MomentGraduation.Record memory r = graduation.record(id);
            console2.log("graduated: pool coins", r.poolCoins, "liquidity", r.liquidity);
            console2.log("hook fees creator/platform/buyback", hook.creatorAccrued(id), hook.platformAccrued(id), hook.buybackAccrued(id));
            console2.log("locked liquidity now", locker.liquidityOf(id));
        }
    }
}
