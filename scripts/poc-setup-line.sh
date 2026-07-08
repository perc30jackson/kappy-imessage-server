#!/usr/bin/env bash
# Full setup for a new PoC line (2 or 3).
# Usage: ./scripts/poc-setup-line.sh <2|3>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE="${1:?usage: poc-setup-line.sh <2|3>}"

case "$LINE" in
  2|3) ;;
  *) echo "line must be 2 or 3" >&2; exit 1 ;;
esac

ENV_EXAMPLE="$ROOT/poc/lines/line-${LINE}.env.example"
ENV_FILE="$ROOT/poc/lines/line-${LINE}.env"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "created $ENV_FILE — set KAPPY_APPLE_ID and KAPPY_APPLE_PASSWORD"
fi

# shellcheck source=/dev/null
source "$ROOT/poc/lines/line-${LINE}.env" 2>/dev/null || true
if [[ -z "${KAPPY_APPLE_ID:-}" || -z "${KAPPY_APPLE_PASSWORD:-}" ]]; then
  echo "edit $ENV_FILE with a dedicated Apple ID before continuing" >&2
  exit 1
fi

chmod +x "$ROOT/scripts/poc-copy-hw-export.sh"
"$ROOT/scripts/poc-copy-hw-export.sh" "${2:-}" || true

if [[ ! -f "${KAPPY_HW_EXPORT:-$ROOT/poc/shared/hw-export.bin}" ]]; then
  echo "hw-export still missing — export from Mac Hardware Info app first" >&2
  exit 1
fi

"$ROOT/scripts/poc-init-line.sh" "$LINE"

echo ""
echo "Next (or use REST API lifecycle endpoints):"
echo "  ./scripts/poc-line.sh $LINE login"
echo "  ./scripts/poc-refresh-validation.sh $LINE --capture"
echo "  ./scripts/poc-line.sh $LINE register"
echo "  ./scripts/poc-line.sh $LINE repl"
echo ""
echo "Or with API running:"
echo "  curl -X POST http://127.0.0.1:8080/v1/lines/$LINE/lifecycle/login -H 'Content-Type: application/json' \\"
echo "    -d '{\"apple_id\":\"...\",\"password\":\"...\"}'"
