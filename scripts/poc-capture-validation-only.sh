#!/usr/bin/env bash
# lldb NAC capture only (no register). Writes validation-pilot.json.
#
# WARNING: Attaching lldb pauses identityservicesd (SIGSTOP). This disrupts
# Messages.app, can sign you out of iMessage, and breaks active kappy-spike APS
# sessions. Only run when spike is NOT listening/sending. Prefer helper VM
# kappy-nacserv for non-destructive refresh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

find_ids_pid() {
  # pipefail + awk `exit` can SIGPIPE the upstream `ps` → spurious exit 141
  ps -ax -o user=,pid=,comm= | awk -v u="$(whoami)" '$3 ~ /identityservicesd$/ && $1 == u {print $2; exit}' || true
}

IDS_PID="$(find_ids_pid)"
if [[ -z "$IDS_PID" ]]; then
  log "identityservicesd not running — opening Messages"
  open -a Messages
  sleep 2
  IDS_PID="$(find_ids_pid)"
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

log "Breakpoints armed."
log "WARNING: lldb pauses identityservicesd — Messages may freeze/sign out."
log "Toggle iMessage OFF→ON in Messages ONLY if you accept that disruption."
"$ROOT/scripts/trigger-imessage-nac.sh"

deadline=$((SECONDS + WAIT_SECS))
while (( SECONDS < deadline )); do
  if [[ -f "$OUT" ]] && python3 -c "import json; json.load(open('$OUT'))" 2>/dev/null; then
    log "Captured $(wc -c <"$OUT" | tr -d ' ') bytes → $OUT"
    exit 0
  fi
  if grep -q "wrote $OUT" "$LLDB_LOG" 2>/dev/null; then
    log "Captured → $OUT"
    exit 0
  fi
  sleep 2
done

log "Timed out after ${WAIT_SECS}s — toggle iMessage while lldb is attached."
tail -15 "$LLDB_LOG" >&2 || true
exit 1
