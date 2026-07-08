#!/usr/bin/env bash
# Physical pilot: capture validation via Frida (sudo) then inject + register.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRIDA_DIR="$ROOT/tools/nac-validation-provider/frida"
SPIKE="$ROOT/spike/target/release/kappy-spike"
STATE="${KAPPY_SPIKE_STATE_DIR:-$ROOT/spike/state}"
OUT="${KAPPY_NAC_FRIDA_OUT:-$ROOT/validation-pilot.json}"
PROFILE="${KAPPY_NAC_FRIDA_PROFILE:-26.5.1}"
TIMEOUT="${KAPPY_NAC_FRIDA_TIMEOUT:-180}"

log() { printf '==> %s\n' "$*"; }

if ! command -v frida >/dev/null 2>&1; then
  log "pip install frida-tools"
  exit 1
fi

IDS_PID="$(ps -ax -o user=,pid=,comm= | awk -v u="$(whoami)" '$3 ~ /identityservicesd$/ && $1 == u {print $2; exit}')"
if [[ -z "$IDS_PID" ]]; then
  log "identityservicesd not running for $(whoami) — open Messages"
  exit 1
fi

if frida -p "$IDS_PID" -e 'console.log("ok")' --timeout=4 2>&1 | grep -q 'unexpected early end-of-stream'; then
  log "Frida cannot attach to identityservicesd on macOS 26.x (kernel blocks task_for_pid on system daemons)."
  log "Use lldb instead:"
  log "  ./scripts/physical-pilot-lldb-register.sh"
  exit 2
fi

log "Pilot: $(whoami) identityservicesd pid=$IDS_PID"
log "Frida capture ($TIMEOUT s) — needs sudo for system daemon injection"
log "In another terminal, trigger NAC:"
printf '  cd %s/spike && KAPPY_SPIKE_STATE_DIR=./state ./target/release/kappy-spike register\n' "$ROOT"
printf '  # or toggle iMessage in Messages.app\n\n'

if [[ -f "$STATE/validation.json" ]]; then
  cp "$STATE/validation.json" "$STATE/validation.json.bak.$(date +%Y%m%d-%H%M%S)"
  log "Backed up existing validation.json (likely VM-sourced — wrong for physical hw)"
fi

sudo python3 "$FRIDA_DIR/capture_validation.py" \
  --pid "$IDS_PID" \
  --profile "$PROFILE" \
  --timeout "$TIMEOUT" \
  -o "$OUT"

log "Inject + register on physical hw..."
export KAPPY_SPIKE_STATE_DIR="$STATE"
"$SPIKE" inject-validation --file "$OUT"
"$SPIKE" register

log "Done. Next: $SPIKE send / $SPIKE listen"
