use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use rustpush::{
    MADRID_SERVICE, duration_since_epoch, IDSRegistration, IDSUser, KeyPairNew,
};
use serde::Deserialize;

use crate::state::SpikeStateDir;

#[derive(Debug, Deserialize)]
struct IdStatusCache {
  #[serde(rename = "com.apple.madrid")]
  madrid: Option<HashMap<String, IdStatusEntry>>,
}

#[derive(Debug, Deserialize)]
struct IdStatusEntry {
  #[serde(rename = "IDStatus")]
  id_status: Option<i64>,
}

fn expand_tilde(path: &Path) -> PathBuf {
  let s = path.to_string_lossy();
  if let Some(rest) = s.strip_prefix("~/") {
    if let Ok(home) = std::env::var("HOME") {
      return PathBuf::from(home).join(rest);
    }
  }
  path.to_path_buf()
}

pub fn expand_path(path: &Path) -> PathBuf {
  expand_tilde(path)
}

fn active_handles(cache: &HashMap<String, IdStatusEntry>) -> Vec<String> {
  cache
    .iter()
    .filter(|(_, entry)| entry.id_status.unwrap_or(0) == 1)
    .map(|(handle, _)| handle.clone())
    .collect()
}

fn load_idstatuscache(path: &Path) -> Result<IdStatusCache> {
  plist::from_file(path).with_context(|| format!("read {}", path.display()))
}

fn load_users(path: &Path) -> Result<Vec<IDSUser>> {
  plist::from_file(path).with_context(|| format!("read {}", path.display()))
}

fn synthesize_madrid(user: &IDSUser, handles: &[String]) -> Result<IDSRegistration> {
  if handles.is_empty() {
    bail!("no active com.apple.madrid handles in idstatuscache");
  }
  Ok(IDSRegistration {
    id_keypair: KeyPairNew {
      cert: user.auth_keypair.cert.clone(),
      private: user.auth_keypair.private.clone(),
    },
    handles: handles.to_vec(),
    registered_at_s: duration_since_epoch().as_secs(),
    heartbeat_interval_s: None,
    data_hash: MADRID_SERVICE.hash_data(),
  })
}

/// Import GUI Messages / identityservicesd registration into spike `id.plist`.
///
/// Preferred path: copy `registration` (+ matching keystore keys) from a donor
/// `id.plist` produced by `kappy-spike register` on the same Apple ID.
///
/// Fallback: synthesize `com.apple.madrid` from `idstatuscache.plist` handles
/// using the spike auth cert (may not work if Apple requires per-service certs).
pub fn import_gui_registration(
  state_dir: &SpikeStateDir,
  idstatuscache: &Path,
  donor_id_plist: Option<&Path>,
  synthesize: bool,
) -> Result<()> {
  let mut users = state_dir.load_users().context("load id.plist (run login first)")?;
  let user = users
    .first_mut()
    .context("id.plist has no IDS users — run login first")?;

  if let Some(donor_path) = donor_id_plist {
    let donor_users = load_users(donor_path)?;
    let donor = donor_users
      .iter()
      .find(|u| u.user_id == user.user_id)
      .with_context(|| {
        format!(
          "donor id.plist has no user matching {} (found: {})",
          user.user_id,
          donor_users
            .iter()
            .map(|u| u.user_id.as_str())
            .collect::<Vec<_>>()
            .join(", ")
        )
      })?;

    if donor.registration.is_empty() {
      bail!("donor id.plist has empty registration — run register on donor first");
    }

    log::info!(
      "merging {} registration service(s) from {}",
      donor.registration.len(),
      donor_path.display()
    );
    user.registration = donor.registration.clone();
    user.auth_keypair = donor.auth_keypair.clone();
    user.protocol_version = donor.protocol_version;
  } else if synthesize {
    let cache = load_idstatuscache(idstatuscache)?;
    let madrid = cache
      .madrid
      .as_ref()
      .context("idstatuscache has no com.apple.madrid section")?;
    let handles = active_handles(madrid);
    log::info!(
      "synthesizing com.apple.madrid from idstatuscache ({} handle(s))",
      handles.len()
    );
    let reg = synthesize_madrid(user, &handles)?;
    user.registration.insert("com.apple.madrid".to_string(), reg);
  } else {
    bail!("provide --donor-id-plist or pass --synthesize");
  }

  state_dir.save_users(&users)?;
  let madrid_handles = users
    .first()
    .and_then(|u| u.registration.get("com.apple.madrid"))
    .map(|r| r.handles.clone())
    .unwrap_or_default();
  log::info!("imported GUI registration; madrid handles: {madrid_handles:?}");
  Ok(())
}

pub fn resolve_import_paths(
  idstatuscache: PathBuf,
  donor_id_plist: Option<PathBuf>,
) -> (PathBuf, Option<PathBuf>) {
  (
    expand_tilde(&idstatuscache),
    donor_id_plist.map(|p| expand_tilde(&p)),
  )
}
