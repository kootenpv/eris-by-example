
function wait_one_block {
	HEIGHT_START=`ethinfo status | jq .chain.block_number`
	HEIGHT=$HEIGHT_START
	while [[ "$HEIGHT" == "$HEIGHT_START" ]]; do
		sleep 1
		HEIGHT=`ethinfo status | jq .chain.block_number`
	done
}

###############
## Install   ##
###############

# install the eth client tools
# go get github.com/eris-ltd/eth-client/...

# install the eris-abi tool
# go get github.com/eris-ltd/eris-abi/cmd/eris-abi

# install the eris-keys daemon
# go get github.com/eris-ltd/eris-keys

# install geth
# go get github.com/ethereum/go-ethereum/cmd/geth

###############
## Setup     ##
###############

# start eris-keys server (for key creation and tx signing)
eris-keys server &

# create an address
ADDR=`eris-keys gen --no-pass --type=secp256k1,sha3`
echo "ADDRESS: $ADDR"

# create data directory for the chain and genesis file
ETH_DIR=~/.myethereum
mkdir $ETH_DIR
ethgen $ADDR > $ETH_DIR/genesis.json

# start geth on a private local network
geth --datadir $ETH_DIR --rpc --mine --genesis $ETH_DIR/genesis.json --maxpeers 0 --etherbase $ADDR --verbosity 7 &> $ETH_DIR/log &

# wait for boot
sleep 3

# get the chain's status
ethinfo status


######################
## Compile Contract ##
######################

# simple solidity contract
read -r -d '' CODE << EOM
contract MyContract {
  int sum;
  function add(int a, int b) returns (int x) {
        sum = a + b;
	x = sum;
  }
}
EOM

# the solidity code needs to be in base64 for the compile server
CODE64=`echo $CODE | base64`

# json data for the curl request to the compile server
read -r -d '' JSON_DATA << EOM
{
	"name":"mycontract",
	"language":"sol",
	"script":"$CODE64"
}
EOM

# location of compiler
URL="https://compilers.eris.industries:8091/compile"

# compile that baby!
RESULT=`curl --silent -X POST -d "${JSON_DATA}" $URL --header "Content-Type:application/json"`

# the compile server returns the bytecode (in base64) and the abi (json)
BYTECODE=`echo $RESULT | jq .bytecode`
ABI=`echo $RESULT | jq .abi`

# trim quotes
BYTECODE="${BYTECODE%\"}"
BYTECODE="${BYTECODE#\"}"

# convert bytecode to hex
# NOTE: this works on mac, but base64 is slightly different on linux (need -d rather than -D)
BYTECODE=`echo $BYTECODE | base64 -D | hexdump -ve '1/1 "%.2X"'`

# unescape quotes in the json and write the ABI to file
ABI=`eval echo $ABI` 
ABI=`echo $ABI | jq .`
echo $ABI > add.abi

echo "BYTE CODE:"
echo $BYTECODE
echo ""

echo "ABI:"
echo $ABI
echo ""


###############
## Deploy    ##
###############

RESULT=`ethtx create --addr=$ADDR --code=$BYTECODE --amt=0 --gas=500000 --price=100000000000 --sign --broadcast`

CONTRACT_ADDR=`echo $RESULT | grep "Contract Address:" | awk '{print $5}'`

echo "New contract address:"
echo $CONTRACT_ADDR

# wait for a block
# (we wait two just incase)
wait_one_block
wait_one_block


# check the code
CODE=`ethinfo account $CONTRACT_ADDR | jq .code`

# strip quotes
CODE="${CODE%\"}"
CODE="${CODE#\"}"

echo "ACCOUNT CODE:"
echo $CODE


if [[ "$CODE" == "0x" ]]; then
	echo "FAILED TO DEPLOY!"
	exit 1
fi

###############
## Call	     ##
###############


FUNCTION="add"
ARG1="25"
ARG2="37"

# pack abi data
DATA=`eris-abi pack --input file add.abi $FUNCTION $ARG1 $ARG2`

echo "DATA FOR CONTRACT CALL:"
echo $DATA
echo ""

ethtx call --addr=$ADDR --to=$CONTRACT_ADDR --data=$DATA --amt=0 --gas=500000 --price=100000000000 --sign --broadcast

wait_one_block
wait_one_block

echo "RESULTING STORAGE FROM ADDING $ARG1 and $ARG2"
ethinfo storage $CONTRACT_ADDR
