use std::collections::VecDeque;
use std::path::Path;
use std::sync::Arc;

use anyhow::{Context, Result};
use chrono::Utc;
use kappy_spike::engine::{self, Connected};
use kappy_spike::keystore_setup;
use kappy_spike::login::LoginOptions;
use kappy_spike::state::SpikeStateDir;
use kappy_spike::validation::{self, NacServFetchConfig};
use rustpush::{Message, MessageInst, MessagePart};
use tokio::sync::{broadcast, Mutex, RwLock};
use tokio::task::JoinHandle;

use crate::config::LineConfig;
use crate::types::{ConnectionState, InboundMessage, LineFiles, LineStatus};

const MAX_INBOUND: usize = 500;

pub struct LineWorker {
    pub id: String,
    pub label: String,
    pub state_dir: SpikeStateDir,
    connected: Arc<RwLock<Option<Arc<Connected>>>>,
    messages: Arc<RwLock<VecDeque<InboundMessage>>>,
    listen_task: Mutex<Option<JoinHandle<()>>>,
    enabled: bool,
    events: Option<tokio::sync::broadcast::Sender<InboundMessage>>,
}

impl LineWorker {
    pub fn new(cfg: &LineConfig) -> Self {
        Self {
            id: cfg.id.clone(),
            label: cfg.label.clone(),
            state_dir: SpikeStateDir::new(&cfg.state_dir),
            connected: Arc::new(RwLock::new(None)),
            messages: Arc::new(RwLock::new(VecDeque::new())),
            listen_task: Mutex::new(None),
            enabled: cfg.enabled,
            events: None,
        }
    }

    pub fn with_events(mut self, events: tokio::sync::broadcast::Sender<InboundMessage>) -> Self {
        self.events = Some(events);
        self
    }

    pub async fn is_online(&self) -> bool {
        self.connected.read().await.is_some()
    }

    pub async fn bootstrap(&self) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        self.state_dir.ensure()?;
        keystore_setup::init(&self.state_dir)?;
        if validation::load_persisted_validation(&self.state_dir.root).await? {
            log::debug!("line {} loaded validation.json", self.id);
        }
        self.try_connect().await;
        Ok(())
    }

    pub async fn try_connect(&self) {
        if !self.files().hw_info {
            return;
        }
        match engine::connect(&self.state_dir).await {
            Ok(conn) => {
                let arc = Arc::new(conn);
                *self.connected.write().await = Some(arc.clone());
                self.spawn_listen(arc).await;
                log::info!("line {} connected", self.id);
            }
            Err(err) => {
                log::warn!("line {} offline: {err:#}", self.id);
                *self.connected.write().await = None;
            }
        }
    }

    async fn spawn_listen(&self, connected: Arc<Connected>) {
        let mut guard = self.listen_task.lock().await;
        if guard.is_some() {
            return;
        }
        let line_id = self.id.clone();
        let messages = self.messages.clone();
        let connected_weak = self.connected.clone();
        let events = self.events.clone();
        let mut rx = connected.conn.messages_cont.subscribe();

        let handle = tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(aps_msg) => match connected.client.handle(aps_msg).await {
                        Ok(Some(inst)) => {
                            let inbound = inst_to_inbound(&line_id, &inst);
                            if let Some(tx) = &events {
                                let _ = tx.send(inbound.clone());
                            }
                            let mut buf = messages.write().await;
                            buf.push_back(inbound);
                            while buf.len() > MAX_INBOUND {
                                buf.pop_front();
                            }
                            log::info!(
                                "line {line_id} inbound id={} sender={:?}",
                                inst.id,
                                inst.sender
                            );
                        }
                        Ok(None) => {}
                        Err(err) => log::warn!("line {line_id} handle error: {err}"),
                    },
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("line {line_id} lagged {n} messages");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        log::warn!("line {line_id} APS channel closed");
                        *connected_weak.write().await = None;
                        break;
                    }
                }
            }
        });
        *guard = Some(handle);
    }

    pub fn files(&self) -> LineFiles {
        let root = &self.state_dir.root;
        LineFiles {
            hw_info: root.join("hw_info.plist").is_file(),
            id_plist: root.join("id.plist").is_file(),
            gsa: root.join("gsa.plist").is_file(),
            keystore: self.state_dir.keystore_path().is_file(),
            validation: root.join("validation.json").is_file(),
        }
    }

    pub fn connection_state(&self, online: bool) -> ConnectionState {
        if !self.files().hw_info {
            ConnectionState::NotActivated
        } else if online {
            ConnectionState::Online
        } else {
            ConnectionState::Offline
        }
    }

    pub async fn status(&self) -> LineStatus {
        let online = self.connected.read().await.is_some();
        let handles = self.registered_handles().await;
        let (validation_valid_until, validation_seconds_remaining) = validation_meta(&self.state_dir);
        LineStatus {
            id: self.id.clone(),
            label: self.label.clone(),
            state_dir: self.state_dir.root.display().to_string(),
            enabled: self.enabled,
            connection: self.connection_state(online),
            handles,
            validation_valid_until,
            validation_seconds_remaining,
            files: self.files(),
        }
    }

    async fn registered_handles(&self) -> Vec<String> {
        match self.state_dir.load_users() {
            Ok(users) => users
                .first()
                .and_then(|u| u.registration.get("com.apple.madrid"))
                .map(|r| r.handles.clone())
                .unwrap_or_default(),
            Err(_) => vec![],
        }
    }

    pub async fn list_messages(&self, limit: usize) -> Vec<InboundMessage> {
        let buf = self.messages.read().await;
        let start = buf.len().saturating_sub(limit);
        buf.range(start..).cloned().collect()
    }

    pub async fn send_text(&self, to: &str, body: &str) -> Result<String> {
        let conn = self
            .connected
            .read()
            .await
            .clone()
            .context("line offline — run lifecycle/register or check validation")?;
        conn.send_text(to, body).await?;
        Ok(format!("sent-{}", chrono::Utc::now().timestamp()))
    }

    pub async fn activate(&self, hw_export: &Path) -> Result<()> {
        engine::activate_from_hw_file(&self.state_dir, hw_export).await?;
        self.try_connect().await;
        Ok(())
    }

    pub async fn login(&self, apple_id: &str, password: &str, two_fa_code: Option<String>) -> Result<()> {
        engine::login(
            &self.state_dir,
            apple_id,
            password,
            LoginOptions { two_fa_code },
        )
        .await?;
        self.try_connect().await;
        Ok(())
    }

    pub async fn register(&self) -> Result<()> {
        let mut connected = engine::connect(&self.state_dir).await?;
        connected.register_ids().await?;
        engine::persist_push_state(&self.state_dir, &connected).await?;
        let arc = Arc::new(connected);
        *self.connected.write().await = Some(arc.clone());
        self.spawn_listen(arc).await;
        Ok(())
    }

    pub async fn refresh_validation(
        &self,
        repo_root: &Path,
        nacserv_url: &str,
        nacserv_token: &str,
    ) -> Result<()> {
        if !nacserv_url.is_empty() && !nacserv_token.is_empty() {
            let cfg = NacServFetchConfig {
                url: nacserv_url.to_string(),
                token: nacserv_token.to_string(),
            };
            validation::fetch_nacserv_and_persist(&self.state_dir.root, &cfg).await?;
        } else {
            let pilot = repo_root.join("validation-pilot.json");
            let text = std::fs::read_to_string(&pilot)
                .with_context(|| format!("read {}", pilot.display()))?;
            validation::persist_validation_json(&self.state_dir.root, &text).await?;
        }
        self.try_connect().await;
        Ok(())
    }

    pub async fn run_validation_refresh_script(
        repo_root: &Path,
        line_id: &str,
        capture: bool,
    ) -> Result<()> {
        let script = repo_root.join("scripts/poc-refresh-validation.sh");
        let mut cmd = tokio::process::Command::new(&script);
        cmd.arg(line_id).current_dir(repo_root);
        if capture {
            cmd.arg("--capture");
        }
        let output = cmd
            .output()
            .await
            .with_context(|| format!("run {}", script.display()))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            anyhow::bail!(
                "validation refresh script failed (exit {:?}): {stdout}{stderr}",
                output.status.code()
            );
        }
        Ok(())
    }

    pub async fn recover_auth(
        &self,
        repo_root: &Path,
        nacserv_url: &str,
        nacserv_token: &str,
        capture: bool,
        apple_id: &str,
        password: &str,
        two_fa_code: Option<String>,
    ) -> Result<()> {
        if capture {
            Self::run_validation_refresh_script(repo_root, &self.id, true).await?;
        } else {
            self.refresh_validation(repo_root, nacserv_url, nacserv_token)
                .await?;
        }
        self.login(apple_id, password, two_fa_code).await?;
        self.register().await?;
        Ok(())
    }

    pub async fn doctor_details(&self) -> (bool, Vec<String>) {
        let mut lines = Vec::new();
        let files = self.files();
        lines.push(format!("hw_info: {}", files.hw_info));
        lines.push(format!("id.plist: {}", files.id_plist));
        lines.push(format!("gsa.plist: {}", files.gsa));
        lines.push(format!("keystore: {}", files.keystore));
        lines.push(format!("validation: {}", files.validation));

        if let Ok(users) = self.state_dir.load_users() {
            for user in &users {
                lines.push(format!("user {} cert {} bytes", user.user_id, user.auth_keypair.cert.len()));
                if let Some(m) = user.registration.get("com.apple.madrid") {
                    lines.push(format!("handles: {}", m.handles.join(", ")));
                }
            }
        }

        let online = self.connected.read().await.is_some();
        lines.push(format!("connection: {:?}", self.connection_state(online)));

        if let Some(conn) = self.connected.read().await.clone() {
            match conn.wait_identity_ready().await {
                Ok(()) => lines.push("identity: ready".into()),
                Err(e) => {
                    lines.push(format!("identity: {e:#}"));
                    return (false, lines);
                }
            }
            return (true, lines);
        }

        if !files.hw_info {
            lines.push("not activated".into());
        } else {
            lines.push("offline — login/register/validation may be required".into());
        }
        (false, lines)
    }
}

fn inst_to_inbound(line_id: &str, inst: &MessageInst) -> InboundMessage {
    let body = extract_body(&inst.message);
    InboundMessage {
        id: inst.id.clone(),
        line_id: line_id.to_string(),
        sender: inst.sender.clone(),
        body,
        received_at: Utc::now(),
    }
}

fn extract_body(msg: &Message) -> Option<String> {
    match msg {
        Message::Message(nm) => {
            let mut texts = Vec::new();
            for indexed in &nm.parts.0 {
                if let MessagePart::Text(t, _) = &indexed.part {
                    texts.push(t.clone());
                }
            }
            if texts.is_empty() {
                None
            } else {
                Some(texts.join(""))
            }
        }
        _ => None,
    }
}

fn validation_meta(state_dir: &SpikeStateDir) -> (Option<String>, Option<i64>) {
    let path = state_dir.root.join("validation.json");
    let Ok(text) = std::fs::read_to_string(path) else {
        return (None, None);
    };
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(&text) else {
        return (None, None);
    };
    let Some(vu) = payload
        .get("valid_until")
        .and_then(|v| v.as_str())
        .map(str::to_string)
    else {
        return (None, None);
    };
    let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&vu.replace('Z', "+00:00")) else {
        return (Some(vu), None);
    };
    let secs = (dt.with_timezone(&Utc) - Utc::now()).num_seconds();
    (Some(vu), Some(secs))
}
