use std::io::{self, Write};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use rustpush::{
    authenticate_apple, login_apple_delegates, AppleAccount, AppleAuthError, ArcAnisetteClient,
    CircleClientSession, DebugMutex, IdmsAuthListener, IdmsMessage, IDSUser, LoginClientInfo,
    LoginDelegate, LoginState, OSConfig, PushError, TrustedPhoneNumber,
};

use crate::anisette::{spike_anisette_client, SpikeAnisetteProvider};
use sha2::{Digest, Sha256};
use tokio::sync::broadcast::error::RecvError;

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

pub fn load_gsa_config(state_dir: &SpikeStateDir) -> Result<GsaConfig> {
    let path = state_dir.root.join("gsa.plist");
    plist::from_file(&path).with_context(|| format!("read {} (run login first)", path.display()))
}

#[derive(Clone, Debug, Default)]
pub struct LoginOptions {
    /// Pre-supplied 6-digit code (also `KAPPY_2FA_CODE`). Prompts interactively when absent.
    pub two_fa_code: Option<String>,
}

fn map_auth_err(err: AppleAuthError) -> anyhow::Error {
    anyhow!("{err}")
}

fn map_auth_err_step(step: &str, err: AppleAuthError) -> anyhow::Error {
    let hint = match &err {
        AppleAuthError::AuthSrpWithMessage(code, _) if *code == -80035 => {
            " Sign in at https://icloud.com to accept terms or fix account issues, then retry."
        }
        AppleAuthError::Bad2faCode => " Check the verification code and try again.",
        AppleAuthError::ExtraStep(_) => {
            " Complete the required step at https://account.apple.com first."
        }
        AppleAuthError::FailedGetting2FAConfig => {
            " Disable Advanced Data Protection on the Apple ID, then retry."
        }
        AppleAuthError::HardwareKeyError => {
            " Disable hardware security keys on the Apple ID, then retry."
        }
        _ => "",
    };
    anyhow!("{step} failed: {err}.{hint}")
}

fn map_push_err(step: &str, err: PushError) -> anyhow::Error {
    match err {
        PushError::Bad2FaCode => anyhow!("{step}: incorrect verification code"),
        other => anyhow!("{step}: {other}"),
    }
}

fn normalize_2fa_code(raw: &str) -> Result<String> {
    let digits: String = raw.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() != 6 {
        anyhow::bail!("verification code must be 6 digits, got {}", digits.len());
    }
    Ok(digits)
}

async fn read_line(prompt: &str) -> Result<String> {
    let prompt = prompt.to_string();
    tokio::task::spawn_blocking(move || {
        eprint!("{prompt}");
        io::stderr().flush()?;
        let mut line = String::new();
        io::stdin().read_line(&mut line)?;
        Ok::<_, io::Error>(line)
    })
    .await
    .context("read stdin")?
    .map_err(|err| anyhow!(err))
}

async fn prompt_2fa_code(staged: &mut Option<String>, context: &str) -> Result<String> {
    if let Some(code) = staged.take() {
        return normalize_2fa_code(&code);
    }
    loop {
        let line = read_line(&format!("{context}\nEnter 6-digit code from your trusted device: "))
            .await?;
        match normalize_2fa_code(line.trim()) {
            Ok(code) => return Ok(code),
            Err(err) => eprintln!("{err:#}"),
        }
    }
}

async fn prompt_phone_id(phones: &[TrustedPhoneNumber]) -> Result<u32> {
    if phones.is_empty() {
        anyhow::bail!("no trusted phone numbers on this Apple ID");
    }
    if phones.len() == 1 {
        let phone = &phones[0];
        log::info!(
            "Sending SMS to {} (…{})",
            phone.number_with_dial_code,
            phone.last_two_digits
        );
        return Ok(phone.id);
    }

    eprintln!("Trusted phone numbers:");
    for (idx, phone) in phones.iter().enumerate() {
        eprintln!(
            "  [{}] {} (…{})",
            idx + 1,
            phone.number_with_dial_code,
            phone.last_two_digits
        );
    }

    loop {
        let line = read_line("Choose SMS number [1]: ").await?;
        let choice = line.trim();
        let index = if choice.is_empty() {
            0
        } else {
            choice
                .parse::<usize>()
                .context("enter a list number")?
                .checked_sub(1)
                .ok_or_else(|| anyhow!("choose a number between 1 and {}", phones.len()))?
        };
        if let Some(phone) = phones.get(index) {
            return Ok(phone.id);
        }
        eprintln!("Invalid choice; try again.");
    }
}

async fn complete_device_2fa(
    conn: &rustpush::APSConnection,
    account: Arc<DebugMutex<AppleAccount<SpikeAnisetteProvider>>>,
    password: &str,
) -> Result<LoginState> {
    let dsid = {
        let guard = account.lock().await;
        guard
            .spd
            .as_ref()
            .and_then(|spd| spd.get("DsPrsId"))
            .and_then(|value| value.as_unsigned_integer())
            .ok_or_else(|| anyhow!("missing DsPrsId after password login"))?
    };

    eprintln!(
        "Trusted-device 2FA required.\n\
         On your iPhone, iPad, or Mac: approve the Apple ID sign-in alert, then tap Allow.\n\
         Waiting up to 5 minutes for approval..."
    );

    let push_token = conn.get_token().await;
    let mut circle =
        CircleClientSession::new(dsid, account.clone(), push_token)
            .await
            .map_err(|err| map_push_err("start trusted-device 2FA", err))?;

    circle
        .send_code(password)
        .await
        .map_err(|err| map_push_err("trusted-device 2FA handshake", err))?;

    let listener = IdmsAuthListener::new(conn.clone()).await;
    let mut subscription = conn.messages_cont.subscribe();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(300);

    loop {
        let remaining = deadline
            .checked_duration_since(tokio::time::Instant::now())
            .ok_or_else(|| anyhow!("timed out waiting for trusted-device 2FA approval"))?;

        tokio::select! {
            msg = subscription.recv() => {
                let msg = match msg {
                    Ok(msg) => msg,
                    Err(RecvError::Lagged(_)) => continue,
                    Err(RecvError::Closed) => anyhow::bail!("APS connection closed during 2FA"),
                };

                let Some(idms) = listener
                    .handle(msg)
                    .map_err(|err| map_push_err("trusted-device 2FA message", err))?
                else {
                    continue;
                };

                match idms {
                    IdmsMessage::TeardownSignIn(_) => {
                        anyhow::bail!("sign-in was cancelled on the trusted device");
                    }
                    IdmsMessage::RequestedSignIn(_) => {
                        log::info!("Sign-in request delivered to trusted device — tap Allow there");
                    }
                    IdmsMessage::CircleRequest(circle_msg, _) => {
                        if let Some(state) = circle
                            .handle_circle_request(&circle_msg)
                            .await
                            .map_err(|err| map_push_err("trusted-device 2FA circle step", err))?
                        {
                            return Ok(state);
                        }
                    }
                }
            }
            _ = tokio::time::sleep(remaining.min(Duration::from_secs(1))) => {
                if tokio::time::Instant::now() >= deadline {
                    anyhow::bail!(
                        "timed out waiting for trusted-device 2FA — approve the alert on your iPhone/iPad/Mac and retry login"
                    );
                }
            }
        }
    }
}

async fn complete_apple_login(
    conn: &rustpush::APSConnection,
    account: Arc<DebugMutex<AppleAccount<SpikeAnisetteProvider>>>,
    apple_id: &str,
    password: &str,
    hashed_password: &[u8],
    options: &mut LoginOptions,
) -> Result<()> {
    log::info!("Starting Apple ID GSA login for {apple_id}");
    let mut login_state = {
        let mut guard = account.lock().await;
        guard
            .login_email_pass(apple_id, hashed_password)
            .await
            .map_err(|err| map_auth_err_step("Apple ID password login", err))?
    };

    loop {
        log::info!("Apple login state: {:?}", login_state);
        login_state = match login_state {
            LoginState::LoggedIn => return Ok(()),
            LoginState::NeedsDevice2FA => {
                eprintln!(
                    "Trusted-device 2FA required — sending sign-in request to your devices.\n\
                     Approve the alert if shown, or use the 6-digit code from Settings / another trusted device."
                );
                account
                    .lock()
                    .await
                    .send_2fa_to_devices()
                    .await
                    .map_err(map_auth_err)?
            }
            LoginState::Needs2FAVerification => {
                let code = prompt_2fa_code(
                    &mut options.two_fa_code,
                    "Use the 6-digit code shown on your trusted device (not SMS).",
                )
                .await?;
                let mut guard = account.lock().await;
                match guard.verify_2fa(code).await {
                    Ok(state) => state,
                    Err(AppleAuthError::Bad2faCode) => {
                        eprintln!("Incorrect verification code; try again.");
                        LoginState::Needs2FAVerification
                    }
                    Err(err) => return Err(map_auth_err(err)),
                }
            }
            LoginState::NeedsSMS2FA => {
                let guard = account.lock().await;
                let extras = guard.get_auth_extras().await.map_err(map_auth_err)?;
                drop(guard);
                if let Some(state) = extras.new_state {
                    state
                } else {
                    let phone_id = prompt_phone_id(&extras.trusted_phone_numbers).await?;
                    account
                        .lock()
                        .await
                        .send_sms_2fa_to_devices(phone_id)
                        .await
                        .map_err(map_auth_err)?
                }
            }
            LoginState::NeedsSMS2FAVerification(body) => {
                log::info!("SMS verification code sent");
                let code = prompt_2fa_code(
                    &mut options.two_fa_code,
                    "Enter the code from the SMS Apple just sent.",
                )
                .await?;
                let mut guard = account.lock().await;
                match guard.verify_sms_2fa(code, body).await {
                    Ok(state) => state,
                    Err(AppleAuthError::Bad2faCode) => {
                        eprintln!("Incorrect SMS code; try again.");
                        LoginState::NeedsSMS2FA
                    }
                    Err(err) => return Err(map_auth_err(err)),
                }
            }
            LoginState::NeedsLogin => account
                .lock()
                .await
                .login_email_pass(apple_id, hashed_password)
                .await
                .map_err(|err| map_auth_err_step("Apple ID re-login", err))?,
            LoginState::NeedsExtraStep(step) => {
                if account.lock().await.get_pet().is_some() {
                    return Ok(());
                }
                anyhow::bail!(
                    "Apple ID requires an extra step at account.apple.com before headless login: {step}"
                );
            }
        };
    }
}

async fn login_client_info(
    config: &Arc<SpikeMacConfig>,
    conn: &rustpush::APSConnection,
) -> LoginClientInfo {
    config.get_gsa_config(&*conn.state.read().await, false)
}

pub async fn apple_login(
    state_dir: &SpikeStateDir,
    config: &Arc<SpikeMacConfig>,
    conn: &rustpush::APSConnection,
    apple_id: &str,
    password: &str,
    options: &mut LoginOptions,
) -> Result<Arc<DebugMutex<AppleAccount<SpikeAnisetteProvider>>>> {
    state_dir.ensure()?;

    let login_config = login_client_info(config, conn).await;
    let anisette: ArcAnisetteClient<SpikeAnisetteProvider> =
        spike_anisette_client(config.as_ref(), login_config.clone(), &state_dir.root)?;

    let apple_account = AppleAccount::new_with_anisette(login_config, anisette)?;

    let account = Arc::new(DebugMutex::new(apple_account));

    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    let hashed = hasher.finalize().to_vec();

    complete_apple_login(
        conn,
        account.clone(),
        apple_id,
        password,
        &hashed,
        options,
    )
    .await?;
    log::info!("Apple ID GSA login complete");

    Ok(account)
}

pub async fn ids_login(
    state_dir: &SpikeStateDir,
    config: &Arc<SpikeMacConfig>,
    account: &Arc<DebugMutex<AppleAccount<SpikeAnisetteProvider>>>,
) -> Result<IDSUser> {
    let mut account_guard = account.lock().await;
    let device_name = config.get_device_name();
    log::info!("Updating iCloud postdata for device {device_name}");
    account_guard
        .update_postdata(&device_name, None, &["icloud", "imessage", "facetime"])
        .await
        .map_err(|err| map_auth_err_step("iCloud postdata", err))?;

    log::info!("Requesting IDS and MobileMe login delegates");
    let delegates = login_apple_delegates(
        &*account_guard,
        None,
        config.as_ref() as &dyn OSConfig,
        &[LoginDelegate::IDS, LoginDelegate::MobileMe],
    )
    .await
    .map_err(|err| anyhow!("IDS delegate login failed: {err}"))?;

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
    options: &mut LoginOptions,
) -> Result<Vec<IDSUser>> {
    let account = apple_login(state_dir, config, conn, apple_id, password, options).await?;
    let user = ids_login(state_dir, config, &account).await?;
    state_dir.save_users(&[user.clone()])?;
    log::info!("IDS user saved to id.plist");
    Ok(vec![user])
}

/// Re-run GSA + IDS delegate login using `gsa.plist` (fixes 6005 after GUI cert import).
pub async fn refresh_login_from_gsa(
    state_dir: &SpikeStateDir,
    config: &Arc<SpikeMacConfig>,
    conn: &rustpush::APSConnection,
    options: &mut LoginOptions,
) -> Result<Vec<IDSUser>> {
    let gsa = load_gsa_config(state_dir)?;
    let hashed_password = gsa.encrypted_password;

    let old_registration = state_dir
        .load_users()
        .ok()
        .and_then(|users| users.into_iter().next())
        .map(|user| user.registration);

    let login_config = login_client_info(config, conn).await;
    let anisette: ArcAnisetteClient<SpikeAnisetteProvider> =
        spike_anisette_client(config.as_ref(), login_config.clone(), &state_dir.root)?;
    let account = Arc::new(DebugMutex::new(AppleAccount::new_with_anisette(
        login_config,
        anisette,
    )?));

    log::info!("Refreshing Apple ID session for {}", gsa.username);
    complete_apple_login(
        conn,
        account.clone(),
        &gsa.username,
        "",
        &hashed_password,
        options,
    )
    .await?;

    let mut user = ids_login(state_dir, config, &account).await?;
    if let Some(registration) = old_registration {
        if !registration.is_empty() {
            log::info!(
                "preserving {} registration service(s) from prior id.plist",
                registration.len()
            );
            user.registration = registration;
        }
    }
    state_dir.save_users(&[user.clone()])?;
    log::info!("refreshed IDS auth_keypair from gsa.plist");
    Ok(vec![user])
}
