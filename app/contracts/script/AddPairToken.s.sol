// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MainnetGuard} from "./lib/MainnetGuard.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Approves an ERC-20 as a pairing asset (e.g. a tokenized stock or a stablecoin) with its own economics.
///         FACTORY=0x... PAIR_TOKEN=0x... PHANTOM_QUOTE=<in token units> GRADUATION_THRESHOLD=<in token units>
///           script/mainnet.sh forge script script/AddPairToken.s.sol:AddPairToken --rpc-url monad --broadcast --ledger
///         (or --account <keystore>; a raw private key is refused on Monad mainnet: security audit 2026-09-26, SEC-1)
contract AddPairToken is MainnetGuard {
    function run() external {
        _refuseRawKeyOnMainnet();
        LaunchpadFactory factory = LaunchpadFactory(vm.envAddress("FACTORY"));
        address pairToken = vm.envAddress("PAIR_TOKEN");
        uint256 phantomQuote = vm.envUint("PHANTOM_QUOTE");
        uint256 graduationThreshold = vm.envUint("GRADUATION_THRESHOLD");
        uint8 decimals = IERC20(pairToken).decimals();
        vm.startBroadcast();
        factory.setPairEconomics(pairToken, phantomQuote, graduationThreshold, decimals, true);
        vm.stopBroadcast();
    }
}
