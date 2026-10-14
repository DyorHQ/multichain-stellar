// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Types, IFeeEscrow, IHolderFeeSharing, ILaunchpadFactory} from "./interfaces/ILaunchpad.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Singleton Uniswap v4 hook for every graduated launch. Pools are created with a zero LP fee and the hook
///         charges the launch's base fee plus creator tax instead: on the quote spent for buys and on the quote
///         received for sells. Exact-output sells are the one case charged in the launch token. Only the graduation
///         executor may initialize a registered pool, so nobody can front-run graduation with a mispriced pool.
///
///         For a launch with holder fee sharing, the holders' cut of a quote-denominated fee is handed to
///         HolderFeeSharing in the same swap that earned it (as the bonding curve does on every curve trade), so a
///         reward only ever reaches the balances that held through the block the fee was paid in. The protocol's cut
///         waits here (`pendingProtocolFees`) and is paid out by `sweepPoolFees`.
contract MemeHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    address public immutable factory;

    mapping(PoolId => Types.PoolLaunch) private _launches;
    mapping(PoolId => mapping(Currency => uint256)) public pendingFees;
    mapping(PoolId => mapping(Currency => uint256)) public pendingCreatorTax;
    /// @notice The protocol's cut of fees whose holders' cut was already forwarded in the swap.
    mapping(PoolId => mapping(Currency => uint256)) public pendingProtocolFees;

    event PoolRegistered(PoolId indexed poolId, address indexed token, address indexed pairToken);
    event FeesTaken(PoolId indexed poolId, Currency indexed currency, uint256 fee, uint256 tax);
    /// The holders' cut forwarded to HolderFeeSharing inside the swap.
    event HolderFeesForwarded(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event PoolFeesSwept(PoolId indexed poolId, Currency indexed currency, uint256 protocolFee, uint256 creatorFee);
    event CreatorFeeRecipientUpdated(PoolId indexed poolId, address indexed recipient);

    error NotPoolManager();
    error NotFactory();
    error NotExecutor();
    error PoolNotRegistered();
    error AlreadyRegistered();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(IPoolManager _poolManager, address _factory) {
        poolManager = _poolManager;
        factory = _factory;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    receive() external payable {}

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

    // ------------------------------------------------------------------ factory

    function registerLaunch(PoolKey calldata key, Types.PoolLaunch calldata launch) external onlyFactory {
        PoolId id = key.toId();
        if (_launches[id].registered) revert AlreadyRegistered();
        _launches[id] = launch;
        _launches[id].registered = true;
        emit PoolRegistered(id, launch.token, launch.quoteToken);
    }

    function setCreatorFeeRecipient(bytes32 poolId, address recipient) external onlyFactory {
        _launches[PoolId.wrap(poolId)].creatorFeeRecipient = recipient;
        emit CreatorFeeRecipientUpdated(PoolId.wrap(poolId), recipient);
    }

    function launches(bytes32 poolId) external view returns (Types.PoolLaunch memory) {
        return _launches[PoolId.wrap(poolId)];
    }

    // ------------------------------------------------------------------ hooks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!_launches[key.toId()].registered) revert PoolNotRegistered();
        if (sender != ILaunchpadFactory(factory).graduationExecutor()) revert NotExecutor();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Types.PoolLaunch storage launch = _launches[id];
        if (!launch.registered) revert PoolNotRegistered();
        bool exactIn = params.amountSpecified < 0;
        bool inputIsQuote = params.zeroForOne ? !launch.tokenIsCurrency0 : launch.tokenIsCurrency0;
        if (exactIn && inputIsQuote) {
            // Buy with an exact quote amount: the fee comes off what is spent, before the pool prices the trade.
            uint256 amountIn = uint256(-params.amountSpecified);
            uint256 fee = CurveMath.feeOf(amountIn, launch.feeBps);
            uint256 tax = CurveMath.feeOf(amountIn, launch.creatorTaxBps);
            Currency quote = launch.tokenIsCurrency0 ? key.currency1 : key.currency0;
            _take(id, quote, fee, tax);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee + tax)), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Types.PoolLaunch storage launch = _launches[id];
        if (!launch.registered) revert PoolNotRegistered();
        bool exactIn = params.amountSpecified < 0;
        bool inputIsQuote = params.zeroForOne ? !launch.tokenIsCurrency0 : launch.tokenIsCurrency0;
        if (exactIn && inputIsQuote) return (IHooks.afterSwap.selector, 0); // already charged in beforeSwap

        // The unspecified currency is the output of an exact-input swap or the input of an exact-output swap.
        bool unspecifiedIs0 = exactIn ? !params.zeroForOne : params.zeroForOne;
        Currency unspecified = unspecifiedIs0 ? key.currency0 : key.currency1;
        int128 signed = unspecifiedIs0 ? delta.amount0() : delta.amount1();
        uint256 base = signed < 0 ? uint256(uint128(-signed)) : uint256(uint128(signed));
        uint256 fee;
        uint256 tax;
        if (exactIn) {
            // Sell: fee comes off the quote received.
            fee = CurveMath.feeOf(base, launch.feeBps);
            tax = CurveMath.feeOf(base, launch.creatorTaxBps);
        } else {
            // Exact output: fee is added on top of what is paid so it still equals bps of the total spend.
            uint256 totalBps = uint256(launch.feeBps) + launch.creatorTaxBps;
            uint256 total = CurveMath.grossForNet(base, totalBps) - base;
            fee = totalBps == 0 ? 0 : (total * launch.feeBps) / totalBps;
            tax = total - fee;
        }
        if (fee + tax == 0) return (IHooks.afterSwap.selector, 0);
        _take(id, unspecified, fee, tax);
        return (IHooks.afterSwap.selector, int128(uint128(fee + tax)));
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
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

    // ------------------------------------------------------------------ fee distribution

    /// @notice Pays out what the hook has collected for a pool in `currency`. Anyone may call it.
    function sweepPoolFees(bytes32 poolId, Currency currency) external {
        PoolId id = PoolId.wrap(poolId);
        Types.PoolLaunch storage launch = _launches[id];
        if (!launch.registered) revert PoolNotRegistered();
        uint256 fee = pendingFees[id][currency];
        uint256 tax = pendingCreatorTax[id][currency];
        uint256 protocolOnly = pendingProtocolFees[id][currency]; // holders' cut already forwarded
        if (fee + tax + protocolOnly == 0) return;
        pendingFees[id][currency] = 0;
        pendingCreatorTax[id][currency] = 0;
        pendingProtocolFees[id][currency] = 0;

        // The split is the one pinned at launch (copied from the curve at graduation), never the live policy.
        uint256 protocolCut = CurveMath.feeOf(fee, launch.protocolShareBps);
        uint256 creatorCut = fee - protocolCut + tax;
        protocolCut += protocolOnly;
        address escrow = ILaunchpadFactory(factory).escrow();
        address protocol = ILaunchpadFactory(factory).protocolFeeRecipient();
        address asset = Currency.unwrap(currency);
        // Holders only share fees denominated in the launch's quote asset; token-denominated fees go to the creator.
        bool toHolders = launch.holderFeeSharing && asset == launch.quoteToken;

        if (currency.isAddressZero()) {
            if (protocolCut > 0) IFeeEscrow(escrow).credit{value: protocolCut}(protocol);
            if (creatorCut > 0) {
                if (toHolders) IHolderFeeSharing(ILaunchpadFactory(factory).holderFeeSharing()).notifyReward{value: creatorCut}(launch.token, creatorCut);
                else IFeeEscrow(escrow).credit{value: creatorCut}(launch.creatorFeeRecipient);
            }
        } else {
            if (protocolCut > 0) {
                TransferHelper.safeApprove(asset, escrow, protocolCut);
                IFeeEscrow(escrow).creditToken(protocol, asset, protocolCut);
            }
            if (creatorCut > 0) {
                if (toHolders) {
                    address sharing = ILaunchpadFactory(factory).holderFeeSharing();
                    TransferHelper.safeApprove(asset, sharing, creatorCut);
                    IHolderFeeSharing(sharing).notifyReward(launch.token, creatorCut);
                } else {
                    TransferHelper.safeApprove(asset, escrow, creatorCut);
                    IFeeEscrow(escrow).creditToken(launch.creatorFeeRecipient, asset, creatorCut);
                }
            }
        }
        emit PoolFeesSwept(id, currency, protocolCut, creatorCut);
    }

    function _take(PoolId id, Currency currency, uint256 fee, uint256 tax) internal {
        poolManager.take(currency, address(this), fee + tax);
        emit FeesTaken(id, currency, fee, tax);
        Types.PoolLaunch storage launch = _launches[id];
        if (launch.holderFeeSharing && Currency.unwrap(currency) == launch.quoteToken) {
            // Forward the holders' cut now (same split as `sweepPoolFees`); keep the protocol's here.
            uint256 protocolCut = CurveMath.feeOf(fee, launch.protocolShareBps);
            uint256 holderCut = fee - protocolCut + tax;
            pendingProtocolFees[id][currency] += protocolCut;
            if (holderCut != 0) _forwardToHolders(id, launch.token, currency, holderCut);
            return;
        }
        pendingFees[id][currency] += fee;
        pendingCreatorTax[id][currency] += tax;
    }

    /// @dev Queues `amount` of the quote asset for the launch's holders (released a block later).
    function _forwardToHolders(PoolId id, address token, Currency currency, uint256 amount) internal {
        address sharing = ILaunchpadFactory(factory).holderFeeSharing();
        if (currency.isAddressZero()) {
            IHolderFeeSharing(sharing).notifyReward{value: amount}(token, amount);
        } else {
            TransferHelper.safeApprove(Currency.unwrap(currency), sharing, amount);
            IHolderFeeSharing(sharing).notifyReward(token, amount);
        }
        emit HolderFeesForwarded(id, currency, amount);
    }
}
