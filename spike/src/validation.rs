use std::sync::Arc;

use anyhow::Result;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

/// Matches Beeper `mac-registration-provider -once` JSON and submit payloads.
#[derive(Debug, Deserialize, Serialize)]
pub struct ValidationPayload {
    pub validation_data: Vec<u8>,
    #[serde(default)]
    pub valid_until: Option<String>,
    #[serde(default)]
    pub nacserv_commit: Option<String>,
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
            return "ok";
        }
        if let Ok(text) = serde_json::to_string(&body) {
            let _ = super::ingest_validation_json(&text).await;
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
