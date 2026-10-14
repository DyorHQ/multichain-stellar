// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IMondayV3Pool} from "./interfaces/IMondayV3.sol";

/// @notice Holds graduated launch liquidity so the principal stays locked forever, while letting the accrued swap
///         fees be harvested to a dedicated recipient. The graduation executor mints the full-range position to this
///         vault (making the vault the position owner), so only the vault can ever poke or collect it.
///
///         `collectFees` calls `burn(lower, upper, 0)` — which removes ZERO liquidity and only moves earned fees into
///         the position's `tokensOwed` — then `collect`s those owed tokens to `lpFeeRecipient`. There is no code path
///         that passes a non-zero amount to `burn`, transfers the position, or touches the underlying liquidity, so
///         the LP principal is unwithdrawable by construction; only fees can ever leave.
///
///         Roles are deliberately separate: `owner` is governance (config only, never receives funds) and
///         `lpFeeRecipient` is the fees address — both are distinct from the launchpad's protocol treasury.
contract MondayFeeVault {
    /// Governance. May change the fee recipient and hand off ownership. Holds and receives no funds.
    address public owner;
    address public pendingOwner;
    /// Where harvested LP swap fees are sent. Distinct from `owner` and from the launchpad protocol treasury.
    address public lpFeeRecipient;

    event FeesCollected(address indexed pool, address indexed recipient, uint128 amount0, uint128 amount1);
    event LpFeeRecipientSet(address indexed recipient);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner, address _lpFeeRecipient) {
        if (_owner == address(0) || _lpFeeRecipient == address(0)) revert ZeroAddress();
        owner = _owner;
        lpFeeRecipient = _lpFeeRecipient;
    }

    /// @notice Harvest the accrued swap fees of this vault's full-range position in `pool` to `lpFeeRecipient`.
    ///         Permissionless: the destination is fixed, so anyone (e.g. a keeper) may trigger a harvest without
    ///         being able to redirect the funds. Removes no liquidity.
    function collectFees(address pool) external returns (uint128 amount0, uint128 amount1) {
        int24 spacing = IMondayV3Pool(pool).tickSpacing();
        int24 lower = TickMath.minUsableTick(spacing);
        int24 upper = TickMath.maxUsableTick(spacing);
        // burn(…, 0) realizes fees into tokensOwed and provably removes zero liquidity — principal is untouched.
        IMondayV3Pool(pool).burn(lower, upper, 0);
        (amount0, amount1) =
            IMondayV3Pool(pool).collect(lpFeeRecipient, lower, upper, type(uint128).max, type(uint128).max);
        emit FeesCollected(pool, lpFeeRecipient, amount0, amount1);
    }

    /// @notice Point future fee harvests at a new address. Governance only.
    function setLpFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        lpFeeRecipient = recipient;
        emit LpFeeRecipientSet(recipient);
    }

    /// @notice Two-step ownership handoff, so a mistyped address cannot brick governance.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }
}
