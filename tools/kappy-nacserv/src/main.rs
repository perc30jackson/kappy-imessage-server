use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use axum::{
    extract::State,
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::Engine;
use clap::Parser;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

/// Miniature NAC validation server (Beeper nacserv-compatible direct mode + kappy helpers).
#[derive(Parser)]
#[command(name = "kappy-nacserv")]
struct Cli {
    #[arg(long, env = "KAPPY_NACSERV_LISTEN", default_value = "127.0.0.1:8788")]
    listen: SocketAddr,

    /// Bearer token clients must send (`Authorization: Bearer …`).
    #[arg(long, env = "KAPPY_NACSERV_TOKEN")]
    token: Option<String>,

    /// Path to `kappy-nac-validation-provider` or `mac-registration-provider`.
    #[arg(long, env = "KAPPY_NAC_PROVIDER")]
    provider: Option<PathBuf>,

    /// Cache validation blobs until this many seconds before expiry.
    #[arg(long, default_value = "60")]
    refresh_skew_secs: u64,
}

/// Beeper `nacserv.Response` (direct GET).
#[derive(Debug, Serialize)]
struct NacServResponse {
    name: String,
    #[serde(with = "serde_base64")]
    data: Vec<u8>,
    valid_until: String,
    versions: HostVersions,
    #[serde(skip_serializing_if = "String::is_empty")]
    error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HostVersions {
    software_build_id: String,
    software_name: String,
    software_version: String,
    serial_number: String,
    hardware_version: String,
    unique_device_id: String,
}

mod serde_base64 {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        base64::engine::general_purpose::STANDARD
            .decode(s.trim())
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Deserialize)]
struct ProviderOnceJson {
    #[serde(deserialize_with = "serde_base64::deserialize")]
    validation_data: Vec<u8>,
}

#[derive(Clone)]
struct CachedValidation {
    data: Vec<u8>,
    valid_until: SystemTime,
}

#[derive(Clone)]
struct AppState {
    token: String,
    provider: PathBuf,
    refresh_skew: Duration,
    versions: HostVersions,
    cache: Arc<Mutex<Option<CachedValidation>>>,
    gen_lock: Arc<Mutex<()>>,
}

fn default_provider_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../nac-validation-provider/kappy-nac-validation-provider")
}

fn resolve_provider(path: Option<PathBuf>) -> Result<PathBuf> {
    let path = path.unwrap_or_else(default_provider_path);
    if path.is_file() {
        return Ok(path);
    }
    if which_provider("mac-registration-provider").is_ok() {
        return Ok(PathBuf::from("mac-registration-provider"));
    }
    anyhow::bail!(
        "NAC provider not found at {} (build tools/nac-validation-provider or install mac-registration-provider)",
        path.display()
    );
}

fn which_provider(name: &str) -> Result<PathBuf> {
    let output = std::process::Command::new("which")
        .arg(name)
        .output()
        .context("which")?;
    if !output.status.success() {
        anyhow::bail!("{name} not in PATH");
    }
    Ok(PathBuf::from(
        String::from_utf8(output.stdout)?.trim().to_string(),
    ))
}

fn read_token(cli: Option<String>) -> Result<String> {
    if let Some(token) = cli {
        return Ok(token);
    }
    let path = config_token_path()?;
    if path.exists() {
        let token = std::fs::read_to_string(&path)?.trim().to_string();
        if token.len() >= 16 {
            return Ok(token);
        }
    }
    let token = uuid::Uuid::new_v4().to_string();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, &token)?;
    log::info!("generated bearer token at {}", path.display());
    Ok(token)
}

fn config_token_path() -> Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME")?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("kappy-nacserv")
        .join("token"))
}

fn run_sw_vers(flag: &str) -> Result<String> {
    let output = std::process::Command::new("sw_vers")
        .arg(flag)
        .output()
        .with_context(|| format!("sw_vers {flag}"))?;
    if !output.status.success() {
        anyhow::bail!("sw_vers {flag} failed");
    }
    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

fn ioreg_field(key: &str) -> Option<String> {
    let output = std::process::Command::new("ioreg")
        .args(["-rd1", "-c", "IOPlatformExpertDevice"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if line.contains(key) {
            if let Some((_k, v)) = line.split_once('=') {
                return Some(v.trim().trim_matches('"').to_string());
            }
        }
    }
    None
}

fn detect_versions() -> HostVersions {
    HostVersions {
        software_build_id: run_sw_vers("-buildVersion").unwrap_or_else(|_| "unknown".into()),
        software_name: "MacOS".to_string(),
        software_version: run_sw_vers("-productVersion").unwrap_or_else(|_| "unknown".into()),
        serial_number: ioreg_field("IOPlatformSerialNumber").unwrap_or_else(|| "UNKNOWN".into()),
        hardware_version: std::process::Command::new("sysctl")
            .args(["-n", "hw.model"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|| "Mac".into()),
        unique_device_id: ioreg_field("IOPlatformUUID").unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
    }
}

fn rfc3339_utc(t: SystemTime) -> String {
    let secs = t
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs() as i64;
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m, d)
}

async fn spawn_provider_once(provider: &PathBuf) -> Result<Vec<u8>> {
    let output = tokio::process::Command::new(provider)
        .arg("-once")
        .env_remove("KAPPY_NAC_INIT")
        .env_remove("KAPPY_NAC_KEY_EST")
        .env_remove("KAPPY_NAC_SIGN")
        .output()
        .await
        .with_context(|| format!("spawn {}", provider.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("provider exited {}: {}", output.status, stderr.trim());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: ProviderOnceJson = serde_json::from_str(stdout.trim()).context("parse provider JSON")?;
    if parsed.validation_data.is_empty() {
        anyhow::bail!("provider returned empty validation_data");
    }
    Ok(parsed.validation_data)
}

async fn get_validation(state: &AppState) -> Result<CachedValidation> {
    if let Some(cached) = cache_fresh(state).await {
        return Ok(cached);
    }

    let _gen = state.gen_lock.lock().await;
    if let Some(cached) = cache_fresh(state).await {
        return Ok(cached);
    }

    log::info!("generating validation via {}", state.provider.display());
    let data = spawn_provider_once(&state.provider).await?;
    let cached = CachedValidation {
        data,
        valid_until: SystemTime::now() + Duration::from_secs(15 * 60),
    };
    *state.cache.lock().await = Some(cached.clone());
    Ok(cached)
}

async fn cache_fresh(state: &AppState) -> Option<CachedValidation> {
    let guard = state.cache.lock().await;
    let cached = guard.as_ref()?;
    match cached.valid_until.duration_since(SystemTime::now()) {
        Ok(remaining) if remaining > state.refresh_skew => Some(cached.clone()),
        _ => None,
    }
}

fn check_auth(headers: &HeaderMap, token: &str) -> Result<(), StatusCode> {
    let header = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if header != format!("Bearer {token}") {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(())
}

async fn health() -> &'static str {
    "ok"
}

async fn direct_nacserv(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<NacServResponse>, StatusCode> {
    check_auth(&headers, &state.token)?;
    match get_validation(&state).await {
        Ok(cached) => Ok(Json(NacServResponse {
            name: "kappy-nacserv".to_string(),
            data: cached.data,
            valid_until: rfc3339_utc(cached.valid_until),
            versions: state.versions.clone(),
            error: String::new(),
        })),
        Err(err) => {
            log::error!("validation generation failed: {err:#}");
            Ok(Json(NacServResponse {
                name: "kappy-nacserv".to_string(),
                data: Vec::new(),
                valid_until: rfc3339_utc(SystemTime::now()),
                versions: state.versions.clone(),
                error: err.to_string(),
            }))
        }
    }
}

async fn post_validation_data(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    check_auth(&headers, &state.token)?;
    let cached = get_validation(&state).await.map_err(|err| {
        log::error!("validation generation failed: {err:#}");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&cached.data);
    Ok((StatusCode::OK, b64).into_response())
}

#[derive(Serialize)]
struct RelayDataResp {
    data: String,
}

#[derive(Serialize)]
struct RelayVersionsResp {
    versions: HostVersions,
}

async fn relay_get_validation(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<RelayDataResp>, StatusCode> {
    check_auth(&headers, &state.token)?;
    let cached = get_validation(&state)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(RelayDataResp {
        data: base64::engine::general_purpose::STANDARD.encode(&cached.data),
    }))
}

async fn relay_get_versions(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<RelayVersionsResp>, StatusCode> {
    check_auth(&headers, &state.token)?;
    Ok(Json(RelayVersionsResp {
        versions: state.versions.clone(),
    }))
}

#[derive(Deserialize)]
struct KappyValidationPayload {
    #[serde(deserialize_with = "serde_base64::deserialize")]
    validation_data: Vec<u8>,
}

async fn post_internal_validation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<KappyValidationPayload>,
) -> Result<&'static str, StatusCode> {
    check_auth(&headers, &state.token)?;
    *state.cache.lock().await = Some(CachedValidation {
        data: body.validation_data,
        valid_until: SystemTime::now() + Duration::from_secs(15 * 60),
    });
    Ok("ok")
}

#[tokio::main]
async fn main() -> Result<()> {
    pretty_env_logger::init();
    let cli = Cli::parse();
    let provider = resolve_provider(cli.provider)?;
    let token = read_token(cli.token)?;

    let state = AppState {
        token: token.clone(),
        provider: provider.clone(),
        refresh_skew: Duration::from_secs(cli.refresh_skew_secs),
        versions: detect_versions(),
        cache: Arc::new(Mutex::new(None)),
        gen_lock: Arc::new(Mutex::new(())),
    };

    log::info!("provider: {}", provider.display());
    log::info!(
        "token: {}…{}",
        &token[..4.min(token.len())],
        &token[token.len().saturating_sub(4)..]
    );

    let app = Router::new()
        .route("/health", get(health))
        .route("/", get(direct_nacserv))
        .route("/validation-data", post(post_validation_data))
        .route("/api/v1/bridge/get-validation-data", post(relay_get_validation))
        .route("/api/v1/bridge/get-version-info", post(relay_get_versions))
        .route("/internal/validation", post(post_internal_validation))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(cli.listen).await?;
    log::info!("kappy-nacserv listening on http://{}", cli.listen);
    axum::serve(listener, app).await?;
    Ok(())
}
