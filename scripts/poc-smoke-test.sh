#!/usr/bin/env bash
# PoC smoke test — preflight/status + optional one-shot send.
#
# Usage:
#   ./scripts/poc-smoke-test.sh
#   ./scripts/poc-smoke-test.sh --line 1 --to tel:+18606050710
#   ./scripts/poc-smoke-test.sh --line 1 --to mailto:henry@jabronicapital.com --body 'hello'
#
# Full 3-line concurrent isolation test requires 3 Apple IDs (one per line).
# Use ./scripts/poc-run-pollers.sh and ./poc/concurrent-tmux.sh for that workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE=""
TO=""
BODY="${KAPPY_SMOKE_BODY:-poc smoke test}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --line) LINE="${2:?--line requires value}"; shift 2 ;;
    --to) TO="${2:?--to requires value}"; shift 2 ;;
    --body) BODY="${2:?--body requires value}"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

echo "=== Preflight ==="
if [[ -x "$ROOT/scripts/poc-preflight.sh" && -n "$LINE" ]]; then
  "$ROOT/scripts/poc-preflight.sh" "$LINE"
elif [[ -x "$ROOT/scripts/poc-preflight.sh" ]]; then
  echo "poc-preflight requires --line; running poc-status for all configured lines"
  "$ROOT/scripts/poc-status.sh"
else
  if [[ -n "$LINE" ]]; then
    "$ROOT/scripts/poc-status.sh" "$LINE"
  else
    "$ROOT/scripts/poc-status.sh"
  fi
fi

echo
echo "=== Concurrent 3-line test ==="
echo "Requires 3 Apple IDs — one logged-in line per poc/lines/line-N.env."
echo "  1. ./scripts/poc-run-pollers.sh          # safe validation pollers (no lldb)"
echo "  2. ./poc/concurrent-tmux.sh              # repl per line (one APS conn each)"
echo "  3. Send from each pane; verify isolation"
echo "See poc/CONCURRENT.md"

if [[ -n "$LINE" && -n "$TO" ]]; then
  echo
  echo "=== Send test (line $LINE → $TO) ==="
  "$ROOT/scripts/poc-line.sh" "$LINE" send --to "$TO" --body "$BODY"
  echo "sent — check recipient device for line $LINE message"
elif [[ -n "$LINE" || -n "$TO" ]]; then
  echo "--line and --to are required together for send test" >&2
  exit 1
fi
