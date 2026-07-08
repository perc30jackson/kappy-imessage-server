use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    middleware,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use tower_http::services::{ServeDir, ServeFile};

use serde::Deserialize;

use crate::config::FleetConfig;
use crate::config;
use crate::line::LineWorker;
use crate::types::{
    DoctorResponse, HealthResponse, InboundMessage, LifecycleResponse, LineStatus, LoginRequest,
    RecoverRequest, SendMessageRequest, SendMessageResponse,
};

#[derive(Clone)]
pub struct AppState {
    pub repo_root: PathBuf,
    pub config: Arc<FleetConfig>,
    pub lines: Arc<HashMap<String, Arc<LineWorker>>>,
    pub events: tokio::sync::broadcast::Sender<InboundMessage>,
}

#[derive(Deserialize)]
pub struct MessagesQuery {
    #[serde(default = "default_limit")]
    limit: usize,
}

fn default_limit() -> usize {
    50
}

pub fn router(state: AppState, api_token: String) -> Router {
    let static_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("static");

    let health = Router::new()
        .route("/health", get(health))
        .with_state(state.clone());

    let api = Router::new()
        .route("/v1/lines", get(list_lines))
        .route("/v1/lines/:id", get(get_line))
        .route("/v1/lines/:id/messages", get(list_messages).post(send_message))
        .route("/v1/lines/:id/doctor", get(doctor))
        .route("/v1/lines/:id/lifecycle/activate", post(lifecycle_activate))
        .route("/v1/lines/:id/lifecycle/login", post(lifecycle_login))
        .route("/v1/lines/:id/lifecycle/register", post(lifecycle_register))
        .route(
            "/v1/lines/:id/lifecycle/refresh-validation",
            post(lifecycle_refresh_validation),
        )
        .route(
            "/v1/lines/:id/lifecycle/capture-validation",
            post(lifecycle_capture_validation),
        )
        .route(
            "/v1/lines/:id/lifecycle/recover-auth",
            post(lifecycle_recover_auth),
        )
        .layer(middleware::from_fn({
            let token = api_token;
            move |headers: axum::http::HeaderMap,
                  request: axum::extract::Request,
                  next: middleware::Next| {
                let token = token.clone();
                async move {
                    if !token.is_empty() && token != "change-me-in-production" {
                        let auth = headers
                            .get(axum::http::header::AUTHORIZATION)
                            .and_then(|v| v.to_str().ok())
                            .unwrap_or("");
                        let provided = auth.strip_prefix("Bearer ").unwrap_or("");
                        if provided != token {
                            return axum::http::StatusCode::UNAUTHORIZED.into_response();
                        }
                    }
                    next.run(request).await
                }
            }
        }))
        .with_state(state);

    let ui = ServeDir::new(&static_dir)
        .not_found_service(ServeFile::new(static_dir.join("index.html")));

    Router::new()
        .merge(health)
        .merge(api)
        .fallback_service(ui)
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let mut online = 0usize;
    for worker in state.lines.values() {
        if worker.is_online().await {
            online += 1;
        }
    }
    Json(HealthResponse {
        ok: true,
        version: env!("CARGO_PKG_VERSION"),
        lines_online: online,
        lines_total: state.lines.len(),
    })
}

async fn list_lines(State(state): State<AppState>) -> Result<Json<Vec<LineStatus>>, ApiError> {
    let mut out = Vec::new();
    for worker in state.lines.values() {
        out.push(worker.status().await);
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(Json(out))
}

async fn get_line(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<LineStatus>, ApiError> {
    let worker = line(&state, &id)?;
    Ok(Json(worker.status().await))
}

async fn list_messages(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<MessagesQuery>,
) -> Result<Json<Vec<InboundMessage>>, ApiError> {
    let worker = line(&state, &id)?;
    Ok(Json(worker.list_messages(q.limit).await))
}

async fn send_message(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<SendMessageRequest>,
) -> Result<Json<SendMessageResponse>, ApiError> {
    let worker = line(&state, &id)?;
    let msg_id = worker.send_text(&req.to, &req.body).await?;
    Ok(Json(SendMessageResponse {
        ok: true,
        message_id: Some(msg_id),
    }))
}

async fn doctor(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<DoctorResponse>, ApiError> {
    let worker = line(&state, &id)?;
    let (ok, details) = worker.doctor_details().await;
    Ok(Json(DoctorResponse { ok, details }))
}

async fn lifecycle_activate(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<LifecycleResponse>, ApiError> {
    let worker = line(&state, &id)?;
    let hw = PathBuf::from(&state.config.api.hw_export);
    worker.activate(&hw).await?;
    Ok(Json(LifecycleResponse {
        ok: true,
        message: format!("activated line {id} from {}", hw.display()),
    }))
}

async fn lifecycle_login(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<LoginRequest>,
) -> Result<Json<LifecycleResponse>, ApiError> {
    let worker = line(&state, &id)?;
    worker
        .login(&req.apple_id, &req.password, req.two_fa_code)
        .await?;
    Ok(Json(LifecycleResponse {
        ok: true,
        message: format!("login OK for {}", req.apple_id),
    }))
}

async fn lifecycle_register(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<LifecycleResponse>, ApiError> {
    let worker = line(&state, &id)?;
    worker.register().await?;
    Ok(Json(LifecycleResponse {
        ok: true,
        message: format!("register OK for line {id}"),
    }))
}

async fn lifecycle_refresh_validation(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<LifecycleResponse>, ApiError> {
    let worker = line(&state, &id)?;
    worker
        .refresh_validation(
            &state.repo_root,
            &state.config.api.nacserv_url,
            &state.config.api.nacserv_token,
        )
        .await?;
    Ok(Json(LifecycleResponse {
        ok: true,
        message: "validation refreshed".into(),
    }))
}

async fn lifecycle_capture_validation(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<LifecycleResponse>, ApiError> {
    line(&state, &id)?;
    LineWorker::run_validation_refresh_script(&state.repo_root, &id, true).await?;
    let worker = line(&state, &id)?;
    worker.try_connect().await;
    Ok(Json(LifecycleResponse {
        ok: true,
        message: "validation captured via lldb — toggle iMessage in Messages if prompted".into(),
    }))
}

async fn lifecycle_recover_auth(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<RecoverRequest>,
) -> Result<Json<LifecycleResponse>, ApiError> {
    let worker = line(&state, &id)?;
    let (env_apple_id, env_password) =
        config::load_line_credentials(&state.repo_root, &id);
    let apple_id = req
        .apple_id
        .or(env_apple_id)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ApiError::bad_request("apple_id required (form or poc/lines/line-N.env)"))?;
    let password = req
        .password
        .or(env_password)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ApiError::bad_request("password required (form or poc/lines/line-N.env)")
        })?;

    worker
        .recover_auth(
            &state.repo_root,
            &state.config.api.nacserv_url,
            &state.config.api.nacserv_token,
            req.capture,
            &apple_id,
            &password,
            req.two_fa_code,
        )
        .await?;

    Ok(Json(LifecycleResponse {
        ok: true,
        message: format!("auth recovery complete for line {id} ({apple_id})"),
    }))
}

fn line(state: &AppState, id: &str) -> Result<Arc<LineWorker>, ApiError> {
    state
        .lines
        .get(id)
        .cloned()
        .ok_or_else(|| ApiError::not_found(format!("line {id} not configured")))
}

pub async fn build_state(repo_root: PathBuf, config: FleetConfig) -> Result<AppState> {
    let (events, _) = tokio::sync::broadcast::channel(256);
    let mut lines = HashMap::new();
    for line_cfg in &config.lines {
        if !line_cfg.enabled {
            continue;
        }
        let worker = Arc::new(
            LineWorker::new(line_cfg).with_events(events.clone()),
        );
        worker.bootstrap().await?;
        lines.insert(line_cfg.id.clone(), worker);
    }
    Ok(AppState {
        repo_root,
        config: Arc::new(config),
        lines: Arc::new(lines),
        events,
    })
}

#[derive(Debug)]
pub struct ApiError(anyhow::Error);

impl ApiError {
    fn not_found(msg: impl Into<String>) -> Self {
        Self(anyhow::anyhow!(msg.into()))
    }

    fn bad_request(msg: impl Into<String>) -> Self {
        Self(anyhow::anyhow!(msg.into()))
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        Self(e)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let msg = format!("{:#}", self.0);
        let status = if msg.contains("not configured") {
            StatusCode::NOT_FOUND
        } else if msg.contains("required") {
            StatusCode::BAD_REQUEST
        } else {
            StatusCode::BAD_REQUEST
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}
