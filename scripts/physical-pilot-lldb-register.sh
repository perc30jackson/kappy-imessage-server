#!/usr/bin/env bash
# Capture NAC validation via lldb (Frida cannot attach to identityservicesd on macOS 26.x).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPIKE="$ROOT/spike/target/release/kappy-spike"
STATE="${KAPPY_SPIKE_STATE_DIR:-$ROOT/spike/state}"
OUT="${KAPPY_NAC_LLDB_OUT:-$ROOT/validation-pilot.json}"
PROFILE="${KAPPY_NAC_LLDB_PROFILE:-26.5.1}"
LLDB_DIR="$ROOT/tools/nac-validation-provider/lldb"

case "$PROFILE" in
  26.5.1)
    NAC_SIGN_OFF=0x7fd004
    NAC_KEY_EST_OFF=0x7e3a44
    NAC_INIT_OFF=0x8832cc
    ;;
  15.0)
    NAC_SIGN_OFF=0x67e4d8
    NAC_KEY_EST_OFF=0x64e200
    NAC_INIT_OFF=0x66b05c
    ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 1 ;;
esac

log() { printf '==> %s\n' "$*"; }

IDS_PID="$(ps -ax -o user=,pid=,comm= | awk -v u="$(whoami)" '$3 ~ /identityservicesd$/ && $1 == u {print $2; exit}')"
if [[ -z "$IDS_PID" ]]; then
  log "identityservicesd not running for $(whoami) — open Messages"
  exit 1
fi

log "Pilot: $(whoami) identityservicesd pid=$IDS_PID"
log "lldb breaks on NACSign — trigger NAC in another terminal:"
printf '  %s/scripts/trigger-imessage-nac.sh\n' "$ROOT"
printf '  # then toggle iMessage OFF/ON in Messages → Settings → iMessage\n'
printf '\n'
log "NOTE: kappy-spike register does NOT call NACSign (uses injected validation.json)."
log "      You must toggle iMessage in Messages.app while lldb is attached.\n"

if [[ -f "$STATE/validation.json" ]]; then
  cp "$STATE/validation.json" "$STATE/validation.json.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
fi

export KAPPY_NAC_SIGN_OFF="$NAC_SIGN_OFF"
export KAPPY_NAC_KEY_EST_OFF="$NAC_KEY_EST_OFF"
export KAPPY_NAC_INIT_OFF="$NAC_INIT_OFF"
export KAPPY_NAC_CAPTURE_OUT="$OUT"
export KAPPY_LLDB_PY_PATH="$LLDB_DIR"

lldb -p "$IDS_PID" -s "$LLDB_DIR/capture_nac.lldb"

if [[ ! -f "$OUT" ]]; then
  log "No validation captured — did NACSign run while lldb was attached?"
  exit 1
fi

log "Inject + register..."
export KAPPY_SPIKE_STATE_DIR="$STATE"
"$SPIKE" inject-validation --file "$OUT"
"$SPIKE" register

log "Done. wrote $OUT"
