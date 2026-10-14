// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

/// @notice Ops upgrade to enable post-graduation LP fee collection and separate the money roles, WITHOUT a full
///         redeploy. It deploys a collectable `MondayFeeVault` plus a fresh `MondayGraduationExecutor` that mints
///         graduated liquidity to the vault, then points the launchpad factory's (swappable) `graduationExecutor`
///         at the new one. Future graduations then route their 1% pool swap fees to the FEES address; the LP
///         principal stays locked (the vault only ever calls burn(…,0)+collect). Already-graduated pools are
///         unaffected — their fees remain locked in the old locker and are not recoverable.
///
///         Three distinct roles:
///           - OWNER    = governance (vault owner; the factory owner is unchanged unless you transfer it separately).
///           - TREASURY = launch fees + the protocol's share of bonding-curve trading fees (via setFeePolicy).
///           - FEES     = post-graduation LP swap fees (the vault's lpFeeRecipient).
///
///         Must be broadcast from the factory OWNER key (setModules/setFeePolicy are onlyOwner):
///           FEES=0x.. TREASURY=0x.. OWNER=0x.. \
///           forge script script/DeployFeeVault.s.sol:DeployFeeVault --rpc-url monad --broadcast --ledger
///         (or --account <keystore name>; never a plaintext --private-key)
///         Dry run first (no --broadcast) to print the addresses and confirm the module re-pass.
///
///         RETIRED (security audit 2026-09-26): written for the pre-2026-09-17 factory, whose Monday executor sat in the
///         `graduationExecutor` slot. The current LaunchpadFactory keeps it in its own slot (`setMondayExecutor`) and
///         freezes both after the first launch, so on a live factory the old body reverted ModulesLocked, and on a fresh
///         one it would have put a Monday executor into the v4 slot and broken every v4 graduation. Deploy.s.sol deploys
///         the MondayFeeVault and sets the Monday executor for new stacks; the old body is in git history.
contract DeployFeeVault is Script {
    function run() external pure {
        revert("DeployFeeVault is retired: Deploy.s.sol deploys the MondayFeeVault and calls setMondayExecutor");
    }
}
