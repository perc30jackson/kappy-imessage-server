#!/usr/bin/env bash
# Point Telnyx messaging profile webhook at a public URL (ngrok, etc.).
#
# Usage:
#   ./scripts/poc-telnyx-set-webhook.sh <webhook-base-url> [line]
#   ./scripts/poc-telnyx-set-webhook.sh https://abc123.ngrok-free.app 2
#
# Appends /webhooks/telnyx/sms-reg if not already present.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${1:?usage: poc-telnyx-set-webhook.sh <https://host> [line]}"
LINE="${2:-2}"

case "$LINE" in
  1|2|3) ;;
  *) echo "line must be 1, 2, or 3" >&2; exit 1 ;;
esac

SHARED_ENV="$ROOT/poc/shared.env"
LINE_ENV="$ROOT/poc/lines/line-${LINE}.env"

# shellcheck source=/dev/null
source "$SHARED_ENV"
# shellcheck source=/dev/null
source "$LINE_ENV"

: "${TELNYX_API_KEY:?set TELNYX_API_KEY in poc/lines/line-${LINE}.env}"
: "${TELNYX_MESSAGING_PROFILE_ID:?set TELNYX_MESSAGING_PROFILE_ID in line env}"

BASE_URL="${BASE_URL%/}"
if [[ "$BASE_URL" == */webhooks/telnyx/sms-reg ]]; then
  WEBHOOK_URL="$BASE_URL"
else
  WEBHOOK_URL="${BASE_URL}/webhooks/telnyx/sms-reg"
fi

echo "Updating Telnyx profile ${TELNYX_MESSAGING_PROFILE_ID}"
echo "  webhook_url → ${WEBHOOK_URL}"

RESP="$(curl -sS -X PATCH \
  -H "Authorization: Bearer ${TELNYX_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"webhook_url\":\"${WEBHOOK_URL}\",\"webhook_api_version\":\"2\"}" \
  "https://api.telnyx.com/v2/messaging_profiles/${TELNYX_MESSAGING_PROFILE_ID}")"

if echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'data' in d else 1)" 2>/dev/null; then
  echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print('ok:', d.get('name'), '→', d.get('webhook_url'))"
else
  echo "$RESP" | python3 -m json.tool >&2 || echo "$RESP" >&2
  exit 1
fi
