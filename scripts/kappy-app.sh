#!/usr/bin/env bash
# Launch Kappy: REST API + web portal. Opens browser to the control UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KAPPY_REPO_ROOT="$ROOT"

CONFIG="${KAPPY_LINES_CONFIG:-$ROOT/poc/lines.toml}"
if [[ ! -f "$CONFIG" ]]; then
  echo "missing $CONFIG — copy poc/lines.toml.example → poc/lines.toml" >&2
  exit 1
fi

LISTEN="$(python3 - <<'PY' "$CONFIG"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)
print(cfg.get("api", {}).get("listen", "127.0.0.1:8080"))
PY
)"

[[ -f "$ROOT/poc/shared.env" ]] && source "$ROOT/poc/shared.env"

API_BIN="$ROOT/target/release/kappy-api"
if [[ ! -x "$API_BIN" ]]; then
  echo "building kappy-api (first run may take a few minutes)..."
  (cd "$ROOT" && cargo build --release -p kappy-api)
fi

export KAPPY_LINES_CONFIG="$CONFIG"
export RUST_LOG="${RUST_LOG:-kappy_api=info,kappy_spike=info,rustpush::ids::user=info}"

URL="http://${LISTEN}/"
echo "Kappy portal: $URL"
echo "Press Ctrl+C to stop."

# Open browser after server is up (background)
(
  for _ in $(seq 1 30); do
    if curl -sf "http://${LISTEN}/health" >/dev/null 2>&1; then
      open "$URL" 2>/dev/null || xdg-open "$URL" 2>/dev/null || true
      break
    fi
    sleep 0.5
  done
) &

exec "$API_BIN"
