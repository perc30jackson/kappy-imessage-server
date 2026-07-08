use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use chrono::{SubsecRound, Utc};
use omnisette::aos_kit::AOSKitAnisetteProvider;
use omnisette::{
    AnisetteClient, AnisetteError, AnisetteProvider, ArcAnisetteClient, LoginClientInfo,
    DEFAULT_ANISETTE_URL_V3,
};
use omnisette::remote_anisette_v3::RemoteAnisetteProviderV3;
use rustpush::OSConfig;
use tokio::sync::Mutex;

use crate::mac_config::SpikeMacConfig;

/// Wraps macOS AOSKit anisette but replaces host identity headers with spike hardware config.
pub struct HardwareAlignedAnisetteProvider {
    inner: AOSKitAnisetteProvider<'static>,
    device_id: String,
    mme_client_info: String,
}

impl HardwareAlignedAnisetteProvider {
    pub fn new(config: &SpikeMacConfig) -> anyhow::Result<Self> {
        Ok(Self {
            inner: AOSKitAnisetteProvider::new()?,
            device_id: config.device_id.clone(),
            mme_client_info: config.get_mme_clientinfo(&config.get_aoskit_version()),
        })
    }
}

impl AnisetteProvider for HardwareAlignedAnisetteProvider {
    async fn get_anisette_headers(&mut self) -> Result<HashMap<String, String>, AnisetteError> {
        let mut headers = self.inner.get_anisette_headers().await?;

        let now = Utc::now().round_subsecs(0);
        headers.insert(
            "X-Apple-I-Client-Time".to_string(),
            now.format("%+").to_string().replace("+00:00", "Z"),
        );
        headers.insert("X-Apple-I-TimeZone".to_string(), "UTC".to_string());
        headers
            .entry("X-Apple-I-MD-RINFO".to_string())
            .or_insert_with(|| "17106176".to_string());

        headers.insert(
            "X-Mme-Device-Id".to_string(),
            self.device_id.to_uppercase(),
        );
        headers.insert("X-Mme-Client-Info".to_string(), self.mme_client_info.clone());
        headers.remove("X-Apple-SRL-NO");

        log::debug!(
            "aoskit anisette aligned to device_id={} (keys: {:?})",
            self.device_id,
            headers.keys().collect::<Vec<_>>()
        );

        Ok(headers)
    }
}

pub enum SpikeAnisetteProvider {
    AosKit(HardwareAlignedAnisetteProvider),
    RawAosKit(AOSKitAnisetteProvider<'static>),
    Remote(RemoteAnisetteProviderV3),
}

impl AnisetteProvider for SpikeAnisetteProvider {
    async fn get_anisette_headers(&mut self) -> Result<HashMap<String, String>, AnisetteError> {
        match self {
            Self::AosKit(provider) => provider.get_anisette_headers().await,
            Self::RawAosKit(provider) => provider.get_anisette_headers().await,
            Self::Remote(provider) => {
                let headers = provider.get_anisette_headers().await?;
                log::debug!(
                    "remote anisette headers (keys: {:?})",
                    headers.keys().collect::<Vec<_>>()
                );
                Ok(headers)
            }
        }
    }
}

enum AnisetteMode {
    Remote,
    AosKit,
    RawAosKit,
    Auto,
}

fn anisette_mode() -> AnisetteMode {
    match std::env::var("KAPPY_ANISETTE").as_deref() {
        Ok("remote") => AnisetteMode::Remote,
        Ok("aoskit") => AnisetteMode::AosKit,
        Ok("raw") => AnisetteMode::RawAosKit,
        Ok(other) => {
            log::warn!("unknown KAPPY_ANISETTE={other:?}, defaulting to auto");
            AnisetteMode::Auto
        }
        Err(_) => AnisetteMode::Auto,
    }
}

fn use_remote_anisette(config: &SpikeMacConfig) -> bool {
    match anisette_mode() {
        AnisetteMode::Remote => true,
        AnisetteMode::AosKit | AnisetteMode::RawAosKit => false,
        AnisetteMode::Auto => config.inner.product_name.starts_with("VirtualMac"),
    }
}

pub fn spike_anisette_client(
    config: &SpikeMacConfig,
    login_config: LoginClientInfo,
    state_dir: &Path,
) -> anyhow::Result<ArcAnisetteClient<SpikeAnisetteProvider>> {
    std::fs::create_dir_all(state_dir.join("anisette"))?;

    let provider = if use_remote_anisette(config) {
        let url = std::env::var("KAPPY_ANISETTE_URL")
            .unwrap_or_else(|_| DEFAULT_ANISETTE_URL_V3.to_string());
        log::info!(
            "using remote anisette at {url} for {} ({})",
            config.inner.product_name,
            config.device_id
        );
        SpikeAnisetteProvider::Remote(RemoteAnisetteProviderV3::new(
            url,
            login_config,
            state_dir.join("anisette"),
        ))
    } else if matches!(anisette_mode(), AnisetteMode::RawAosKit) {
        log::info!("using raw aoskit anisette for {}", config.inner.product_name);
        SpikeAnisetteProvider::RawAosKit(AOSKitAnisetteProvider::new()?)
    } else {
        log::info!("using aoskit anisette for {}", config.inner.product_name);
        SpikeAnisetteProvider::AosKit(HardwareAlignedAnisetteProvider::new(config)?)
    };

    Ok(Arc::new(Mutex::new(AnisetteClient::new(provider))))
}
