#!/usr/bin/env bash
# Activate a new PoC line from shared Mac Hardware Info export.
# Usage: ./scripts/poc-init-line.sh <2|3>   (line 1 uses existing spike/state)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE="${1:?usage: poc-init-line.sh <2|3>}"

case "$LINE" in
  2|3) ;;
  *)
    echo "use poc-line.sh 1 for line 1 (existing spike/state); init is for lines 2–3" >&2
    exit 1
    ;;
esac

SHARED_ENV="$ROOT/poc/shared.env"
LINE_ENV="$ROOT/poc/lines/line-${LINE}.env"
EXPECTED_STATE="$ROOT/poc/lines/line-${LINE}/state"

[[ -f "$SHARED_ENV" ]] || { echo "copy poc/shared.env.example → poc/shared.env" >&2; exit 1; }
[[ -f "$LINE_ENV" ]] || { echo "copy poc/lines/line-${LINE}.env.example → poc/lines/line-${LINE}.env" >&2; exit 1; }

# shellcheck source=/dev/null
source "$SHARED_ENV"
# shellcheck source=/dev/null
source "$LINE_ENV"

if [[ -z "${KAPPY_SPIKE_STATE_DIR:-}" ]]; then
  echo "KAPPY_SPIKE_STATE_DIR unset in $LINE_ENV" >&2
  exit 1
fi

resolve_path() {
  cd "$1" 2>/dev/null && pwd || echo "$1"
}

ACTUAL_STATE="$(resolve_path "$KAPPY_SPIKE_STATE_DIR")"
EXPECTED_RESOLVED="$(resolve_path "$EXPECTED_STATE")"

if [[ "$ACTUAL_STATE" != "$EXPECTED_RESOLVED" ]]; then
  echo "KAPPY_SPIKE_STATE_DIR mismatch in $LINE_ENV" >&2
  echo "  expected: $EXPECTED_STATE" >&2
  echo "  got:      ${KAPPY_SPIKE_STATE_DIR}" >&2
  exit 1
fi

mkdir -p "$KAPPY_SPIKE_STATE_DIR"

HW="${KAPPY_HW_EXPORT:-$ROOT/poc/shared/hw-export.bin}"
if [[ ! -f "$HW" ]]; then
  echo "missing hardware export: $HW" >&2
  echo "run: ./scripts/poc-copy-hw-export.sh" >&2
  echo "or export from Mac Hardware Info app → poc/shared/hw-export.bin" >&2
  exit 1
fi

if [[ -z "${KAPPY_APPLE_ID:-}" || -z "${KAPPY_APPLE_PASSWORD:-}" ]]; then
  echo "warning: set KAPPY_APPLE_ID and KAPPY_APPLE_PASSWORD in $LINE_ENV before login" >&2
fi

"$ROOT/scripts/poc-line.sh" "$LINE" activate --hw-info "$HW"

cat <<EOF

activated line $LINE (state: $KAPPY_SPIKE_STATE_DIR)

Next steps:
  1. login      ./scripts/poc-line.sh $LINE login
  2. validation ./scripts/poc-refresh-validation.sh $LINE --capture
  3. register   ./scripts/poc-line.sh $LINE register
  4. repl       ./scripts/poc-line.sh $LINE repl

EOF
