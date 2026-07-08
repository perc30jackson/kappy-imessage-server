#!/usr/bin/env bash
# Start kappy-api REST server for the 3-line PoC fleet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KAPPY_REPO_ROOT="$ROOT"

CONFIG="${KAPPY_LINES_CONFIG:-$ROOT/poc/lines.toml}"
if [[ ! -f "$CONFIG" ]]; then
  echo "missing $CONFIG — copy poc/lines.toml.example → poc/lines.toml" >&2
  exit 1
fi

# Optional: load shared env for nacserv token override
[[ -f "$ROOT/poc/shared.env" ]] && source "$ROOT/poc/shared.env"

API_BIN="$ROOT/target/release/kappy-api"
if [[ ! -x "$API_BIN" ]]; then
  echo "building kappy-api..."
  (cd "$ROOT" && cargo build --release -p kappy-api)
fi

export KAPPY_LINES_CONFIG="$CONFIG"
export RUST_LOG="${RUST_LOG:-kappy_api=info,kappy_spike=info,rustpush::ids::user=info}"

exec "$API_BIN"
