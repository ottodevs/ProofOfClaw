// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ProofOfClawVerifier.sol";
import "../src/ProofOfClawINFT.sol";
import "../src/RiscZeroMockVerifier.sol";

/// @title Deploy0G -- Deploy Proof of Claw contracts to 0G Chain
/// @notice Deploys ProofOfClawVerifier and ProofOfClawINFT to 0G Testnet or Mainnet.
///         If RISC_ZERO_VERIFIER_ADDRESS is not set, deploys a mock verifier (testnet only).
///
/// Usage (testnet):
///   forge script script/Deploy0G.s.sol --rpc-url https://evmrpc-testnet.0g.ai \
///     --broadcast --evm-version cancun
///
/// Usage (mainnet -- requires real verifier):
///   forge script script/Deploy0G.s.sol --rpc-url https://evmrpc.0g.ai \
///     --broadcast --evm-version cancun
///
/// Required env vars:
///   PRIVATE_KEY                 -- Deployer wallet (must have 0G tokens for gas)
///
/// Optional env vars:
///   RISC_ZERO_VERIFIER_ADDRESS  -- RISC Zero verifier address on 0G (deploys mock if unset)
///   RISC_ZERO_IMAGE_ID          -- RISC Zero guest image ID (uses placeholder if unset)
contract Deploy0GScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Resolve or deploy RISC Zero verifier
        address verifierAddress = vm.envOr("RISC_ZERO_VERIFIER_ADDRESS", address(0));
        bool usingMock = verifierAddress == address(0);
        if (usingMock) {
            RiscZeroMockVerifier mockVerifier = new RiscZeroMockVerifier();
            verifierAddress = address(mockVerifier);
            console.log("RiscZeroMockVerifier deployed at:", verifierAddress);
            console.log("WARNING: Using mock verifier -- testnet only!");
        }

        // 2. Resolve image ID (placeholder if unset)
        bytes32 imageId = vm.envOr("RISC_ZERO_IMAGE_ID", bytes32(0));
        if (imageId == bytes32(0)) {
            imageId = keccak256("proof-of-claw-guest-placeholder");
            console.log("Using placeholder image ID (compile zkvm guest for real ID)");
        }

        // 3. Deploy ProofOfClawVerifier
        ProofOfClawVerifier proofOfClaw = new ProofOfClawVerifier(
            IRiscZeroVerifier(verifierAddress),
            imageId
        );
        console.log("ProofOfClawVerifier deployed at:", address(proofOfClaw));

        // 4. Deploy ProofOfClawINFT (ERC-7857 iNFT)
        ProofOfClawINFT inft = new ProofOfClawINFT(address(proofOfClaw));
        console.log("ProofOfClawINFT deployed at:", address(inft));

        // 5. Log deployment info
        console.log("---");
        console.log("Chain: 0G");
        console.log("RiscZero Verifier:", verifierAddress);
        console.log("ProofOfClawVerifier:", address(proofOfClaw));
        console.log("iNFT:", address(inft));
        console.log("Image ID:", vm.toString(imageId));
        if (usingMock) {
            console.log("Mode: TESTNET (mock verifier)");
        } else {
            console.log("Mode: PRODUCTION (real verifier)");
        }
        console.log("---");
        console.log("Next steps:");
        console.log("  1. Set INFT_CONTRACT in .env to the iNFT address above");
        console.log("  2. Set RISC_ZERO_VERIFIER_ADDRESS in .env");
        console.log("  3. Verify contracts: forge verify-contract <address> ProofOfClawINFT --chain-id 16602");
        console.log("  4. Mint agent iNFT via the frontend deploy wizard");

        vm.stopBroadcast();
    }
}
