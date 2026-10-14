// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "../../../src/moments/interfaces/IMoments.sol";

/// Permit2 SignatureTransfer stand-in: enforces requestedAmount <= permitted.amount and pulls from `owner`
/// (who approved this mock). Signature checking is exercised against the real Permit2 in the fork test.
contract MockPermit2 is IPermit2 {
    uint256 public lastRequested;

    function permitTransferFrom(PermitTransferFrom memory permit, SignatureTransferDetails calldata d, address owner, bytes calldata) external {
        require(d.requestedAmount <= permit.permitted.amount, "MockPermit2: over permitted");
        lastRequested = d.requestedAmount;
        require(IERC20(permit.permitted.token).transferFrom(owner, d.to, d.requestedAmount), "MockPermit2: transfer");
    }
}
