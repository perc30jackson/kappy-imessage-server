#!/usr/bin/env bash
# Show PoC line status (state files, validation expiry, registered handles).
# Usage: ./scripts/poc-status.sh [1|2|3]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

show_line() {
  local line="$1"
  local env="$ROOT/poc/lines/line-${line}.env"
  if [[ ! -f "$env" ]]; then
    echo "line $line: missing $env"
    return
  fi
  # shellcheck source=/dev/null
  source "$env"
  echo "=== Line $line ==="
  echo "state: $KAPPY_SPIKE_STATE_DIR"
  for f in hw_info.plist id.plist gsa.plist validation.json; do
    if [[ -f "$KAPPY_SPIKE_STATE_DIR/$f" ]]; then
      echo "  ok  $f"
    else
      echo "  MISSING $f"
    fi
  done
  if [[ -f "$KAPPY_SPIKE_STATE_DIR/validation.json" ]]; then
    python3 - "$KAPPY_SPIKE_STATE_DIR/validation.json" <<'PY' 2>/dev/null || true
import json, sys
from datetime import datetime, timezone
d = json.load(open(sys.argv[1]))
vu = d.get("valid_until", "?")
print(f"  validation valid_until: {vu}")
if vu and vu != "?":
    dt = datetime.fromisoformat(vu.replace("Z", "+00:00"))
    delta = (dt - datetime.now(timezone.utc)).total_seconds()
    print(f"  validation expires in: {int(delta)}s")
PY
  fi
  if [[ -f "$KAPPY_SPIKE_STATE_DIR/id.plist" ]]; then
    echo "  madrid handles:"
    plutil -p "$KAPPY_SPIKE_STATE_DIR/id.plist" 2>/dev/null \
      | grep -E 'handles|mailto|tel:' | head -6 | sed 's/^/    /'
  fi
  echo
}

if [[ -n "${1:-}" ]]; then
  show_line "$1"
else
  for n in 1 2 3; do
    [[ -f "$ROOT/poc/lines/line-${n}.env" ]] && show_line "$n" || true
  done
fi

echo "=== Validation sources ==="
for url in "http://192.168.64.3:8788" "http://192.168.64.2:8788" "http://127.0.0.1:8788"; do
  if curl -sf --connect-timeout 2 "${url}/health" >/dev/null 2>&1; then
    echo "  nacserv UP  $url"
  else
    echo "  nacserv down $url"
  fi
done
if [[ -f "$ROOT/validation-pilot.json" ]]; then
  echo "  validation-pilot.json: $(wc -c <"$ROOT/validation-pilot.json" | tr -d ' ') bytes"
else
  echo "  validation-pilot.json: missing"
fi
