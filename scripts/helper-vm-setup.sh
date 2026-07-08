#!/usr/bin/env bash
# Runs ON the helper VM. Installs NAC provider + kappy-nacserv.
# macOS ≤14.3: mac-registration-provider (Beeper)
# macOS ≥15:   kappy-nac-validation-provider (pushed by remote-setup-helper-vm.sh)
set -euo pipefail

INSTALL_ROOT="${KAPPY_HELPER_ROOT:-/usr/local/kappy}"
NACSERV_BIN="${KAPPY_NACSERV_BIN:-$INSTALL_ROOT/kappy-nacserv}"
LISTEN_ADDR="${KAPPY_NACSERV_LISTEN:-0.0.0.0:8788}"
TOKEN_FILE="${KAPPY_NACSERV_TOKEN_FILE:-$INSTALL_ROOT/token}"
MACOS_MAJOR=0
PROVIDER_BIN=""

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_sudo() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "re-run with sudo: sudo $0"
  fi
}

check_macos() {
  local ver major
  ver="$(sw_vers -productVersion)"
  log "macOS version: $ver ($(sw_vers -buildVersion))"
  major="${ver%%.*}"
  MACOS_MAJOR="$major"
  if [[ "$major" -ge 15 ]]; then
    PROVIDER_BIN="${KAPPY_NAC_PROVIDER:-$INSTALL_ROOT/kappy-nac-validation-provider}"
    log "macOS $ver — using kappy-nac-validation-provider (iCloud-capable VM path)"
  else
    PROVIDER_BIN="${KAPPY_NAC_PROVIDER:-/usr/local/bin/mac-registration-provider}"
    log "macOS $ver — using mac-registration-provider (≤14.3)"
  fi
}

install_provider() {
  if [[ -x "$PROVIDER_BIN" ]]; then
    log "NAC provider already at $PROVIDER_BIN"
    return
  fi
  if [[ "$MACOS_MAJOR" -ge 15 ]]; then
    die "kappy-nac-validation-provider not found at $PROVIDER_BIN — run remote-setup-helper-vm.sh from the pilot (pushes provider for macOS 15+ guests)"
  fi
  log "Installing mac-registration-provider..."
  local tmp
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" \
    'https://github.com/beeper/mac-registration-provider/releases/download/v0.3.0/mac-registration-provider'
  mkdir -p "$(dirname "$PROVIDER_BIN")"
  install -m 755 "$tmp" "$PROVIDER_BIN"
  xattr -cr "$PROVIDER_BIN" 2>/dev/null || true
  rm -f "$tmp"
  log "Installed $PROVIDER_BIN"
}

install_nacserv() {
  [[ -x "$NACSERV_BIN" ]] || die "kappy-nacserv not found at $NACSERV_BIN (push from host first)"
}

ensure_token() {
  mkdir -p "$(dirname "$TOKEN_FILE")"
  if [[ -f "$TOKEN_FILE" ]] && [[ "$(wc -c < "$TOKEN_FILE" | tr -d ' ')" -ge 16 ]]; then
    log "Using existing token at $TOKEN_FILE"
    return
  fi
  if [[ -n "${KAPPY_NACSERV_TOKEN:-}" ]]; then
    printf '%s' "$KAPPY_NACSERV_TOKEN" >"$TOKEN_FILE"
  else
    uuidgen | tr '[:upper:]' '[:lower:]' >"$TOKEN_FILE"
  fi
  chmod 600 "$TOKEN_FILE"
  log "Bearer token: $(cat "$TOKEN_FILE")"
}

test_provider() {
  log "Testing $PROVIDER_BIN -once..."
  local out
  out="$(mktemp)"
  if ! "$PROVIDER_BIN" -once >"$out" 2>/tmp/kappy-provider-test.err; then
    cat /tmp/kappy-provider-test.err >&2
    die "NAC provider -once failed"
  fi
  if ! grep -q '"validation_data"' "$out"; then
    head -c 500 "$out" >&2
    die "provider output missing validation_data"
  fi
  log "NAC generation OK ($(wc -c < "$out" | tr -d ' ') bytes JSON)"
  rm -f "$out"
}

write_launchdaemon() {
  local token plist
  token="$(cat "$TOKEN_FILE")"
  plist="/Library/LaunchDaemons/com.kappy.nacserv.plist"
  log "Writing $plist (listen $LISTEN_ADDR)"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.kappy.nacserv</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NACSERV_BIN}</string>
    <string>--listen</string>
    <string>${LISTEN_ADDR}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>KAPPY_NAC_PROVIDER</key>
    <string>${PROVIDER_BIN}</string>
    <key>KAPPY_NACSERV_TOKEN</key>
    <string>${token}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/kappy-nacserv.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/kappy-nacserv.err</string>
</dict>
</plist>
EOF
  chmod 644 "$plist"
  launchctl bootout system/com.kappy.nacserv 2>/dev/null || true
  launchctl bootstrap system "$plist"
  launchctl enable system/com.kappy.nacserv
  launchctl kickstart -k system/com.kappy.nacserv
}

verify_http() {
  sleep 2
  local token ip
  token="$(cat "$TOKEN_FILE")"
  ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
  log "Health: $(curl -fsS "http://127.0.0.1:8788/health" 2>/dev/null || echo FAIL)"
  if curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:8788/" | head -c 80 | grep -q '"data"'; then
    log "Authenticated validation endpoint OK"
  else
    die "GET / failed — check /var/log/kappy-nacserv.err"
  fi
  log "Helper ready at http://${ip}:8788"
  log "Pilot env:"
  printf '  export KAPPY_NACSERV_URL=http://%s:8788\n' "$ip"
  printf '  export KAPPY_NACSERV_TOKEN=%s\n' "$token"
}

main() {
  need_sudo
  check_macos
  mkdir -p "$INSTALL_ROOT"
  install_provider
  install_nacserv
  ensure_token
  test_provider
  write_launchdaemon
  verify_http
}

main "$@"
