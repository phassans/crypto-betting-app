-include .env

.PHONY: all test clean deploy-anvil

all: clean remove install update build

# Clean the repo
clean  :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules

install :; npm install @chainlink/contracts && npm install @openzeppelin/contracts && npm install forge-std && npm install dapphub/ds-test

# Update Dependencies
update:; forge update

build:; forge build

test :; forge test 

slither :; slither ./src 

# solhint should be installed globally
lint :; solhint src/**/*.sol && solhint src/*.sol

# use the "@" to hide the command from your shell 
deploy-arb-sepolia :; @forge script script/${contract}.s.sol:Deploy${contract} --rpc-url ${ARB_SEPOLIA_RPC_URL}  --private-key ${PRIVATE_KEY} --broadcast --verify --etherscan-api-key ${ETHERSCAN_API_KEY}  -vvvv

-include ${FCT_PLUGIN_PATH}/makefile-external