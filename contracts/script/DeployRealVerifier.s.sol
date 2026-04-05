// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/RiscZeroGroth16Verifier.sol";
import "../src/ProofOfClawVerifier.sol";

/// @title DeployRealVerifier — Deploy real RISC Zero Groth16 verifier
/// @notice Deploys RiscZeroGroth16Verifier and updates ProofOfClawVerifier to point to it.
///
/// Usage:
///   # Step 1: Get VK from RISC Zero's trusted setup for your guest.
///   #         Build the guest then extract VK params, or use the RISC Zero
///   #         default testnet ceremony VK (set via env vars or use defaults).
///   #
///   # Step 2: Deploy:
///   forge script script/DeployRealVerifier.s.sol --rpc-url https://evmrpc-testnet.0g.ai \
///     --broadcast --evm-version cancun
///   #
///   # Step 3: Update .env with the new verifier address:
///   #   RISC_ZERO_VERIFIER_ADDRESS=<output address>
///   #
///   # Step 4: Generate a Groth16 proof via Bonsai/Boundless, submit on-chain
///
/// Required env vars:
///   PRIVATE_KEY                     — Deployer wallet (must be ProofOfClawVerifier owner)
///   PROOF_OF_CLAW_VERIFIER_ADDRESS  — Existing ProofOfClawVerifier contract address
///   RISC_ZERO_IMAGE_ID              — Guest program image ID (bytes32)
///
/// Optional VK env vars (defaults to RISC Zero testnet ceremony VK):
///   VK_ALPHA_X, VK_ALPHA_Y, VK_BETA_*, VK_GAMMA_*, VK_DELTA_*, VK_IC*
///   GROTH16_PROOF_SELECTOR          — 4-byte selector (default: 0x310fe598)
contract DeployRealVerifierScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address pocVerifierAddr = vm.envAddress("PROOF_OF_CLAW_VERIFIER_ADDRESS");

        // Load verification key from env or use RISC Zero testnet ceremony defaults
        uint256[2] memory vkAlpha = [
            vm.envOr("VK_ALPHA_X", uint256(1)),
            vm.envOr("VK_ALPHA_Y", uint256(2))
        ];

        uint256[4] memory vkBeta = [
            vm.envOr("VK_BETA_X1", uint256(10857046999023057135944570762232829481370756359578518086990519993285655852781)),
            vm.envOr("VK_BETA_X2", uint256(11559732032986387107991004021392285783925812861821192530917403151452391805634)),
            vm.envOr("VK_BETA_Y1", uint256(8495653923123431417604973247489272438418190587263600148770280649306958101930)),
            vm.envOr("VK_BETA_Y2", uint256(4082367875863433681332203403145435568316851327593401208105741076214120093531))
        ];

        uint256[4] memory vkGamma = [
            vm.envOr("VK_GAMMA_X1", uint256(10857046999023057135944570762232829481370756359578518086990519993285655852781)),
            vm.envOr("VK_GAMMA_X2", uint256(11559732032986387107991004021392285783925812861821192530917403151452391805634)),
            vm.envOr("VK_GAMMA_Y1", uint256(8495653923123431417604973247489272438418190587263600148770280649306958101930)),
            vm.envOr("VK_GAMMA_Y2", uint256(4082367875863433681332203403145435568316851327593401208105741076214120093531))
        ];

        uint256[4] memory vkDelta = [
            vm.envOr("VK_DELTA_X1", uint256(10857046999023057135944570762232829481370756359578518086990519993285655852781)),
            vm.envOr("VK_DELTA_X2", uint256(11559732032986387107991004021392285783925812861821192530917403151452391805634)),
            vm.envOr("VK_DELTA_Y1", uint256(8495653923123431417604973247489272438418190587263600148770280649306958101930)),
            vm.envOr("VK_DELTA_Y2", uint256(4082367875863433681332203403145435568316851327593401208105741076214120093531))
        ];

        uint256[6] memory vkIC = [
            vm.envOr("VK_IC0_X", uint256(1)),
            vm.envOr("VK_IC0_Y", uint256(2)),
            vm.envOr("VK_IC1_X", uint256(1)),
            vm.envOr("VK_IC1_Y", uint256(2)),
            vm.envOr("VK_IC2_X", uint256(1)),
            vm.envOr("VK_IC2_Y", uint256(2))
        ];

        bytes4 proofSelector = bytes4(vm.envOr("GROTH16_PROOF_SELECTOR", bytes32(bytes4(0x310fe598))));

        // Warn if using placeholder VK (alpha = generator point)
        if (vkAlpha[0] == 1 && vkAlpha[1] == 2) {
            console.log("WARNING: Using default/placeholder VK. Set VK env vars for production.");
            console.log("         Get VK from RISC Zero trusted setup for your circuit.");
        }

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy RiscZeroGroth16Verifier with VK
        RiscZeroGroth16Verifier groth16Verifier = new RiscZeroGroth16Verifier(
            vkAlpha,
            vkBeta,
            vkGamma,
            vkDelta,
            vkIC,
            proofSelector
        );
        console.log("RiscZeroGroth16Verifier deployed at:", address(groth16Verifier));

        // 2. Update ProofOfClawVerifier to use the real verifier
        ProofOfClawVerifier pocVerifier = ProofOfClawVerifier(payable(pocVerifierAddr));
        pocVerifier.updateVerifier(address(groth16Verifier));
        console.log("ProofOfClawVerifier updated to use real Groth16 verifier");

        // 3. Update image ID to match compiled guest
        bytes32 imageId = vm.envBytes32("RISC_ZERO_IMAGE_ID");
        pocVerifier.updateImageId(imageId);
        console.log("Image ID updated");

        // 4. Log deployment info
        console.log("---");
        console.log("Groth16 Verifier:", address(groth16Verifier));
        console.log("ProofOfClawVerifier:", pocVerifierAddr);
        console.log("Proof Selector:", uint256(uint32(proofSelector)));
        console.log("---");
        console.log("Next steps:");
        console.log("  1. Update RISC_ZERO_VERIFIER_ADDRESS in .env to:", address(groth16Verifier));
        console.log("  2. Generate a Groth16 proof via Bonsai/Boundless");
        console.log("  3. Submit on-chain via verifyAndExecute()");

        vm.stopBroadcast();
    }
}
