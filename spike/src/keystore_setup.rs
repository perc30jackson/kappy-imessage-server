use std::collections::HashSet;
use std::path::Path;
use std::sync::RwLock;

use anyhow::{Context, Result};
use keystore::{
    init_keystore,
    software::{NoEncryptor, SoftwareKeystore, SoftwareKeystoreState},
};
use plist::{Dictionary, Value};
use rustpush::IDSUser;

use crate::state::SpikeStateDir;

/// rustpush stores APS/IDS keys via the global keystore; must run before activate/login.
pub fn init(state_dir: &SpikeStateDir) -> Result<()> {
    state_dir.ensure()?;
    let path = state_dir.keystore_path();
    let persist_path = path.clone();
    let initial: SoftwareKeystoreState =
        plist::from_file(&path).unwrap_or_default();

    init_keystore(SoftwareKeystore {
        state: RwLock::new(initial),
        update_state: Box::new(move |state| {
            if let Err(err) = plist::to_file_xml(&persist_path, state) {
                log::warn!("failed to persist keystore.plist: {err}");
            }
        }),
        encryptor: NoEncryptor,
    });

    log::debug!("keystore initialized at {}", path.display());
    Ok(())
}

fn collect_key_aliases(user: &IDSUser) -> HashSet<String> {
    let mut aliases = HashSet::new();
    aliases.insert(user.auth_keypair.private.0.clone());
    for reg in user.registration.values() {
        aliases.insert(reg.id_keypair.private.0.clone());
    }
    aliases
}

fn keys_dict(store: &mut Value) -> Result<&mut Dictionary> {
    store
        .as_dictionary_mut()
        .and_then(|d| d.get_mut("keys"))
        .and_then(|k| k.as_dictionary_mut())
        .context("keystore plist missing keys dictionary")
}

/// Merge donor spike `keystore.plist` keys into `state_dir` before `init()`.
pub fn merge_keystore_files(
    state_dir: &SpikeStateDir,
    donor_keystore: &Path,
    donor_id_plist: &Path,
) -> Result<()> {
    let donor_users: Vec<IDSUser> =
        plist::from_file(donor_id_plist).with_context(|| format!("read {}", donor_id_plist.display()))?;
    let donor = donor_users
        .first()
        .context("donor id.plist has no users")?;
    let aliases = collect_key_aliases(donor);

    let target_path = state_dir.keystore_path();
    let mut target: Value = plist::from_file(&target_path).unwrap_or_else(|_| {
        Value::Dictionary(Dictionary::from_iter([(
            "keys".to_string(),
            Value::Dictionary(Dictionary::new()),
        )]))
    });
    let donor_state: Value =
        plist::from_file(donor_keystore).with_context(|| format!("read {}", donor_keystore.display()))?;
    let donor_keys = donor_state
        .as_dictionary()
        .and_then(|d| d.get("keys"))
        .and_then(|k| k.as_dictionary())
        .context("donor keystore missing keys dictionary")?;

    let target_keys = keys_dict(&mut target)?;
    let mut merged = 0usize;
    for alias in &aliases {
        if let Some(key) = donor_keys.get(alias) {
            target_keys.insert(alias.clone(), key.clone());
            merged += 1;
        } else {
            log::warn!("donor keystore missing alias {alias}");
        }
    }

    state_dir.ensure()?;
    plist::to_file_xml(&target_path, &target).context("write merged keystore.plist")?;
    log::info!("merged {merged} keystore key(s) into {}", target_path.display());
    Ok(())
}
