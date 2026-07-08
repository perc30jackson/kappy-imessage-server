use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use rustpush::{APSState, IDSNGMIdentity, IDSUser};
use serde::{Deserialize, Serialize};

use crate::hardware::{bin_deserialize, bin_serialize};
use crate::mac_config::{SpikeMacConfig, SpikeMacConfigSnapshot};
use crate::validation::shared_store;

pub const IDENTITY_LABEL: &str = "kappy-spike";

#[derive(Serialize, Deserialize, Clone)]
pub struct SavedHardwareState {
    pub push: APSState,
    #[serde(serialize_with = "bin_serialize", deserialize_with = "bin_deserialize")]
    pub identity: Vec<u8>,
    pub os_config: SpikeMacConfigSnapshot,
}

pub struct SpikeStateDir {
    pub root: PathBuf,
}

impl Clone for SpikeStateDir {
    fn clone(&self) -> Self {
        Self {
            root: self.root.clone(),
        }
    }
}

impl SpikeStateDir {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn ensure(&self) -> Result<()> {
        std::fs::create_dir_all(&self.root).context("create state dir")?;
        Ok(())
    }

    fn hw_path(&self) -> PathBuf {
        self.root.join("hw_info.plist")
    }

    fn users_path(&self) -> PathBuf {
        self.root.join("id.plist")
    }

    pub fn save_hardware(
        &self,
        push: &APSState,
        identity: &IDSNGMIdentity,
        config: &Arc<SpikeMacConfig>,
    ) -> Result<()> {
        self.ensure()?;
        let state = SavedHardwareState {
            push: push.clone(),
            identity: identity.save(IDENTITY_LABEL)?.into(),
            os_config: config.snapshot(),
        };
        plist::to_file_xml(self.hw_path(), &state).context("write hw_info.plist")?;
        Ok(())
    }

    pub fn load_hardware(&self) -> Result<(SavedHardwareState, Arc<SpikeMacConfig>, IDSNGMIdentity)> {
        let state: SavedHardwareState =
            plist::from_file(self.hw_path()).context("read hw_info.plist (run activate first)")?;
        let config = SpikeMacConfig::from_snapshot(state.os_config.clone(), shared_store());
        let identity = IDSNGMIdentity::restore(&state.identity, IDENTITY_LABEL)
            .context("restore IDSNGMIdentity")?;
        Ok((state, config, identity))
    }

    pub fn save_users(&self, users: &[IDSUser]) -> Result<()> {
        self.ensure()?;
        let users = users.to_vec();
        plist::to_file_xml(self.users_path(), &users).context("write id.plist")?;
        Ok(())
    }

    pub fn load_users(&self) -> Result<Vec<IDSUser>> {
        plist::from_file(self.users_path()).context("read id.plist (run login first)")
    }

    pub fn id_cache_path(&self) -> PathBuf {
        self.root.join("id_cache.plist")
    }

    pub fn keystore_path(&self) -> PathBuf {
        self.root.join("keystore.plist")
    }

    pub fn write_meta(&self, key: &str, value: &impl Serialize) -> Result<()> {
        self.ensure()?;
        let path = self.root.join(format!("{key}.json"));
        let json = serde_json::to_string_pretty(value)?;
        std::fs::write(path, json)?;
        Ok(())
    }
}

pub fn read_file_bytes(path: &Path) -> Result<Vec<u8>> {
    let data = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    Ok(data)
}
