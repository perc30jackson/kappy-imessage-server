#!/usr/bin/env bash
# Run full kappy-spike stack on the UTM helper VM (VirtualMac2,1 + local nacserv).
# For fresh macOS 15+ VM setup (iCloud path), see docs/utm-macos15-fresh-vm.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_HOST="${HELPER_HOST:-192.168.64.3}"
HELPER_USER="${HELPER_USER:-henrynguyen}"
HELPER_SSH="${HELPER_USER}@${HELPER_HOST}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -i "${HELPER_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}" -o IdentitiesOnly=yes)
SPIKE_BIN="${KAPPY_SPIKE_BIN:-$ROOT/spike/target/release/kappy-spike}"
HW_EXPORT_BIN="${KAPPY_HW_EXPORT_BIN:-$ROOT/tools/hw-export/.build/release/kappy-hw-export}"
HELPER_HOME="${HELPER_HOME:-$(ssh "${SSH_OPTS[@]}" "$HELPER_SSH" 'printf %s "$HOME"')}"
STATE_DIR="${KAPPY_VM_STATE_DIR:-$HELPER_HOME/kappy-spike-state}"
if [[ -f "$ROOT/spike/.env.helper" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/spike/.env.helper"
fi
NACSERV_TOKEN="${KAPPY_NACSERV_TOKEN:-}"

log() { printf '==> %s\n' "$*"; }

ssh_vm() { ssh "${SSH_OPTS[@]}" "$HELPER_SSH" "$@"; }
scp_vm() { scp "${SSH_OPTS[@]}" "$@"; }

preflight_guest() {
  local ver major
  ver="$(ssh_vm 'sw_vers -productVersion' 2>/dev/null || echo unknown)"
  major="${ver%%.*}"
  log "Guest macOS: $ver"
  if [[ "$major" != "unknown" && "$major" -lt 15 ]]; then
    log "WARNING: guest < 15 — expect -80009 on login unless you recreate VM (docs/utm-macos15-fresh-vm.md)"
  fi
}

[[ -x "$SPIKE_BIN" ]] || { log "Build spike first: cd spike && CARGO_TARGET_DIR=target cargo build --release"; exit 1; }
[[ -x "$HW_EXPORT_BIN" ]] || { log "Build hw-export: cd tools/hw-export && swift build -c release"; exit 1; }

preflight_guest

log "Deploying spike + hw-export to VM..."
scp_vm "$SPIKE_BIN" "$HELPER_SSH:/tmp/kappy-spike"
scp_vm "$HW_EXPORT_BIN" "$HELPER_SSH:/tmp/kappy-hw-export"
ssh_vm "xattr -cr /tmp/kappy-spike /tmp/kappy-hw-export 2>/dev/null || true; pkill -9 -f kappy-spike 2>/dev/null || true"

log "Activate + validation on VM..."
ssh_vm "set -e
  rm -rf '$STATE_DIR' && mkdir -p '$STATE_DIR'
  export KAPPY_SPIKE_STATE_DIR='$STATE_DIR'
  export KAPPY_NACSERV_URL=http://127.0.0.1:8788
  export KAPPY_NACSERV_TOKEN='${NACSERV_TOKEN:?set KAPPY_NACSERV_TOKEN or source spike/.env.helper}'
  /tmp/kappy-hw-export > /tmp/hw.bin
  /tmp/kappy-spike activate --hw-info /tmp/hw.bin
  /tmp/kappy-spike fetch-validation-nacserv
  plutil -p '$STATE_DIR/hw_info.plist' | grep -E 'product_name|platform_serial|device_id' | head -3
  wc -c '$STATE_DIR/validation.json'
"

log "Login (auto remote anisette on VirtualMac — do not set KAPPY_ANISETTE=raw)..."
ssh_vm "export KAPPY_SPIKE_STATE_DIR='$STATE_DIR'
  export KAPPY_APPLE_ID='${KAPPY_APPLE_ID:?set KAPPY_APPLE_ID on pilot before running}'
  export KAPPY_APPLE_PASSWORD='${KAPPY_APPLE_PASSWORD:?set KAPPY_APPLE_PASSWORD on pilot before running}'
  export KAPPY_2FA_CODE='${KAPPY_2FA_CODE:-}'
  unset KAPPY_ANISETTE
  RUST_LOG=info,icloud_auth=error,kappy_spike=info /tmp/kappy-spike login"

log "Register..."
ssh_vm "export KAPPY_SPIKE_STATE_DIR='$STATE_DIR'
  RUST_LOG=info /tmp/kappy-spike register"

log "VM full stack complete. id.plist:"
ssh_vm "ls -la '$STATE_DIR/id.plist' '$STATE_DIR/gsa.plist'"
