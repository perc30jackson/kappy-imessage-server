#!/usr/bin/env bash
# Export hardware identity from the UTM helper VM and re-activate kappy-spike on the host
# using that identity (VirtualMac2,1). Validation still comes from kappy-nacserv on the same VM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_HOST="${HELPER_HOST:-192.168.64.2}"
HELPER_USER="${HELPER_USER:-worker}"
HELPER_SSH="${HELPER_USER}@${HELPER_HOST}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -i "${HELPER_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}" -o IdentitiesOnly=yes)
HW_EXPORT_BIN="${KAPPY_HW_EXPORT_BIN:-$ROOT/tools/hw-export/.build/release/kappy-hw-export}"
SPIKE_BIN="${KAPPY_SPIKE_BIN:-$ROOT/spike/target/release/kappy-spike}"
STATE_DIR="${KAPPY_SPIKE_STATE_DIR:-$ROOT/spike/state}"
OUT_HW="${ROOT}/spike/utm-hw-export.bin"

log() { printf '==> %s\n' "$*"; }

build_hw_export() {
  if [[ -x "$HW_EXPORT_BIN" ]]; then
    return
  fi
  log "Building kappy-hw-export..."
  (cd "$ROOT/tools/hw-export" && swift build -c release)
}

build_spike() {
  if [[ -x "$SPIKE_BIN" ]]; then
    return
  fi
  log "Building kappy-spike..."
  (cd "$ROOT/spike" && CARGO_TARGET_DIR=target cargo build --release)
}

ssh_vm() {
  ssh "${SSH_OPTS[@]}" "$HELPER_SSH" "$@"
}

scp_vm() {
  scp "${SSH_OPTS[@]}" "$@"
}

export_hw_from_vm() {
  log "Copying kappy-hw-export to VM..."
  scp_vm "$HW_EXPORT_BIN" "$HELPER_SSH:/tmp/kappy-hw-export"
  ssh_vm "chmod +x /tmp/kappy-hw-export"

  log "Exporting hardware identity on VM (VirtualMac2,1)..."
  ssh_vm "/tmp/kappy-hw-export" >"$OUT_HW"
  [[ -s "$OUT_HW" ]] || { log "empty hw export"; exit 1; }

  log "VM hardware export: $OUT_HW ($(wc -c <"$OUT_HW" | tr -d ' ') bytes)"
  log "Inspect on host after activate:"
  printf '  plutil -p %s/state/hw_info.plist | grep board_id\n' "$ROOT/spike"
}

reactivate_pilot() {
  local backup="${STATE_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ -d "$STATE_DIR" ]]; then
    log "Backing up state to $backup"
    mv "$STATE_DIR" "$backup"
  fi
  mkdir -p "$STATE_DIR"

  export KAPPY_SPIKE_STATE_DIR="$STATE_DIR"
  log "Activating pilot with VM hardware identity..."
  "$SPIKE_BIN" activate --hw-info "$OUT_HW"

  if [[ -f "$ROOT/spike/.env.helper" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/spike/.env.helper"
    log "Refreshing validation from kappy-nacserv on VM..."
    "$SPIKE_BIN" fetch-validation-nacserv
  else
    log "No spike/.env.helper — run fetch-validation-nacserv manually"
  fi
}

show_vm_hw() {
  log "VM IORegistry snapshot:"
  ssh_vm "ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'board-id|IOPlatformSerialNumber|model' | head -5"
}

show_next_steps() {
  cat <<EOF

Pilot re-activated with UTM VM hardware identity.

Verify board_id is NOT Mac-0a000000:
  plutil -p $STATE_DIR/hw_info.plist | grep board_id

Then login on the HOST (not the VM):
  source $ROOT/spike/.env.helper
  export KAPPY_APPLE_ID='…'
  export KAPPY_APPLE_PASSWORD='…'
  cd $ROOT/spike
  $SPIKE_BIN login
  $SPIKE_BIN register

Note: Apple ID login runs on the physical Mac (26.5.1); only hardware + NAC come from the UTM VM.

EOF
}

main() {
  build_hw_export
  build_spike
  [[ -x "$HW_EXPORT_BIN" ]] || { log "missing $HW_EXPORT_BIN"; exit 1; }
  [[ -x "$SPIKE_BIN" ]] || { log "missing $SPIKE_BIN"; exit 1; }

  show_vm_hw
  export_hw_from_vm
  reactivate_pilot
  show_next_steps
  log "Done."
}

main "$@"
