// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {Types, IFeeEscrow, IHolderFeeSharing, ILaunchpadFactory} from "./interfaces/ILaunchpad.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice One per launch. Prices and settles every trade before graduation on a constant-product curve with a
///         phantom quote reserve. Fees come off the input on buys and off the output on sells; the snipe tax only
///         applies to buys in the first seconds. The final buy is clamped to the graduation threshold and the
///         unused quote is refunded. Once complete, the factory sweeps the reserves into the Uniswap v4 pool.
contract BondingCurve {
    address public immutable factory;
    address public immutable token;
    address public immutable pairToken; // address(0) = native MON
    address public immutable escrow;
    address public immutable sharing;
    uint256 public immutable phantomQuote;
    uint256 public immutable graduationThreshold;
    uint256 public immutable reservedTokens; // the token reserve left when the threshold is raised
    uint16 public immutable feeBps;
    uint16 public immutable creatorTaxBps;
    /// @dev The protocol's share of the base fee, pinned at launch. Reading it live from the factory would let the
    ///      owner retroactively rewrite the split that `expectedEconomics` promised the creator.
    uint16 public immutable protocolShareBps;
    bool public immutable holderFeeSharing;
    /// @dev Hard ceiling on fee + creator tax + snipe tax. The opening-second snipe tax (98%) plus a 10% creator tax
    ///      would exceed 100% and make every buy revert with an arithmetic panic (or, at exactly 100%, take the
    ///      whole input for zero tokens); the snipe portion is clamped so a buy always returns something.
    uint256 public constant MAX_TOTAL_BPS = 9_900;
    uint64 public immutable launchedAt;

    address public creatorFeeRecipient;
    uint16[] private _snipeTaxSchedule;
    mapping(address => bool) public snipeTaxExempt;

    uint256 public quoteReserve; // phantom + real
    uint256 public tokenReserve;
    uint256 public realQuoteReserve;
    bool public completed;
    bool public swept;
    bool public rescued;
    uint256 private _entered = 1;

    event CurveBuy(address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax);
    event CurveSell(address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax);
    event CurveBuyRefunded(address indexed buyer, uint256 refundAmount);
    event CurveCompleted(address indexed token);
    event FeesDistributed(uint256 protocolFee, uint256 creatorFee);
    event CreatorFeeRecipientUpdated(address indexed recipient);
    event CurveSwept(address indexed to, uint256 quoteAmount, uint256 tokenAmount);
    event RescueEnabled();

    error CurveNotTrading();
    error CurveIsCompleted();
    error SlippageExceeded();
    error NativeValueMismatch();
    error UnexpectedNativeValue();
    error NotFactory();
    error ZeroAmount();
    error Reentrancy();
    error InsufficientRealReserve();
    error AlreadySwept();
    error UnsupportedQuoteToken();

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address _factory, Types.CurveInit memory init) {
        factory = _factory;
        token = init.token;
        pairToken = init.pairToken;
        escrow = ILaunchpadFactory(_factory).escrow();
        sharing = ILaunchpadFactory(_factory).holderFeeSharing();
        phantomQuote = init.phantomQuote;
        graduationThreshold = init.graduationThreshold;
        reservedTokens = CurveMath.reservedSupply(init.supply, init.phantomQuote, init.graduationThreshold);
        feeBps = init.feeBps;
        creatorTaxBps = init.creatorTaxBps;
        protocolShareBps = init.protocolShareBps;
        creatorFeeRecipient = init.creatorFeeRecipient;
        holderFeeSharing = init.holderFeeSharing;
        launchedAt = uint64(block.timestamp);
        _snipeTaxSchedule = init.snipeTaxSchedule;
        snipeTaxExempt[init.deployer] = true;
        snipeTaxExempt[init.creatorFeeRecipient] = true;
        for (uint256 i = 0; i < init.snipeTaxExemptions.length; i++) {
            snipeTaxExempt[init.snipeTaxExemptions[i]] = true;
        }
        quoteReserve = init.phantomQuote;
        tokenReserve = init.supply; // the factory transfers the supply in right after construction
    }

    // ------------------------------------------------------------------ trading

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (completed || rescued) revert CurveNotTrading();
        if (quoteIn == 0) revert ZeroAmount();
        _pullQuote(quoteIn);

        (uint256 used, uint256 net, uint256 fee, uint256 tax, uint256 snipe, uint256 refund) = _buyBreakdown(quoteIn, recipient);
        tokensOut = CurveMath.amountOut(net, quoteReserve, tokenReserve);
        if (tokensOut < minTokensOut) revert SlippageExceeded();

        quoteReserve += net;
        tokenReserve -= tokensOut;
        realQuoteReserve += net;

        TransferHelper.safeTransfer(token, recipient, tokensOut);
        _distributeFees(fee + snipe, tax);
        emit CurveBuy(msg.sender, recipient, used, tokensOut, fee + snipe, tax);

        if (refund > 0) {
            TransferHelper.pay(pairToken, msg.sender, refund);
            emit CurveBuyRefunded(msg.sender, refund);
        }
        if (realQuoteReserve >= graduationThreshold) {
            completed = true;
            emit CurveCompleted(token);
            ILaunchpadFactory(factory).onCurveComplete(token);
        }
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external nonReentrant returns (uint256 quoteOut) {
        if (completed && !rescued) revert CurveNotTrading();
        if (tokensIn == 0) revert ZeroAmount();
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), tokensIn);

        uint256 gross = CurveMath.amountOut(tokensIn, tokenReserve, quoteReserve);
        if (gross > realQuoteReserve) revert InsufficientRealReserve();
        (uint256 fee, uint256 tax) = rescued ? (0, 0) : (CurveMath.feeOf(gross, feeBps), CurveMath.feeOf(gross, creatorTaxBps));
        quoteOut = gross - fee - tax;
        if (quoteOut < minQuoteOut) revert SlippageExceeded();

        tokenReserve += tokensIn;
        quoteReserve -= gross;
        realQuoteReserve -= gross;

        _distributeFees(fee, tax);
        TransferHelper.pay(pairToken, recipient, quoteOut);
        emit CurveSell(msg.sender, recipient, tokensIn, quoteOut, fee, tax);
    }

    // ------------------------------------------------------------------ factory hooks

    /// @notice Hands the collected quote and the remaining tokens to `to` (the graduation executor).
    function sweep(address to) external onlyFactory returns (uint256 quoteAmount, uint256 tokenAmount) {
        if (!completed) revert CurveNotTrading();
        if (swept) revert AlreadySwept();
        swept = true;
        quoteAmount = realQuoteReserve;
        tokenAmount = tokenReserve;
        realQuoteReserve = 0;
        TransferHelper.pay(pairToken, to, quoteAmount);
        TransferHelper.safeTransfer(token, to, tokenAmount);
        emit CurveSwept(to, quoteAmount, tokenAmount);
    }

    /// @notice Stuck-launch valve: reopens the curve for fee-free sells so holders can exit at the curve price.
    function enableRescue() external onlyFactory {
        if (!completed) revert CurveNotTrading();
        if (swept) revert AlreadySwept();
        rescued = true;
        emit RescueEnabled();
    }

    /// @dev v2 (sec2): no snipe-tax exemption for the new recipient. The initial recipient is exempted at launch; a
    ///      hand-off (possibly a chain of them inside the 4-second window) must not exempt wallets past MAX_EXEMPTIONS.
    function setCreatorFeeRecipient(address recipient) external onlyFactory {
        creatorFeeRecipient = recipient;
        emit CreatorFeeRecipientUpdated(recipient);
    }

    // ------------------------------------------------------------------ views

    function isNativeQuote() external view returns (bool) {
        return pairToken == address(0);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (quoteReserve, tokenReserve);
    }

    function sellableTokens() public view returns (uint256) {
        return tokenReserve > reservedTokens ? tokenReserve - reservedTokens : 0;
    }

    function readyToGraduate() external view returns (bool) {
        return completed && !swept && !rescued;
    }

    function graduated() external view returns (bool) {
        return swept;
    }

    /// @dev Quote per token, 18-decimal fixed point.
    function price() external view returns (uint256) {
        return FullMath.mulDiv(quoteReserve, 1e18, tokenReserve);
    }

    function snipeTaxSchedule() external view returns (uint16[] memory) {
        return _snipeTaxSchedule;
    }

    function currentSnipeTaxBps(address recipient) public view returns (uint256) {
        if (snipeTaxExempt[recipient]) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= _snipeTaxSchedule.length) return 0;
        return _snipeTaxSchedule[elapsed];
    }

    /// @notice Previews a buy exactly as `buy` would settle it.
    function quoteBuy(uint256 quoteIn, address recipient)
        external
        view
        returns (uint256 tokensOut, uint256 used, uint256 fee, uint256 tax, uint256 snipe, uint256 refund)
    {
        if (completed || rescued || quoteIn == 0) return (0, 0, 0, 0, 0, quoteIn);
        uint256 net;
        (used, net, fee, tax, snipe, refund) = _buyBreakdown(quoteIn, recipient);
        tokensOut = CurveMath.amountOut(net, quoteReserve, tokenReserve);
    }

    function quoteSell(uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee, uint256 tax) {
        if ((completed && !rescued) || tokensIn == 0) return (0, 0, 0);
        uint256 gross = CurveMath.amountOut(tokensIn, tokenReserve, quoteReserve);
        if (gross > realQuoteReserve) return (0, 0, 0);
        if (!rescued) {
            fee = CurveMath.feeOf(gross, feeBps);
            tax = CurveMath.feeOf(gross, creatorTaxBps);
        }
        quoteOut = gross - fee - tax;
    }

    // ------------------------------------------------------------------ internals

    function _buyBreakdown(uint256 quoteIn, address recipient)
        internal
        view
        returns (uint256 used, uint256 net, uint256 fee, uint256 tax, uint256 snipe, uint256 refund)
    {
        uint256 baseBps = uint256(feeBps) + creatorTaxBps;
        uint256 snipeBps = currentSnipeTaxBps(recipient);
        if (baseBps + snipeBps > MAX_TOTAL_BPS) snipeBps = baseBps >= MAX_TOTAL_BPS ? 0 : MAX_TOTAL_BPS - baseBps;
        uint256 totalBps = baseBps + snipeBps;
        used = quoteIn;
        net = quoteIn - CurveMath.feeOf(quoteIn, totalBps);
        uint256 remaining = graduationThreshold - realQuoteReserve;
        if (net > remaining) {
            used = CurveMath.grossForNet(remaining, totalBps);
            if (used > quoteIn) used = quoteIn;
            net = used - CurveMath.feeOf(used, totalBps);
            if (net > remaining) net = remaining;
            refund = quoteIn - used;
        }
        fee = CurveMath.feeOf(used, feeBps);
        tax = CurveMath.feeOf(used, creatorTaxBps);
        snipe = used - net - fee - tax; // absorbs rounding so used == net + fee + tax + snipe
    }

    function _pullQuote(uint256 quoteIn) internal {
        if (pairToken == address(0)) {
            if (msg.value != quoteIn) revert NativeValueMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            // v2 (sec2, LP-6): the curve books exactly `quoteIn`, so a fee-on-transfer quote asset (which delivers
            // less) would make it insolvent. Such an asset can never trade here.
            uint256 before = IERC20(pairToken).balanceOf(address(this));
            TransferHelper.safeTransferFrom(pairToken, msg.sender, address(this), quoteIn);
            if (IERC20(pairToken).balanceOf(address(this)) - before != quoteIn) revert UnsupportedQuoteToken();
        }
    }

    /// @dev Protocol takes its (launch-pinned) share of the base fee (snipe tax included); the rest plus the whole
    ///      creator tax goes to the creator wallet, or to the holders when holder fee sharing is on.
    function _distributeFees(uint256 baseFee, uint256 tax) internal {
        if (baseFee + tax == 0) return;
        uint256 protocolCut = CurveMath.feeOf(baseFee, protocolShareBps);
        uint256 creatorCut = baseFee - protocolCut + tax;
        address protocol = ILaunchpadFactory(factory).protocolFeeRecipient();
        if (pairToken == address(0)) {
            if (protocolCut > 0) IFeeEscrow(escrow).credit{value: protocolCut}(protocol);
            if (creatorCut > 0) {
                if (holderFeeSharing) IHolderFeeSharing(sharing).notifyReward{value: creatorCut}(token, creatorCut);
                else IFeeEscrow(escrow).credit{value: creatorCut}(creatorFeeRecipient);
            }
        } else {
            if (protocolCut > 0) {
                TransferHelper.safeApprove(pairToken, escrow, protocolCut);
                IFeeEscrow(escrow).creditToken(protocol, pairToken, protocolCut);
            }
            if (creatorCut > 0) {
                if (holderFeeSharing) {
                    TransferHelper.safeApprove(pairToken, sharing, creatorCut);
                    IHolderFeeSharing(sharing).notifyReward(token, creatorCut);
                } else {
                    TransferHelper.safeApprove(pairToken, escrow, creatorCut);
                    IFeeEscrow(escrow).creditToken(creatorFeeRecipient, pairToken, creatorCut);
                }
            }
        }
        emit FeesDistributed(protocolCut, creatorCut);
    }
}
