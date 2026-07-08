use anyhow::{Context, Result};

use crate::engine::connect_aps;
use crate::state::SpikeStateDir;

/// Query Apple `id-get-handles` for each IDS user (after login).
pub async fn doctor_handles(state_dir: &SpikeStateDir) -> Result<()> {
    let session = connect_aps(state_dir).await?;
    let users = session
        .state_dir
        .load_users()
        .context("load id.plist — run login first")?;
    let aps_state = session.conn.state.read().await.clone();

    println!("IDS handle probe (Apple id-get-handles)\n");
    println!("state: {}", state_dir.root.display());
    println!("APS push token: {}", aps_state.token.is_some());

    let mut any_tel = false;
    let mut any_mailto = false;

    for user in &users {
        let kind = if user.user_id.starts_with("P:") {
            "phone (P:)"
        } else {
            "Apple ID"
        };
        println!("\n[{kind}] user_id={}", user.user_id);

        if let Some(madrid) = user.registration.get("com.apple.madrid") {
            if madrid.handles.is_empty() {
                println!("  local registration: (empty — run register)");
            } else {
                println!("  local registration: {}", madrid.handles.join(", "));
            }
        } else {
            println!("  local registration: none");
        }

        match user.get_handle_data(&aps_state).await {
            Ok(handles) if handles.is_empty() => {
                println!("  Apple allows: (none)");
            }
            Ok(handles) => {
                println!("  Apple allows registration for:");
                for h in handles {
                    if h.uri.starts_with("tel:") {
                        any_tel = true;
                    }
                    if h.uri.starts_with("mailto:") {
                        any_mailto = true;
                    }
                    println!("    {}", h.uri);
                    if !h.aliases.is_empty() {
                        for (alias, attrs) in &h.aliases {
                            let feat = if attrs.feature_id.is_empty() {
                                "alias"
                            } else {
                                attrs.feature_id.as_str()
                            };
                            println!("      alias {alias} ({feat})");
                        }
                    }
                }
            }
            Err(e) => {
                println!("  id-get-handles failed: {e:#}");
            }
        }
    }

    println!();
    if any_tel {
        println!("tel: handles present — Mac-only register can include phone if validation + register succeed.");
    } else {
        println!("No tel: in Apple’s allowed list — SMSLess/SMS REG or Apple ID phone linking required before register.");
    }
    if any_mailto {
        println!("mailto: handles present — email iMessage path is available.");
    }
    Ok(())
}
