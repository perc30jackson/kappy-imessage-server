#!/usr/bin/env bash
# Run this IN Terminal.app ON THE VM (not over SSH) — do NOT use sudo.
# Requires: Xcode CLT, Developer Mode ON (+ reboot), GUI iMessage signed in.
set -euo pipefail

EXPORT="${1:-$HOME/ids-export.json}"
ROOT="${KAPPY_IDS_EXPORT_DIR:-$HOME/kappy-imessage-server/tools/kappy-ids-export}"

console_user() {
  stat -f %Su /dev/console 2>/dev/null || logname 2>/dev/null || whoami
}

if [[ "$(id -u)" -eq 0 ]]; then
  TARGET_USER="$(console_user)"
  TARGET_HOME="$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  TARGET_HOME="${TARGET_HOME:-/Users/${TARGET_USER}}"
  if [[ "$EXPORT" == "$HOME/"* ]] || [[ "$EXPORT" == ~/* ]]; then
    EXPORT="${TARGET_HOME}/ids-export.json"
  fi
  echo "Do not use sudo for capture (identityservicesd runs as your login user)." >&2
  echo "Re-running as ${TARGET_USER} -> ${EXPORT}" >&2
  exec sudo -u "${TARGET_USER}" \
    env KAPPY_IDS_USER="${TARGET_USER}" HOME="${TARGET_HOME}" USER="${TARGET_USER}" \
    KAPPY_IDS_SKIP_PRIVATE_KEY="${KAPPY_IDS_SKIP_PRIVATE_KEY:-1}" \
    "${ROOT}/capture-ids.sh" "${EXPORT}"
fi

if ! xcrun --find lldb >/dev/null 2>&1; then
  echo "Install Xcode CLT: xcode-select --install" >&2
  exit 1
fi

echo "Note: Messages may pause briefly during capture (~5s). It should stay signed in." >&2
if csrutil status 2>/dev/null | grep -qi "enabled"; then
  echo "WARNING: SIP is enabled — lldb cannot attach to identityservicesd on this Mac." >&2
  echo "  Either disable SIP (Recovery: csrutil disable) or use:" >&2
  echo "  ~/kappy-spike-bin/kappy-spike --state-dir ~/kappy-spike-state import-gui-registration --synthesize" >&2
  exit 1
fi
export KAPPY_IDS_SKIP_PRIVATE_KEY="${KAPPY_IDS_SKIP_PRIVATE_KEY:-1}"

DEV_STATUS="$(DevToolsSecurity -status 2>&1)"
if [[ "$DEV_STATUS" != *"enabled"* ]]; then
  echo "Developer Mode is OFF ($DEV_STATUS)." >&2
  echo "1. System Settings -> Privacy & Security -> Developer Mode -> On" >&2
  echo "2. Confirm with your password when prompted" >&2
  echo "3. Reboot the VM (required — attach will fail until you do)" >&2
  echo "4. After reboot, run once: sudo DevToolsSecurity -enable" >&2
  echo "5. Re-run (no sudo): bash ~/vm-gui-capture-local.sh $EXPORT" >&2
  exit 1
fi

"$ROOT/capture-ids.sh" "$EXPORT"
echo
echo "Next (same machine):"
echo "  ~/kappy-spike-bin/kappy-spike --state-dir ~/kappy-spike-state refresh-login"
echo "  ~/kappy-spike-bin/kappy-spike --state-dir ~/kappy-spike-state import-ids-export --file $EXPORT"
echo "  ~/kappy-spike-bin/kappy-spike --state-dir ~/kappy-spike-state send --to +18606050710 --body test"
