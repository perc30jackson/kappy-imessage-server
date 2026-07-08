#!/usr/bin/env bash
# On the UTM helper VM: refresh validation from local nacserv, then register.
# Fixes 6004 (cross-machine / stale validation). Expect 6001 on VirtualMac2,1.
# If you get 6005 after import-ids-export / import-gui-registration, run:
#   kappy-spike --state-dir "$STATE_DIR" refresh-login
set -euo pipefail

STATE_DIR="${KAPPY_SPIKE_STATE_DIR:-$HOME/kappy-spike-state}"
SPIKE_BIN="${KAPPY_SPIKE_BIN:-$HOME/kappy-spike-bin/kappy-spike}"
NACSERV_URL="${KAPPY_NACSERV_URL:-http://127.0.0.1:8788}"
NACSERV_TOKEN="${KAPPY_NACSERV_TOKEN:?set KAPPY_NACSERV_TOKEN}"

export RUST_LOG="${RUST_LOG:-rustpush::ids::user=info,kappy_spike=info}"

echo "== fetch validation from local nacserv =="
"$SPIKE_BIN" --state-dir "$STATE_DIR" fetch-validation-nacserv \
  --url "$NACSERV_URL" --token "$NACSERV_TOKEN"

echo "== register =="
"$SPIKE_BIN" --state-dir "$STATE_DIR" register
