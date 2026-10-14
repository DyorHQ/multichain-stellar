#!/usr/bin/env bash
# Sourcify-verify every Moments contract recorded in deployments/moments-143.json (Monad mainnet).
# Moments contracts inline Uniswap v4-core libraries, so — like the Launchpad — the deployed bytecode is normally
# produced under the `v4core` compilation profile (foundry.toml). Try that first, fall back to the default profile.
# Run from contracts/ after `forge script script/moments/Deploy.s.sol:DeployMoments … --broadcast`.
set -euo pipefail
cd "$(dirname "$0")/../.."
J=${RECORD:-deployments/moments-143.json} # RECORD=deployments/pending-moments-143.json right after a broadcast
addr() { python3 -c "import json; print(json.load(open('$J'))['$1'])"; }
V="--chain 143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/ --watch"
verify() {
  echo "== $2 @ $1"
  ~/.foundry/bin/forge verify-contract "$1" "$2" $V --compilation-profile v4core \
    || ~/.foundry/bin/forge verify-contract "$1" "$2" $V \
    || echo "!! $2 failed under both profiles"
}
verify "$(addr factory)"    src/moments/MomentsFactory.sol:MomentsFactory
verify "$(addr vesting)"    src/moments/MomentVesting.sol:MomentVesting
verify "$(addr collect)"    src/moments/MomentCollect.sol:MomentCollect
verify "$(addr locker)"     src/moments/MomentLocker.sol:MomentLocker
verify "$(addr graduation)" src/moments/MomentGraduation.sol:MomentGraduation
verify "$(addr buyback)"    src/moments/MomentBuyback.sol:MomentBuyback
verify "$(addr hook)"       src/moments/MomentFeeHook.sol:MomentFeeHook
# Per-Moment coin + NFT are CREATE2-deployed by the factory at publish; verify them per Moment:
#   forge verify-contract <coin> src/moments/MomentCoin.sol:MomentCoin $V --constructor-args $(cast abi-encode "c(uint256,string,string,address,address)" <id> "<name>" "<symbol>" <vesting> <graduation>)
echo "done"
