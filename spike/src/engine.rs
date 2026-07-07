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
use crate::login::login_flow;
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

    let (conn, push_err) =
        APSConnectionResource::new(config.as_ref() as &dyn OSConfig, None).await;
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

pub async fn connect(state_dir: &SpikeStateDir) -> Result<Connected> {
    let (saved, config, identity) = state_dir.load_hardware()?;
    let (conn, push_err) = APSConnectionResource::new(
        config.as_ref() as &dyn OSConfig,
        Some(saved.push),
    )
    .await;
    if let Some(err) = push_err {
        log::warn!("APS reconnect warning: {err}");
    }

    let users = state_dir.load_users().unwrap_or_default();
    let client = make_imclient(state_dir, &conn, &users, &identity).await?;
    Ok(Connected {
        state_dir: state_dir.clone(),
        config,
        identity,
        conn,
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

    pub async fn send_text(&self, to: &str, body: &str) -> Result<()> {
        let handle = normalize_recipient(to);
        let mut msg = MessageInst::new(
            ConversationData {
                participants: vec![handle.clone()],
                cv_name: None,
                sender_guid: None,
                after_guid: None,
            },
            &handle,
            Message::Message(NormalMessage::new(body.to_string(), MessageType::IMessage)),
        );
        self.client
            .send(&mut msg)
            .await
            .map_err(|e| anyhow::anyhow!("send failed: {e}"))?;
        log::info!("sent message id={} to {handle}", msg.id);
        Ok(())
    }

    pub async fn listen(&self) -> Result<()> {
        let mut rx = self.conn.messages_cont.subscribe();
        log::info!("listening for inbound APS messages (Ctrl+C to stop)…");
        loop {
            match rx.recv().await {
                Ok(aps_msg) => match self.client.handle(aps_msg).await {
                    Ok(Some(inst)) => {
                        log::info!("INBOUND iMessage: {:?}", inst);
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
}

pub async fn login(state_dir: &SpikeStateDir, apple_id: &str, password: &str) -> Result<()> {
    let mut connected = connect(state_dir).await?;
    let users = login_flow(
        &connected.state_dir,
        &connected.config,
        &connected.conn,
        apple_id,
        password,
    )
    .await?;
    connected.users = users;
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

pub fn persist_push_state(state_dir: &SpikeStateDir, connected: &Connected) -> Result<()> {
    let push = connected.conn.state.read().await.clone();
    state_dir.save_hardware(&push, &connected.identity, &connected.config)
}
