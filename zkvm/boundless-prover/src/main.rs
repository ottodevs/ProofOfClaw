//! Boundless Groth16 Prover for Proof of Claw
//!
//! Submits a proof request to the Boundless proving marketplace on Sepolia,
//! waits for fulfillment, and outputs the Groth16 seal ready for on-chain verification.
//!
//! Usage:
//!   # First generate a STARK receipt:
//!   cd zkvm && ./target/release/proof-of-claw-host > /dev/null
//!
//!   # Then submit to Boundless for Groth16 wrapping:
//!   ./target/release/boundless-prover
//!
//! Required env vars:
//!   PRIVATE_KEY         — Funded Sepolia wallet
//!   SEPOLIA_RPC_URL     — Sepolia RPC endpoint
//!
//! The guest ELF and image ID are loaded automatically from the build artifacts.

use alloy::{
    network::EthereumWallet,
    providers::ProviderBuilder,
    signers::local::PrivateKeySigner,
};
use anyhow::{Context, Result};
use boundless_market::{
    client::ClientBuilder,
    deployments::SEPOLIA,
    contracts::Input,
};
use risc0_zkvm::compute_image_id;
use serde::{Deserialize, Serialize};
use std::time::Duration;

const GUEST_ELF: &[u8] = include_bytes!("../../target/riscv32im-risc0-zkvm-elf/release/proof-of-claw-guest");

#[derive(Serialize, Deserialize)]
struct ExecutionTrace {
    agent_id: String,
    inference_commitment: [u8; 32],
    tool_invocations: Vec<ToolInvocation>,
    policy_check_results: Vec<PolicyResult>,
    output_commitment: [u8; 32],
    action_value: u64,
}

#[derive(Serialize, Deserialize)]
struct ToolInvocation {
    tool_name: String,
    input_hash: [u8; 32],
    output_hash: [u8; 32],
    capability_hash: [u8; 32],
    within_policy: bool,
}

#[derive(Serialize, Deserialize)]
struct PolicyResult {
    rule_id: String,
    severity: String,
    details: String,
}

#[derive(Serialize, Deserialize)]
struct AgentPolicy {
    allowed_tools: Vec<String>,
    endpoint_allowlist: Vec<String>,
    max_value_autonomous: u64,
    capability_root: [u8; 32],
}

#[derive(Serialize, Deserialize, Debug)]
struct VerifiedOutput {
    agent_id: String,
    policy_hash: [u8; 32],
    output_commitment: [u8; 32],
    all_checks_passed: bool,
    requires_ledger_approval: bool,
    action_value: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let image_id = compute_image_id(GUEST_ELF)?;
    println!("Proof of Claw — Boundless Groth16 Prover");
    println!("Image ID: 0x{}", hex::encode(image_id.as_bytes()));

    // Load env
    let private_key = std::env::var("PRIVATE_KEY")
        .context("PRIVATE_KEY env var required")?;
    let rpc_url = std::env::var("SEPOLIA_RPC_URL")
        .unwrap_or_else(|_| "https://ethereum-sepolia-rpc.publicnode.com".to_string());

    // Set up wallet and provider
    let signer: PrivateKeySigner = private_key.parse()
        .context("Invalid PRIVATE_KEY")?;
    let wallet = EthereumWallet::from(signer.clone());
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .on_http(rpc_url.parse()?);

    println!("Wallet: {:?}", signer.address());

    // Build Boundless client using Sepolia deployment
    let client = ClientBuilder::default()
        .with_deployment(SEPOLIA)
        .build(&provider, &signer)
        .await
        .context("Failed to build Boundless client")?;

    // Build proof input (trace + policy serialized together)
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
            },
        ],
        policy_check_results: vec![],
        output_commitment: [0u8; 32],
        action_value: 50_000_000_000_000_000,
    };

    let policy = AgentPolicy {
        allowed_tools: vec!["swap_tokens".to_string(), "transfer".to_string()],
        endpoint_allowlist: vec!["https://api.uniswap.org".to_string()],
        max_value_autonomous: 100_000_000_000_000_000,
        capability_root: [0u8; 32],
    };

    let input_bytes = bincode::serialize(&(&trace, &policy))
        .context("Failed to serialize input")?;

    println!("Submitting proof request to Boundless (Sepolia)...");
    println!("Input size: {} bytes", input_bytes.len());
    println!("Guest ELF size: {} bytes", GUEST_ELF.len());

    // Submit proof request
    let request_id = client
        .submit(client.new_request(
            Input::builder()
                .with_image_id(image_id)
                .with_input(&input_bytes)
                .with_elf(GUEST_ELF)
                .build(),
        ))
        .await
        .context("Failed to submit proof request to Boundless")?;

    println!("Proof request submitted! ID: {request_id}");
    println!("Waiting for fulfillment (this may take 2-10 minutes)...");

    // Wait for the proof to be fulfilled
    let expires_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() + 600; // 10 minute timeout

    let receipt = client
        .wait_for_request_fulfillment(
            request_id,
            Duration::from_secs(10), // check every 10s
            expires_at,
        )
        .await
        .context("Proof request was not fulfilled in time")?;

    println!("\n=== PROOF FULFILLED ===");
    println!("Journal length: {} bytes", receipt.journal.bytes.len());

    // Decode output
    let output: VerifiedOutput = receipt.journal.decode()
        .context("Failed to decode journal")?;
    println!("Agent: {}", output.agent_id);
    println!("All checks passed: {}", output.all_checks_passed);

    // Extract Groth16 seal
    match receipt.inner.groth16() {
        Ok(groth16) => {
            let seal_hex = hex::encode(&groth16.seal);
            println!("\n=== ON-CHAIN READY (Groth16) ===");
            println!("Seal length: {} bytes", groth16.seal.len());
            println!("\nSolidity calldata for verifyAndExecute():");
            println!("  imageId:     0x{}", hex::encode(image_id.as_bytes()));
            println!("  seal:        0x{}", seal_hex);
            println!("  journalData: 0x{}", hex::encode(&receipt.journal.bytes));

            // Save to file for easy consumption
            let output_path = "groth16-proof.json";
            let proof_json = serde_json::json!({
                "image_id": format!("0x{}", hex::encode(image_id.as_bytes())),
                "seal": format!("0x{}", seal_hex),
                "journal": format!("0x{}", hex::encode(&receipt.journal.bytes)),
                "journal_hash": format!("0x{}", hex::encode(sha256(&receipt.journal.bytes))),
            });
            std::fs::write(output_path, serde_json::to_string_pretty(&proof_json)?)?;
            println!("\nProof saved to: {output_path}");
        }
        Err(_) => {
            println!("WARNING: Receipt is not Groth16. Got STARK/Succinct receipt instead.");
            println!("The Boundless marketplace may have returned a non-Groth16 proof.");
        }
    }

    Ok(())
}

fn sha256(data: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}
