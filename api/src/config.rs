use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct FleetConfig {
    pub api: ApiConfig,
    pub lines: Vec<LineConfig>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ApiConfig {
    #[serde(default = "default_listen")]
    pub listen: String,
    #[serde(default)]
    pub token: String,
    #[serde(default = "default_hw_export")]
    pub hw_export: String,
    #[serde(default)]
    pub nacserv_url: String,
    #[serde(default)]
    pub nacserv_token: String,
}

fn default_listen() -> String {
    "127.0.0.1:8080".to_string()
}

fn default_hw_export() -> String {
    "poc/shared/hw-export.bin".to_string()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LineConfig {
    pub id: String,
    #[serde(default)]
    pub label: String,
    pub state_dir: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}

impl FleetConfig {
    pub fn load(repo_root: &Path, path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("read fleet config {}", path.display()))?;
        let mut cfg: FleetConfig = toml::from_str(&text).context("parse lines.toml")?;
        for line in &mut cfg.lines {
            line.state_dir = resolve_path(repo_root, &line.state_dir);
        }
        cfg.api.hw_export = resolve_path(repo_root, &cfg.api.hw_export);
        if std::env::var("KAPPY_API_TOKEN")
            .ok()
            .filter(|s| !s.is_empty())
            .is_some()
        {
            cfg.api.token = std::env::var("KAPPY_API_TOKEN").unwrap();
        }
        if let Ok(url) = std::env::var("KAPPY_NACSERV_URL") {
            if !url.is_empty() {
                cfg.api.nacserv_url = url;
            }
        }
        if let Ok(token) = std::env::var("KAPPY_NACSERV_TOKEN") {
            cfg.api.nacserv_token = token;
        }
        if let Ok(listen) = std::env::var("KAPPY_API_LISTEN") {
            if !listen.is_empty() {
                cfg.api.listen = listen;
            }
        }
        Ok(cfg)
    }

    pub fn line(&self, id: &str) -> Option<&LineConfig> {
        self.lines.iter().find(|l| l.id == id)
    }
}

fn resolve_path(repo_root: &Path, raw: &str) -> String {
    let p = PathBuf::from(raw);
    if p.is_absolute() {
        return p.to_string_lossy().into_owned();
    }
    repo_root.join(p).to_string_lossy().into_owned()
}

/// Load Apple ID credentials from poc/lines/line-N.env if present.
pub fn load_line_credentials(repo_root: &Path, line_id: &str) -> (Option<String>, Option<String>) {
    let env_path = repo_root.join(format!("poc/lines/line-{line_id}.env"));
    let Ok(text) = std::fs::read_to_string(&env_path) else {
        return (None, None);
    };
    let mut apple_id = None;
    let mut password = None;
    for line in text.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("export KAPPY_APPLE_ID=") {
            let v = v.trim_matches('"').trim_matches('\'');
            if !v.is_empty() {
                apple_id = Some(v.to_string());
            }
        }
        if let Some(v) = line.strip_prefix("export KAPPY_APPLE_PASSWORD=") {
            let v = v.trim_matches('"').trim_matches('\'');
            if !v.is_empty() {
                password = Some(v.to_string());
            }
        }
    }
    (apple_id, password)
}
