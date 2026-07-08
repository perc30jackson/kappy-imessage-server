#!/usr/bin/env bash
# Refresh validation for a PoC line.
# Usage: ./scripts/poc-refresh-validation.sh <1|2|3> [--capture]
#
# Order: nacserv (if reachable) → existing validation-pilot.json if fresh → lldb capture (--capture or stale)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE="${1:?usage: poc-refresh-validation.sh <1|2|3> [--capture]}"
FORCE_CAPTURE=false
[[ "${2:-}" == "--capture" ]] && FORCE_CAPTURE=true

log() { printf '==> %s\n' "$*"; }

validation_fresh() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
data = json.load(open(path))
vu = data.get("valid_until")
if not vu:
    sys.exit(0)
dt = datetime.fromisoformat(vu.replace("Z", "+00:00"))
# refresh 2 minutes before expiry
ok = dt > datetime.now(timezone.utc) and (dt - datetime.now(timezone.utc)).total_seconds() > 120
sys.exit(0 if ok else 1)
PY
}

try_nacserv() {
  local url token
  for url in \
    "${KAPPY_NACSERV_URL:-}" \
    "http://192.168.64.3:8788" \
    "http://192.168.64.2:8788" \
    "http://127.0.0.1:8788"; do
    [[ -n "$url" ]] || continue
    if curl -sf --connect-timeout 2 "${url%/}/health" >/dev/null 2>&1; then
      token="${KAPPY_NACSERV_TOKEN:-}"
      if [[ -z "$token" && -f "$ROOT/poc/shared.env" ]]; then
        # shellcheck source=/dev/null
        source "$ROOT/poc/shared.env"
        token="${KAPPY_NACSERV_TOKEN:-}"
      fi
      if [[ -n "$token" ]]; then
        log "nacserv reachable at $url"
        KAPPY_NACSERV_URL="$url" KAPPY_NACSERV_TOKEN="$token" \
          "$ROOT/scripts/poc-line.sh" "$LINE" fetch-validation-nacserv
        return 0
      fi
    fi
  done
  return 1
}

inject_pilot() {
  local pilot="$ROOT/validation-pilot.json"
  [[ -f "$pilot" ]] || return 1
  log "injecting $pilot"
  "$ROOT/scripts/poc-line.sh" "$LINE" inject-validation --file "$pilot"
}

run_capture() {
  log "DESTRUCTIVE: lldb attach — stop spike listen/send and expect Messages disruption"
  log "Prefer helper VM nacserv when possible"
  "$ROOT/scripts/poc-capture-validation-only.sh"
  inject_pilot
  log "captured + injected validation-pilot.json"
}

# shellcheck source=/dev/null
[[ -f "$ROOT/poc/lines/line-${LINE}.env" ]] && source "$ROOT/poc/lines/line-${LINE}.env"

STATE_VAL="${KAPPY_SPIKE_STATE_DIR:-}/validation.json"
if [[ "$FORCE_CAPTURE" == false && -n "${KAPPY_SPIKE_STATE_DIR:-}" ]] && validation_fresh "$STATE_VAL"; then
  log "line validation.json still fresh — nothing to do"
  exit 0
fi

if [[ "$FORCE_CAPTURE" == false ]] && try_nacserv; then
  log "validation refreshed via nacserv"
  exit 0
fi

PILOT="$ROOT/validation-pilot.json"
if [[ "$FORCE_CAPTURE" == false ]] && validation_fresh "$PILOT"; then
  inject_pilot
  log "injected fresh validation-pilot.json (no capture needed)"
  exit 0
fi

if [[ "$FORCE_CAPTURE" == false ]]; then
  log "nacserv unavailable and validation-pilot.json stale/missing"
  log "run: $0 $LINE --capture"
  exit 1
fi

run_capture
