#!/usr/bin/env bash
# Recover from 6005 Bad auth cert / "Resource has been closed".
# Usage: ./scripts/poc-recover-auth.sh <1|2|3> [--capture]
#
# Order: refresh validation → login → register (NOT refresh-login).
# Pass --capture to allow destructive lldb validation capture when stale.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE="${1:?usage: poc-recover-auth.sh <1|2|3> [--capture]}"
FORCE_CAPTURE=false
[[ "${2:-}" == "--capture" ]] && FORCE_CAPTURE=true

case "$LINE" in
  1|2|3) ;;
  *) echo "line must be 1, 2, or 3" >&2; exit 1 ;;
esac

SHARED_ENV="$ROOT/poc/shared.env"
LINE_ENV="$ROOT/poc/lines/line-${LINE}.env"

[[ -f "$SHARED_ENV" ]] || { echo "missing $SHARED_ENV — copy from poc/shared.env.example" >&2; exit 1; }
[[ -f "$LINE_ENV" ]] || { echo "missing $LINE_ENV — copy from poc/lines/line-${LINE}.env.example" >&2; exit 1; }

# shellcheck source=/dev/null
source "$SHARED_ENV"
# shellcheck source=/dev/null
source "$LINE_ENV"

log() { printf '==> %s\n' "$*"; }

if [[ -z "${KAPPY_APPLE_ID:-}" || -z "${KAPPY_APPLE_PASSWORD:-}" ]]; then
  echo "KAPPY_APPLE_ID and KAPPY_APPLE_PASSWORD required for login" >&2
  echo "export them in the shell or add to poc/shared.env" >&2
  exit 1
fi

log "line $LINE auth recovery (state: $KAPPY_SPIKE_STATE_DIR)"

if [[ "$FORCE_CAPTURE" == true ]]; then
  log "refreshing validation (capture allowed)"
  "$ROOT/scripts/poc-refresh-validation.sh" "$LINE" --capture
else
  log "refreshing validation (safe — no lldb capture)"
  "$ROOT/scripts/poc-refresh-validation.sh" "$LINE"
fi

log "login (full Apple ID flow — not refresh-login)"
"$ROOT/scripts/poc-line.sh" "$LINE" login

log "register IDS services"
"$ROOT/scripts/poc-line.sh" "$LINE" register

echo
log "auth recovery complete"
echo "Next: ./scripts/poc-line.sh $LINE repl"
echo "  then: send <to> <body>"
