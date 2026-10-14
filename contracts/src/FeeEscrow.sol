// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Fee router with automatic push-then-escrow delivery. Every fee credited here is FIRST sent straight to
///         its recipient; only if that direct send fails — the recipient reverts, can't receive, or exceeds the
///         bounded gas — is a claimable balance booked instead. So in the normal case protocol/creator fees land in
///         their wallets with no claim step, while a hostile or unusual recipient can never brick the paying
///         transaction (curve trade, launch, pool sweep) or lose the funds: they simply become claimable.
///
///         Holder-shared rewards do NOT come through here — they are split pro-rata among all holders by
///         HolderFeeSharing, which is inherently claim-based (there is no single address to push to).
contract FeeEscrow {
    /// @dev Gas forwarded on a direct push. Comfortably covers an EOA or a typical smart-contract wallet (e.g. a
    ///      Safe) receiving funds, but bounded so a griefing recipient cannot burn unlimited gas on the payer's tx.
    ///      A recipient that needs more simply falls back to a claimable balance.
    uint256 private constant PUSH_GAS = 60_000;

    mapping(address => uint256) public balanceOf; // native, claimable (only set when a direct push failed)
    mapping(address => mapping(address => uint256)) public balanceOfToken; // recipient => token => claimable

    /// Booked as claimable because the direct send failed.
    event Credited(address indexed recipient, uint256 amount);
    event CreditedToken(address indexed recipient, address indexed token, uint256 amount);
    /// Sent straight to the recipient (no claim needed).
    event Paid(address indexed recipient, uint256 amount);
    event PaidToken(address indexed recipient, address indexed token, uint256 amount);
    /// Claimed a previously-booked fallback balance.
    event Claimed(address indexed recipient, uint256 amount);
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);

    error NothingToClaim();
    error Reentrancy();

    uint256 private _lock = 1;

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @notice Credit native fees to `recipient`: push directly, else book a claimable balance. Never reverts on a
    ///         bad recipient, so it cannot brick the caller (a curve trade, launch, or pool sweep).
    function credit(address recipient) external payable nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount, gas: PUSH_GAS}("");
        if (ok) {
            emit Paid(recipient, amount);
        } else {
            balanceOf[recipient] += amount;
            emit Credited(recipient, amount);
        }
    }

    /// @notice Credit ERC-20 fees to `recipient`. Pulls `amount` from the caller (so a credit is always backed by
    ///         value received), then pushes it on to `recipient`, falling back to a claimable balance on failure.
    function creditToken(address recipient, address token, uint256 amount) external nonReentrant {
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        if (amount == 0) return;
        if (_tryPushToken(token, recipient, amount)) {
            emit PaidToken(recipient, token, amount);
        } else {
            balanceOfToken[recipient][token] += amount;
            emit CreditedToken(recipient, token, amount);
        }
    }

    function claim() external nonReentrant {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balanceOf[msg.sender] = 0;
        TransferHelper.sendNative(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function claimToken(address token) external nonReentrant {
        uint256 amount = balanceOfToken[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        balanceOfToken[msg.sender][token] = 0;
        TransferHelper.safeTransfer(token, msg.sender, amount);
        emit ClaimedToken(msg.sender, token, amount);
    }

    /// @dev Best-effort ERC-20 transfer with bounded gas: swallows reverts, missing return data, and `false`
    ///      returns, reporting only a definitive success. Non-reverting so the caller can fall back to escrow.
    function _tryPushToken(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call{gas: PUSH_GAS}(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        // Treat only a clean success as success: no return data, or a well-formed 32-byte `true`. Malformed
        // (short) or `false` returns fall back to a claimable balance instead of reverting the payer's tx. The
        // gas cap also bounds how much return data the token can produce, so this never becomes a return bomb.
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }
}
