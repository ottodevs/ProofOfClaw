.PHONY: all build-agent build-zkvm build-contracts test clean

all: build-agent build-contracts

build-agent:
	cd agent && cargo build --release

build-zkvm:
	cd zkvm && cargo build --release

build-contracts:
	cd contracts && forge build

test-agent:
	cd agent && cargo test

test-contracts:
	cd contracts && forge test

deploy-contracts:
	cd contracts && forge script script/Deploy.s.sol --rpc-url $(RPC_URL) --broadcast

deploy-0g-testnet:
	cd contracts && forge script script/Deploy0G.s.sol \
		--rpc-url https://evmrpc-testnet.0g.ai \
		--broadcast --evm-version cancun

deploy-0g-mainnet:
	cd contracts && forge script script/Deploy0G.s.sol \
		--rpc-url https://evmrpc.0g.ai \
		--broadcast --evm-version cancun

deploy-sepolia:
	cd contracts && forge script script/Deploy.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast --verify

run-agent:
	cd agent && cargo run

clean:
	cd agent && cargo clean
	cd zkvm && cargo clean
	cd contracts && forge clean

check:
	cd agent && cargo check
	cd contracts && forge build
