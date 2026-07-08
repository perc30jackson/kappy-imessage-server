#!/usr/bin/env bash
# Poll Beeper registration relay for validation data (macOS 26 alternate path).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPIKE="${KAPPY_SPIKE_BIN:-$ROOT/spike/target/release/kappy-spike}"
STATE_DIR="${KAPPY_SPIKE_STATE_DIR:-$ROOT/spike/state}"
INTERVAL="${SUBMIT_INTERVAL:-300}"

: "${KAPPY_RELAY_CODE:?set KAPPY_RELAY_CODE from mac-registration-provider -relay on an older Mac}"

if [[ ! -x "$SPIKE" ]]; then
  echo "Building kappy-spike..."
  (cd "$ROOT/spike" && cargo build --release)
fi

export KAPPY_SPIKE_STATE_DIR="$STATE_DIR"
exec "$SPIKE" validation-relay-poller --interval-secs "$INTERVAL"
