#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPIKE="${KAPPY_SPIKE_BIN:-$ROOT/spike/target/release/kappy-spike}"
STATE_DIR="${KAPPY_SPIKE_STATE_DIR:-$ROOT/spike/state}"
INTERVAL="${SUBMIT_INTERVAL:-300}"

: "${KAPPY_NACSERV_TOKEN:?set KAPPY_NACSERV_TOKEN from helper Mac ~/.config/kappy-nacserv/token}"
export KAPPY_NACSERV_URL="${KAPPY_NACSERV_URL:-http://127.0.0.1:8788}"

if [[ ! -x "$SPIKE" ]]; then
  echo "Building kappy-spike..."
  (cd "$ROOT/spike" && cargo build --release)
fi

export KAPPY_SPIKE_STATE_DIR="$STATE_DIR"
exec "$SPIKE" validation-nacserv-poller --interval-secs "$INTERVAL"
