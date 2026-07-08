use std::path::Path;

use anyhow::{bail, Context, Result};
use base64::Engine;
use keystore::{KeystoreAccessRules, KeystoreDigest, KeystorePadding, RsaKey};
use rustpush::{
    facetime::{FACETIME_SERVICE, VIDEO_SERVICE},
    findmy::MULTIPLEX_SERVICE,
    IDSRegistration, KeyPairNew, MADRID_SERVICE,
};
use serde::Deserialize;

use crate::state::SpikeStateDir;

#[derive(Debug, Deserialize)]
struct IdsExport {
    profile_id: String,
    private_key_alias: Option<String>,
    auth_cert_b64: Option<String>,
    private_key_der_b64: Option<String>,
    registrations: Vec<IdsExportRegistration>,
}

#[derive(Debug, Deserialize)]
struct IdsExportRegistration {
    spike_service: String,
    handles: Vec<String>,
    registration_cert_b64: String,
    registered_at_s: u64,
}

fn ids_access_rules() -> KeystoreAccessRules {
    KeystoreAccessRules {
        signature_padding: vec![KeystorePadding::PKCS1],
        digests: vec![KeystoreDigest::Sha1],
        can_sign: true,
        ..Default::default()
    }
}

fn service_hash(spike_service: &str) -> Result<u64> {
    let hash = match spike_service {
        "com.apple.madrid" => MADRID_SERVICE.hash_data(),
        "com.apple.ess" => VIDEO_SERVICE.hash_data(),
        "com.apple.private.alloy.facetime.multi" => FACETIME_SERVICE.hash_data(),
        "com.apple.private.alloy.multiplex1" => MULTIPLEX_SERVICE.hash_data(),
        other => bail!("unsupported spike service {other}"),
    };
    Ok(hash)
}

fn decode_b64(field: &str, b64: &str) -> Result<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(b64)
        .with_context(|| format!("decode base64 for {field}"))
}

fn rsa_alias(export: &IdsExport) -> String {
    export
        .private_key_alias
        .clone()
        .unwrap_or_else(|| format!("ids:{}", export.profile_id))
}

/// Merge GUI IDS export (from `kappy-ids-export`) into spike `id.plist` + keystore.
///
/// Requires keystore to be initialized (`keystore_setup::init`) so `RsaKey::import`
/// can persist the private key when included in the export.
pub fn import_ids_export(state_dir: &SpikeStateDir, export_path: &Path) -> Result<()> {
    let export: IdsExport =
        serde_json::from_slice(&std::fs::read(export_path).with_context(|| {
            format!("read {}", export_path.display())
        })?)
        .with_context(|| format!("parse {}", export_path.display()))?;

    if export.registrations.is_empty() {
        bail!("export has no registrations");
    }

    let alias = rsa_alias(&export);
    if let Some(der_b64) = &export.private_key_der_b64 {
        let der = decode_b64("private_key_der_b64", der_b64)?;
        RsaKey::import(&alias, 2048, &der, ids_access_rules())
            .with_context(|| format!("import RSA key into keystore alias {alias}"))?;
        log::info!("imported RSA private key into keystore ({alias})");
    } else {
        log::warn!(
            "export has no private_key_der_b64 — keystore must already contain {alias}"
        );
    }

    let mut users = state_dir.load_users().context("load id.plist (run login first)")?;
    let user = users
        .first_mut()
        .context("id.plist has no IDS users — run login first")?;

    if user.user_id != export.profile_id {
        bail!(
            "export profile_id {} does not match id.plist user {} — wrong export or Apple ID",
            export.profile_id,
            user.user_id
        );
    }

    if let Some(auth_b64) = &export.auth_cert_b64 {
        user.auth_keypair.cert = decode_b64("auth_cert_b64", auth_b64)?;
        user.auth_keypair.private = RsaKey(alias.clone());
        log::info!("updated auth_keypair cert from GUI export");
    }

    let mut merged = 0usize;
    for entry in &export.registrations {
        if entry.handles.is_empty() {
            log::warn!("skip {}: no handles", entry.spike_service);
            continue;
        }
        let cert = decode_b64(
            &format!("{}.registration_cert_b64", entry.spike_service),
            &entry.registration_cert_b64,
        )?;
        let reg = IDSRegistration {
            id_keypair: KeyPairNew {
                cert,
                private: RsaKey(alias.clone()),
            },
            handles: entry.handles.clone(),
            registered_at_s: entry.registered_at_s,
            heartbeat_interval_s: None,
            data_hash: service_hash(&entry.spike_service)?,
        };
        user.registration.insert(entry.spike_service.clone(), reg);
        merged += 1;
        log::info!(
            "imported {} ({} handle(s))",
            entry.spike_service,
            entry.handles.len()
        );
    }

    if merged == 0 {
        bail!("no registration services imported");
    }

    state_dir.save_users(&users)?;

    let madrid_handles = users
        .first()
        .and_then(|u| u.registration.get("com.apple.madrid"))
        .map(|r| r.handles.clone())
        .unwrap_or_default();
    log::info!(
        "import-ids-export OK: {merged} service(s); madrid handles: {madrid_handles:?}"
    );
    Ok(())
}
