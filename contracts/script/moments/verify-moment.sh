#!/usr/bin/env bash
# Sourcify-verify the per-Moment coin + NFT of a published Moment (both are CREATE2-deployed by the factory at
# publish, so each instance needs its own submission). Usage: ./script/moments/verify-moment.sh <momentId>
set -euo pipefail
cd "$(dirname "$0")/../.."
ID="${1:?momentId}"
J=deployments/moments-143.json
RPC=https://rpc.monad.xyz
CAST=~/.foundry/bin/cast
FACTORY=$(python3 -c "import json; print(json.load(open('$J'))['factory'])")
VESTING=$(python3 -c "import json; print(json.load(open('$J'))['vesting'])")
GRAD=$(python3 -c "import json; print(json.load(open('$J'))['graduation'])")
COLLECT=$(python3 -c "import json; print(json.load(open('$J'))['collect'])")
# Moment struct: (creator, platform, treasury, coin, nft, price, threshold, rateNum, rateDen, creatorBps, platformBps, reserveBps, creatorAllocBps, expiryCreatorBps, royaltyBps, publishedAt, deadline)
read -r CREATOR _ _ COIN NFT _ _ _ _ _ _ _ _ _ ROYALTY _ _ < <($CAST call "$FACTORY" "getMoment(uint256)((address,address,address,address,address,uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint64,uint64))" "$ID" --rpc-url $RPC | tr -d '(),' )
NAME=$($CAST call "$COIN" "name()(string)" --rpc-url $RPC | sed 's/^"//; s/"$//')
SYMBOL=$($CAST call "$COIN" "symbol()(string)" --rpc-url $RPC | sed 's/^"//; s/"$//')
# Provenance struct: (mediaURI, mediaHash, place, date, animationURI)
PROV=$($CAST call "$NFT" "provenance()((string,bytes32,string,uint64,string))" --rpc-url $RPC)
MEDIA=$(python3 -c "import re,sys; s=sys.argv[1]; print(re.findall(r'\"(.*?)\"', s)[0])" "$PROV")
PLACE=$(python3 -c "import re,sys; s=sys.argv[1]; print(re.findall(r'\"(.*?)\"', s)[1])" "$PROV")
HASH=$(python3 -c "import re,sys; s=sys.argv[1]; print(re.findall(r'0x[0-9a-fA-F]{64}', s)[0])" "$PROV")
ANIM=$(python3 -c "import re,sys; s=sys.argv[1]; f=re.findall(r'\"(.*?)\"', s); print(f[2] if len(f)>2 else '')" "$PROV")
DATE=$(python3 -c "import re,sys; s=sys.argv[1]; print(re.findall(r'(\d+),', s)[-1])" "$PROV")
V="--chain 143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/ --watch"
verify() {
  echo "== $2 @ $1"
  ~/.foundry/bin/forge verify-contract "$1" "$2" $V --compilation-profile v4core --constructor-args "$3" \
    || ~/.foundry/bin/forge verify-contract "$1" "$2" $V --constructor-args "$3" \
    || echo "!! $2 failed under both profiles"
}
COIN_ARGS=$($CAST abi-encode "c(uint256,string,string,address,address)" "$ID" "$NAME" "$SYMBOL" "$VESTING" "$GRAD")
NFT_ARGS=$($CAST abi-encode "c(uint256,string,string,address,address,address,uint16,(string,bytes32,string,uint64,string))" "$ID" "$NAME" "$SYMBOL" "$CREATOR" "$COLLECT" "$GRAD" "$ROYALTY" "($MEDIA,$HASH,$PLACE,$DATE,$ANIM)")
verify "$COIN" src/moments/MomentCoin.sol:MomentCoin "$COIN_ARGS"
verify "$NFT"  src/moments/MomentNFT.sol:MomentNFT "$NFT_ARGS"
echo "done"
