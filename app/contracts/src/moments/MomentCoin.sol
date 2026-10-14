// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {MomentTypes} from "./interfaces/IMoments.sol";

/// @notice The per-Moment coin. Fixed 100M supply (18 dp), capped at the ERC-20 level. The ONLY minters are the
///         vesting contract (claims) and the graduation executor (the pool seed), both fixed at construction.
///         No owner, no owner mint, no transfer tax, no pause. Nothing is minted to anyone before graduation.
contract MomentCoin is ERC20Capped {
    uint256 public constant SUPPLY = MomentTypes.SUPPLY;

    uint256 public immutable momentId;
    address public immutable vesting;
    address public immutable graduation;

    error NotMinter();
    error ZeroAddress();

    constructor(uint256 _momentId, string memory name_, string memory symbol_, address _vesting, address _graduation)
        ERC20(name_, symbol_)
        ERC20Capped(MomentTypes.SUPPLY)
    {
        if (_vesting == address(0) || _graduation == address(0)) revert ZeroAddress();
        momentId = _momentId;
        vesting = _vesting;
        graduation = _graduation;
    }

    /// @notice Mints vested coins (vesting) or the pool seed (graduation). The cap makes `totalSupply <= SUPPLY`
    ///         a hard invariant enforced on every mint.
    function mint(address to, uint256 amount) external {
        if (msg.sender != vesting && msg.sender != graduation) revert NotMinter();
        _mint(to, amount);
    }
}
