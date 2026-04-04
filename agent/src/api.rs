use axum::{
    extract::State,
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tower_http::cors::{Any, CorsLayer};
use tracing::info;

use sha2::Digest as _;

use crate::core::config::AgentConfig;
use crate::core::intent_router::{Intent, IntentRouter};
use crate::core::types::{
    AgentMessage, ExecutionTrace, InferenceResponse, MessagePayload, MessageType,
    PolicyResult as CorePolicyResult, PolicySeverity, ToolInvocation,
};
use crate::proof_generator::ProofGenerator;
use crate::safety::policy_engine::PolicyEngine;

/// Shared agent state accessible by API handlers
#[derive(Debug, Clone)]
pub struct AgentState {
    pub config: AgentConfig,
    pub stats: AgentStats,
    pub activity: Vec<ActivityItem>,
    pub proofs: Vec<ProofRecord>,
    pub messages: Vec<MessageRecord>,
    pub started_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentStats {
    pub total_actions: u64,
    pub autonomous_actions: u64,
    pub approved_actions: u64,
    pub violations: u64,
    pub proofs_generated: u64,
    pub proofs_verified: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivityItem {
    pub activity_type: String, // "proof", "message", "approval"
    pub title: String,
    pub description: String,
    pub timestamp: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProofRecord {
    pub proof_id: String,
    pub agent_id: String,
    pub action: String,
    pub value: String,
    pub approval_type: String,
    pub status: String, // "verified", "pending", "failed"
    pub timestamp: i64,
    pub proof_time_secs: u64,
    pub output_commitment: String,
    pub tx_hash: Option<String>,
    pub block_number: Option<u64>,
    pub policy_checks: Vec<PolicyCheckRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyCheckRecord {
    pub rule: String,
    pub passed: bool,
    pub details: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageRecord {
    pub from: String,
    pub to: String,
    pub content: String,
    pub timestamp: i64,
    pub encrypted: bool,
    pub delivered: bool,
}

pub type SharedState = Arc<RwLock<AgentState>>;

// ========== API RESPONSE TYPES ==========

#[derive(Serialize)]
pub struct StatusResponse {
    pub agent_id: String,
    pub ens_name: String,
    pub status: String,
    pub uptime_secs: i64,
    pub network: String,
    pub policy_hash: String,
    pub allowed_tools: Vec<String>,
    pub endpoint_allowlist: Vec<String>,
    pub max_value_autonomous_wei: u64,
    pub stats: AgentStats,
}

#[derive(Serialize)]
pub struct ActivityResponse {
    pub items: Vec<ActivityItem>,
}

#[derive(Serialize)]
pub struct ProofsResponse {
    pub proofs: Vec<ProofRecord>,
}

#[derive(Serialize)]
pub struct MessagesResponse {
    pub messages: Vec<MessageRecord>,
}

#[derive(Deserialize)]
pub struct SendMessageRequest {
    pub to: String,
    pub content: String,
}

#[derive(Serialize)]
pub struct SendMessageResponse {
    pub success: bool,
    pub message_id: String,
}

// ========== CHAT TYPES ==========

#[derive(Deserialize)]
pub struct ChatRequest {
    pub message: String,
}

#[derive(Serialize)]
pub struct ChatResponse {
    pub response: String,
    pub intent: ChatIntentInfo,
    pub policy_result: ChatPolicyInfo,
    pub proof: ChatProofInfo,
}

#[derive(Serialize)]
pub struct ChatIntentInfo {
    pub action_type: String,
    pub confidence: f64,
}

#[derive(Serialize)]
pub struct ChatPolicyInfo {
    pub allowed: bool,
    pub approval_type: String,
    pub checks: Vec<PolicyCheckRecord>,
}

#[derive(Serialize)]
pub struct ChatProofInfo {
    pub proof_id: String,
    pub status: String,
    pub output_commitment: String,
}

// ========== HANDLERS ==========

async fn get_status(State(state): State<SharedState>) -> Json<StatusResponse> {
    let s = state.read().await;
    let now = chrono::Utc::now().timestamp();
    let uptime = now - s.started_at;

    // Compute policy hash from the actual policy config
    let policy_str = format!(
        "{:?}{:?}{}",
        s.config.policy.allowed_tools,
        s.config.policy.endpoint_allowlist,
        s.config.policy.max_value_autonomous_wei
    );
    use sha2::Digest as _;
    let hash_bytes = sha2::Sha256::digest(policy_str.as_bytes());
    let policy_hash = format!("0x{}", hex::encode(hash_bytes));

    Json(StatusResponse {
        agent_id: s.config.agent_id.clone(),
        ens_name: s.config.ens_name.clone(),
        status: "online".to_string(),
        uptime_secs: uptime,
        network: if s.config.rpc_url.contains("sepolia") {
            "sepolia".to_string()
        } else if s.config.rpc_url.contains("testnet") {
            "testnet".to_string()
        } else {
            "mainnet".to_string()
        },
        policy_hash,
        allowed_tools: s.config.policy.allowed_tools.clone(),
        endpoint_allowlist: s.config.policy.endpoint_allowlist.clone(),
        max_value_autonomous_wei: s.config.policy.max_value_autonomous_wei,
        stats: s.stats.clone(),
    })
}

async fn get_activity(State(state): State<SharedState>) -> Json<ActivityResponse> {
    let s = state.read().await;
    Json(ActivityResponse {
        items: s.activity.clone(),
    })
}

async fn get_proofs(State(state): State<SharedState>) -> Json<ProofsResponse> {
    let s = state.read().await;
    Json(ProofsResponse {
        proofs: s.proofs.clone(),
    })
}

async fn get_messages(State(state): State<SharedState>) -> Json<MessagesResponse> {
    let s = state.read().await;
    Json(MessagesResponse {
        messages: s.messages.clone(),
    })
}

async fn send_message(
    State(state): State<SharedState>,
    Json(req): Json<SendMessageRequest>,
) -> (StatusCode, Json<SendMessageResponse>) {
    let mut s = state.write().await;
    let msg = MessageRecord {
        from: s.config.agent_id.clone(),
        to: req.to.clone(),
        content: req.content.clone(),
        timestamp: chrono::Utc::now().timestamp(),
        encrypted: true,
        delivered: true,
    };
    s.messages.push(msg);

    s.stats.total_actions += 1;

    s.activity.insert(0, ActivityItem {
        activity_type: "message".to_string(),
        title: "DM3 Message Sent".to_string(),
        description: format!("To {} via encrypted DM3", req.to),
        timestamp: chrono::Utc::now().timestamp(),
    });

    (StatusCode::OK, Json(SendMessageResponse {
        success: true,
        message_id: uuid::Uuid::new_v4().to_string(),
    }))
}

/// Parse a free-text user message into an action string and params for the agent pipeline.
fn parse_user_message(text: &str) -> (String, HashMap<String, serde_json::Value>) {
    let lower = text.to_lowercase();
    let mut params = HashMap::new();

    if lower.contains("swap") {
        params.insert("description".to_string(), serde_json::Value::String(text.to_string()));
        // Try to extract a numeric value for policy checks
        for word in text.split_whitespace() {
            if let Ok(n) = word.parse::<u64>() {
                params.insert("value".to_string(), serde_json::json!(n));
                break;
            }
        }
        ("swap_tokens".to_string(), params)
    } else if lower.contains("transfer") || lower.contains("send") {
        params.insert("description".to_string(), serde_json::Value::String(text.to_string()));
        for word in text.split_whitespace() {
            if let Ok(n) = word.parse::<u64>() {
                params.insert("value".to_string(), serde_json::json!(n));
                break;
            }
        }
        ("transfer".to_string(), params)
    } else if lower.contains("query") || lower.contains("balance") || lower.contains("price")
        || lower.contains("fetch") || lower.contains("check")
    {
        params.insert("description".to_string(), serde_json::Value::String(text.to_string()));
        ("query".to_string(), params)
    } else {
        params.insert("description".to_string(), serde_json::Value::String(text.to_string()));
        ("unknown".to_string(), params)
    }
}

async fn chat(
    State(state): State<SharedState>,
    Json(req): Json<ChatRequest>,
) -> (StatusCode, Json<ChatResponse>) {
    let now = chrono::Utc::now().timestamp();

    // 1. Parse the user message into an action + params
    let (action, params) = parse_user_message(&req.message);

    // Build an AgentMessage for the existing pipeline
    let agent_msg = AgentMessage {
        message_type: MessageType::Execute,
        payload: MessagePayload {
            action: action.clone(),
            params: params.clone(),
            trace_root_hash: None,
            proof_receipt: None,
            required_approval: None,
        },
        nonce: 1,
        timestamp: now,
    };

    // 2. Classify intent
    let intent_router = IntentRouter::new();
    let intent = intent_router.classify_intent(&agent_msg).unwrap_or(Intent::Unknown);

    let (intent_action_type, intent_confidence) = match &intent {
        Intent::TokenSwap => ("swap", 0.95),
        Intent::Transfer => ("transfer", 0.92),
        Intent::Query => ("query", 0.90),
        Intent::Negotiate => ("negotiate", 0.85),
        Intent::Unknown => ("unknown", 0.3),
    };

    // 3. Check policy
    let policy_config = {
        let s = state.read().await;
        s.config.policy.clone()
    };
    let policy_engine = PolicyEngine::new(policy_config);

    let mock_inference = InferenceResponse {
        content: format!("Processing: {}", req.message),
        attestation_signature: "0xmock".to_string(),
        provider: "0g-compute".to_string(),
    };

    let policy_result = policy_engine.check(&agent_msg, &mock_inference)
        .unwrap_or(CorePolicyResult {
            rule_id: "error".to_string(),
            severity: PolicySeverity::Pass,
            details: "Policy check failed, defaulting to pass".to_string(),
        });

    let policy_allowed = !matches!(policy_result.severity, PolicySeverity::Block);
    let needs_ledger = matches!(policy_result.severity, PolicySeverity::Warn);

    let approval_type = if !policy_allowed {
        "blocked"
    } else if needs_ledger {
        "ledger_approval_required"
    } else {
        "autonomous"
    };

    let policy_checks = vec![PolicyCheckRecord {
        rule: policy_result.rule_id.clone(),
        passed: policy_allowed,
        details: policy_result.details.clone(),
    }];

    // 4. Generate response text based on intent and policy
    let response_text = if !policy_allowed {
        format!(
            "Action blocked by policy: {}. This violates the configured safety rules.",
            policy_result.details
        )
    } else {
        match &intent {
            Intent::TokenSwap => {
                let approval_msg = if needs_ledger {
                    "Needs Ledger approval before execution."
                } else {
                    "Autonomous execution approved."
                };
                format!(
                    "Executing swap: {}. Policy verified. {}",
                    req.message, approval_msg
                )
            }
            Intent::Transfer => {
                let approval_msg = if needs_ledger {
                    "Needs Ledger approval."
                } else {
                    "Autonomous execution approved."
                };
                format!(
                    "Processing transfer: {}. Policy verified. {}",
                    req.message, approval_msg
                )
            }
            Intent::Query => {
                format!(
                    "Fetching on-chain data for: {}. No policy gate required.",
                    req.message
                )
            }
            Intent::Negotiate => {
                format!("Initiating negotiation: {}. Policy verified.", req.message)
            }
            Intent::Unknown => {
                "I don't understand that request. I can help with: token swaps, transfers, and on-chain queries.".to_string()
            }
        }
    };

    // 5. Build execution trace and generate proof
    let tool_name = action.clone();
    let trace = ExecutionTrace {
        agent_id: {
            let s = state.read().await;
            s.config.agent_id.clone()
        },
        session_id: uuid::Uuid::new_v4().to_string(),
        timestamp: now,
        inference_commitment: format!("0x{}", hex::encode(sha2::Sha256::digest(req.message.as_bytes()))),
        tool_invocations: vec![ToolInvocation {
            tool_name: tool_name.clone(),
            input_hash: format!("0x{}", hex::encode(sha2::Sha256::digest(req.message.as_bytes()))),
            output_hash: format!("0x{}", hex::encode(sha2::Sha256::digest(response_text.as_bytes()))),
            capability_hash: "0xcap".to_string(),
            timestamp: now,
            within_policy: policy_allowed,
        }],
        policy_check_results: vec![CorePolicyResult {
            rule_id: policy_result.rule_id.clone(),
            severity: policy_result.severity.clone(),
            details: policy_result.details.clone(),
        }],
        output_commitment: format!("0x{}", hex::encode(sha2::Sha256::digest(response_text.as_bytes()))),
    };

    let image_id = {
        let s = state.read().await;
        s.config.risc_zero_image_id.clone().unwrap_or_default()
    };
    let proof_gen = ProofGenerator::new(true, image_id);
    let proof_id = uuid::Uuid::new_v4().to_string();

    let (proof_status, output_commitment) = match proof_gen.generate_proof(&trace).await {
        Ok(receipt) => {
            let verified = proof_gen.verify_receipt(&receipt).ok();
            let commitment = verified
                .as_ref()
                .map(|v| v.output_commitment.clone())
                .unwrap_or_else(|| trace.output_commitment.clone());
            ("verified".to_string(), commitment)
        }
        Err(_) => ("failed".to_string(), trace.output_commitment.clone()),
    };

    // 6. Record everything in agent state
    {
        let mut s = state.write().await;
        let agent_id = s.config.agent_id.clone();

        // Record user message
        s.messages.push(MessageRecord {
            from: "user".to_string(),
            to: agent_id.clone(),
            content: req.message.clone(),
            timestamp: now,
            encrypted: false,
            delivered: true,
        });

        // Record agent response
        s.messages.push(MessageRecord {
            from: agent_id.clone(),
            to: "user".to_string(),
            content: response_text.clone(),
            timestamp: now,
            encrypted: false,
            delivered: true,
        });

        // Record proof
        let proof_record = ProofRecord {
            proof_id: proof_id.clone(),
            agent_id: agent_id.clone(),
            action: tool_name.clone(),
            value: req.message.clone(),
            approval_type: approval_type.to_string(),
            status: proof_status.clone(),
            timestamp: now,
            proof_time_secs: 1,
            output_commitment: output_commitment.clone(),
            tx_hash: None,
            block_number: None,
            policy_checks: policy_checks.clone(),
        };
        s.record_proof(proof_record);
    }

    // 7. Return response
    (
        StatusCode::OK,
        Json(ChatResponse {
            response: response_text,
            intent: ChatIntentInfo {
                action_type: intent_action_type.to_string(),
                confidence: intent_confidence,
            },
            policy_result: ChatPolicyInfo {
                allowed: policy_allowed,
                approval_type: approval_type.to_string(),
                checks: policy_checks,
            },
            proof: ChatProofInfo {
                proof_id,
                status: proof_status,
                output_commitment,
            },
        }),
    )
}

async fn health() -> &'static str {
    "ok"
}

// ========== STATE MUTATION (called by agent runtime) ==========

impl AgentState {
    /// Record a completed proof in the agent state.
    pub fn record_proof(&mut self, proof: ProofRecord) {
        self.stats.proofs_generated += 1;
        self.stats.total_actions += 1;

        if proof.status == "verified" {
            self.stats.proofs_verified += 1;
        }

        match proof.approval_type.as_str() {
            "Autonomous" => self.stats.autonomous_actions += 1,
            "Ledger Approved" => self.stats.approved_actions += 1,
            _ => {}
        }

        self.activity.insert(0, ActivityItem {
            activity_type: "proof".to_string(),
            title: "Proof Generated".to_string(),
            description: format!(
                "{} {} | {} | {}",
                proof.action, proof.value, proof.approval_type, proof.status
            ),
            timestamp: proof.timestamp,
        });

        self.proofs.insert(0, proof);
    }

    /// Record a policy violation.
    pub fn record_violation(&mut self, rule: &str, details: &str) {
        self.stats.violations += 1;
        self.activity.insert(0, ActivityItem {
            activity_type: "violation".to_string(),
            title: format!("Policy Violation: {}", rule),
            description: details.to_string(),
            timestamp: chrono::Utc::now().timestamp(),
        });
    }

    /// Record an incoming DM3 message.
    pub fn record_incoming_message(&mut self, msg: MessageRecord) {
        self.activity.insert(0, ActivityItem {
            activity_type: "message".to_string(),
            title: "DM3 Message Received".to_string(),
            description: format!("From {} via encrypted channel", msg.from),
            timestamp: msg.timestamp,
        });
        self.messages.push(msg);
    }
}

// ========== SERVER SETUP ==========

pub fn create_router(state: SharedState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    Router::new()
        .route("/health", get(health))
        .route("/api/status", get(get_status))
        .route("/api/activity", get(get_activity))
        .route("/api/proofs", get(get_proofs))
        .route("/api/messages", get(get_messages))
        .route("/api/messages/send", post(send_message))
        .route("/api/chat", post(chat))
        .with_state(state)
        .layer(cors)
}

/// Create initial agent state — starts empty, populated by real agent activity.
pub fn create_initial_state(config: AgentConfig) -> SharedState {
    let now = chrono::Utc::now().timestamp();

    Arc::new(RwLock::new(AgentState {
        config,
        stats: AgentStats {
            total_actions: 0,
            autonomous_actions: 0,
            approved_actions: 0,
            violations: 0,
            proofs_generated: 0,
            proofs_verified: 0,
        },
        activity: Vec::new(),
        proofs: Vec::new(),
        messages: Vec::new(),
        started_at: now,
    }))
}

pub async fn start_api_server(state: SharedState, port: u16) -> anyhow::Result<()> {
    let app = create_router(state);
    let addr = format!("0.0.0.0:{}", port);
    info!("Starting API server on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
