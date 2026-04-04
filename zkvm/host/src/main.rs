use risc0_zkvm::{default_prover, compute_image_id, ExecutorEnv, Receipt};
use serde::{Deserialize, Serialize};
use anyhow::Result;

#[derive(Serialize, Deserialize)]
struct ExecutionTrace {
    agent_id: String,
    inference_commitment: [u8; 32],
    tool_invocations: Vec<ToolInvocation>,
    policy_check_results: Vec<PolicyResult>,
    output_commitment: [u8; 32],
    action_value: u64,
}

#[derive(Serialize, Deserialize, Clone)]
struct ToolInvocation {
    tool_name: String,
    input_hash: [u8; 32],
    output_hash: [u8; 32],
    capability_hash: [u8; 32],
    within_policy: bool,
}

#[derive(Serialize, Deserialize, Clone)]
struct PolicyResult {
    rule_id: String,
    severity: String,
    details: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct AgentPolicy {
    allowed_tools: Vec<String>,
    endpoint_allowlist: Vec<String>,
    max_value_autonomous: u64,
    capability_root: [u8; 32],
}

#[derive(Serialize, Deserialize)]
struct ProofOutput {
    seal: String,
    journal: String,
    image_id: String,
}

// Pre-built guest ELF
const GUEST_ELF: &[u8] = include_bytes!("../../target/riscv32im-risc0-zkvm-elf/release/proof-of-claw-guest");

fn main() -> Result<()> {
    println!("Proof of Claw - RISC Zero Host");
    println!("================================\n");

    // Compute image ID from ELF
    let image_id = compute_image_id(GUEST_ELF)?;
    println!("Guest Image ID: 0x{}\n", hex::encode(image_id.as_bytes()));

    // Example execution trace from an agent
    let trace = ExecutionTrace {
        agent_id: "alice.proofofclaw.eth".to_string(),
        inference_commitment: [0u8; 32],
        tool_invocations: vec![
            ToolInvocation {
                tool_name: "swap_tokens".to_string(),
                input_hash: [1u8; 32],
                output_hash: [2u8; 32],
                capability_hash: [3u8; 32],
                within_policy: true,
            }
        ],
        policy_check_results: vec![
            PolicyResult {
                rule_id: "value_limit".to_string(),
                severity: "Pass".to_string(),
                details: "Action value within limits".to_string(),
            }
        ],
        output_commitment: [4u8; 32],
        action_value: 50_000_000_000_000_000u64, // 0.05 ETH
    };

    let policy = AgentPolicy {
        allowed_tools: vec!["swap_tokens".to_string(), "transfer".to_string()],
        endpoint_allowlist: vec!["https://api.uniswap.org".to_string()],
        max_value_autonomous: 100_000_000_000_000_000u64, // 0.1 ETH
        capability_root: [0u8; 32],
    };

    println!("Generating proof...");
    let receipt = generate_proof(&trace, &policy)?;

    println!("Proof generated successfully!\n");

    // Extract seal and journal for on-chain verification
    let seal = receipt.seal.clone();
    let journal = receipt.journal.bytes.clone();

    println!("Proof Details:");
    println!("  - Image ID:        0x{}", hex::encode(image_id.as_bytes()));
    println!("  - Seal length:     {} bytes", seal.len());
    println!("  - Journal length:  {} bytes", journal.len());

    // Output data for on-chain verification
    let proof_output = ProofOutput {
        seal: hex::encode(&seal),
        journal: hex::encode(&journal),
        image_id: hex::encode(image_id.as_bytes()),
    };

    // Save to file for use in deployment/verification scripts
    let output_json = serde_json::to_string_pretty(&proof_output)?;
    std::fs::write("proof_output.json", output_json)?;
    println!("\nProof data saved to: proof_output.json");

    // Print the Solidity-compatible call data
    println!("\n=== ON-CHAIN VERIFICATION DATA ===");
    println!("\nImage ID (for deployment):");
    println!("export RISC_ZERO_IMAGE_ID=0x{}", hex::encode(image_id.as_bytes()));
    println!("\nSeal (bytes):");
    println!("0x{}", hex::encode(&seal));
    println!("\nJournal (bytes):");
    println!("0x{}", hex::encode(&journal));

    Ok(())
}

fn generate_proof(trace: &ExecutionTrace, policy: &AgentPolicy) -> Result<Receipt> {
    let env = ExecutorEnv::builder()
        .write(trace)?
        .write(policy)?
        .build()?;

    let prover = default_prover();
    let receipt = prover.prove(env, GUEST_ELF)?;

    Ok(receipt)
}
