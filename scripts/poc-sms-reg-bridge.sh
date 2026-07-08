#!/usr/bin/env bash
# Run sms-reg-webhook on LAN for Android SMS bridge (no ngrok required).
#
# Usage:
#   ./scripts/poc-sms-reg-bridge.sh [line] [--register]
#   ./scripts/poc-sms-reg-bridge.sh 2 --register
#
# Phone app: set Mac URL to http://<lan-ip>:8790
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE=2
REGISTER=false
LISTEN="${KAPPY_SMS_REG_WEBHOOK_LISTEN:-0.0.0.0:8790}"

for arg in "$@"; do
  case "$arg" in
    --register) REGISTER=true ;;
    1|2|3) LINE="$arg" ;;
    *)
      echo "unknown arg: $arg (usage: poc-sms-reg-bridge.sh [1|2|3] [--register])" >&2
      exit 1
      ;;
  esac
done

SHARED_ENV="$ROOT/poc/shared.env"
LINE_ENV="$ROOT/poc/lines/line-${LINE}.env"

# shellcheck source=/dev/null
source "$SHARED_ENV"
# shellcheck source=/dev/null
source "$LINE_ENV"

SPIKE="${KAPPY_SPIKE_BIN:-$ROOT/target/release/kappy-spike}"
if [[ ! -x "$SPIKE" ]]; then
  echo "building kappy-spike..."
  (cd "$ROOT" && cargo build --release -p kappy-spike)
  SPIKE="$ROOT/target/release/kappy-spike"
fi

mkdir -p "$KAPPY_SPIKE_STATE_DIR"
export KAPPY_SPIKE_STATE_DIR

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"

WEBHOOK_ARGS=(sms-reg-webhook --listen "$LISTEN")
if $REGISTER; then
  WEBHOOK_ARGS+=(--register)
fi

echo "SMS REG bridge webhook on http://${LISTEN}"
if [[ -n "$LAN_IP" ]]; then
  echo "Android app Mac URL: http://${LAN_IP}:8790"
else
  echo "Could not detect LAN IP — run: ipconfig getifaddr en0"
fi
echo ""
echo "Then:"
echo "  ./scripts/poc-line.sh ${LINE} sms-reg-send --dry-run"
echo "  Open Kappy SMS Bridge on phone → Fetch REG-REQ → Send REG-REQ"
echo ""

exec "$SPIKE" --state-dir "$KAPPY_SPIKE_STATE_DIR" "${WEBHOOK_ARGS[@]}"
