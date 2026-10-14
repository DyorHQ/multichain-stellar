// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Shared safety rails for the scripts that sign on Monad mainnet (chain 143). Security audit 2026-09-26:
///         - SEC-1: sign with a hardware wallet (`--ledger`) or an encrypted Foundry keystore (`--account`), never a
///           raw private key. A script cannot see how forge signs, so it refuses the tell-tale environment variables
///           (script/mainnet.sh also refuses --private-key/--mnemonic/--interactive on the command line).
///           `ALLOW_RAW_KEY_143=1` overrides, on purpose only.
///         - RO-7: a run never overwrites a live deployment record. See `_recordPath`.
abstract contract MainnetGuard is Script {
    uint256 internal constant MONAD_MAINNET = 143;

    function _refuseRawKeyOnMainnet() internal view {
        if (block.chainid != MONAD_MAINNET || vm.envOr("ALLOW_RAW_KEY_143", false)) return;
        string[5] memory names = ["PRIVATE_KEY", "TREASURY_KEY", "OWNER_KEY", "DEPLOYER_PRIVATE_KEY", "ETH_PRIVATE_KEY"];
        for (uint256 i = 0; i < names.length; i++) {
            // Only the length is read; the value is never logged.
            if (bytes(vm.envOr(names[i], string(""))).length != 0) {
                revert(string.concat(names[i], " is set: on Monad mainnet sign with --ledger or --account <keystore>, never a raw key. Unset it (ALLOW_RAW_KEY_143=1 overrides)."));
            }
        }
    }

    /// @dev Where a deploy script writes its record `deployments/<name>`:
    ///      - dry run (no --broadcast):            deployments/dryrun-<name>   (never read by the apps or keepers)
    ///      - broadcast on Monad mainnet (or a fork of it, which also reports 143): deployments/pending-<name>, promoted
    ///        to <name> by hand only after the addresses are verified on mainnet (script/README.md)
    ///      - broadcast anywhere else:             deployments/<name>
    ///      Before this, every run (dry runs and fork rehearsals included) rewrote deployments/143.json, and the keepers
    ///      and `npm run sync:deployment` trust that file.
    function _recordPath(string memory name) internal view returns (string memory) {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return string.concat("deployments/dryrun-", name);
        if (block.chainid == MONAD_MAINNET) return string.concat("deployments/pending-", name);
        return string.concat("deployments/", name);
    }

    /// @dev An address that must be given explicitly on Monad mainnet (no default); elsewhere `fallback_` applies.
    function _addr(string memory name, address fallback_) internal view returns (address a) {
        if (block.chainid == MONAD_MAINNET) {
            a = vm.envAddress(name);
            require(a != address(0), string.concat(name, " must be set on Monad mainnet"));
        } else {
            a = vm.envOr(name, fallback_);
        }
    }

    /// @dev A number that must be given explicitly on Monad mainnet (no default); elsewhere `fallback_` applies.
    function _uint(string memory name, uint256 fallback_) internal view returns (uint256) {
        return block.chainid == MONAD_MAINNET ? vm.envUint(name) : vm.envOr(name, fallback_);
    }
}
