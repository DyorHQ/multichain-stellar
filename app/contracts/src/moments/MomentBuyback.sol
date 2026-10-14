// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MomentTypes, IMomentsFactory} from "./interfaces/IMoments.sol";
import {IMomentLocker, IMomentFeeHook, IMomentGraduationRegistry} from "./interfaces/IMomentsMarket.sol";
import {MomentPoolMath} from "./libraries/MomentPoolMath.sol";

/// @notice Buyback-and-LP for the 0.5% fee share. `execute` pulls a Moment's accrued buyback USDC from the hook,
///         swaps roughly half of it into the coin through the pool (fee-exempt, price impact capped at 1% per
///         call), and adds coin + USDC to the locked full-range position — pairing every coin the locker holds
///         (bought or earned as LP fee) and using USDC the locker already holds first. USDC that the impact cap
///         leaves unspent, or that the pairing does not need, is carried to the next round. Nothing can leave this
///         contract except into the PoolManager (paying for the swap) and into the locker; there is no owner
///         and no address parameter anywhere.
///
///         MEV note: the swap is permissionless but bounded to a 1% price move per call and one call per hour
///         per Moment. A sandwich has to pay the 1% hook fee plus the 0.5% LP fee twice (3% round trip) to
///         capture at most that 1% move, so it loses money — see test/moments/Buyback.t.sol. Callers may still
///         pass `minCoinOut`.
///
///         Price and balance guards:
///         - the round refuses to run (`PriceMoved`) when the pool price is more than `MAX_OPEN_DEVIATION_BPS` away
///           from where it stood before the first swap of this block (recorded by the fee hook). A same-block
///           sandwich would have to move the price further than that to matter, and cannot; moving it less costs
///           more in fees (1% hook + 0.5% LP, each way) than adding liquidity at a price ≤2% off can yield.
///         - the pairing top-up is sized against the USDC the locker holds for THIS Moment (per-Moment accounting
///           in MomentLocker), not the locker's whole shared USDC balance.
///         - sec2: a push made in an EARLIER block passes the block-open guard, so the locker caps what one round
///           adds at 0.5% of the position (`MomentLocker.MAX_INCREASE_BPS`). With this contract's 1% impact cap, one
///           round hands a cross-block sandwich about 1% of its push, less than the push's fees. Whatever a round does
///           not add stays held for the Moment and is paired later.
contract MomentBuyback is IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 public constant MAX_IMPACT_BPS = 100; // 1% price move per call
    uint256 public constant MIN_INTERVAL = 1 hours; // per Moment
    uint256 public constant MIN_AMOUNT = 1_000_000; // 1 USDC: no dust rounds
    /// @dev sqrt(10000/10100)·1e9 and sqrt(10100/10000)·1e9: the sqrt-price factors for a 1% price move.
    uint256 private constant SQRT_DOWN_1E9 = 995037190;
    uint256 private constant SQRT_UP_1E9 = 1004987562;
    /// @notice The most the price may have moved within the current block before a round runs (2%).
    uint256 public constant MAX_OPEN_DEVIATION_BPS = 200;
    /// @dev sqrt(10000/10200)·1e9 and sqrt(10200/10000)·1e9: the sqrt-price bounds of a 2% price move.
    uint256 private constant SQRT_OPEN_DOWN_1E9 = 990147542;
    uint256 private constant SQRT_OPEN_UP_1E9 = 1009950494;

    IPoolManager public immutable poolManager;
    IMomentsFactory public immutable factory;
    IERC20 public immutable USDC;

    mapping(uint256 => uint256) public carry; // USDC held here for a Moment between rounds
    mapping(uint256 => uint64) public lastRun;

    struct Round {
        uint256 budget; // carry + pulled
        uint256 usdcSpent; // USDC swapped into coin
        uint256 coinBought;
        uint256 usdcToPool; // USDC sent to the locker to pair the coin
        uint128 liquidityAdded;
        uint256 carried; // USDC left here for the next round
    }

    event Buyback(uint256 indexed momentId, uint256 budget, uint256 usdcSpent, uint256 coinBought, uint256 usdcToPool, uint128 liquidityAdded, uint256 carried);

    error NotPoolManager();
    error TooSoon();
    error BelowMinimum();
    error Slippage();
    error PriceMoved();
    error ZeroAddress();

    constructor(IPoolManager _poolManager, IMomentsFactory _factory, IERC20 _usdc) {
        if (address(_poolManager) == address(0) || address(_factory) == address(0) || address(_usdc) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        factory = _factory;
        USDC = _usdc;
    }

    /// @notice Runs one buyback-and-LP round for a graduated Moment. Permissionless.
    function execute(uint256 momentId, uint256 minCoinOut) external nonReentrant returns (Round memory r) {
        if (block.timestamp < uint256(lastRun[momentId]) + MIN_INTERVAL) revert TooSoon();
        PoolKey memory key = IMomentGraduationRegistry(factory.graduation()).poolKeyOf(momentId); // reverts unless graduated
        address locker = factory.locker();
        IMomentFeeHook hook = IMomentFeeHook(factory.feeHook());
        _checkBlockOpen(key, hook.blockOpenSqrtPrice(momentId));
        uint256 pulled = hook.pullBuyback(momentId);
        r.budget = carry[momentId] + pulled;
        if (r.budget < MIN_AMOUNT) revert BelowMinimum();
        // effects
        carry[momentId] = 0;
        lastRun[momentId] = uint64(block.timestamp);

        // 1. Swap about half the budget into coin, bounded by the impact cap. Coin lands in the locker directly.
        bool usdcIs0 = Currency.unwrap(key.currency0) == address(USDC);
        (uint256 spent, uint256 got, uint160 sqrtAfter) =
            abi.decode(poolManager.unlock(abi.encode(key, usdcIs0, r.budget / 2, locker)), (uint256, uint256, uint160));
        if (got < minCoinOut) revert Slippage();
        r.usdcSpent = spent;
        r.coinBought = got;

        // 2. Pair: the locker adds everything it holds, so size the USDC top-up for ALL the coin it now holds
        //    (bought + LP-fee coin already folded in) at the post-swap price, net of USDC it already holds for
        //    THIS Moment (other Moments' idle USDC in the shared locker is not ours to pair with).
        uint256 remaining = r.budget - spent;
        uint256 coinHeld = IMomentLocker(locker).available(momentId, usdcIs0 ? key.currency1 : key.currency0);
        uint256 usdcHeld = IMomentLocker(locker).available(momentId, usdcIs0 ? key.currency0 : key.currency1);
        uint256 needed = _usdcForCoin(key, usdcIs0, sqrtAfter, coinHeld);
        uint256 missing = needed > usdcHeld ? needed - usdcHeld : 0;
        r.usdcToPool = missing < remaining ? missing : remaining;
        r.carried = remaining - r.usdcToPool;
        carry[momentId] = r.carried;
        if (r.usdcToPool != 0) USDC.safeTransfer(locker, r.usdcToPool);
        (r.liquidityAdded,,) = IMomentLocker(locker).increase(momentId);
        emit Buyback(momentId, r.budget, spent, got, r.usdcToPool, r.liquidityAdded, r.carried);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool usdcIs0, uint256 spend, address locker) = abi.decode(data, (PoolKey, bool, uint256, address));
        PoolId id = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        // Buying coin: zeroForOne when USDC is currency0 (price falls), else oneForZero (price rises).
        uint160 limit = usdcIs0
            ? uint160(Math.mulDiv(sqrtP, SQRT_DOWN_1E9, 1e9))
            : uint160(Math.mulDiv(sqrtP, SQRT_UP_1E9, 1e9));
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = poolManager.swap(
            key, IPoolManager.SwapParams({zeroForOne: usdcIs0, amountSpecified: -int256(spend), sqrtPriceLimitX96: limit}), ""
        );
        int128 dUsdc = usdcIs0 ? delta.amount0() : delta.amount1();
        int128 dCoin = usdcIs0 ? delta.amount1() : delta.amount0();
        uint256 spent = dUsdc < 0 ? uint256(uint128(-dUsdc)) : 0;
        uint256 got = dCoin > 0 ? uint256(uint128(dCoin)) : 0;
        Currency usdcCurrency = usdcIs0 ? key.currency0 : key.currency1;
        Currency coinCurrency = usdcIs0 ? key.currency1 : key.currency0;
        if (spent != 0) {
            poolManager.sync(usdcCurrency);
            usdcCurrency.transfer(address(poolManager), spent);
            poolManager.settle();
        }
        if (got != 0) poolManager.take(coinCurrency, locker, got);
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(id);
        return abi.encode(spent, got, sqrtAfter);
    }

    /// @dev Reverts `PriceMoved` unless the live price is within `MAX_OPEN_DEVIATION_BPS` of the price
    ///      before the first swap of this block.
    function _checkBlockOpen(PoolKey memory key, uint160 openSqrtP) private view {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        if (
            uint256(sqrtP) > Math.mulDiv(openSqrtP, SQRT_OPEN_UP_1E9, 1e9)
                || uint256(sqrtP) < Math.mulDiv(openSqrtP, SQRT_OPEN_DOWN_1E9, 1e9)
        ) revert PriceMoved();
    }

    /// @dev USDC (rounded up) that pairs `coin` in the full-range position at price sqrtP.
    function _usdcForCoin(PoolKey memory key, bool usdcIs0, uint160 sqrtP, uint256 coin) private pure returns (uint256) {
        if (coin == 0) return 0;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing));
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing));
        if (usdcIs0) {
            uint256 l = MomentPoolMath.liquidityForAmount1(sqrtA, sqrtP, coin);
            if (l > type(uint128).max) l = type(uint128).max;
            return MomentPoolMath.amount0ForLiquidity(sqrtP, sqrtB, uint128(l));
        } else {
            uint256 l = MomentPoolMath.liquidityForAmount0(sqrtP, sqrtB, coin);
            if (l > type(uint128).max) l = type(uint128).max;
            return MomentPoolMath.amount1ForLiquidity(sqrtA, sqrtP, uint128(l));
        }
    }
}
