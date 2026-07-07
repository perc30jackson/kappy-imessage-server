use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use rustpush::{
    activation::ActivationInfo, util::encode_hex, DebugMeta, OSConfig, PushError, RegisterMeta,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::hardware::HardwareConfig;
use crate::validation::ValidationStore;

/// Mac hardware config with externally supplied validation data (Beeper nac path).
#[derive(Clone)]
pub struct SpikeMacConfig {
    pub inner: HardwareConfig,
    pub version: String,
    pub protocol_version: u32,
    pub device_id: String,
    pub icloud_ua: String,
    pub aoskit_version: String,
    pub udid: Option<String>,
    #[serde(skip)]
    pub validation: ValidationStore,
}

/// Plist-serializable snapshot (validation store rehydrated at runtime).
#[derive(Serialize, Deserialize, Clone)]
pub struct SpikeMacConfigSnapshot {
    pub inner: HardwareConfig,
    pub version: String,
    pub protocol_version: u32,
    pub device_id: String,
    pub icloud_ua: String,
    pub aoskit_version: String,
    pub udid: Option<String>,
}

impl SpikeMacConfig {
    pub fn snapshot(&self) -> SpikeMacConfigSnapshot {
        SpikeMacConfigSnapshot {
            inner: self.inner.clone(),
            version: self.version.clone(),
            protocol_version: self.protocol_version,
            device_id: self.device_id.clone(),
            icloud_ua: self.icloud_ua.clone(),
            aoskit_version: self.aoskit_version.clone(),
            udid: self.udid.clone(),
        }
    }

    pub fn from_snapshot(snapshot: SpikeMacConfigSnapshot, validation: ValidationStore) -> Arc<Self> {
        Arc::new(Self {
            inner: snapshot.inner,
            version: snapshot.version,
            protocol_version: snapshot.protocol_version,
            device_id: snapshot.device_id,
            icloud_ua: snapshot.icloud_ua,
            aoskit_version: snapshot.aoskit_version,
            udid: snapshot.udid,
            validation,
        })
    }
}

#[async_trait]
impl OSConfig for SpikeMacConfig {
    fn build_activation_info(&self, csr: Vec<u8>) -> ActivationInfo {
        ActivationInfo {
            activation_randomness: Uuid::new_v4().to_string().to_uppercase(),
            activation_state: "Unactivated",
            build_version: self.inner.os_build_num.clone(),
            device_cert_request: csr.into(),
            device_class: "MacOS".to_string(),
            product_type: self.inner.product_name.clone(),
            product_version: self.version.clone(),
            serial_number: self.inner.platform_serial_number.clone(),
            unique_device_id: self.device_id.clone().to_uppercase(),
        }
    }

    fn get_udid(&self) -> String {
        self.udid.clone().expect("missing udid")
    }

    fn get_normal_ua(&self, item: &str) -> String {
        let part = self.icloud_ua.split_whitespace().next().unwrap_or("com.apple.iCloudHelper/282");
        format!("{item} {part}")
    }

    fn get_aoskit_version(&self) -> String {
        self.aoskit_version.clone()
    }

    fn get_mme_clientinfo(&self, for_item: &str) -> String {
        format!(
            "<{}> <macOS;{};{}> <{}>",
            self.inner.product_name, self.version, self.inner.os_build_num, for_item
        )
    }

    fn get_version_ua(&self) -> String {
        format!(
            "[macOS,{},{},{}]",
            self.version, self.inner.os_build_num, self.inner.product_name
        )
    }

    fn get_activation_device(&self) -> String {
        "MacOS".to_string()
    }

    fn get_device_uuid(&self) -> String {
        self.device_id.clone()
    }

    fn get_device_name(&self) -> String {
        format!("Mac-{}", self.inner.platform_serial_number)
    }

    async fn generate_validation_data(&self) -> Result<Vec<u8>, PushError> {
        self.validation
            .get()
            .await
            .ok_or_else(|| PushError::CustomerMessage(rustpush::SupportAlert {
                title: "Validation data missing".to_string(),
                body: "Run mac-registration-provider -once or start validation-server + submit sidecar"
                    .to_string(),
                action: None,
            }))
    }

    fn get_protocol_version(&self) -> u32 {
        self.protocol_version
    }

    fn get_register_meta(&self) -> RegisterMeta {
        RegisterMeta {
            hardware_version: self.inner.product_name.clone(),
            os_version: format!("macOS,{},{}", self.version, self.inner.os_build_num),
            software_version: self.inner.os_build_num.clone(),
        }
    }

    fn get_debug_meta(&self) -> DebugMeta {
        DebugMeta {
            user_version: self.version.clone(),
            hardware_version: self.inner.product_name.clone(),
            serial_number: self.inner.platform_serial_number.clone(),
        }
    }

    fn get_gsa_hardware_headers(&self) -> HashMap<String, String> {
        [
            ("X-Apple-I-MLB", self.inner.mlb.as_str()),
            ("X-Apple-I-ROM", encode_hex(&self.inner.rom).as_str()),
            ("X-Apple-I-SRL-NO", self.inner.platform_serial_number.as_str()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    fn get_serial_number(&self) -> String {
        self.inner.platform_serial_number.clone()
    }

    fn get_login_url(&self) -> &'static str {
        "https://setup.icloud.com/setup/signin/v2/login"
    }

    fn get_private_data(&self) -> plist::Dictionary {
        let apple_epoch = SystemTime::UNIX_EPOCH + Duration::from_secs(978_307_200);
        plist::Dictionary::from_iter([
            ("ap", plist::Value::String("0".to_string())),
            (
                "d",
                plist::Value::String(format!(
                    "{:.6}",
                    apple_epoch.elapsed().unwrap_or_default().as_secs_f64()
                )),
            ),
            ("dt", plist::Value::Integer(1.into())),
            ("gt", plist::Value::String("0".to_string())),
            ("h", plist::Value::String("1".to_string())),
            ("m", plist::Value::String("0".to_string())),
            ("p", plist::Value::String("0".to_string())),
            ("pb", plist::Value::String(self.inner.os_build_num.clone())),
            ("pn", plist::Value::String("macOS".to_string())),
            ("pv", plist::Value::String(self.version.clone())),
            ("s", plist::Value::String("0".to_string())),
            ("t", plist::Value::String("0".to_string())),
            ("u", plist::Value::String(self.device_id.clone().to_uppercase())),
            ("v", plist::Value::String("1".to_string())),
        ])
    }
}
