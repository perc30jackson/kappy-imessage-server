#!/usr/bin/env bash
# Run Beeper mac-registration-provider in submit mode against the spike validation HTTP endpoint.
# Requires: mac-registration-provider binary on PATH (see beeper/mac-registration-provider releases).
set -euo pipefail
INTERVAL="${SUBMIT_INTERVAL:-300}"
URL="${VALIDATION_SUBMIT_URL:-http://127.0.0.1:8787/internal/validation}"
TOKEN="${SUBMIT_TOKEN:-}"

ARGS=(-submit-interval "${INTERVAL}s")
if [[ -n "$TOKEN" ]]; then
  ARGS+=(-submit-token "$TOKEN")
fi

echo "Submitting validation data every ${INTERVAL}s to ${URL}"
exec mac-registration-provider "${ARGS[@]}" "$URL"
