use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use kappy_spike::engine;
use kappy_spike::state::SpikeStateDir;
use kappy_spike::validation;

fn init_rustls() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}

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
    /// Apple ID login + IDS delegate (step 2; prompts for 2FA when required)
    Login {
        #[arg(long, env = "KAPPY_APPLE_ID")]
        apple_id: String,
        #[arg(long, env = "KAPPY_APPLE_PASSWORD")]
        password: String,
        /// Optional 6-digit 2FA code (otherwise read interactively from stdin)
        #[arg(long, env = "KAPPY_2FA_CODE")]
        two_fa_code: Option<String>,
    },
    /// Re-login from saved gsa.plist (refreshes auth_keypair after GUI cert import)
    RefreshLogin {
        /// Optional 6-digit 2FA code (otherwise read interactively from stdin)
        #[arg(long, env = "KAPPY_2FA_CODE")]
        two_fa_code: Option<String>,
    },
    /// Load validation JSON from `mac-registration-provider -once` (step 3a)
    InjectValidation {
        #[arg(long)]
        file: PathBuf,
    },
    /// Fetch validation from Beeper registration relay (macOS 26 alternate path)
    FetchValidationRelay {
        #[arg(long, env = "KAPPY_RELAY_HOST", default_value = "https://registration-relay.beeper.com")]
        host: String,
        #[arg(long, env = "KAPPY_RELAY_CODE")]
        code: String,
        #[arg(long, env = "KAPPY_BEEPER_TOKEN")]
        beeper_token: Option<String>,
    },
    /// Poll registration relay and refresh validation.json (macOS 26 alternate path)
    ValidationRelayPoller {
        #[arg(long, env = "KAPPY_RELAY_HOST", default_value = "https://registration-relay.beeper.com")]
        host: String,
        #[arg(long, env = "KAPPY_RELAY_CODE")]
        code: String,
        #[arg(long, env = "KAPPY_BEEPER_TOKEN")]
        beeper_token: Option<String>,
        #[arg(long, default_value = "300")]
        interval_secs: u64,
    },
    /// Fetch validation from kappy-nacserv (direct Beeper nacserv API)
    FetchValidationNacserv {
        #[arg(long, env = "KAPPY_NACSERV_URL", default_value = "http://127.0.0.1:8788")]
        url: String,
        #[arg(long, env = "KAPPY_NACSERV_TOKEN")]
        token: String,
    },
    /// Poll kappy-nacserv and refresh validation.json
    ValidationNacservPoller {
        #[arg(long, env = "KAPPY_NACSERV_URL", default_value = "http://127.0.0.1:8788")]
        url: String,
        #[arg(long, env = "KAPPY_NACSERV_TOKEN")]
        token: String,
        #[arg(long, default_value = "300")]
        interval_secs: u64,
    },
    /// HTTP server for `mac-registration-provider` submit mode (step 3b)
    ValidationServer {
        #[arg(long, default_value = "127.0.0.1:8787")]
        listen: SocketAddr,
    },
    /// IDS register with MADRID_SERVICE (step 4; requires validation + login)
    Register,
    /// Import GUI Messages registration into id.plist (after Messages.app iMessage setup)
    ImportGuiRegistration {
        /// identityservicesd handle cache (default: ~/Library/IdentityServices/idstatuscache.plist)
        #[arg(long, default_value = "~/Library/IdentityServices/idstatuscache.plist")]
        idstatuscache: PathBuf,
        /// Donor id.plist with successful `register` (copies registration + optional keystore)
        #[arg(long)]
        donor_id_plist: Option<PathBuf>,
        /// Donor keystore.plist matching --donor-id-plist (merged before keystore init)
        #[arg(long)]
        donor_keystore: Option<PathBuf>,
        /// Build com.apple.madrid from idstatuscache using spike auth cert (experimental)
        #[arg(long)]
        synthesize: bool,
    },
    /// Import GUI IDS export JSON (from kappy-ids-export / capture-ids.sh)
    ImportIdsExport {
        #[arg(long)]
        file: PathBuf,
    },
    /// Send a DM text (step 5 — T0.2)
    Send {
        #[arg(long)]
        to: String,
        #[arg(long)]
        body: String,
    },
    /// Log inbound messages (step 5 — T0.3)
    Listen,
    /// Listen + send on one APS connection (type: `send <to> <body>`)
    Repl,
    /// Persist APS push state after successful session (T0.4)
    SaveState,
    /// Check auth cert, registration, and identity readiness
    Doctor,
    /// Query Apple id-get-handles (which mailto:/tel: URIs can be registered)
    DoctorHandles,
    /// Probe Apple carrier bundles for SMS / SMSLess (EAP-AKA) registration paths
    ProbeCarrier {
        /// MCC+MNC without separator (e.g. 310260). Repeatable.
        #[arg(long = "mccmnc")]
        mccmnc: Vec<String>,
        /// Also probe common US MVNO / eSIM MCC/MNC codes (Telnyx roster)
        #[arg(long)]
        telnyx_presets: bool,
    },
    /// Send REG-REQ SMS via Telnyx to Apple carrier gateway (phone number registration)
    SmsRegSend {
        /// Carrier MCC+MNC for gateway lookup (e.g. 310260)
        #[arg(long, env = "KAPPY_SMS_MCCMNC", default_value = "310260")]
        mccmnc: String,
        /// Handset / SIM MSISDN that will send REG-REQ (E.164). Defaults to TELNYX_FROM_NUMBER.
        /// For eSIM path use TELNYX_ESIM_MSISDN (not the messaging long code).
        #[arg(long, env = "KAPPY_SMS_HANDSET_NUMBER")]
        handset: Option<String>,
        /// Telnyx Messaging long code (only needed for API send, used as handset fallback)
        #[arg(long, env = "TELNYX_FROM_NUMBER")]
        from: Option<String>,
        /// Telnyx API key (not required for --dry-run)
        #[arg(long, env = "TELNYX_API_KEY", default_value = "")]
        api_key: String,
        /// Override SMS gateway destination (default: from carrier.plist)
        #[arg(long, env = "KAPPY_SMS_GATEWAY")]
        gateway: Option<String>,
        /// Build REG-REQ and save pending; do not call Telnyx (use when API cannot reach Apple short codes)
        #[arg(long)]
        dry_run: bool,
    },
    /// Complete SMS registration from REG-RESP body (paste or webhook capture)
    SmsRegComplete {
        /// Full REG-RESP SMS text
        #[arg(long, conflicts_with = "file")]
        text: Option<String>,
        /// File containing REG-RESP SMS text
        #[arg(long, conflicts_with = "text")]
        file: Option<PathBuf>,
        /// Run IDS register after phone auth
        #[arg(long)]
        register: bool,
    },
    /// HTTP webhook for Telnyx inbound SMS → auto sms-reg-complete
    SmsRegWebhook {
        #[arg(long, default_value = "127.0.0.1:8790")]
        listen: SocketAddr,
        #[arg(long)]
        register: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    init_rustls();
    pretty_env_logger::init();
    let cli = Cli::parse();
    let state_dir = SpikeStateDir::new(cli.state_dir);

    if let Commands::ImportGuiRegistration {
        donor_id_plist,
        donor_keystore,
        ..
    } = &cli.command
    {
        if let (Some(donor_id), Some(donor_ks)) = (donor_id_plist, donor_keystore) {
            kappy_spike::keystore_setup::merge_keystore_files(
                &state_dir,
                &kappy_spike::import_gui::expand_path(donor_ks),
                &kappy_spike::import_gui::expand_path(donor_id),
            )?;
        }
    }

    kappy_spike::keystore_setup::init(&state_dir)?;
    if validation::load_persisted_validation(&state_dir.root).await? {
        log::debug!("loaded persisted validation.json");
    }

    match cli.command {
        Commands::Activate { hw_info } => {
            engine::activate_from_hw_file(&state_dir, &hw_info).await?;
        }
        Commands::Login {
            apple_id,
            password,
            two_fa_code,
        } => {
            engine::login(
                &state_dir,
                &apple_id,
                &password,
                kappy_spike::login::LoginOptions { two_fa_code },
            )
            .await?;
        }
        Commands::RefreshLogin { two_fa_code } => {
            engine::refresh_login(
                &state_dir,
                kappy_spike::login::LoginOptions { two_fa_code },
            )
            .await?;
        }
        Commands::InjectValidation { file } => {
            let text = std::fs::read_to_string(&file)?;
            validation::persist_validation_json(&state_dir.root, &text).await?;
            log::info!("validation data loaded from {}", file.display());
        }
        Commands::FetchValidationRelay {
            host,
            code,
            beeper_token,
        } => {
            let cfg = validation::RelayFetchConfig {
                host,
                code,
                beeper_token,
            };
            validation::fetch_relay_and_persist(&state_dir.root, &cfg, "registration-relay").await?;
        }
        Commands::ValidationRelayPoller {
            host,
            code,
            beeper_token,
            interval_secs,
        } => {
            let cfg = validation::RelayFetchConfig {
                host,
                code,
                beeper_token,
            };
            validation::relay_refresh_loop(
                state_dir.root.clone(),
                cfg,
                std::time::Duration::from_secs(interval_secs),
            )
            .await?;
        }
        Commands::FetchValidationNacserv { url, token } => {
            let cfg = validation::NacServFetchConfig { url, token };
            validation::fetch_nacserv_and_persist(&state_dir.root, &cfg).await?;
        }
        Commands::ValidationNacservPoller {
            url,
            token,
            interval_secs,
        } => {
            let cfg = validation::NacServFetchConfig { url, token };
            validation::nacserv_refresh_loop(
                state_dir.root.clone(),
                cfg,
                std::time::Duration::from_secs(interval_secs),
            )
            .await?;
        }
        Commands::ValidationServer { listen } => {
            validation::http::serve(listen).await?;
        }
        Commands::Register => {
            let mut connected = engine::connect(&state_dir).await?;
            connected.register_ids().await?;
            engine::persist_push_state(&state_dir, &connected).await?;
        }
        Commands::ImportGuiRegistration {
            idstatuscache,
            donor_id_plist,
            donor_keystore: _,
            synthesize,
        } => {
            let (cache_path, donor_path) =
                kappy_spike::import_gui::resolve_import_paths(idstatuscache, donor_id_plist);
            kappy_spike::import_gui::import_gui_registration(
                &state_dir,
                &cache_path,
                donor_path.as_deref(),
                synthesize,
            )?;
        }
        Commands::ImportIdsExport { file } => {
            kappy_spike::import_ids_export::import_ids_export(&state_dir, &file)?;
        }
        Commands::Send { to, body } => {
            let connected = engine::connect(&state_dir).await?;
            connected.send_text(&to, &body).await?;
        }
        Commands::Listen => {
            let connected = engine::connect(&state_dir).await?;
            connected.listen().await?;
        }
        Commands::Repl => {
            let connected = std::sync::Arc::new(engine::connect(&state_dir).await?);
            connected.listen_repl().await?;
        }
        Commands::SaveState => {
            let connected = engine::connect(&state_dir).await?;
            engine::persist_push_state(&state_dir, &connected).await?;
            log::info!("saved hw_info.plist push state");
        }
        Commands::Doctor => {
            engine::doctor(&state_dir).await?;
        }
        Commands::DoctorHandles => {
            kappy_spike::ids_handles::doctor_handles(&state_dir).await?;
        }
        Commands::ProbeCarrier {
            mccmnc,
            telnyx_presets,
        } => {
            kappy_spike::carrier_probe::probe_carriers(&mccmnc, telnyx_presets).await?;
        }
        Commands::SmsRegSend {
            mccmnc,
            from,
            handset,
            api_key,
            gateway,
            dry_run,
        } => {
            let handset_number = handset
                .or(from)
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "set KAPPY_SMS_HANDSET_NUMBER (eSIM MSISDN) or TELNYX_FROM_NUMBER"
                    )
                })?;
            if !dry_run && api_key.is_empty() {
                anyhow::bail!("TELNYX_API_KEY required unless --dry-run");
            }
            kappy_spike::sms_reg::sms_reg_send(
                &state_dir,
                &mccmnc,
                &handset_number,
                &api_key,
                gateway.as_deref(),
                dry_run,
            )
            .await?;
        }
        Commands::SmsRegComplete {
            text,
            file,
            register,
        } => {
            let body = match (text, file) {
                (Some(t), None) => t,
                (None, Some(path)) => std::fs::read_to_string(&path)
                    .with_context(|| format!("read {}", path.display()))?,
                _ => anyhow::bail!("pass --text or --file with REG-RESP body"),
            };
            kappy_spike::sms_reg::sms_reg_complete(&state_dir, &body, register).await?;
        }
        Commands::SmsRegWebhook { listen, register } => {
            kappy_spike::sms_reg::webhook::serve(state_dir, listen, register).await?;
        }
    }

    Ok(())
}
