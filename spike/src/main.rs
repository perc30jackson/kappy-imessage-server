use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use kappy_spike::engine;
use kappy_spike::state::SpikeStateDir;
use kappy_spike::validation;

#[derive(Parser)]
#[command(name = "kappy-spike", about = "U0 rustpush iMessage feasibility spike (macOS)")]
struct Cli {
    /// State directory (hw_info.plist, id.plist, anisette/)
    #[arg(long, env = "KAPPY_SPIKE_STATE_DIR", default_value = "./state")]
    state_dir: PathBuf,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Import Mac-Hardware-Info export and create APS identity (step 1)
    Activate {
        #[arg(long)]
        hw_info: PathBuf,
    },
    /// Apple ID login + IDS delegate (step 2; may prompt 2FA on device)
    Login {
        #[arg(long, env = "KAPPY_APPLE_ID")]
        apple_id: String,
        #[arg(long, env = "KAPPY_APPLE_PASSWORD")]
        password: String,
    },
    /// Load validation JSON from `mac-registration-provider -once` (step 3a)
    InjectValidation {
        #[arg(long)]
        file: PathBuf,
    },
    /// HTTP server for `mac-registration-provider` submit mode (step 3b)
    ValidationServer {
        #[arg(long, default_value = "127.0.0.1:8787")]
        listen: SocketAddr,
    },
    /// IDS register with MADRID_SERVICE (step 4; requires validation + login)
    Register,
    /// Send a DM text (step 5 — T0.2)
    Send {
        #[arg(long)]
        to: String,
        #[arg(long)]
        body: String,
    },
    /// Log inbound messages (step 5 — T0.3)
    Listen,
    /// Persist APS push state after successful session (T0.4)
    SaveState,
}

#[tokio::main]
async fn main() -> Result<()> {
    pretty_env_logger::init();
    let cli = Cli::parse();
    let state_dir = SpikeStateDir::new(cli.state_dir);

    match cli.command {
        Commands::Activate { hw_info } => {
            engine::activate_from_hw_file(&state_dir, &hw_info).await?;
        }
        Commands::Login { apple_id, password } => {
            engine::login(&state_dir, &apple_id, &password).await?;
        }
        Commands::InjectValidation { file } => {
            validation::load_validation_json(&file).await?;
            log::info!("validation data loaded from {}", file.display());
        }
        Commands::ValidationServer { listen } => {
            validation::http::serve(listen).await?;
        }
        Commands::Register => {
            let mut connected = engine::connect(&state_dir).await?;
            connected.register_ids().await?;
            engine::persist_push_state(&state_dir, &connected)?;
        }
        Commands::Send { to, body } => {
            let connected = engine::connect(&state_dir).await?;
            connected.send_text(&to, &body).await?;
        }
        Commands::Listen => {
            let connected = engine::connect(&state_dir).await?;
            connected.listen().await?;
        }
        Commands::SaveState => {
            let connected = engine::connect(&state_dir).await?;
            engine::persist_push_state(&state_dir, &connected)?;
            log::info!("saved hw_info.plist push state");
        }
    }

    Ok(())
}
