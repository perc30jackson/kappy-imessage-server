#!/usr/bin/env bash
# Attach lldb, wait for pilot-local NAC capture, inject + register.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPIKE="$ROOT/spike/target/release/kappy-spike"
STATE="${KAPPY_SPIKE_STATE_DIR:-$ROOT/spike/state}"
OUT="${KAPPY_NAC_LLDB_OUT:-$ROOT/validation-pilot.json}"
PROFILE="${KAPPY_NAC_LLDB_PROFILE:-26.5.1}"
LLDB_DIR="$ROOT/tools/nac-validation-provider/lldb"
LLDB_LOG="${KAPPY_NAC_LLDB_LOG:-$ROOT/lldb-capture.log}"
WAIT_SECS="${KAPPY_NAC_WAIT_SECS:-300}"

case "$PROFILE" in
  26.5.1)
    export KAPPY_NAC_SIGN_OFF=0x7fd004
    export KAPPY_NAC_KEY_EST_OFF=0x7e3a44
    export KAPPY_NAC_INIT_OFF=0x8832cc
    ;;
  15.0)
    export KAPPY_NAC_SIGN_OFF=0x67e4d8
    export KAPPY_NAC_KEY_EST_OFF=0x64e200
    export KAPPY_NAC_INIT_OFF=0x66b05c
    ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 1 ;;
esac

export KAPPY_NAC_CAPTURE_OUT="$OUT"
export KAPPY_LLDB_PY_PATH="$LLDB_DIR"

log() { printf '==> %s\n' "$*"; }

cleanup() {
  if [[ -n "${LLDB_PID:-}" ]] && kill -0 "$LLDB_PID" 2>/dev/null; then
    kill "$LLDB_PID" 2>/dev/null || true
    wait "$LLDB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

IDS_PID="$(ps -ax -o user=,pid=,comm= | awk -v u="$(whoami)" '$3 ~ /identityservicesd$/ && $1 == u {print $2; exit}')"
if [[ -z "$IDS_PID" ]]; then
  log "identityservicesd not running — opening Messages"
  open -a Messages
  sleep 2
  IDS_PID="$(ps -ax -o user=,pid=,comm= | awk -v u="$(whoami)" '$3 ~ /identityservicesd$/ && $1 == u {print $2; exit}')"
fi
[[ -n "$IDS_PID" ]] || { log "identityservicesd still not running"; exit 1; }

rm -f "$OUT"
: >"$LLDB_LOG"

log "Attaching lldb to identityservicesd pid=$IDS_PID (log: $LLDB_LOG)"
lldb -p "$IDS_PID" -s "$LLDB_DIR/capture_nac.lldb" >>"$LLDB_LOG" 2>&1 &
LLDB_PID=$!

for _ in $(seq 1 60); do
  if grep -q "breakpoint on NACSign" "$LLDB_LOG" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$LLDB_PID" 2>/dev/null; then
    log "lldb exited early — tail $LLDB_LOG"
    tail -20 "$LLDB_LOG" >&2 || true
    exit 1
  fi
  sleep 0.5
done

grep -q "breakpoint on NACSign" "$LLDB_LOG" || {
  log "lldb never set NACSign breakpoint"
  tail -30 "$LLDB_LOG" >&2 || true
  exit 1
}

log "Breakpoints armed. Toggle iMessage now (Messages → Settings → iMessage OFF → ON)."
"$ROOT/scripts/trigger-imessage-nac.sh"

deadline=$((SECONDS + WAIT_SECS))
while (( SECONDS < deadline )); do
  if [[ -f "$OUT" ]] && python3 -c "import json; json.load(open('$OUT'))" 2>/dev/null; then
    log "Captured $(wc -c <"$OUT" | tr -d ' ') bytes → $OUT"
    break
  fi
  if grep -q "wrote $OUT" "$LLDB_LOG" 2>/dev/null; then
    break
  fi
  if grep -q "scheduled return breakpoint" "$LLDB_LOG" 2>/dev/null; then
    log "NACSign return breakpoint set — waiting for dump..."
  elif grep -q "breakpoint command add failed" "$LLDB_LOG" 2>/dev/null; then
    log "Return breakpoint setup failed — check $LLDB_LOG"
    break
  elif grep -q "hit NAC trace" "$LLDB_LOG" 2>/dev/null; then
    log "NAC pipeline started (trace hit) — finish iMessage toggle if needed"
  fi
  sleep 2
done

if [[ ! -f "$OUT" ]]; then
  log "Timed out after ${WAIT_SECS}s — no validation captured."
  log "Try: Sign Out of iMessage, then Sign In while this script runs."
  log "lldb log tail:"
  tail -25 "$LLDB_LOG" >&2 || true
  exit 1
fi

log "Inject + register..."
export KAPPY_SPIKE_STATE_DIR="$STATE"
"$SPIKE" inject-validation --file "$OUT"
if "$SPIKE" register; then
  log "Register OK"
else
  log "Register failed — pilot validation is captured in $OUT; retry register manually"
  exit 1
fi

log "Done."
