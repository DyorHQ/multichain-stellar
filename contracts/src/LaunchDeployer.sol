// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types} from "./interfaces/ILaunchpad.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {BondingCurve} from "./BondingCurve.sol";

/// @notice Holds the curve's creation code. Created by the LaunchDeployer, which is its only caller.
contract CurveDeployer {
    address public immutable launchDeployer;

    error NotLaunchDeployer();

    constructor() {
        launchDeployer = msg.sender;
    }

    function deploy(bytes32 salt, address factory, Types.CurveInit calldata init) external returns (address) {
        if (msg.sender != launchDeployer) revert NotLaunchDeployer();
        return address(new BondingCurve{salt: salt}(factory, init));
    }
}

/// @notice Holds the token's creation code (and owns the curve deployer) so the factory stays under the EIP-170 size
///         limit. Only the factory may deploy. Token addresses are deterministic (CREATE2 from this contract) so the
///         factory can register a token with the fee-sharing module before the token exists.
contract LaunchDeployer {
    address public immutable factory;
    CurveDeployer public immutable curveDeployer;

    error NotFactory();

    constructor(address _factory) {
        factory = _factory;
        curveDeployer = new CurveDeployer();
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    function predictToken(bytes32 salt, Types.TokenInit calldata init) external view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(LaunchToken).creationCode, abi.encode(factory, init)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function deployToken(bytes32 salt, Types.TokenInit calldata init) external onlyFactory returns (address) {
        return address(new LaunchToken{salt: salt}(factory, init));
    }

    function deployCurve(bytes32 salt, Types.CurveInit calldata init) external onlyFactory returns (address) {
        return curveDeployer.deploy(salt, factory, init);
    }
}
