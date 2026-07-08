#!/usr/bin/env bash
# Run from the HOST Mac. Pushes kappy-nacserv + runs helper-vm-setup.sh over SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_HOST="${HELPER_HOST:-192.168.64.3}"
HELPER_USER="${HELPER_USER:-henrynguyen}"
HELPER_SSH="${HELPER_USER}@${HELPER_HOST}"
INSTALL_ROOT="${KAPPY_HELPER_ROOT:-/usr/local/kappy}"
NACSERV_LOCAL="${KAPPY_NACSERV_BIN:-$ROOT/tools/kappy-nacserv/target/release/kappy-nacserv}"
NAC_PROVIDER_LOCAL="${KAPPY_NAC_PROVIDER_LOCAL:-$ROOT/tools/nac-validation-provider/kappy-nac-validation-provider}"
SSH_IDENTITY="${HELPER_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -f "$SSH_IDENTITY" ]]; then
  SSH_OPTS+=(-i "$SSH_IDENTITY" -o IdentitiesOnly=yes)
fi

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

build_nacserv() {
  if [[ -x "$NACSERV_LOCAL" ]]; then
    return
  fi
  log "Building kappy-nacserv..."
  CARGO_TARGET_DIR="$ROOT/tools/kappy-nacserv/target" \
    cargo build --release --manifest-path "$ROOT/tools/kappy-nacserv/Cargo.toml"
}

build_nac_provider() {
  if [[ -x "$NAC_PROVIDER_LOCAL" ]]; then
    return
  fi
  log "Building kappy-nac-validation-provider..."
  make -C "$ROOT/tools/nac-validation-provider"
}

guest_macos_major() {
  ssh_cmd "$HELPER_SSH" 'sw_vers -productVersion' 2>/dev/null | cut -d. -f1
}

ssh_cmd() {
  if [[ -n "${HELPER_SSH_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    sshpass -e ssh "${SSH_OPTS[@]}" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$@"
  fi
}

scp_cmd() {
  if [[ -n "${HELPER_SSH_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    sshpass -e scp "${SSH_OPTS[@]}" "$@"
  else
    scp "${SSH_OPTS[@]}" "$@"
  fi
}

wait_for_ssh() {
  local tries="${1:-30}"
  log "Waiting for SSH port on $HELPER_HOST (max ${tries}s)..."
  for ((i = 1; i <= tries; i++)); do
    if nc -z -G 1 "$HELPER_HOST" 22 2>/dev/null; then
      log "SSH port open"
      return 0
    fi
    sleep 1
  done
  return 1
}

check_ssh_auth() {
  if ssh_cmd -o BatchMode=yes -o ConnectTimeout=5 "$HELPER_SSH" 'echo ok' 2>/dev/null | grep -q ok; then
    return 0
  fi
  if [[ -n "${HELPER_SSH_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    export SSHPASS="$HELPER_SSH_PASSWORD"
    ssh_cmd -o ConnectTimeout=5 "$HELPER_SSH" 'echo ok' 2>/dev/null | grep -q ok
    return $?
  fi
  return 1
}

print_ssh_enable_help() {
  cat >&2 <<EOF

SSH port on $HELPER_HOST is not open.

In the UTM window for this VM, open Terminal and run:

  sudo systemsetup -setremotelogin on

Then re-run:

  HELPER_HOST=$HELPER_HOST HELPER_USER=$HELPER_USER $0

EOF
}

print_ssh_auth_help() {
  cat >&2 <<EOF

SSH to $HELPER_SSH requires authentication.

Option A — copy your SSH key (enter VM password once):

  ssh-copy-id $HELPER_SSH
  HELPER_HOST=$HELPER_HOST HELPER_USER=$HELPER_USER $0

Option B — password via sshpass:

  brew install sshpass   # or: brew install hudochenkov/sshpass/sshpass
  HELPER_SSH_PASSWORD='your-vm-password' HELPER_HOST=$HELPER_HOST HELPER_USER=$HELPER_USER $0

EOF
}

sudo_remote() {
  local pass="${HELPER_SUDO_PASSWORD:-${HELPER_SSH_PASSWORD:-}}"
  local cmd="$*"
  if [[ -n "$pass" ]]; then
    ssh_cmd "$HELPER_SSH" "printf '%s\\n' $(printf %q "$pass") | sudo -S -p '' bash -c $(printf %q "$cmd")"
  else
    ssh_cmd "$HELPER_SSH" "sudo bash -c $(printf %q "$cmd")"
  fi
}

push_files() {
  local major files=()
  major="$(guest_macos_major || echo 0)"
  log "Guest macOS major version: ${major:-unknown}"

  files=("$NACSERV_LOCAL" "$ROOT/scripts/helper-vm-setup.sh")
  if [[ "${major:-0}" -ge 15 ]]; then
    build_nac_provider
    [[ -x "$NAC_PROVIDER_LOCAL" ]] || die "missing $NAC_PROVIDER_LOCAL"
    files+=("$NAC_PROVIDER_LOCAL")
  fi

  log "Copying artifacts to $HELPER_SSH:$INSTALL_ROOT/"
  sudo_remote "mkdir -p '$INSTALL_ROOT' && chown \$(whoami) '$INSTALL_ROOT'"
  scp_cmd "${files[@]}" "$HELPER_SSH:/tmp/"
  sudo_remote "install -m 755 /tmp/kappy-nacserv '$INSTALL_ROOT/kappy-nacserv'"
  if [[ "${major:-0}" -ge 15 ]]; then
    sudo_remote "install -m 755 /tmp/kappy-nac-validation-provider '$INSTALL_ROOT/kappy-nac-validation-provider'"
    ssh_cmd "$HELPER_SSH" "xattr -cr '$INSTALL_ROOT/kappy-nac-validation-provider' 2>/dev/null || true"
    # linker-signed binaries from the pilot host are SIGKILL'd on macOS 15 guests without ad-hoc resign
    sudo_remote "codesign -s - -f '$INSTALL_ROOT/kappy-nac-validation-provider'"
  fi
}

run_remote_setup() {
  log "Running remote setup (sudo)..."
  local pass major env_extra=""
  major="$(guest_macos_major || echo 0)"
  if [[ "${major:-0}" -ge 15 ]]; then
    env_extra="KAPPY_NAC_PROVIDER='$INSTALL_ROOT/kappy-nac-validation-provider'"
  fi
  pass="${HELPER_SUDO_PASSWORD:-${HELPER_SSH_PASSWORD:-}}"
  if [[ -n "$pass" ]]; then
    ssh_cmd "$HELPER_SSH" "printf '%s\\n' $(printf %q "$pass") | sudo -S -p '' env KAPPY_NACSERV_BIN='$INSTALL_ROOT/kappy-nacserv' $env_extra bash /tmp/helper-vm-setup.sh"
  else
    ssh_cmd "$HELPER_SSH" "sudo env KAPPY_NACSERV_BIN='$INSTALL_ROOT/kappy-nacserv' $env_extra bash /tmp/helper-vm-setup.sh"
  fi
}

configure_pilot() {
  local token ip pass="${HELPER_SUDO_PASSWORD:-${HELPER_SSH_PASSWORD:-}}"
  if [[ -n "$pass" ]]; then
    token="$(ssh_cmd "$HELPER_SSH" "printf '%s\\n' $(printf %q "$pass") | sudo -S -p '' cat '$INSTALL_ROOT/token'")"
  else
    token="$(ssh_cmd "$HELPER_SSH" "sudo cat '$INSTALL_ROOT/token'")"
  fi
  ip="$(ssh_cmd "$HELPER_SSH" "ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1")"
  local env_file="$ROOT/spike/.env.helper"
  cat >"$env_file" <<EOF
# Helper VM — source before fetch-validation-nacserv
export KAPPY_NACSERV_URL=http://${ip}:8788
export KAPPY_NACSERV_TOKEN=${token}
export KAPPY_SPIKE_STATE_DIR=$ROOT/spike/state
EOF
  chmod 600 "$env_file"
  log "Wrote pilot env: $env_file"
  log "Fetch validation:"
  printf '  source %s && cd %s/spike && ./target/release/kappy-spike fetch-validation-nacserv\n' "$env_file" "$ROOT"
}

main() {
  build_nacserv
  [[ -x "$NACSERV_LOCAL" ]] || die "missing $NACSERV_LOCAL"

  if ! wait_for_ssh 30; then
    print_ssh_enable_help
    exit 1
  fi

  if ! check_ssh_auth; then
    print_ssh_auth_help
    exit 1
  fi

  local major
  major="$(guest_macos_major || echo 0)"
  if [[ "${major:-0}" -lt 15 ]]; then
    log "Guest is macOS ${major}.x — iCloud login in VM is unlikely to work."
    log "For Apple-supported iCloud path see: docs/utm-macos15-fresh-vm.md"
  fi

  push_files
  run_remote_setup
  configure_pilot
  log "Done."
  if [[ "${major:-0}" -ge 15 ]]; then
    log "Next: sign into iCloud in the VM, then run scripts/test-vm-full-stack.sh"
  fi
}

main "$@"
