use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use plist::Data;
use rustpush::{authenticate_phone, get_gateways_for_mccmnc, AuthPhone, IDSUser};
use serde::{Deserialize, Serialize};

use crate::engine::{connect, connect_aps, persist_push_state};
use crate::state::SpikeStateDir;
use crate::util::encode_hex;

const TELNYX_MESSAGES_URL: &str = "https://api.telnyx.com/v2/messages";
const TELNYX_SHORT_CODE_MESSAGES_URL: &str = "https://api.telnyx.com/v2/messages/short_code";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegResp {
    pub version: u32,
    pub request_id: u32,
    pub phone_number: String,
    pub signature_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmsRegPending {
    pub request_id: u32,
    pub push_token_hex: String,
    pub reg_req_body: String,
    pub gateway: String,
    pub from_number: String,
    pub mccmnc: String,
}

fn pending_path(state_dir: &SpikeStateDir) -> std::path::PathBuf {
    state_dir.root.join("sms-reg-pending.json")
}

pub fn load_pending(state_dir: &SpikeStateDir) -> Result<Option<SmsRegPending>> {
    let path = pending_path(state_dir);
    if !path.exists() {
        return Ok(None);
    }
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("read {}", path.display()))?;
    Ok(Some(serde_json::from_str(&text)?))
}

fn parse_query_string(query: &str) -> HashMap<String, String> {
    query
        .split(';')
        .filter_map(|pair| {
            let (k, v) = pair.split_once('=')?;
            Some((k.trim().to_string(), v.trim().to_string()))
        })
        .collect()
}

/// Parse `REG-RESP?v=3;r=…;n=+1…;s=HEX` from an inbound SMS body.
pub fn parse_reg_resp(text: &str) -> Result<RegResp> {
    let haystack = text
        .lines()
        .find(|l| l.contains("REG-RESP"))
        .or_else(|| {
            text.split_whitespace()
                .find(|w| w.contains("REG-RESP"))
        })
        .unwrap_or(text);

    let (_, query) = haystack
        .split_once('?')
        .ok_or_else(|| anyhow!("REG-RESP missing query string"))?;
    let fields = parse_query_string(query);

    let version = fields
        .get("v")
        .ok_or_else(|| {
            anyhow!(
                "REG-RESP missing v= — paste the full SMS from Apple (e.g. REG-RESP?v=3;r=…;n=+1…;s=HEX), not a placeholder"
            )
        })?
        .parse()
        .context("parse v=")?;
    let request_id = fields
        .get("r")
        .ok_or_else(|| anyhow!("REG-RESP missing r="))?
        .parse()
        .context("parse r=")?;
    let phone_number = fields
        .get("n")
        .cloned()
        .ok_or_else(|| anyhow!("REG-RESP missing n="))?;
    let signature_hex = fields
        .get("s")
        .cloned()
        .ok_or_else(|| anyhow!("REG-RESP missing s="))?;

    if !phone_number.starts_with('+') {
        anyhow::bail!("unexpected phone format in REG-RESP: {phone_number}");
    }

    Ok(RegResp {
        version,
        request_id,
        phone_number,
        signature_hex,
    })
}

pub fn build_reg_req(push_token_hex: &str, request_id: u32) -> String {
    format!("REG-REQ?v=3;t={push_token_hex};r={request_id}")
}

/// Apple US carrier gateways (e.g. T-Mobile `22223333`, AT&T `28818773`) are short codes,
/// not E.164 numbers. Prefixing `+1` produces invalid destinations like `+122223333`.
fn is_apple_short_code_gateway(raw: &str) -> bool {
    let trimmed = raw.trim();
    trimmed.chars().all(|c| c.is_ascii_digit()) && (5..=8).contains(&trimmed.len())
}

fn normalize_gateway(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.starts_with('+') {
        trimmed.to_string()
    } else if is_apple_short_code_gateway(trimmed) {
        trimmed.to_string()
    } else if trimmed.chars().all(|c| c.is_ascii_digit()) {
        format!("+{trimmed}")
    } else {
        trimmed.to_string()
    }
}

fn telnyx_send_url(gateway: &str) -> &'static str {
    if is_apple_short_code_gateway(gateway) {
        TELNYX_SHORT_CODE_MESSAGES_URL
    } else {
        TELNYX_MESSAGES_URL
    }
}

fn telnyx_error_hint(gateway: &str, body: &str) -> String {
    let mut hints = Vec::new();
    if is_apple_short_code_gateway(gateway) {
        hints.push(
            "Apple US SMS REG gateways (e.g. 22223333) are short codes; many CPaaS APIs \
             (including Telnyx long-code → short-code) cannot deliver them.",
        );
        hints.push(
            "Try --gateway +447786205094 (UK gateway; needs Telnyx intl + alpha sender), \
             or send REG-REQ from a real handset/modem on the carrier and paste REG-RESP \
             into sms-reg-complete.",
        );
    }
    if body.contains("Alpha sender not configured") {
        hints.push(
            "International REG gateway: add an alphanumeric sender ID to your Telnyx \
             messaging profile and whitelist GB.",
        );
    }
    if body.contains("Invalid source number") && is_apple_short_code_gateway(gateway) {
        hints.push(
            "Telnyx /messages/short_code may require a provisioned short code as `from`; \
             long codes often cannot originate short-code traffic.",
        );
    }
    if hints.is_empty() {
        String::new()
    } else {
        format!("\n\nHint: {}", hints.join("\nHint: "))
    }
}

pub async fn resolve_gateway(mccmnc: &str) -> Result<String> {
    let cfg = get_gateways_for_mccmnc(mccmnc)
        .await
        .map_err(|e| anyhow!("carrier lookup for {mccmnc}: {e}"))?;
    Ok(normalize_gateway(&cfg.gateway))
}

pub async fn send_reg_req_telnyx(
    api_key: &str,
    from_number: &str,
    gateway: &str,
    body: &str,
) -> Result<()> {
    let url = telnyx_send_url(gateway);
    let client = reqwest::Client::new();
    let resp = client
        .post(url)
        .bearer_auth(api_key)
        .json(&serde_json::json!({
            "from": from_number,
            "to": gateway,
            "text": body,
        }))
        .send()
        .await
        .context("telnyx send")?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        anyhow::bail!(
            "telnyx send failed ({status}) via {url}: {text}{}",
            telnyx_error_hint(gateway, &text)
        );
    }
    log::info!("telnyx accepted REG-REQ → {gateway} (via {url})");
    Ok(())
}

pub async fn sms_reg_send(
    state_dir: &SpikeStateDir,
    mccmnc: &str,
    from_number: &str,
    api_key: &str,
    gateway_override: Option<&str>,
    dry_run: bool,
) -> Result<SmsRegPending> {
    let session = connect_aps(state_dir).await?;
    let push_token = session
        .conn
        .state
        .read()
        .await
        .token
        .clone()
        .ok_or_else(|| anyhow!("APS has no push token — run activate first"))?;
    let push_token_hex = encode_hex(&push_token).to_uppercase();
    let request_id: u32 = rand::random();

    let gateway = match gateway_override {
        Some(g) => normalize_gateway(g),
        None => resolve_gateway(mccmnc).await?,
    };

    let body = build_reg_req(&push_token_hex, request_id);
    log::info!("REG-REQ body: {body}");

    let pending = SmsRegPending {
        request_id,
        push_token_hex,
        reg_req_body: body.clone(),
        gateway: gateway.clone(),
        from_number: from_number.to_string(),
        mccmnc: mccmnc.to_string(),
    };
    let path = pending_path(state_dir);
    std::fs::write(&path, serde_json::to_string_pretty(&pending)?)
        .with_context(|| format!("write {}", path.display()))?;
    log::info!("saved pending request to {}", path.display());

    if dry_run {
        log::info!("dry-run: Telnyx API send skipped");
        log::info!(
            "manual SMS from HANDSET {from_number} → gateway {gateway}:\n{body}"
        );
        log::info!(
            "REG-RESP will stamp n= as the handset MSISDN ({from_number}). \
             Paste into sms-reg-complete, or use webhook if that number can receive via Telnyx."
        );
        return Ok(pending);
    }

    log::info!("sending from {from_number} to {gateway}");
    if let Err(e) = send_reg_req_telnyx(api_key, from_number, &gateway, &body).await {
        anyhow::bail!(
            "{e:#}\n\nPending REG-REQ saved at {} — send that SMS manually from {from_number}, then sms-reg-complete when REG-RESP arrives.",
            path.display()
        );
    }

    log::info!("wait for REG-RESP on {from_number} (Telnyx webhook or sms-reg-complete --text …)");
    Ok(pending)
}

fn decode_signature_hex(hex: &str) -> Result<Vec<u8>> {
    let hex = hex.trim();
    if hex.len() % 2 != 0 {
        anyhow::bail!("signature hex length must be even");
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).context("signature hex"))
        .collect()
}

pub async fn sms_reg_complete(
    state_dir: &SpikeStateDir,
    reg_resp_text: &str,
    do_register: bool,
) -> Result<Vec<IDSUser>> {
    let parsed = parse_reg_resp(reg_resp_text)?;
    log::info!(
        "REG-RESP v={} r={} n={} sig_len={}",
        parsed.version,
        parsed.request_id,
        parsed.phone_number,
        parsed.signature_hex.len()
    );

    if let Ok(pending_text) = std::fs::read_to_string(pending_path(state_dir)) {
        let pending: SmsRegPending = serde_json::from_str(&pending_text)?;
        if pending.request_id != parsed.request_id {
            log::warn!(
                "request id mismatch: pending {} vs REG-RESP {}",
                pending.request_id,
                parsed.request_id
            );
        }
    }

    let session = connect_aps(state_dir).await?;
    let push_token = session
        .conn
        .state
        .read()
        .await
        .token
        .clone()
        .ok_or_else(|| anyhow!("APS has no push token"))?;

    let sig_bytes = decode_signature_hex(&parsed.signature_hex)?;
    let phone_user = authenticate_phone(
        &parsed.phone_number,
        AuthPhone {
            push_token: Data::new(push_token.to_vec()),
            sigs: vec![Data::new(sig_bytes)],
        },
        session.config.as_ref(),
    )
    .await
    .map_err(|e| anyhow!("authenticate_phone: {e}"))?;

    log::info!("phone IDS auth OK for P:{}", parsed.phone_number);

    let mut users = state_dir.load_users().unwrap_or_default();
    users.retain(|u| !u.user_id.starts_with("P:"));
    users.push(phone_user);
    state_dir.save_users(&users)?;

    if do_register {
        let mut connected = connect(state_dir).await?;
        connected.register_ids().await?;
        persist_push_state(state_dir, &connected).await?;
        log::info!("register OK — check handles with doctor-handles");
    }

    Ok(users)
}

pub mod webhook {
    use super::*;
    use axum::{
        extract::State,
        http::StatusCode,
        routing::{get, post},
        Json, Router,
    };

    #[derive(Clone)]
    struct WebhookState {
        state_dir: SpikeStateDir,
        auto_register: bool,
    }

    #[derive(Deserialize)]
    struct TelnyxWebhook {
        data: TelnyxData,
    }

    #[derive(Deserialize)]
    struct TelnyxData {
        event_type: String,
        payload: TelnyxPayload,
    }

    #[derive(Deserialize)]
    struct TelnyxPayload {
        text: Option<String>,
    }

    #[derive(Deserialize)]
    struct BridgeIngest {
        text: String,
    }

    async fn complete_from_text(
        ctx: &WebhookState,
        text: &str,
    ) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
        if !text.contains("REG-RESP") {
            return Ok(Json(serde_json::json!({ "ok": true, "ignored": "not REG-RESP" })));
        }
        match sms_reg_complete(&ctx.state_dir, text, ctx.auto_register).await {
            Ok(_) => Ok(Json(serde_json::json!({ "ok": true, "completed": true }))),
            Err(e) => Err((StatusCode::BAD_REQUEST, format!("{e:#}"))),
        }
    }

    async fn handle_telnyx(
        State(ctx): State<Arc<WebhookState>>,
        Json(body): Json<TelnyxWebhook>,
    ) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
        if body.data.event_type != "message.received" {
            return Ok(Json(serde_json::json!({ "ok": true, "ignored": true })));
        }
        let Some(text) = body.data.payload.text else {
            return Ok(Json(serde_json::json!({ "ok": true, "ignored": "no text" })));
        };
        complete_from_text(&ctx, &text).await
    }

    async fn handle_bridge(
        State(ctx): State<Arc<WebhookState>>,
        Json(body): Json<BridgeIngest>,
    ) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
        complete_from_text(&ctx, &body.text).await
    }

    async fn handle_pending(
        State(ctx): State<Arc<WebhookState>>,
    ) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
        match load_pending(&ctx.state_dir) {
            Ok(Some(pending)) => Ok(Json(serde_json::json!({
                "ok": true,
                "pending": pending,
            }))),
            Ok(None) => Err((
                StatusCode::NOT_FOUND,
                "no sms-reg-pending.json — run sms-reg-send --dry-run first".to_string(),
            )),
            Err(e) => Err((StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}"))),
        }
    }

    pub async fn serve(state_dir: SpikeStateDir, listen: SocketAddr, auto_register: bool) -> Result<()> {
        let ctx = Arc::new(WebhookState {
            state_dir,
            auto_register,
        });
        let app = Router::new()
            .route("/webhooks/telnyx/sms-reg", post(handle_telnyx))
            .route("/webhooks/sms-reg/bridge", post(handle_bridge))
            .route("/webhooks/sms-reg/pending", get(handle_pending))
            .with_state(ctx);
        log::info!("sms-reg webhook on http://{listen}");
        log::info!("  Telnyx:  /webhooks/telnyx/sms-reg");
        log::info!("  Bridge:  POST /webhooks/sms-reg/bridge {{\"text\":\"REG-RESP?...\"}}");
        log::info!("  Pending: GET  /webhooks/sms-reg/pending");
        let listener = tokio::net::TcpListener::bind(listen).await?;
        axum::serve(listener, app).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_sample_reg_resp() {
        let sample = "REG-RESP?v=3;r=1604858336;n=+11234567890;s=CA21C50C645469B25F4B65C38A7DCEC56592E038F39489F35C7CD6972D";
        let parsed = parse_reg_resp(sample).unwrap();
        assert_eq!(parsed.request_id, 1604858336);
        assert_eq!(parsed.phone_number, "+11234567890");
    }

    #[test]
    fn build_reg_req_format() {
        let req = build_reg_req("AABB", 42);
        assert_eq!(req, "REG-REQ?v=3;t=AABB;r=42");
    }

    #[test]
    fn normalize_tmobile_gateway_short_code() {
        assert_eq!(normalize_gateway("22223333"), "22223333");
        assert!(!normalize_gateway("22223333").starts_with("+1"));
    }

    #[test]
    fn normalize_uk_gateway_e164() {
        assert_eq!(normalize_gateway("+447786205094"), "+447786205094");
    }

    #[test]
    fn short_code_detection() {
        assert!(is_apple_short_code_gateway("22223333"));
        assert!(is_apple_short_code_gateway("28818773"));
        assert!(!is_apple_short_code_gateway("+447786205094"));
    }
}
