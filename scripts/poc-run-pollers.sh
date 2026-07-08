#!/usr/bin/env bash
# Start safe validation-nacserv-poller per configured PoC line (no lldb).
#
# Safe mode only — same policy as poc-validation-daemon.sh (nacserv fetch, no capture).
# Manual lldb: ./scripts/poc-refresh-validation.sh <N> --capture
#
# Usage:
#   ./scripts/poc-run-pollers.sh              # start pollers for configured lines
#   ./scripts/poc-run-pollers.sh --stop       # stop all pollers
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$ROOT/poc/run"
LOG_DIR="$ROOT/poc/logs"
INTERVAL="${KAPPY_VALIDATION_POLL_INTERVAL:-300}"
STOP=false

for arg in "$@"; do
  case "$arg" in
    --stop) STOP=true ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg (try --stop)" >&2
      exit 1
      ;;
  esac
done

configured_lines() {
  local n
  for n in 1 2 3; do
    [[ -f "$ROOT/poc/lines/line-${n}.env" ]] && echo "$n"
  done
}

poller_running() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 1
  local pid
  pid="$(cat "$pidfile")"
  kill -0 "$pid" 2>/dev/null
}

stop_line() {
  local line="$1"
  local pidfile="$RUN_DIR/line-${line}-poller.pid"
  if poller_running "$pidfile"; then
    local pid
    pid="$(cat "$pidfile")"
    kill "$pid" 2>/dev/null || true
    sleep 0.5
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    echo "line $line: stopped poller (pid $pid)"
  elif [[ -f "$pidfile" ]]; then
    echo "line $line: poller not running (stale pidfile)"
  else
    echo "line $line: no poller"
  fi
  rm -f "$pidfile"
}

start_line() {
  local line="$1"
  local pidfile="$RUN_DIR/line-${line}-poller.pid"
  local logfile="$LOG_DIR/line-${line}-poller.log"

  mkdir -p "$RUN_DIR" "$LOG_DIR"

  if poller_running "$pidfile"; then
    echo "line $line: poller already running (pid $(cat "$pidfile"))"
    return 0
  fi
  rm -f "$pidfile"

  nohup "$ROOT/scripts/poc-line.sh" "$line" validation-nacserv-poller --interval-secs "$INTERVAL" \
    >>"$logfile" 2>&1 &
  echo "$!" >"$pidfile"
  echo "line $line: started poller pid $(cat "$pidfile") → $logfile"
}

if [[ "$STOP" == true ]]; then
  for line in $(configured_lines); do
    stop_line "$line"
  done
  exit 0
fi

lines="$(configured_lines)"
if [[ -z "$lines" ]]; then
  echo "no configured lines — copy poc/lines/line-N.env.example" >&2
  exit 1
fi

for line in $lines; do
  start_line "$line"
done
