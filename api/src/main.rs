mod config;
mod line;
mod routes;
mod types;

use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

fn init_rustls() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}

#[tokio::main]
async fn main() -> Result<()> {
    init_rustls();
    pretty_env_logger::init();

    let repo_root = std::env::var("KAPPY_REPO_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .expect("repo root")
                .to_path_buf()
        });

    let config_path = std::env::var("KAPPY_LINES_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join("poc/lines.toml"));

    if !config_path.is_file() {
        anyhow::bail!(
            "missing {} — copy from poc/lines.toml.example",
            config_path.display()
        );
    }

    let fleet = config::FleetConfig::load(&repo_root, &config_path)?;
    let listen: SocketAddr = fleet
        .api
        .listen
        .parse()
        .with_context(|| format!("parse listen address {}", fleet.api.listen))?;

    let state = routes::build_state(repo_root.clone(), fleet.clone()).await?;
    let token = fleet.api.token.clone();

    let app = routes::router(state, token)
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .layer(TraceLayer::new_for_http());

    log::info!("kappy-api listening on http://{listen}");
    log::info!("open portal at http://{listen}/");
    log::info!("lines configured: {}", fleet.lines.len());
    let listener = tokio::net::TcpListener::bind(listen).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
