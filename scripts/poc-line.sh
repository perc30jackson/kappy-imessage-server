#!/usr/bin/env bash
# Run kappy-spike for a PoC line (1–3).
# Usage: ./scripts/poc-line.sh <line> <spike-subcommand> [args...]
# Example: ./scripts/poc-line.sh 1 listen
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE="${1:?usage: poc-line.sh <1|2|3> <spike-command> [args...]}"
shift

case "$LINE" in
  1|2|3) ;;
  *) echo "line must be 1, 2, or 3" >&2; exit 1 ;;
esac

SHARED_ENV="$ROOT/poc/shared.env"
LINE_ENV="$ROOT/poc/lines/line-${LINE}.env"

if [[ ! -f "$SHARED_ENV" ]]; then
  echo "missing $SHARED_ENV — copy from poc/shared.env.example" >&2
  exit 1
fi
if [[ ! -f "$LINE_ENV" ]]; then
  echo "missing $LINE_ENV — copy from poc/lines/line-${LINE}.env.example" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$SHARED_ENV"
# shellcheck source=/dev/null
source "$LINE_ENV"

SPIKE="${KAPPY_SPIKE_BIN:-$ROOT/target/release/kappy-spike}"
if [[ ! -x "$SPIKE" ]]; then
  echo "building kappy-spike..."
  (cd "$ROOT" && cargo build --release -p kappy-spike)
  SPIKE="$ROOT/target/release/kappy-spike"
fi

mkdir -p "$KAPPY_SPIKE_STATE_DIR"
export KAPPY_SPIKE_STATE_DIR

exec "$SPIKE" --state-dir "$KAPPY_SPIKE_STATE_DIR" "$@"
