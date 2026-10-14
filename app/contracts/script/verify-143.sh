#!/usr/bin/env bash
# Sourcify-verify every launchpad contract recorded in deployments/143.json (Monad mainnet).
# The deployed bytecode is produced under the `v4core` compilation profile (see foundry.toml), so that profile
# must be passed or Sourcify reports a misleading bytecode mismatch. Run from contracts/ after `forge script … --broadcast`.
set -euo pipefail
cd "$(dirname "$0")/.."
J=${RECORD:-deployments/143.json} # RECORD=deployments/pending-143.json right after a broadcast (script/README.md)
addr() { python3 -c "import json,sys; print(json.load(open('$J'))['$1'])"; }
V="--chain 143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/ --compilation-profile v4core --watch"
verify() { echo "== $2 @ $1"; ~/.foundry/bin/forge verify-contract "$1" "$2" $V || echo "!! $2 failed — retry with --compilation-profile default"; }
verify "$(addr factory)"            src/LaunchpadFactory.sol:LaunchpadFactory
verify "$(addr escrow)"             src/FeeEscrow.sol:FeeEscrow
verify "$(addr holderFeeSharing)"   src/HolderFeeSharing.sol:HolderFeeSharing
verify "$(addr locker)"             src/LaunchLocker.sol:LaunchLocker
verify "$(addr hook)"               src/MemeHook.sol:MemeHook
verify "$(addr graduationExecutor)" src/GraduationExecutor.sol:GraduationExecutor
verify "$(addr mondayExecutor)"     src/MondayGraduationExecutor.sol:MondayGraduationExecutor
verify "$(addr launchAndBuyRouter)" src/LaunchAndBuyRouter.sol:LaunchAndBuyRouter
verify "$(addr launchDeployer)"     src/LaunchDeployer.sol:LaunchDeployer
FV=$(addr feeVault); [ "$FV" != "0x0000000000000000000000000000000000000000" ] && verify "$FV" src/MondayFeeVault.sol:MondayFeeVault
# CurveDeployer is created by LaunchDeployer's constructor: read its address and verify it too.
CD=$(~/.foundry/bin/cast call "$(addr launchDeployer)" "curveDeployer()(address)" --rpc-url https://rpc.monad.xyz)
verify "$CD" src/LaunchDeployer.sol:CurveDeployer
echo "done"
