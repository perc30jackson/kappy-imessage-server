#!/usr/bin/env bash
# Run kappy NAC validation wrapper in submit mode against the spike validation HTTP endpoint.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROVIDER="${KAPPY_NAC_PROVIDER:-$ROOT/tools/nac-validation-provider/kappy-nac-validation-provider}"
INTERVAL="${SUBMIT_INTERVAL:-300}"
URL="${VALIDATION_SUBMIT_URL:-http://127.0.0.1:8787/internal/validation}"

if [[ ! -x "$PROVIDER" ]]; then
  echo "Building kappy-nac-validation-provider..."
  make -C "$ROOT/tools/nac-validation-provider"
fi

exec "$PROVIDER" -submit-interval "$INTERVAL" "$URL"

