#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${KAPPY_NACSERV_BIN:-$ROOT/tools/kappy-nacserv/target/release/kappy-nacserv}"
PROVIDER="${KAPPY_NAC_PROVIDER:-$ROOT/tools/nac-validation-provider/kappy-nac-validation-provider}"

if [[ ! -x "$BIN" ]]; then
  echo "Building kappy-nacserv..."
  cargo build --release --manifest-path "$ROOT/tools/kappy-nacserv/Cargo.toml"
fi

if [[ ! -x "$PROVIDER" ]] && ! command -v mac-registration-provider >/dev/null 2>&1; then
  echo "Building kappy-nac-validation-provider..."
  make -C "$ROOT/tools/nac-validation-provider"
fi

export KAPPY_NAC_PROVIDER="$PROVIDER"
exec "$BIN" "$@"
