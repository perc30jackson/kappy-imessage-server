#!/usr/bin/env bash
# Run on the UTM VM (GUI iMessage must be active). Requires Xcode CLT (lldb).
# Exports GUI IDS certs and imports them into kappy-spike state, then send.
set -euo pipefail

STATE_DIR="${KAPPY_SPIKE_STATE_DIR:-$HOME/kappy-spike-state}"
EXPORT_PATH="${1:-$HOME/ids-export.json}"
SPIKE_BIN="${KAPPY_SPIKE_BIN:-$HOME/kappy-spike-bin/kappy-spike}"
IDS_EXPORT_DIR="${KAPPY_IDS_EXPORT_DIR:-$HOME/kappy-imessage-server/tools/kappy-ids-export}"

if [[ ! -x "$SPIKE_BIN" ]]; then
  echo "missing kappy-spike: $SPIKE_BIN" >&2
  exit 1
fi

if [[ -f "$EXPORT_PATH" ]]; then
  echo "== using existing export: $EXPORT_PATH =="
elif xcrun --find lldb >/dev/null 2>&1 && [[ -x "$IDS_EXPORT_DIR/capture-ids.sh" ]]; then
  echo "== capture GUI IDS registrations =="
  if KAPPY_IDS_USER="${USER}" KAPPY_IDS_CAPTURE_OUT="$EXPORT_PATH" \
    "$IDS_EXPORT_DIR/capture-ids.sh" "$EXPORT_PATH"; then
    echo "capture OK"
  else
    echo "capture failed — falling back to idstatuscache synthesize" >&2
    RUST_LOG=info "$SPIKE_BIN" --state-dir "$STATE_DIR" refresh-login
    RUST_LOG=info "$SPIKE_BIN" --state-dir "$STATE_DIR" import-gui-registration --synthesize
    EXPORT_PATH=""
  fi
else
  echo "lldb unavailable — using idstatuscache synthesize" >&2
  RUST_LOG=info "$SPIKE_BIN" --state-dir "$STATE_DIR" refresh-login
  RUST_LOG=info "$SPIKE_BIN" --state-dir "$STATE_DIR" import-gui-registration --synthesize
  EXPORT_PATH=""
fi

if [[ -n "$EXPORT_PATH" ]]; then
  echo "== refresh auth + import export into spike state ($STATE_DIR) =="
  RUST_LOG=info "$SPIKE_BIN" --state-dir "$STATE_DIR" refresh-login
  RUST_LOG=info "$SPIKE_BIN" --state-dir "$STATE_DIR" \
    import-ids-export --file "$EXPORT_PATH"
fi

echo "== send test (no register) =="
TO="${KAPPY_SEND_TO:-+18606050710}"
BODY="${KAPPY_SEND_BODY:-kappy vm gui-import test}"
RUST_LOG=info "$SPIKE_BIN" --state-dir "$STATE_DIR" send --to "$TO" --body "$BODY"
