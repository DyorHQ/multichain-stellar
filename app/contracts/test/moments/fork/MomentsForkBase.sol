// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MomentsMarketBase} from "../MomentsMarketBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MomentTypes, IPermit2} from "../../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../../src/moments/MomentCollect.sol";
import {MomentCoin} from "../../../src/moments/MomentCoin.sol";
import {MomentFeeHook} from "../../../src/moments/MomentFeeHook.sol";
import {MomentLocker} from "../../../src/moments/MomentLocker.sol";
import {MomentGraduation} from "../../../src/moments/MomentGraduation.sol";
import {MomentBuyback} from "../../../src/moments/MomentBuyback.sol";
import {MomentHookAddress} from "../../../src/moments/libraries/HookAddress.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Phase 3 fixture: the Moments stack deployed on a Monad MAINNET fork against the real PoolManager, real USDC,
/// real Permit2 and the real Universal Router. Only our own contracts are fresh.
///   forge test --code-size-limit 100000000 --match-path 'test/moments/fork/*.t.sol' --fork-url monad
abstract contract MomentsForkBase is MomentsMarketBase {
    address internal constant USDC_ADDR = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant PM_ADDR = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address internal constant UR_ADDR = 0x0D97Dc33264bfC1c226207428A79b26757fb9dc3;
    uint256 internal constant FORK_BLOCK = 105_303_689; // pinned so RPC reads cache across tests

    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");
    address internal mallory = makeAddr("mallory");

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    function setUp() public virtual override {
        // Public Monad RPCs prune old state, so the pinned block eventually stops being served: MOMENTS_FORK_BLOCK
        // re-pins the fork (any recent block works; the stack under test is deployed fresh on the fork).
        vm.createSelectFork("monad", vm.envOr("MOMENTS_FORK_BLOCK", FORK_BLOCK));
        usdc = MockUSDC(USDC_ADDR); // only the ERC-20 surface of the real USDC is used through this handle
        permit2 = MockPermit2(PERMIT2_ADDR);
        factory = new MomentsFactory(gov, _policy(THRESHOLD));
        vesting = new MomentVesting(factory);
        collect = new MomentCollect(IERC20(USDC_ADDR), IPermit2(PERMIT2_ADDR), factory, vesting);
        (address grad, address lockerAddr, address hookAddr, address buybackAddr) = _deployMarket();
        vm.prank(gov);
        factory.setModules(address(collect), address(vesting), grad, lockerAddr, hookAddr, buybackAddr);
        address[7] memory users = [alice, bob, carol, dave, eve, mallory, creator];
        for (uint256 i = 0; i < users.length; i++) {
            deal(USDC_ADDR, users[i], 1_000_000_000_000); // $1,000,000 of the real USDC
            vm.startPrank(users[i]);
            usdc.approve(address(collect), type(uint256).max);
            usdc.approve(PERMIT2_ADDR, type(uint256).max);
            usdc.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deployMarket() internal virtual override returns (address, address, address, address) {
        manager = IPoolManager(PM_ADDR);
        swapRouter = new PoolSwapTest(manager);
        locker = new MomentLocker(manager, factory);
        executor = new MomentGraduation(manager, factory, IERC20(USDC_ADDR));
        buyback = new MomentBuyback(manager, factory, IERC20(USDC_ADDR));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(MomentFeeHook).creationCode, abi.encode(manager, factory, IERC20(USDC_ADDR))));
        (address predicted, bytes32 salt) = MomentHookAddress.mine(address(this), flags, initCodeHash, 500_000);
        hook = new MomentFeeHook{salt: salt}(manager, factory, IERC20(USDC_ADDR));
        require(address(hook) == predicted, "hook address");
        return (address(executor), address(locker), address(hook), address(buyback));
    }

    /// Exact-input swap through the REAL Universal Router (V4_SWAP: SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL),
    /// funded through Permit2 exactly like the DyorHQ app does it.
    function _urSwapExactIn(address who, PoolKey memory key, bool zeroForOne, uint128 amountIn) internal {
        Currency cIn = zeroForOne ? key.currency0 : key.currency1;
        Currency cOut = zeroForOne ? key.currency1 : key.currency0;
        vm.startPrank(who);
        IERC20(Currency.unwrap(cIn)).approve(PERMIT2_ADDR, type(uint256).max);
        IPermit2Allowance(PERMIT2_ADDR).approve(Currency.unwrap(cIn), UR_ADDR, type(uint160).max, type(uint48).max);
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams({poolKey: key, zeroForOne: zeroForOne, amountIn: amountIn, amountOutMinimum: 0, hookData: ""}));
        params[1] = abi.encode(cIn, uint256(amountIn));
        params[2] = abi.encode(cOut, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        IUniversalRouter(UR_ADDR).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 60);
        vm.stopPrank();
    }

    /// USDC per coin (whole USDC per whole coin), scaled 1e18, from the pool's sqrt price. The raw pool ratio is
    /// USDC units (6 dp) per coin wei (18 dp), so the human price is that ratio x 1e12; x1e18 => x1e30.
    function _usdcPerCoinX18(PoolKey memory key, bool usdcIs0) internal view returns (uint256) {
        uint256 sp = _sqrtPrice(key);
        uint256 ratioX96 = FullMath.mulDiv(sp, sp, 1 << 96); // currency1 per currency0, raw units
        return usdcIs0 ? FullMath.mulDiv(1e30, 1 << 96, ratioX96) : FullMath.mulDiv(ratioX96, 1e30, 1 << 96);
    }

    /// Fee-adjusted constant-product expectation for selling `coinsIn` into a full-range pool holding
    /// (`poolCoins`, `poolUsdc`): the 0.5% LP fee comes off the input; returns (usdcOut, dropX18).
    function _expectedSell(uint256 poolCoins, uint256 poolUsdc, uint256 coinsIn) internal view returns (uint256 usdcOut, uint256 dropX18) {
        uint256 netIn = coinsIn * (1_000_000 - executor.LP_FEE()) / 1_000_000;
        uint256 x2 = poolCoins + netIn;
        uint256 y2 = FullMath.mulDiv(poolCoins, poolUsdc, x2);
        usdcOut = poolUsdc - y2;
        uint256 ratio = FullMath.mulDiv(FullMath.mulDiv(poolCoins, 1e18, x2), poolCoins, x2); // (x/x')^2
        dropX18 = 1e18 - ratio;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// The per-Moment supply invariant, in every state.
    function _assertSupply(uint256 id) internal view {
        MomentTypes.Moment memory m = factory.getMoment(id);
        MomentCoin coin = MomentCoin(m.coin);
        uint256 alloc = S * m.creatorAllocBps / BPS;
        if (executor.isGraduated(id)) {
            MomentGraduation.Record memory r = executor.record(id);
            assertEq(r.poolCoins + vesting.totalEntitlement(id) + alloc, S, "pool + sum ent + creator == S");
            assertEq(coin.totalSupply(), r.poolCoins + vesting.totalMinted(id), "minted == pool seed + claims");
        } else {
            assertEq(coin.totalSupply(), 0, "no coin before graduation");
            (uint256 ents, uint256 alloc2, uint256 remainder,,) = collect.supplyCheck(id);
            assertEq(ents + alloc2 + remainder, S);
        }
        assertLe(coin.totalSupply(), S);
    }
}
