use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
pub struct LineStatus {
    pub id: String,
    pub label: String,
    pub state_dir: String,
    pub enabled: bool,
    pub connection: ConnectionState,
    pub handles: Vec<String>,
    pub validation_valid_until: Option<String>,
    pub validation_seconds_remaining: Option<i64>,
    pub files: LineFiles,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    Online,
    Offline,
    NotActivated,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct LineFiles {
    pub hw_info: bool,
    pub id_plist: bool,
    pub gsa: bool,
    pub keystore: bool,
    pub validation: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct InboundMessage {
    pub id: String,
    pub line_id: String,
    pub sender: Option<String>,
    pub body: Option<String>,
    pub received_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SendMessageRequest {
    pub to: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SendMessageResponse {
    pub ok: bool,
    pub message_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LoginRequest {
    pub apple_id: String,
    pub password: String,
    #[serde(default)]
    pub two_fa_code: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RecoverRequest {
    #[serde(default)]
    pub capture: bool,
    pub apple_id: Option<String>,
    pub password: Option<String>,
    #[serde(default)]
    pub two_fa_code: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LifecycleResponse {
    pub ok: bool,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct DoctorResponse {
    pub ok: bool,
    pub details: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HealthResponse {
    pub ok: bool,
    pub version: &'static str,
    pub lines_online: usize,
    pub lines_total: usize,
}

pub fn new_event_id() -> String {
    Uuid::new_v4().to_string()
}
