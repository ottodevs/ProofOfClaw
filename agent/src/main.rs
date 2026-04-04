#[allow(dead_code)]
mod core;
#[allow(dead_code)]
mod tools;
#[allow(dead_code)]
mod safety;
#[allow(dead_code)]
mod integrations;
#[allow(dead_code)]
mod ironclaw_adapter;
#[allow(dead_code)]
mod proof_agent;
#[allow(dead_code)]
mod proof_generator;
#[allow(dead_code)]
mod api;

use anyhow::Result;
use tracing::{info, error};
use tracing_subscriber;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    info!("Starting Proof of Claw Agent");

    let config = core::config::AgentConfig::from_env()?;

    // API server port (default 8420)
    let api_port: u16 = std::env::var("API_PORT")
        .unwrap_or_else(|_| "8420".to_string())
        .parse()
        .unwrap_or(8420);

    // Create shared state for API
    let state = api::create_initial_state(config.clone());

    // Spawn API server in background
    let api_state = state.clone();
    tokio::spawn(async move {
        if let Err(e) = api::start_api_server(api_state, api_port).await {
            error!("API server error: {}", e);
        }
    });

    info!("API server starting on port {}", api_port);

    #[cfg(feature = "ironclaw-integration")]
    {
        info!("Running with IronClaw integration");
        let agent = proof_agent::ProofOfClawAgent::new(config).await?;
        info!("Agent initialized: {}", agent.id());

        if let Err(e) = agent.run_with_ironclaw().await {
            error!("Agent error: {}", e);
            return Err(e);
        }
    }

    #[cfg(not(feature = "ironclaw-integration"))]
    {
        info!("Running in standalone mode");
        let mut agent = proof_agent::ProofOfClawAgent::new(config).await?;
        agent.set_state(state);
        info!("Agent initialized: {}", agent.id());

        if let Err(e) = agent.run_standalone().await {
            error!("Agent error: {}", e);
            return Err(e);
        }
    }

    Ok(())
}
