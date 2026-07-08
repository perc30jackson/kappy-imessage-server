#!/usr/bin/env bash
# Run on a Mac with working mac-registration-provider (macOS <= 14.3).
# Generates validation JSON and POSTs it to the pilot Mac's validation-server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROVIDER="${KAPPY_NAC_PROVIDER:-mac-registration-provider}"
INTERVAL="${SUBMIT_INTERVAL:-300}"
URL="${VALIDATION_SUBMIT_URL:?set VALIDATION_SUBMIT_URL, e.g. http://PILOT_IP:8787/internal/validation}"

if ! command -v "$PROVIDER" >/dev/null 2>&1; then
  echo "error: $PROVIDER not found (install Beeper mac-registration-provider on macOS <= 14.3)" >&2
  exit 1
fi

push_once() {
  local json
  json="$("$PROVIDER" -once)"
  curl -sf -X POST -H 'Content-Type: application/json' -d "$json" "$URL" >/dev/null
  echo "pushed validation to $URL"
}

while true; do
  if push_once; then
    :
  else
    echo "push failed; retrying in ${INTERVAL}s" >&2
  fi
  sleep "$INTERVAL"
done
