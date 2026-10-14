// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types, IHolderFeeSharing} from "./interfaces/ILaunchpad.sol";

/// @notice The memecoin: a fixed-supply ERC-20 minted entirely to the launchpad at creation, carrying the
///         creator-supplied metadata on-chain. When holder fee sharing is on, every balance change is reported
///         to the sharing contract before it happens so rewards stay pro-rata.
contract LaunchToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable factory;
    address public immutable deployer;
    address public immutable holderFeeSharing; // address(0) when fees go to the creator wallet

    string private _logo;
    string private _description;
    Types.Socials private _socials;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(address _factory, Types.TokenInit memory init) {
        name = init.name;
        symbol = init.symbol;
        _logo = init.logo;
        _description = init.description;
        _socials = init.socials;
        factory = _factory;
        deployer = init.deployer;
        holderFeeSharing = init.holderFeeSharing;
        _mint(init.initialHolder, init.supply);
    }

    function getTokenInfo()
        external
        view
        returns (address tokenDeployer, string memory tokenLogo, string memory tokenDescription, Types.Socials memory tokenSocials)
    {
        return (deployer, _logo, _description, _socials);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        // Self-transfers are net-zero; skip the fee-sharing hook (settling both sides for one account would
        // double-credit rewards) but still emit Transfer for ERC-20 compliance.
        if (from != to) {
            if (holderFeeSharing != address(0)) IHolderFeeSharing(holderFeeSharing).beforeTransfer(from, to, amount);
            unchecked {
                balanceOf[from] -= amount;
                balanceOf[to] += amount;
            }
        }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        if (holderFeeSharing != address(0)) IHolderFeeSharing(holderFeeSharing).beforeTransfer(address(0), to, amount);
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }
}
