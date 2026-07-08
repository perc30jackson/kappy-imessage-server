#!/usr/bin/env bash
# Run sms-reg-webhook locally + ngrok tunnel + update Telnyx webhook URL.
#
# Prereqs:
#   1. poc/ngrok.env with NGROK_AUTHTOKEN (copy from poc/ngrok.env.example)
#   2. poc/lines/line-N.env with TELNYX_* vars
#   3. kappy-spike built (auto-builds if missing)
#
# Usage:
#   ./scripts/poc-sms-reg-tunnel.sh [line] [--register]
#   ./scripts/poc-sms-reg-tunnel.sh 2 --register
#
# Leaves webhook + ngrok running until Ctrl+C.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE=2
REGISTER=false

for arg in "$@"; do
  case "$arg" in
    --register) REGISTER=true ;;
    1|2|3) LINE="$arg" ;;
    *)
      echo "unknown arg: $arg (usage: poc-sms-reg-tunnel.sh [1|2|3] [--register])" >&2
      exit 1
      ;;
  esac
done

SHARED_ENV="$ROOT/poc/shared.env"
LINE_ENV="$ROOT/poc/lines/line-${LINE}.env"
NGROK_ENV="$ROOT/poc/ngrok.env"

for f in "$SHARED_ENV" "$LINE_ENV"; do
  if [[ ! -f "$f" ]]; then
    echo "missing $f" >&2
    exit 1
  fi
done

# shellcheck source=/dev/null
source "$SHARED_ENV"
# shellcheck source=/dev/null
source "$LINE_ENV"

PORT="${KAPPY_SMS_REG_WEBHOOK_PORT:-8790}"
WEBHOOK_PID=""
NGROK_PID=""

cleanup() {
  local code=$?
  [[ -n "$WEBHOOK_PID" ]] && kill "$WEBHOOK_PID" 2>/dev/null || true
  [[ -n "$NGROK_PID" ]] && kill "$NGROK_PID" 2>/dev/null || true
  exit "$code"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$NGROK_ENV" ]]; then
  echo "missing $NGROK_ENV" >&2
  echo "  1. Sign up: https://dashboard.ngrok.com/signup" >&2
  echo "  2. Copy poc/ngrok.env.example → poc/ngrok.env" >&2
  echo "  3. Paste authtoken from https://dashboard.ngrok.com/get-started/your-authtoken" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$NGROK_ENV"

if [[ -z "${NGROK_AUTHTOKEN:-}" ]]; then
  echo "NGROK_AUTHTOKEN is empty in $NGROK_ENV" >&2
  exit 1
fi

if ! command -v ngrok >/dev/null 2>&1; then
  echo "ngrok not found — install: brew install ngrok/ngrok/ngrok" >&2
  exit 1
fi

ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null 2>&1 || true

SPIKE="${KAPPY_SPIKE_BIN:-$ROOT/target/release/kappy-spike}"
if [[ ! -x "$SPIKE" ]]; then
  echo "building kappy-spike..."
  (cd "$ROOT" && cargo build --release -p kappy-spike)
  SPIKE="$ROOT/target/release/kappy-spike"
fi

mkdir -p "$KAPPY_SPIKE_STATE_DIR"
export KAPPY_SPIKE_STATE_DIR

WEBHOOK_ARGS=(sms-reg-webhook --listen "127.0.0.1:${PORT}")
if $REGISTER; then
  WEBHOOK_ARGS+=(--register)
fi

echo "Starting sms-reg-webhook on 127.0.0.1:${PORT} (line ${LINE})..."
"$SPIKE" --state-dir "$KAPPY_SPIKE_STATE_DIR" "${WEBHOOK_ARGS[@]}" &
WEBHOOK_PID=$!

# Wait for webhook to bind
for _ in $(seq 1 30); do
  if curl -sS -o /dev/null "http://127.0.0.1:${PORT}/webhooks/telnyx/sms-reg" -X POST \
    -H "Content-Type: application/json" \
    -d '{"data":{"event_type":"message.received","payload":{"text":"ping"}}}' 2>/dev/null; then
    break
  fi
  sleep 0.2
done

echo "Starting ngrok http ${PORT}..."
ngrok http "$PORT" --log=stdout >/tmp/kappy-ngrok.log 2>&1 &
NGROK_PID=$!

PUBLIC_URL=""
for _ in $(seq 1 60); do
  TUNNELS="$(curl -sS http://127.0.0.1:4040/api/tunnels 2>/dev/null || true)"
  PUBLIC_URL="$(echo "$TUNNELS" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for t in data.get('tunnels', []):
        url = t.get('public_url', '')
        if url.startswith('https://'):
            print(url)
            break
except Exception:
    pass
" 2>/dev/null || true)"
  if [[ -n "$PUBLIC_URL" ]]; then
    break
  fi
  sleep 0.5
done

if [[ -z "$PUBLIC_URL" ]]; then
  echo "ngrok did not expose a public URL within 30s" >&2
  echo "ngrok log:" >&2
  tail -20 /tmp/kappy-ngrok.log >&2 || true
  exit 1
fi

echo ""
echo "ngrok public URL: ${PUBLIC_URL}"
echo "ngrok inspector:  http://127.0.0.1:4040"
echo ""

if [[ -n "${TELNYX_API_KEY:-}" && -n "${TELNYX_MESSAGING_PROFILE_ID:-}" ]]; then
  "$ROOT/scripts/poc-telnyx-set-webhook.sh" "$PUBLIC_URL" "$LINE"
else
  echo "Skipping Telnyx webhook update (set TELNYX_API_KEY + TELNYX_MESSAGING_PROFILE_ID in line env)"
  echo "Manual: ./scripts/poc-telnyx-set-webhook.sh ${PUBLIC_URL} ${LINE}"
fi

echo ""
echo "Ready. In another terminal:"
echo "  source poc/lines/line-${LINE}.env"
echo "  ./scripts/poc-line.sh ${LINE} sms-reg-send --mccmnc \${KAPPY_SMS_MCCMNC:-310260}"
echo ""
echo "Press Ctrl+C to stop webhook + ngrok."

wait "$WEBHOOK_PID"
