#!/usr/bin/env bash
# Open a tmux session with one repl per configured PoC line.
#
# One APS connection per line — use repl (not separate listen + send).
#
# Usage:
#   ./poc/concurrent-tmux.sh
#
# In each pane, send test messages (real handles, not placeholders):
#   send tel:+18606050710 poc line 1 outbound
#   send mailto:henry@jabronicapital.com hello from line 1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="${KAPPY_POC_TMUX_SESSION:-poc}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux required — install with: brew install tmux" >&2
  exit 1
fi

lines=()
for n in 1 2 3; do
  [[ -f "$ROOT/poc/lines/line-${n}.env" ]] && lines+=("$n")
done

if [[ ${#lines[@]} -eq 0 ]]; then
  echo "no configured lines — copy poc/lines/line-N.env.example" >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "attaching to existing session: $SESSION"
  exec tmux attach -t "$SESSION"
fi

repl_cmd() {
  local line="$1"
  printf "cd '%s' && echo '=== Line %s repl ===' && echo 'send tel:+18606050710 poc line %s outbound' && echo 'send mailto:henry@jabronicapital.com hello from line %s' && ./scripts/poc-line.sh %s repl" \
    "$ROOT" "$line" "$line" "$line" "$line"
}

first="${lines[0]}"
tmux new-session -d -s "$SESSION" -n repl "$(repl_cmd "$first")"

for line in "${lines[@]:1}"; do
  tmux split-window -t "$SESSION:repl" "$(repl_cmd "$line")"
done

tmux select-layout -t "$SESSION:repl" tiled
echo "session $SESSION: ${#lines[@]} repl pane(s) — attach with: tmux attach -t $SESSION"
exec tmux attach -t "$SESSION"
