use std::sync::Arc;

use anyhow::{Context, Result};
use rustpush::{
    facetime::{FACETIME_SERVICE, VIDEO_SERVICE},
    findmy::MULTIPLEX_SERVICE,
    register, APSConnectionResource, ConversationData, IDSNGMIdentity, IMClient, MADRID_SERVICE,
    Message, MessageInst, MessageType, NormalMessage, OSConfig,
};
use tokio::sync::broadcast::error::RecvError;

use crate::hwinfo::normalize_recipient;
use crate::login::{login_flow, refresh_login_from_gsa, LoginOptions};
use crate::mac_config::SpikeMacConfig;
use crate::state::{read_file_bytes, SpikeStateDir};
use crate::util::plist_to_string;

pub async fn activate_from_hw_file(
    state_dir: &SpikeStateDir,
    hw_path: &std::path::Path,
) -> Result<()> {
    let bytes = read_file_bytes(hw_path)?;
    let config = crate::hwinfo::spike_config_from_hw_bytes(&bytes)?;
    let identity = IDSNGMIdentity::new().context("create IDSNGMIdentity")?;

    let (conn, push_err) = APSConnectionResource::new(config.clone(), None).await;
    if let Some(err) = push_err {
        log::warn!("APS setup warning: {err}");
    }

    let push = conn.state.read().await.clone();
    state_dir.save_hardware(&push, &identity, &config)?;
    log::info!(
        "Activated hardware identity for serial {}",
        config.inner.platform_serial_number
    );
    Ok(())
}

/// APS + hardware state only. Used for login before `id.plist` exists.
pub struct ApsSession {
    pub state_dir: SpikeStateDir,
    pub config: Arc<SpikeMacConfig>,
    pub identity: IDSNGMIdentity,
    pub conn: rustpush::APSConnection,
}

pub async fn connect_aps(state_dir: &SpikeStateDir) -> Result<ApsSession> {
    let (saved, config, identity) = state_dir.load_hardware()?;
    let (conn, push_err) =
        APSConnectionResource::new(config.clone(), Some(saved.push)).await;
    if let Some(err) = push_err {
        log::warn!("APS reconnect warning: {err}");
    }
    Ok(ApsSession {
        state_dir: state_dir.clone(),
        config,
        identity,
        conn,
    })
}

pub async fn connect(state_dir: &SpikeStateDir) -> Result<Connected> {
    let session = connect_aps(state_dir).await?;
    let users = session.state_dir.load_users().context("load id.plist (run login + register first)")?;
    let client = make_imclient(
        &session.state_dir,
        &session.conn,
        &users,
        &session.identity,
    )
    .await?;
    Ok(Connected {
        state_dir: session.state_dir,
        config: session.config,
        identity: session.identity,
        conn: session.conn,
        client,
        users,
    })
}

#[derive(Clone)]
pub struct Connected {
    pub state_dir: SpikeStateDir,
    pub config: Arc<SpikeMacConfig>,
    pub identity: IDSNGMIdentity,
    pub conn: rustpush::APSConnection,
    pub client: Arc<IMClient>,
    pub users: Vec<rustpush::IDSUser>,
}

impl Connected {
    pub async fn register_ids(&mut self) -> Result<()> {
        if self.users.is_empty() {
            anyhow::bail!("no IDS users — run `login` first");
        }
        let config = self.config.clone();
        let aps = self.conn.state.read().await.clone();
        let mut users = self.users.clone();
        register(
            config.as_ref() as &dyn OSConfig,
            &aps,
            &[
                &MADRID_SERVICE,
                &MULTIPLEX_SERVICE,
                &FACETIME_SERVICE,
                &VIDEO_SERVICE,
            ],
            &mut users,
            &self.identity,
        )
        .await
        .map_err(|e| anyhow::anyhow!("register failed: {e}"))?;
        self.users = users.clone();
        self.state_dir.save_users(&users)?;
        log::info!("register_ids OK for {} user(s)", users.len());
        Ok(())
    }

    fn sender_handle_for(&self, recipient: &str) -> Result<String> {
        let user = self
            .users
            .first()
            .context("no IDS users — run `login` and `register` first")?;
        let handles = &user.registration["com.apple.madrid"].handles;
        let pick = |prefix: &str| handles.iter().find(|h| h.starts_with(prefix)).cloned();
        let sender = if recipient.starts_with("tel:") {
            pick("tel:")
        } else if recipient.starts_with("mailto:") {
            pick("mailto:")
        } else {
            None
        }
        .or_else(|| handles.first().cloned())
        .context("no registered iMessage handles on this account")?;
        log::info!(
            "using sender handle {sender} (registered: {})",
            handles.join(", ")
        );
        Ok(sender)
    }

    pub async fn send_text(&self, to: &str, body: &str) -> Result<()> {
        let recipient = normalize_recipient(to);
        let sender = self.sender_handle_for(&recipient)?;
        log::info!("sending to {recipient} from {sender}");
        let mut msg = MessageInst::new(
            ConversationData {
                participants: vec![recipient.clone()],
                cv_name: None,
                sender_guid: None,
                after_guid: None,
            },
            &sender,
            Message::Message(NormalMessage::new(body.to_string(), MessageType::IMessage)),
        );
        self.client
            .send(&mut msg)
            .await
            .map_err(|e| anyhow::anyhow!("send failed: {e}"))?;
        log::info!("sent message id={} from {sender} to {recipient}", msg.id);
        Ok(())
    }

    pub async fn listen(&self) -> Result<()> {
        let mut rx = self.conn.messages_cont.subscribe();
        log::info!("listening for inbound APS messages (Ctrl+C to stop)…");
        loop {
            match rx.recv().await {
                Ok(aps_msg) => match self.client.handle(aps_msg).await {
                    Ok(Some(inst)) => {
                        log::info!(
                            "INBOUND iMessage id={} sender={:?}",
                            inst.id,
                            inst.sender
                        );
                    }
                    Ok(None) => {}
                    Err(err) => log::warn!("handle error: {err}"),
                },
                Err(RecvError::Lagged(n)) => {
                    log::warn!("lagged {n} messages");
                }
                Err(RecvError::Closed) => break,
            }
        }
        Ok(())
    }

    /// Wait for IDS identity resource; outbound send needs this (inbound may work without it).
    pub async fn wait_identity_ready(&self) -> Result<()> {
        use rustpush::PushError;

        match self.client.identity.ensure_ready().await {
            Ok(()) => Ok(()),
            Err(PushError::ResourceClosed) => {
                anyhow::bail!(
                    "IDS identity resource closed (register likely failed with 6005). \
                     Run `login` then `register` before send/repl. Inbound may still work."
                )
            }
            Err(e) => Err(anyhow::anyhow!("identity not ready: {e}")),
        }
    }

    /// Listen + send from one APS connection. Avoids "Resource has been closed" when
    /// a separate `send` process competes with `listen`.
    pub async fn listen_repl(self: Arc<Self>) -> Result<()> {
        use tokio::io::{AsyncBufReadExt, BufReader};

        log::info!("repl mode: inbound messages logged; type: send <to> <body>");
        if let Err(e) = self.wait_identity_ready().await {
            log::warn!("identity preflight: {e:#}");
            log::warn!("try: poc-line.sh 1 login && poc-line.sh 1 register");
        }
        let mut rx = self.conn.messages_cont.subscribe();
        let mut stdin = BufReader::new(tokio::io::stdin()).lines();

        loop {
            tokio::select! {
                msg = rx.recv() => {
                    match msg {
                        Ok(aps_msg) => match self.client.handle(aps_msg).await {
                            Ok(Some(inst)) => {
                                log::info!(
                                    "INBOUND iMessage id={} sender={:?}",
                                    inst.id,
                                    inst.sender
                                );
                            }
                            Ok(None) => {}
                            Err(err) => log::warn!("handle error: {err}"),
                        },
                        Err(RecvError::Lagged(n)) => log::warn!("lagged {n} messages"),
                        Err(RecvError::Closed) => {
                            log::warn!("APS channel closed — exiting repl");
                            break;
                        }
                    }
                }
                line = stdin.next_line() => {
                    match line? {
                        None => break,
                        Some(line) => {
                            let line = line.trim();
                            if line.is_empty() {
                                continue;
                            }
                            if let Some(rest) = line.strip_prefix("send ") {
                                let Some((to, body)) = rest.split_once(' ') else {
                                    log::warn!("usage: send <to> <message>");
                                    continue;
                                };
                                if let Err(err) = self.send_text(to, body).await {
                                    log::error!("send failed: {err:#}");
                                    log::error!("if validation expired, refresh then restart repl");
                                }
                            } else {
                                log::warn!("unknown command (try: send +1... hello)");
                            }
                        }
                    }
                }
            }
        }
        Ok(())
    }
}

pub async fn login(
    state_dir: &SpikeStateDir,
    apple_id: &str,
    password: &str,
    mut options: LoginOptions,
) -> Result<()> {
    let session = connect_aps(state_dir).await?;
    login_flow(
        &session.state_dir,
        &session.config,
        &session.conn,
        apple_id,
        password,
        &mut options,
    )
    .await?;
    Ok(())
}

pub async fn refresh_login(state_dir: &SpikeStateDir, mut options: LoginOptions) -> Result<()> {
    let session = connect_aps(state_dir).await?;
    refresh_login_from_gsa(
        &session.state_dir,
        &session.config,
        &session.conn,
        &mut options,
    )
    .await?;
    Ok(())
}

async fn make_imclient(
    state_dir: &SpikeStateDir,
    conn: &rustpush::APSConnection,
    users: &[rustpush::IDSUser],
    identity: &IDSNGMIdentity,
) -> Result<Arc<IMClient>> {
    let id_path = state_dir.root.join("id.plist");
    let cache_path = state_dir.id_cache_path();
    let id_path_clone = id_path.clone();
    Ok(Arc::new(
        IMClient::new(
            conn.clone(),
            users.to_vec(),
            identity.clone(),
            &[
                &MADRID_SERVICE,
                &MULTIPLEX_SERVICE,
                &FACETIME_SERVICE,
                &VIDEO_SERVICE,
            ],
            cache_path,
            conn.os_config.clone(),
            Box::new(move |updated_keys| {
                if let Ok(xml) = plist_to_string(&updated_keys) {
                    let _ = std::fs::write(&id_path_clone, xml);
                }
            }),
        )
        .await,
    ))
}

pub async fn persist_push_state(state_dir: &SpikeStateDir, connected: &Connected) -> Result<()> {
    let push = connected.conn.state.read().await.clone();
    state_dir.save_hardware(&push, &connected.identity, &connected.config)
}

/// Auth / registration health check (connect briefly, probe identity resource).
pub async fn doctor(state_dir: &SpikeStateDir) -> Result<()> {
    use std::path::Path;

    let mut healthy = true;

    let check = |path: &Path, label: &str| {
        if path.is_file() {
            log::info!("ok  {label}");
            true
        } else {
            log::error!("MISSING {label}");
            false
        }
    };

    log::info!("state dir: {}", state_dir.root.display());

    for (name, path) in [
        ("hw_info.plist", state_dir.root.join("hw_info.plist")),
        ("id.plist", state_dir.root.join("id.plist")),
        ("keystore.plist", state_dir.keystore_path()),
        ("gsa.plist", state_dir.root.join("gsa.plist")),
        ("validation.json", state_dir.root.join("validation.json")),
    ] {
        if !check(&path, name) {
            healthy = false;
        }
    }

    let val_path = state_dir.root.join("validation.json");
    if val_path.is_file() {
        if let Ok(text) = std::fs::read_to_string(&val_path) {
            if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(vu) = payload.get("valid_until").and_then(|v| v.as_str()) {
                    log::info!("validation valid_until: {vu}");
                } else {
                    log::warn!("validation.json has no valid_until");
                }
            }
        }
    }

    let users = match state_dir.load_users() {
        Ok(users) => users,
        Err(e) => {
            log::error!("id.plist: {e:#}");
            anyhow::bail!("doctor found issues");
        }
    };

    if users.is_empty() {
        log::error!("no IDS users in id.plist — run login");
        healthy = false;
    } else {
        log::info!("IDS users: {}", users.len());
        for user in &users {
            let cert_len = user.auth_keypair.cert.len();
            log::info!(
                "  user {} auth cert: {} bytes",
                user.user_id,
                cert_len
            );
            if cert_len == 0 {
                log::error!("  auth_keypair cert empty — run login");
                healthy = false;
            }
            if let Some(madrid) = user.registration.get("com.apple.madrid") {
                let handles = &madrid.handles;
                if handles.is_empty() {
                    log::warn!("  com.apple.madrid: no handles (run register)");
                } else {
                    log::info!("  com.apple.madrid handles: {}", handles.join(", "));
                }
            } else {
                log::warn!("  com.apple.madrid: not registered");
            }
        }
    }

    if !healthy {
        anyhow::bail!("doctor found issues");
    }

    log::info!("connecting briefly to probe identity resource…");
    let connected = connect(state_dir).await?;
    match connected.wait_identity_ready().await {
        Ok(()) => log::info!("identity: ready (outbound send should work)"),
        Err(e) => {
            log::error!("identity: {e:#}");
            log::error!("fix: login → refresh validation → register (see poc-recover-auth.sh)");
            anyhow::bail!("doctor found issues");
        }
    }
    // Avoid rustpush APSInterestToken drop panic when the tokio runtime shuts down.
    std::mem::forget(connected);
    Ok(())
}
