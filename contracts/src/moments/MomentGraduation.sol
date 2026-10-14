// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {
    MomentTypes, IMomentsFactory, IMomentCollect, IMomentVesting, IMomentCoin, IMomentNFT, IMomentGraduation
} from "./interfaces/IMoments.sol";
import {IMomentLocker, IMomentFeeHook, IMomentGraduationRegistry} from "./interfaces/IMomentsMarket.sol";
import {MomentPoolMath} from "./libraries/MomentPoolMath.sol";

/// @notice Graduates a completed Moment atomically: takes the reserve, mints the pool coins
///         (S − creator allocation − Σ entitlements, the exact conservation identity), opens the coin/USDC v4
///         pool at the price-continuous opening price, locks a full-range position in MomentLocker, starts
///         vesting, closes the NFT edition and records the pool. Anything failing reverts the whole step, so a
///         Moment is either fully graduated or still GraduationPending (retriable by anyone). No owner, no
///         parameters, no pause: the only way in is the collect contract's terminal collect or a permissionless
///         retry, and every asset ends up in the locker.
contract MomentGraduation is IMomentGraduation, IMomentGraduationRegistry, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = MomentTypes.BPS;
    uint256 private constant S = MomentTypes.SUPPLY;
    /// @dev Pool LP fee, in hundredths of a bip (1e6 = 100%): 0.5%. It accrues to the locked full-range position,
    ///      which is the only LP, and is folded back into that position by the locker (depth grows with volume).
    ///      The hook charges the 1% Moments fee on top.
    uint24 public constant LP_FEE = 5_000;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    IMomentsFactory public immutable factory;
    IERC20 public immutable USDC;

    struct Record {
        PoolKey key;
        uint160 sqrtPriceX96; // opening price
        uint128 liquidity; // locked at graduation
        uint256 reserve; // USDC released from the collect contract
        uint256 poolCoins; // coins minted for the pool
        uint256 usedUsdc; // USDC actually placed in the position (dust stays locked in the locker)
        uint256 usedCoin;
        uint64 at;
    }

    mapping(uint256 => Record) private _records;

    event Graduated(
        uint256 indexed momentId,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 reserve,
        uint256 poolCoins,
        uint256 usedUsdc,
        uint256 usedCoin
    );

    error AlreadyGraduated();
    error NotPending();
    error SupplyInvariant();
    error PriceOutOfRange();
    error NotGraduated();
    error ZeroAddress();

    constructor(IPoolManager _poolManager, IMomentsFactory _factory, IERC20 _usdc) {
        if (address(_poolManager) == address(0) || address(_factory) == address(0) || address(_usdc) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        factory = _factory;
        USDC = _usdc;
    }

    /// @notice Graduates `momentId`. Called by the collect contract on the terminal collect (in an isolated
    ///         subcall) and by anyone as a retry while the Moment is GraduationPending.
    function graduate(uint256 momentId) external nonReentrant {
        if (_records[momentId].at != 0) revert AlreadyGraduated();
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        IMomentCollect collect = IMomentCollect(factory.collect());
        IMomentVesting vesting = IMomentVesting(factory.vesting());
        address locker = factory.locker();
        if (collect.state(momentId) != MomentTypes.State.GraduationPending) revert NotPending();

        // 1. Reserve USDC straight into the locker.
        uint256 reserve = collect.releaseReserve(momentId, locker);

        // 2. Pool coins by the exact conservation identity; nothing may exist before this mint.
        uint256 ents = vesting.totalEntitlement(momentId);
        uint256 alloc = S * m.creatorAllocBps / BPS;
        uint256 poolCoins = S - alloc - ents; // reverts if ever over-promised
        if (poolCoins == 0) revert SupplyInvariant();
        IMomentCoin coin = IMomentCoin(m.coin);
        if (coin.totalSupply() != 0) revert SupplyInvariant();
        coin.mint(locker, poolCoins);
        if (coin.totalSupply() + ents + alloc != S) revert SupplyInvariant();

        // 3. Pool key (currencies sorted by address) and the price-continuous opening price.
        bool usdcIs0 = address(USDC) < m.coin;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdcIs0 ? address(USDC) : m.coin),
            currency1: Currency.wrap(usdcIs0 ? m.coin : address(USDC)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(factory.feeHook())
        });
        (uint256 amount0, uint256 amount1) = usdcIs0 ? (reserve, poolCoins) : (poolCoins, reserve);
        uint160 sqrtPriceX96 = MomentPoolMath.sqrtPriceX96(amount0, amount1);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert PriceOutOfRange();
        IMomentFeeHook(address(key.hooks)).register(key, momentId);
        poolManager.initialize(key, sqrtPriceX96);

        // 4. Lock the full-range position, funded from the locker's balances.
        (uint128 liquidity, uint256 used0, uint256 used1) = IMomentLocker(locker).seed(momentId, key);

        // 5. Flip: vesting starts, edition fixed, collect ledger closed.
        vesting.activate(momentId);
        IMomentNFT(m.nft).close();
        collect.markGraduated(momentId);

        // 6. Registry.
        _records[momentId] = Record({
            key: key,
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity,
            reserve: reserve,
            poolCoins: poolCoins,
            usedUsdc: usdcIs0 ? used0 : used1,
            usedCoin: usdcIs0 ? used1 : used0,
            at: uint64(block.timestamp)
        });
        emit Graduated(momentId, key.toId(), sqrtPriceX96, liquidity, reserve, poolCoins, usdcIs0 ? used0 : used1, usdcIs0 ? used1 : used0);
    }

    // ------------------------------------------------------------------ registry views

    function record(uint256 momentId) external view returns (Record memory r) {
        r = _records[momentId];
        if (r.at == 0) revert NotGraduated();
    }

    function poolKeyOf(uint256 momentId) external view returns (PoolKey memory) {
        Record storage r = _records[momentId];
        if (r.at == 0) revert NotGraduated();
        return r.key;
    }

    function isGraduated(uint256 momentId) external view returns (bool) {
        return _records[momentId].at != 0;
    }

    /// @notice The pool key a Moment WILL graduate into (computable before graduation from the CREATE2 coin).
    function previewPoolKey(uint256 momentId) external view returns (PoolKey memory) {
        MomentTypes.Moment memory m = factory.getMoment(momentId);
        bool usdcIs0 = address(USDC) < m.coin;
        return PoolKey({
            currency0: Currency.wrap(usdcIs0 ? address(USDC) : m.coin),
            currency1: Currency.wrap(usdcIs0 ? m.coin : address(USDC)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(factory.feeHook())
        });
    }
}
