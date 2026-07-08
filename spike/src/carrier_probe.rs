use anyhow::Result;
use rustpush::{get_gateways_for_mccmnc, PushError};

/// US MCC/MNC codes common on MVNO / eSIM profiles (incl. Telnyx multi-IMSI roster).
pub const TELNYX_PRESET_MCCMNC: &[&str] = &[
    "310260", // T-Mobile US
    "310160", // T-Mobile alternate
    "310410", // AT&T
    "311480", // Verizon MVNO bucket
    "312530", // various MVNOs
    "310120", // Sprint legacy / T-Mobile
    "311580", // US Cellular
];

pub async fn probe_mccmnc(mccmnc: &str) -> Result<()> {
    let mccmnc = mccmnc.trim();
    print!("{mccmnc}");
    match get_gateways_for_mccmnc(mccmnc).await {
        Ok(cfg) => {
            println!(" — found carrier bundle");
            println!("  sms_gateway: {}", cfg.gateway);
            if cfg.supports_smsless() {
                println!("  smsless: yes");
                if let Some(url) = cfg.entitlement_server_url() {
                    println!("  entitlement_server: {url}");
                }
                if let Some(ver) = cfg.entitlement_protocol_version() {
                    println!("  entitlement_protocol: {ver}");
                }
                println!("  → authenticate_smsless path may be viable (still needs EAP-AKA / SIM)");
            } else {
                println!("  smsless: no (ICCAuthUnsupported — SMS REG path only, if any)");
            }
        }
        Err(PushError::CarrierNotFound) => {
            println!(" — no Apple carrier bundle for this MCC/MNC");
        }
        Err(e) => {
            println!(" — error: {e}");
        }
    }
    println!();
    Ok(())
}

pub async fn probe_carriers(mccmncs: &[String], include_telnyx_presets: bool) -> Result<()> {
    let mut codes: Vec<String> = mccmncs
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if include_telnyx_presets {
        for preset in TELNYX_PRESET_MCCMNC {
            if !codes.iter().any(|c| c == *preset) {
                codes.push((*preset).to_string());
            }
        }
    }

    if codes.is_empty() {
        anyhow::bail!("pass --mccmnc <code> and/or --telnyx-presets");
    }

    println!("Apple carrier bundle probe (iTunes MZITunesClientCheck)\n");
    for code in &codes {
        probe_mccmnc(code).await?;
    }
    println!("SMSLess requires carrier_entitlements in carrier.plist + live EAP-AKA (USIM).");
    println!("SMS gateway uses REG-REQ/REG-RESP via {}", "PhoneNumberRegistrationGatewayAddress");
    Ok(())
}
