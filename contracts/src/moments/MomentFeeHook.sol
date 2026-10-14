// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {MomentTypes, IMomentsFactory} from "./interfaces/IMoments.sol";
import {IMomentFeeHook} from "./interfaces/IMomentsMarket.sol";

/// @notice Singleton v4 hook for every graduated Moment pool. On top of the pool's own 0.5% LP fee (which accrues
///         to the locked position), the hook charges 1% of the USDC side of every swap — off the USDC spent on
///         buys, off the USDC received on sells, whichever leg is USDC — and splits it 0.2% creator / 0.3% platform
///         / 0.5% buyback. Fees are held
///         here in USDC and are pull-only by the Moment's immutable creator and platform; the buyback share can
///         only be pulled by the buyback module. Only the graduation executor can initialize a registered pool,
///         and the hook refuses to serve unregistered pools, so nobody can front-run graduation with a mispriced
///         pool or attach this hook to an arbitrary pair. The buyback module's own swaps are fee-exempt.
///
///         Before the first swap of each block the hook
///         records the pool's price, so the buyback can refuse to add liquidity at a price someone moved within
///         the same block (the sandwich pattern). One storage slot per Moment; written once per block.
contract MomentFeeHook is IHooks, IMomentFeeHook, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = MomentTypes.BPS;
    uint256 public constant FEE_BPS = 100; // 1% of the USDC leg
    uint256 public constant CREATOR_SHARE_BPS = 2_000; // of the fee (= 0.2% of volume)
    uint256 public constant PLATFORM_SHARE_BPS = 3_000; // of the fee (= 0.3% of volume)
    // buyback share = the remainder (= 0.5% of volume, plus the split's rounding dust)

    IPoolManager public immutable poolManager;
    IMomentsFactory public immutable factory;
    Currency public immutable usdc;

    mapping(PoolId => uint256) public momentOf; // registered pools only
    mapping(uint256 => PoolId) public poolOf;
    mapping(uint256 => uint256) public creatorAccrued;
    mapping(uint256 => uint256) public platformAccrued;
    mapping(uint256 => uint256) public buybackAccrued;

    /// @dev The pool price before the first swap of `blockNumber` (packed in one slot).
    struct BlockOpen {
        uint160 sqrtPriceX96;
        uint64 blockNumber;
    }

    mapping(uint256 => BlockOpen) private _blockOpen;

    event PoolRegistered(uint256 indexed momentId, PoolId indexed poolId);
    event FeeTaken(uint256 indexed momentId, uint256 fee, uint256 creatorPart, uint256 platformPart, uint256 buybackPart);
    event FeesWithdrawn(uint256 indexed momentId, address indexed beneficiary, uint256 amount);
    event BuybackPulled(uint256 indexed momentId, uint256 amount);

    error NotPoolManager();
    error NotGraduation();
    error NotBuyback();
    error NotBeneficiary();
    error PoolNotRegistered();
    error AlreadyRegistered();
    error NotUsdcPair();
    error NothingToWithdraw();
    error HookNotImplemented();
    error ZeroAddress();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, IMomentsFactory _factory, IERC20 _usdc) {
        if (address(_poolManager) == address(0) || address(_factory) == address(0) || address(_usdc) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        factory = _factory;
        usdc = Currency.wrap(address(_usdc));
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ registry (graduation executor only)

    function register(PoolKey calldata key, uint256 momentId) external {
        if (msg.sender != factory.graduation()) revert NotGraduation();
        if (Currency.unwrap(key.currency0) != Currency.unwrap(usdc) && Currency.unwrap(key.currency1) != Currency.unwrap(usdc)) revert NotUsdcPair();
        PoolId id = key.toId();
        if (momentOf[id] != 0 || PoolId.unwrap(poolOf[momentId]) != bytes32(0)) revert AlreadyRegistered();
        momentOf[id] = momentId;
        poolOf[momentId] = id;
        emit PoolRegistered(momentId, id);
    }

    // ------------------------------------------------------------------ hooks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (momentOf[key.toId()] == 0) revert PoolNotRegistered();
        if (sender != factory.graduation()) revert NotGraduation();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Charges the fee here when USDC is the SPECIFIED currency: exact-input buys (fee off the input) and
    ///      exact-output sells (the pool outputs the fee on top, so the swapper still receives exactly what was
    ///      asked for and the fee is 1% of the gross USDC out).
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint256 momentId = momentOf[poolId];
        if (momentId == 0) revert PoolNotRegistered();
        BlockOpen storage open = _blockOpen[momentId];
        if (open.blockNumber != block.number) {
            // First swap of this block — remember the price it starts from.
            (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
            open.sqrtPriceX96 = sqrtP;
            open.blockNumber = uint64(block.number);
        }
        if (sender == factory.buyback()) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (!_usdcIsSpecified(key, params)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        bool exactIn = params.amountSpecified < 0;
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = exactIn ? amount * FEE_BPS / BPS : amount * FEE_BPS / (BPS - FEE_BPS);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        _take(momentId, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @dev Charges the fee here when USDC is the UNSPECIFIED currency: exact-input sells (fee off the USDC
    ///      received) and exact-output buys (fee added on top of the USDC paid, 1% of the gross spend).
    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 momentId = momentOf[key.toId()];
        if (momentId == 0) revert PoolNotRegistered();
        if (sender == factory.buyback()) return (IHooks.afterSwap.selector, 0);
        if (_usdcIsSpecified(key, params)) return (IHooks.afterSwap.selector, 0); // charged in beforeSwap
        int128 usdcDelta = _usdcIs0(key) ? delta.amount0() : delta.amount1();
        uint256 fee;
        if (usdcDelta < 0) {
            fee = uint256(uint128(-usdcDelta)) * FEE_BPS / (BPS - FEE_BPS); // exact-output buy: swapper pays USDC
        } else {
            fee = uint256(uint128(usdcDelta)) * FEE_BPS / BPS; // exact-input sell: swapper receives USDC
        }
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        _take(momentId, fee);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    function _take(uint256 momentId, uint256 fee) private {
        poolManager.take(usdc, address(this), fee);
        uint256 creatorPart = fee * CREATOR_SHARE_BPS / BPS;
        uint256 platformPart = fee * PLATFORM_SHARE_BPS / BPS;
        uint256 buybackPart = fee - creatorPart - platformPart;
        creatorAccrued[momentId] += creatorPart;
        platformAccrued[momentId] += platformPart;
        buybackAccrued[momentId] += buybackPart;
        emit FeeTaken(momentId, fee, creatorPart, platformPart, buybackPart);
    }

    function _usdcIs0(PoolKey calldata key) private view returns (bool) {
        return Currency.unwrap(key.currency0) == Currency.unwrap(usdc);
    }

    /// @dev The specified currency is the input of an exact-input swap or the output of an exact-output swap.
    function _usdcIsSpecified(PoolKey calldata key, IPoolManager.SwapParams calldata params) private view returns (bool) {
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIs0 = params.zeroForOne == exactIn;
        return specifiedIs0 == _usdcIs0(key);
    }

    // ------------------------------------------------------------------ pull-only proceeds

    function withdrawCreator(uint256 momentId) external nonReentrant returns (uint256 amount) {
        if (msg.sender != factory.getMoment(momentId).creator) revert NotBeneficiary();
        amount = creatorAccrued[momentId];
        if (amount == 0) revert NothingToWithdraw();
        creatorAccrued[momentId] = 0;
        IERC20(Currency.unwrap(usdc)).safeTransfer(msg.sender, amount);
        emit FeesWithdrawn(momentId, msg.sender, amount);
    }

    function withdrawPlatform(uint256 momentId) external nonReentrant returns (uint256 amount) {
        if (msg.sender != factory.getMoment(momentId).platform) revert NotBeneficiary();
        amount = platformAccrued[momentId];
        if (amount == 0) revert NothingToWithdraw();
        platformAccrued[momentId] = 0;
        IERC20(Currency.unwrap(usdc)).safeTransfer(msg.sender, amount);
        emit FeesWithdrawn(momentId, msg.sender, amount);
    }

    /// @notice Hands the accrued buyback USDC to the buyback module (and nobody else).
    function pullBuyback(uint256 momentId) external nonReentrant returns (uint256 amount) {
        if (msg.sender != factory.buyback()) revert NotBuyback();
        amount = buybackAccrued[momentId];
        if (amount == 0) return 0;
        buybackAccrued[momentId] = 0;
        IERC20(Currency.unwrap(usdc)).safeTransfer(msg.sender, amount);
        emit BuybackPulled(momentId, amount);
    }

    // ------------------------------------------------------------------ views

    /// @notice The pool's sqrt price before the first swap of the CURRENT block, or its live price when
    ///         nothing has swapped in this block yet (then the two are the same thing).
    function blockOpenSqrtPrice(uint256 momentId) external view returns (uint160 sqrtPriceX96) {
        BlockOpen storage open = _blockOpen[momentId];
        if (open.blockNumber == block.number) return open.sqrtPriceX96;
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolOf[momentId]);
    }

    // ------------------------------------------------------------------ unused hook entry points

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
