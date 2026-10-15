#!/usr/bin/env bash
# Deploys Weir v2 on Robinhood Chain (4663) against the EXISTING WEIR token. Every value is pinned below.
#   Dry run (no key, nothing sent):   DRY_RUN=1 DEPLOYER=0x<any address with ETH> ./script/deploy-weir-v2.sh
#   Real deploy (key stays in your shell, is never printed):
#     set -a; source ~/.imd-weir-payer.env; set +a; ./script/deploy-weir-v2.sh
set -euo pipefail
RPC="${RPC:-https://rpc.mainnet.chain.robinhood.com}"
WEIR=0x58b82fa656ecf47a0dca5be6bad06b92e22f7dbe
IMD=0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127
INTAKE=0xa43e6f75ee006411f79ac1c84120606c2330de82
SIGNER=0x5598aa9146215bc13eb26f2c692ad1461fd32982
TIMEOUT=604800
MIN_HOLD=10000000000000000000000
cd "$(dirname "$0")/.."

[ "$(cast chain-id --rpc-url "$RPC")" = "4663" ] || { echo "RPC is not Robinhood Chain (4663)"; exit 1; }
for a in "$WEIR" "$IMD" "$INTAKE"; do
  [ "$(cast code "$a" --rpc-url "$RPC" | wc -c)" -gt 4 ] || { echo "no contract code at $a"; exit 1; }
done
[ "$(cast call "$WEIR" 'decimals()(uint8)' --rpc-url "$RPC")" = "18" ] || { echo "WEIR token is not 18 decimals"; exit 1; }

if [ "${DRY_RUN:-0}" = "1" ]; then
  DEPLOYER="${DEPLOYER:?set DEPLOYER for a dry run}"
else
  : "${IMD_PAYER_PRIVATE_KEY:?load the payer env first (set -a; source ~/.imd-weir-payer.env; set +a)}"
  DEPLOYER="$(cast wallet address --private-key "$IMD_PAYER_PRIVATE_KEY")"
fi
BAL="$(cast balance "$DEPLOYER" --rpc-url "$RPC")"
echo "deployer $DEPLOYER holds $BAL wei of ETH on Robinhood Chain"

forge build --force >/dev/null
ARGS="$(cast abi-encode 'constructor(address,address,address,address,uint40,uint256)' "$WEIR" "$IMD" "$INTAKE" "$SIGNER" "$TIMEOUT" "$MIN_HOLD")"
BYTECODE="$(python3 -c "import json;print(json.load(open('out/Weir.sol/Weir.json'))['bytecode']['object'])")"
GAS="$(cast estimate --rpc-url "$RPC" --from "$DEPLOYER" --create "${BYTECODE}${ARGS#0x}")"
PRICE="$(cast gas-price --rpc-url "$RPC")"
COST=$(( GAS * PRICE ))
echo "estimated gas $GAS, estimated cost $COST wei"
[ "$BAL" -gt $(( COST * 3 )) ] || { echo "not enough ETH for the deployment (need about 3x the estimate)"; exit 1; }
[ "${DRY_RUN:-0}" = "1" ] && { echo "dry run ok; nothing was sent"; exit 0; }

OUT="$(forge create src/Weir.sol:Weir --rpc-url "$RPC" --private-key "$IMD_PAYER_PRIVATE_KEY" --broadcast --json \
  --constructor-args "$WEIR" "$IMD" "$INTAKE" "$SIGNER" "$TIMEOUT" "$MIN_HOLD")"
ADDR="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['deployedTo'])")"
TX="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")"
echo "deployed Weir v2 at $ADDR (tx $TX)"

chk() { [ "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" ] || { echo "MISMATCH in $3: $1 vs $2"; exit 1; }; }
chk "$(cast call "$ADDR" 'weir()(address)' --rpc-url "$RPC")" "$WEIR" weir
chk "$(cast call "$ADDR" 'imd()(address)' --rpc-url "$RPC")" "$IMD" imd
chk "$(cast call "$ADDR" 'intake()(address)' --rpc-url "$RPC")" "$INTAKE" intake
chk "$(cast call "$ADDR" 'oracleSigner()(address)' --rpc-url "$RPC")" "$SIGNER" oracleSigner
[ "$(cast call "$ADDR" 'disputeTimeout()(uint40)' --rpc-url "$RPC" | awk '{print $1}')" = "$TIMEOUT" ] || { echo "MISMATCH disputeTimeout"; exit 1; }
[ "$(cast call "$ADDR" 'minHold()(uint256)' --rpc-url "$RPC" | awk '{print $1}')" = "$MIN_HOLD" ] || { echo "MISMATCH minHold"; exit 1; }
echo "constructor values verified on chain. Weir v2 = $ADDR"
