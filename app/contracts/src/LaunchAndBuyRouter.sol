// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types, IBondingCurve, ILaunchpadFactory} from "./interfaces/ILaunchpad.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Optional router: creates a launch and makes the creator's first buy in one transaction, so nobody
///         can get in before the developer buy. The deployer is snipe-tax exempt by construction.
contract LaunchAndBuyRouter {
    ILaunchpadFactory public immutable factory;

    error NativeValueMismatch();

    constructor(ILaunchpadFactory _factory) {
        factory = _factory;
    }

    receive() external payable {}

    function launchAndBuy(
        Types.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve, uint256 tokensOut) {
        uint256 fee = factory.launchFee();
        if (msg.value != (pairToken == address(0) ? fee + quoteIn : fee)) revert NativeValueMismatch();
        // Baseline the router's PRE-EXISTING balance (anything not part of this call). Refunds below only ever return
        // the unused portion of THIS call's funds, so funds mistakenly sent to the router can't be swept by a caller.
        uint256 nativeBaseline = address(this).balance - msg.value;
        // The snipe tax keys on the buy's `recipient`, and only the deployer is exempt by construction. A dev buy
        // delivered to another wallet would otherwise be taxed 98% in the launch block, so exempt that wallet too.
        (token, curve) = factory.launchTokenFor{value: fee}(params, launchConfigId, pairToken, _withRecipient(snipeTaxExemptions, recipient), msg.sender);
        if (quoteIn == 0) {
            _refundNative(nativeBaseline);
            return (token, curve, 0);
        }

        if (pairToken == address(0)) {
            tokensOut = IBondingCurve(curve).buy{value: quoteIn}(quoteIn, minTokensOut, recipient);
            _refundNative(nativeBaseline);
        } else {
            uint256 tokenBaseline = IERC20(pairToken).balanceOf(address(this));
            TransferHelper.safeTransferFrom(pairToken, msg.sender, address(this), quoteIn);
            TransferHelper.safeApprove(pairToken, curve, quoteIn);
            tokensOut = IBondingCurve(curve).buy(quoteIn, minTokensOut, recipient);
            uint256 bal = IERC20(pairToken).balanceOf(address(this));
            if (bal > tokenBaseline) TransferHelper.safeTransfer(pairToken, msg.sender, bal - tokenBaseline);
            _refundNative(nativeBaseline);
        }
    }

    /// @dev The caller's exemption list plus the dev-buy recipient (when it is not the deployer itself).
    function _withRecipient(address[] calldata list, address recipient) private view returns (address[] memory out) {
        if (recipient == msg.sender || recipient == address(0)) return list;
        out = new address[](list.length + 1);
        for (uint256 i = 0; i < list.length; i++) {
            out[i] = list[i];
        }
        out[list.length] = recipient;
    }

    /// @dev Return any native above `baseline` (this call's unused fee/quote) to the caller; never the baseline.
    function _refundNative(uint256 baseline) private {
        uint256 bal = address(this).balance;
        if (bal > baseline) TransferHelper.sendNative(msg.sender, bal - baseline);
    }
}
