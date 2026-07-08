use std::io::Cursor;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use prost::Message;
use rand::Rng;

use crate::hardware::HardwareConfig;
use crate::mac_config::SpikeMacConfig;

pub mod bbhwinfo {
    include!(concat!(env!("OUT_DIR"), "/bbhwinfo.rs"));
}

const OABS_MAGIC: &[u8] = b"OABS";

/// Strip Mac-Hardware-Info `OABS` export wrapper; return raw `HwInfo` protobuf bytes.
pub fn strip_oabs_export(data: &[u8]) -> Result<Vec<u8>> {
    if data.len() >= 5 && &data[..4] == OABS_MAGIC {
        let _prevent_sharing = data[4];
        return Ok(data[5..].to_vec());
    }
    Ok(data.to_vec())
}

pub fn parse_hw_info_bytes(data: &[u8]) -> Result<bbhwinfo::HwInfo> {
    let raw = strip_oabs_export(data)?;
    bbhwinfo::HwInfo::decode(&mut Cursor::new(raw)).context("decode HwInfo protobuf")
}

pub fn spike_config_from_hw_bytes(data: &[u8]) -> Result<Arc<SpikeMacConfig>> {
    let copied = parse_hw_info_bytes(data)?;
    let inner = copied.inner.ok_or_else(|| anyhow!("HwInfo missing inner"))?;
    let io_mac: [u8; 6] = inner
        .io_mac_address
        .try_into()
        .map_err(|_| anyhow!("io_mac_address must be 6 bytes"))?;

    Ok(Arc::new(SpikeMacConfig {
        inner: HardwareConfig {
            product_name: inner.product_name,
            io_mac_address: io_mac,
            platform_serial_number: inner.platform_serial_number,
            platform_uuid: inner.platform_uuid,
            root_disk_uuid: inner.root_disk_uuid,
            board_id: inner.board_id,
            os_build_num: inner.os_build_num,
            platform_serial_number_enc: inner.platform_serial_number_enc,
            platform_uuid_enc: inner.platform_uuid_enc,
            root_disk_uuid_enc: inner.root_disk_uuid_enc,
            rom: inner.rom,
            rom_enc: inner.rom_enc,
            mlb: inner.mlb,
            mlb_enc: inner.mlb_enc,
        },
        version: copied.version,
        protocol_version: copied.protocol_version as u32,
        device_id: copied.device_id,
        icloud_ua: copied.icloud_ua,
        aoskit_version: copied.aoskit_version,
        udid: Some(generate_udid()),
        validation: crate::validation::shared_store(),
    }))
}

pub fn generate_udid() -> String {
    let udid: [u8; 32] = rand::thread_rng().gen();
    crate::util::encode_hex(&udid).to_uppercase()
}

pub fn normalize_recipient(handle: &str) -> String {
    let trimmed = handle.trim();
    if trimmed.contains(':') {
        return trimmed.to_string();
    }
    if trimmed.starts_with('+') {
        return format!("tel:{trimmed}");
    }
    if trimmed.contains('@') {
        return format!("mailto:{trimmed}");
    }
    trimmed.to_string()
}
