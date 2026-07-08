#!/usr/bin/env bash
# Safe validation poller for PoC lines — does NOT attach lldb or touch Messages.
#
# Safe operations only:
#   1. Skip if line validation.json is still fresh
#   2. Fetch from kappy-nacserv (helper VM) when reachable
#   3. Re-inject validation-pilot.json if still fresh (no new capture)
#
# lldb capture is DESTRUCTIVE (pauses identityservicesd, can sign you out of Messages).
# Use only manually: ./scripts/poc-refresh-validation.sh 1 --capture
#
# Usage:
#   ./scripts/poc-validation-daemon.sh              # one safe refresh cycle (all configured lines)
#   ./scripts/poc-validation-daemon.sh --loop       # poll every 12 min (safe)
#   ./scripts/poc-validation-daemon.sh --line 2     # single line only
#   ./scripts/poc-validation-daemon.sh --line 2 --loop
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOOP=false
LINE_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --loop) LOOP=true; shift ;;
    --line)
      LINE_FILTER="${2:?usage: --line <1|2|3>}"
      case "$LINE_FILTER" in
        1|2|3) ;;
        *) echo "line must be 1, 2, or 3" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    --auto-toggle)
      echo "ERROR: --auto-toggle removed — it signs you out of Messages and crashes the app." >&2
      echo "Use helper VM nacserv for hands-off refresh, or manual: poc-refresh-validation.sh 1 --capture" >&2
      exit 1
      ;;
    *)
      echo "unknown arg: $1" >&2
      echo "usage: poc-validation-daemon.sh [--loop] [--line <1|2|3>]" >&2
      exit 1
      ;;
  esac
done

log() { printf '[poc-daemon] %s\n' "$*"; }

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
ok = dt > datetime.now(timezone.utc) and (dt - datetime.now(timezone.utc)).total_seconds() > 120
sys.exit(0 if ok else 1)
PY
}

lines() {
  local n
  if [[ -n "$LINE_FILTER" ]]; then
    [[ -f "$ROOT/poc/lines/line-${LINE_FILTER}.env" ]] || {
      echo "missing poc/lines/line-${LINE_FILTER}.env" >&2
      return 1
    }
    echo "$LINE_FILTER"
    return 0
  fi
  for n in 1 2 3; do
    [[ -f "$ROOT/poc/lines/line-${n}.env" ]] && echo "$n"
  done
}

refresh_line() {
  local line="$1"
  local env="$ROOT/poc/lines/line-${line}.env"
  # shellcheck source=/dev/null
  source "$env"
  local state_val="$KAPPY_SPIKE_STATE_DIR/validation.json"

  if validation_fresh "$state_val"; then
    log "line $line: validation fresh — skip"
    return 0
  fi

  log "line $line: validation stale — trying safe refresh"
  if "$ROOT/scripts/poc-refresh-validation.sh" "$line"; then
    log "line $line: refreshed"
    return 0
  fi

  log "line $line: STALE — start helper VM nacserv OR run manually (disrupts Messages):"
  log "  ./scripts/poc-refresh-validation.sh $line --capture"
  return 1
}

refresh_once() {
  local line any_fail=false
  for line in $(lines); do
    refresh_line "$line" || any_fail=true
  done
  [[ "$any_fail" == false ]]
}

if [[ "$LOOP" == true ]]; then
  INTERVAL="${KAPPY_VALIDATION_INTERVAL:-720}"
  if [[ -n "$LINE_FILTER" ]]; then
    log "safe loop line $LINE_FILTER every ${INTERVAL}s (nacserv / inject only — no lldb)"
  else
    log "safe loop all configured lines every ${INTERVAL}s (nacserv / inject only — no lldb)"
  fi
  while true; do
    refresh_once || log "some lines stale — waiting for nacserv or manual capture"
    sleep "$INTERVAL"
  done
else
  refresh_once
fi
