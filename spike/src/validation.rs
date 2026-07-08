use std::sync::Arc;

use anyhow::Result;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

/// Matches Beeper `mac-registration-provider -once` JSON and submit payloads.
#[derive(Debug, Deserialize, Serialize)]
pub struct ValidationPayload {
    #[serde(deserialize_with = "deserialize_validation_data")]
    pub validation_data: Vec<u8>,
    #[serde(default)]
    pub valid_until: Option<String>,
    #[serde(default)]
    pub nacserv_commit: Option<String>,
}

fn deserialize_validation_data<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::{self, Visitor};
    use std::fmt;

    struct ValidationDataVisitor;

    impl<'de> Visitor<'de> for ValidationDataVisitor {
        type Value = Vec<u8>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("base64 string or byte array")
        }

        fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            base64::engine::general_purpose::STANDARD
                .decode(value.trim())
                .map_err(E::custom)
        }

        fn visit_bytes<E>(self, value: &[u8]) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(value.to_vec())
        }

        fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
        where
            A: de::SeqAccess<'de>,
        {
            let mut out = Vec::new();
            while let Some(byte) = seq.next_element()? {
                out.push(byte);
            }
            Ok(out)
        }
    }

    deserializer.deserialize_any(ValidationDataVisitor)
}

#[derive(Clone)]
pub struct ValidationStore {
    inner: Arc<RwLock<Option<Vec<u8>>>>,
}

impl ValidationStore {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(None)),
        }
    }

    pub async fn set(&self, bytes: Vec<u8>) {
        *self.inner.write().await = Some(bytes);
    }

    pub async fn get(&self) -> Option<Vec<u8>> {
        self.inner.read().await.clone()
    }
}

static STORE: std::sync::OnceLock<ValidationStore> = std::sync::OnceLock::new();

pub fn shared_store() -> ValidationStore {
    STORE.get_or_init(ValidationStore::new).clone()
}

pub async fn load_validation_json(path: &std::path::Path) -> Result<()> {
    let text = std::fs::read_to_string(path)?;
    ingest_validation_json(&text).await
}

pub async fn persist_validation_json(state_dir: &std::path::Path, text: &str) -> Result<()> {
    let payload: ValidationPayload = serde_json::from_str(text).map_err(|e| {
        anyhow::anyhow!(
            "validation file is not valid JSON (expected {{\"validation_data\":\"...\"}}): {e}"
        )
    })?;
    std::fs::create_dir_all(state_dir)?;
    std::fs::write(state_dir.join("validation.json"), text)?;
    shared_store().set(payload.validation_data).await;
    Ok(())
}

pub async fn load_persisted_validation(state_dir: &std::path::Path) -> Result<bool> {
    let path = state_dir.join("validation.json");
    if !path.exists() {
        return Ok(false);
    }
    load_validation_json(&path).await?;
    Ok(true)
}

pub async fn ingest_validation_json(text: &str) -> Result<()> {
    let payload: ValidationPayload = serde_json::from_str(text)?;
    shared_store().set(payload.validation_data).await;
    Ok(())
}

pub async fn ingest_validation_base64(b64: &str) -> Result<()> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64.trim())?;
    shared_store().set(bytes).await;
    Ok(())
}

/// Beeper registration-relay bridge response (`POST /api/v1/bridge/get-validation-data`).
#[derive(Debug, Deserialize)]
struct RelayValidationResponse {
    data: String,
}

#[derive(Clone, Debug)]
pub struct RelayFetchConfig {
    pub host: String,
    pub code: String,
    pub beeper_token: Option<String>,
}

pub async fn fetch_relay_validation(cfg: &RelayFetchConfig) -> Result<Vec<u8>> {
    let host = cfg.host.trim_end_matches('/');
    let url = format!("{host}/api/v1/bridge/get-validation-data");
    let mut req = reqwest::Client::new()
        .post(url)
        .bearer_auth(&cfg.code)
        .header("Content-Length", "0");
    if let Some(token) = &cfg.beeper_token {
        req = req.header("X-Beeper-Access-Token", token);
    }

    let resp = req.send().await?;
    let status = resp.status();
    let body = resp.text().await?;
    if !status.is_success() {
        anyhow::bail!("relay returned {status}: {body}");
    }

    let parsed: RelayValidationResponse = serde_json::from_str(&body)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(parsed.data.trim())
        .map_err(|e| anyhow::anyhow!("relay data is not valid base64: {e}"))?;
    if bytes.is_empty() {
        anyhow::bail!("relay returned empty validation data");
    }
    Ok(bytes)
}

pub fn validation_payload_json(bytes: &[u8], source: &str) -> Result<String> {
    let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
    let payload = serde_json::json!({
        "validation_data": b64,
        "nacserv_commit": source,
    });
    Ok(serde_json::to_string(&payload)?)
}

pub async fn fetch_relay_and_persist(
    state_dir: &std::path::Path,
    cfg: &RelayFetchConfig,
    source: &str,
) -> Result<()> {
    let bytes = fetch_relay_validation(cfg).await?;
    let text = validation_payload_json(&bytes, source)?;
    persist_validation_json(state_dir, &text).await?;
    log::info!("fetched {} bytes of validation data from relay", bytes.len());
    Ok(())
}

pub async fn relay_refresh_loop(
    state_dir: std::path::PathBuf,
    cfg: RelayFetchConfig,
    interval: std::time::Duration,
) -> Result<()> {
    loop {
        match fetch_relay_and_persist(&state_dir, &cfg, "registration-relay").await {
            Ok(()) => {}
            Err(err) => log::error!("relay validation refresh failed: {err:#}"),
        }
        tokio::time::sleep(interval).await;
    }
}

/// Beeper direct nacserv response (`GET /` with bearer token).
#[derive(Debug, Deserialize)]
struct NacServDirectResponse {
    #[serde(default, deserialize_with = "deserialize_validation_data")]
    data: Vec<u8>,
    #[serde(default)]
    error: String,
}

#[derive(Clone, Debug)]
pub struct NacServFetchConfig {
    pub url: String,
    pub token: String,
}

pub async fn fetch_nacserv_validation(cfg: &NacServFetchConfig) -> Result<Vec<u8>> {
    let url = cfg.url.trim_end_matches('/');
    let resp = reqwest::Client::new()
        .get(url)
        .bearer_auth(&cfg.token)
        .send()
        .await?;
    let status = resp.status();
    let body = resp.text().await?;
    if !status.is_success() {
        anyhow::bail!("nacserv returned {status}: {body}");
    }
    let parsed: NacServDirectResponse = serde_json::from_str(&body)?;
    if !parsed.error.is_empty() {
        anyhow::bail!("nacserv error: {}", parsed.error);
    }
    if parsed.data.is_empty() {
        anyhow::bail!("nacserv returned empty validation data");
    }
    Ok(parsed.data)
}

pub async fn fetch_nacserv_and_persist(state_dir: &std::path::Path, cfg: &NacServFetchConfig) -> Result<()> {
    let bytes = fetch_nacserv_validation(cfg).await?;
    let text = validation_payload_json(&bytes, "kappy-nacserv")?;
    persist_validation_json(state_dir, &text).await?;
    log::info!("fetched {} bytes of validation data from nacserv", bytes.len());
    Ok(())
}

pub async fn nacserv_refresh_loop(
    state_dir: std::path::PathBuf,
    cfg: NacServFetchConfig,
    interval: std::time::Duration,
) -> Result<()> {
    loop {
        match fetch_nacserv_and_persist(&state_dir, &cfg).await {
            Ok(()) => {}
            Err(err) => log::error!("nacserv validation refresh failed: {err:#}"),
        }
        tokio::time::sleep(interval).await;
    }
}

pub mod http {
    use std::net::SocketAddr;

    use anyhow::Result;
    use axum::{routing::post, Json, Router};

    use super::ValidationPayload;

    async fn post_validation(Json(body): Json<serde_json::Value>) -> &'static str {
        if let Ok(payload) = serde_json::from_value::<ValidationPayload>(body.clone()) {
            super::shared_store()
                .set(payload.validation_data)
                .await;
        }
        if let Ok(text) = serde_json::to_string(&body) {
            if let Ok(state_dir) = std::env::var("KAPPY_SPIKE_STATE_DIR") {
                let _ = super::persist_validation_json(std::path::Path::new(&state_dir), &text).await;
            } else {
                let _ = super::ingest_validation_json(&text).await;
            }
        }
        "ok"
    }

    pub async fn serve(addr: SocketAddr) -> Result<()> {
        let app = Router::new().route("/internal/validation", post(post_validation));
        let listener = tokio::net::TcpListener::bind(addr).await?;
        log::info!("validation ingest listening on http://{addr}/internal/validation");
        axum::serve(listener, app).await?;
        Ok(())
    }
}
