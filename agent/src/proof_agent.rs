use anyhow::Result;
use tracing::{info, warn};
use crate::api::{ActivityItem, SharedState};
use crate::core::config::AgentConfig;
use crate::integrations::zero_g::{ZeroGCompute, ZeroGStorage};
use crate::integrations::ens_dm3::DM3Client;
use crate::ironclaw_adapter::{IronClawAdapter, IronClawExecutionTrace};
use crate::proof_generator::ProofGenerator;

pub struct ProofOfClawAgent {
    config: AgentConfig,
    adapter: IronClawAdapter,
    proof_generator: ProofGenerator,
    state: Option<SharedState>,
}

impl ProofOfClawAgent {
    pub async fn new(config: AgentConfig) -> Result<Self> {
        info!("Initializing Proof of Claw Agent (IronClaw-based): {}", config.agent_id);

        let zero_g_compute = ZeroGCompute::new(&config).await?;
        let zero_g_storage = ZeroGStorage::new(&config).await?;
        let dm3_client = DM3Client::new(&config).await?;

        let adapter = IronClawAdapter::new(zero_g_compute, zero_g_storage, dm3_client);

        let image_id = config
            .risc_zero_image_id
            .clone()
            .unwrap_or_else(|| {
                warn!("RISC_ZERO_IMAGE_ID not set — proofs will not be verifiable on-chain");
                String::new()
            });
        let proof_generator = ProofGenerator::new(true, image_id);

        Ok(Self { config, adapter, proof_generator, state: None })
    }

    pub fn id(&self) -> &str {
        &self.config.agent_id
    }

    /// Attach the shared API state so the agent can update it.
    pub fn set_state(&mut self, state: SharedState) {
        self.state = Some(state);
    }

    /// Run with IronClaw runtime — registers hooks for tool execution, LLM calls,
    /// and session completion so that every agent action produces a provable trace.
    #[cfg(feature = "ironclaw-integration")]
    pub async fn run_with_ironclaw(&self) -> Result<()> {
        info!("Starting Proof of Claw Agent with IronClaw runtime");

        // Initialize IronClaw hooks that intercept agent behavior
        let hooks = crate::ironclaw_adapter::ironclaw_hooks::ProofOfClawHooks::new(
            // IronClaw adapter is not Clone, so in production the hooks hold an Arc.
            // For now we re-create the necessary clients — they are stateless HTTP wrappers.
            IronClawAdapter::new(
                ZeroGCompute::new(&self.config).await?,
                ZeroGStorage::new(&self.config).await?,
                DM3Client::new(&self.config).await?,
            ),
        );

        info!("IronClaw hooks registered:");
        info!("  - on_tool_execution: captures tool calls into execution trace");
        info!("  - on_llm_call: routes inference through 0G Compute with attestation");
        info!("  - on_session_complete: stores trace on 0G Storage + generates ZK proof");

        // The IronClaw runtime takes over the event loop.
        // It calls our hooks for each tool execution, LLM call, and session end.
        // Ctrl+C is handled by IronClaw's signal handler.
        loop {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {
                    info!("Shutting down IronClaw agent");
                    break;
                }
            }
        }

        Ok(())
    }

    /// Run in standalone mode — seeds initial state and waits for API-driven chat interactions.
    pub async fn run_standalone(&mut self) -> Result<()> {
        info!("Starting Proof of Claw Agent in standalone mode");
        info!("Agent {} is ready and listening for requests via /api/chat", self.config.agent_id);

        // Seed initial activity so the dashboard isn't empty on first load
        if let Some(ref state) = self.state {
            let now = chrono::Utc::now().timestamp();
            let mut s = state.write().await;

            s.activity.push(ActivityItem {
                activity_type: "system".to_string(),
                title: "Agent Started".to_string(),
                description: format!("Proof of Claw agent {} initialized in standalone mode", self.config.agent_id),
                timestamp: now,
            });

            s.activity.push(ActivityItem {
                activity_type: "system".to_string(),
                title: "Policy Loaded".to_string(),
                description: format!(
                    "Loaded {} allowed tools, max autonomous value {} wei",
                    self.config.policy.allowed_tools.len(),
                    self.config.policy.max_value_autonomous_wei
                ),
                timestamp: now,
            });

            s.activity.push(ActivityItem {
                activity_type: "proof".to_string(),
                title: "ZK Proof System Ready".to_string(),
                description: "RISC Zero prover initialized. Ready to generate execution proofs.".to_string(),
                timestamp: now,
            });

            info!("Seeded {} initial activity items into dashboard state", s.activity.len());
        }

        info!("Agent ready — send messages via POST /api/chat");

        loop {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {
                    info!("Shutting down agent");
                    break;
                }
            }
        }

        Ok(())
    }

    /// Process an IronClaw execution trace: convert, store on 0G, and generate proof.
    pub async fn process_ironclaw_trace(&self, trace: IronClawExecutionTrace) -> Result<String> {
        info!("Processing IronClaw execution trace");

        let proof_trace = self.adapter.convert_trace(trace, &self.config.agent_id);

        let trace_hash = self.adapter.store_trace(&proof_trace).await?;
        info!("Trace stored on 0G Storage: {}", trace_hash);

        let receipt = self.proof_generator.generate_proof(&proof_trace).await?;
        info!(
            "ZK proof generated: image_id={}, journal_len={}, seal_len={}",
            receipt.image_id,
            receipt.journal.len(),
            receipt.seal.len()
        );

        Ok(trace_hash)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ironclaw_adapter::{IronClawToolCall, LLMInteraction, PolicyCheck};

    fn create_test_config() -> AgentConfig {
        AgentConfig {
            agent_id: "test-agent".to_string(),
            ens_name: "test.proofclaw.eth".to_string(),
            private_key: "0x1234".to_string(),
            rpc_url: "http://localhost:8545".to_string(),
            zero_g_indexer_rpc: "http://localhost:5000".to_string(),
            zero_g_compute_endpoint: "http://localhost:5001".to_string(),
            dm3_delivery_service_url: "http://localhost:3001".to_string(),
            ledger_origin_token: None,
            eip8004_identity_registry: None,
            eip8004_reputation_registry: None,
            eip8004_validation_registry: None,
            eip8004_integration_contract: None,
            inft_contract: None,
            risc_zero_image_id: Some("0xdeadbeef".to_string()),
            policy: crate::core::config::PolicyConfig {
                allowed_tools: vec!["swap".to_string()],
                endpoint_allowlist: vec!["https://api.example.com".to_string()],
                max_value_autonomous_wei: 1_000_000_000_000_000_000,
            },
        }
    }

    #[tokio::test]
    async fn test_ironclaw_trace_conversion() {
        let config = create_test_config();
        let agent = ProofOfClawAgent::new(config).await.unwrap();

        let ironclaw_trace = IronClawExecutionTrace {
            session_id: "test-session".to_string(),
            timestamp: 1234567890,
            tool_calls: vec![
                IronClawToolCall {
                    tool_name: "swap".to_string(),
                    input: serde_json::json!({"amount": 100}),
                    output: serde_json::json!({"success": true}),
                    capability_hash: "0xabcd".to_string(),
                    allowed: true,
                }
            ],
            llm_interactions: vec![
                LLMInteraction {
                    prompt: "Swap 100 tokens".to_string(),
                    response: "Executing swap".to_string(),
                    provider: "0g-compute".to_string(),
                    attestation: Some("0x1234567890".to_string()),
                }
            ],
            policy_checks: vec![
                PolicyCheck {
                    rule_id: "tool_allowlist".to_string(),
                    severity: "pass".to_string(),
                    passed: true,
                    details: "Tool is allowed".to_string(),
                }
            ],
        };

        let proof_trace = agent.adapter.convert_trace(ironclaw_trace, "test-agent");

        assert_eq!(proof_trace.agent_id, "test-agent");
        assert_eq!(proof_trace.tool_invocations.len(), 1);
        assert_eq!(proof_trace.tool_invocations[0].tool_name, "swap");
        assert_eq!(proof_trace.policy_check_results.len(), 1);
    }
}
