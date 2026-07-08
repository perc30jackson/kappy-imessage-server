#!/usr/bin/env bash
# Pre-flight checks before repl/send on a PoC line.
# Usage: ./scripts/poc-preflight.sh <1|2|3>
#
# Exits non-zero when critical state files are missing.
# Warns when validation expires within 120s.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE="${1:?usage: poc-preflight.sh <1|2|3>}"

case "$LINE" in
  1|2|3) ;;
  *) echo "line must be 1, 2, or 3" >&2; exit 1 ;;
esac

SHARED_ENV="$ROOT/poc/shared.env"
LINE_ENV="$ROOT/poc/lines/line-${LINE}.env"

[[ -f "$SHARED_ENV" ]] || { echo "missing $SHARED_ENV" >&2; exit 1; }
[[ -f "$LINE_ENV" ]] || { echo "missing $LINE_ENV" >&2; exit 1; }

# shellcheck source=/dev/null
source "$SHARED_ENV"
# shellcheck source=/dev/null
source "$LINE_ENV"

warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

echo "=== poc-preflight line $LINE ==="
"$ROOT/scripts/poc-status.sh" "$LINE"

STATE="${KAPPY_SPIKE_STATE_DIR:?KAPPY_SPIKE_STATE_DIR not set}"
CRITICAL=(hw_info.plist id.plist keystore.plist validation.json)

for f in "${CRITICAL[@]}"; do
  if [[ ! -f "$STATE/$f" ]]; then
    fail "missing critical file: $STATE/$f"
  fi
done

if [[ -f "$STATE/validation.json" ]]; then
  python3 - "$STATE/validation.json" <<'PY' || true
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
data = json.load(open(path))
vu = data.get("valid_until")
if not vu:
    print("validation: no valid_until field")
    sys.exit(0)
dt = datetime.fromisoformat(vu.replace("Z", "+00:00"))
delta = int((dt - datetime.now(timezone.utc)).total_seconds())
print(f"validation expires in: {delta}s")
if delta < 120:
    print(f"WARN: validation expires in {delta}s (< 120s) — run poc-refresh-validation.sh")
    sys.exit(2)
PY
  rc=$?
  if [[ "$rc" == 2 ]]; then
    warn "validation expires within 120s — run: ./scripts/poc-refresh-validation.sh $LINE"
  fi
fi

echo
echo "=== spike doctor ==="
echo "note: register has no --dry-run; doctor checks identity readiness instead"
if ! "$ROOT/scripts/poc-line.sh" "$LINE" doctor; then
  warn "doctor reported issues — run: ./scripts/poc-recover-auth.sh $LINE"
  exit 1
fi

echo
echo "preflight OK — safe to run: ./scripts/poc-line.sh $LINE repl"
