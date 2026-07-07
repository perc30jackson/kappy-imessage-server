use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use rustpush::{
    authenticate_apple, default_provider, login_apple_delegates, AppleAccount, ArcAnisetteClient,
    DefaultAnisetteProvider, IDSUser, LoginClientInfo, LoginDelegate, OSConfig,
};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use crate::mac_config::SpikeMacConfig;
use crate::state::SpikeStateDir;

#[derive(serde::Serialize, serde::Deserialize)]
struct GsaConfig {
    username: String,
    encrypted_password: Vec<u8>,
    #[serde(default)]
    postdata_done: Option<bool>,
}

impl GsaConfig {
    fn encrypt(password: &[u8]) -> Result<Vec<u8>> {
        Ok(password.to_vec())
    }
}

async fn login_client_info(
    config: &Arc<SpikeMacConfig>,
    conn: &rustpush::APSConnection,
) -> LoginClientInfo {
    config.get_gsa_config(&*conn.state.read().await, true)
}

pub async fn apple_login(
    state_dir: &SpikeStateDir,
    config: &Arc<SpikeMacConfig>,
    conn: &rustpush::APSConnection,
    apple_id: &str,
    password: &str,
) -> Result<Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>> {
    state_dir.ensure()?;
    let anisette_dir = state_dir.root.join("anisette");
    std::fs::create_dir_all(&anisette_dir)?;

    let login_config = login_client_info(config, conn).await;
    let anisette: ArcAnisetteClient<DefaultAnisetteProvider> =
        default_provider(login_config, anisette_dir);

    let mut apple_account = AppleAccount::new_with_anisette(
        login_client_info(config, conn).await,
        anisette,
    )?;

    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    let hashed = hasher.finalize().to_vec();

    let login_state = apple_account.login_email_pass(apple_id, &hashed).await?;
    log::info!("Apple login state: {:?}", login_state);

    Ok(Arc::new(Mutex::new(apple_account)))
}

pub async fn ids_login(
    state_dir: &SpikeStateDir,
    config: &Arc<SpikeMacConfig>,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
) -> Result<IDSUser> {
    let mut account_guard = account.lock().await;
    account_guard
        .update_postdata("Apple Device", None, &["icloud", "imessage", "facetime"])
        .await?;

    let delegates = login_apple_delegates(
        &*account_guard,
        None,
        config.as_ref() as &dyn OSConfig,
        &[LoginDelegate::IDS, LoginDelegate::MobileMe],
    )
    .await?;

    let username = account_guard
        .username
        .clone()
        .ok_or_else(|| anyhow!("missing username after login"))?;
    let hashed_password = account_guard
        .hashed_password
        .clone()
        .ok_or_else(|| anyhow!("missing password after login"))?;

    plist::to_file_xml(
        state_dir.root.join("gsa.plist"),
        &GsaConfig {
            username,
            encrypted_password: GsaConfig::encrypt(&hashed_password)?,
            postdata_done: Some(true),
        },
    )?;

    let ids = delegates
        .ids
        .ok_or_else(|| anyhow!("IDS delegate missing from Apple login"))?;
    let user = authenticate_apple(ids, config.as_ref() as &dyn OSConfig).await?;
    Ok(user)
}

pub async fn login_flow(
    state_dir: &SpikeStateDir,
    config: &Arc<SpikeMacConfig>,
    conn: &rustpush::APSConnection,
    apple_id: &str,
    password: &str,
) -> Result<Vec<IDSUser>> {
    let account = apple_login(state_dir, config, conn, apple_id, password).await?;
    let user = ids_login(state_dir, config, &account).await?;
    state_dir.save_users(&[user.clone()])?;
    log::info!("IDS user saved to id.plist");
    Ok(vec![user])
}
