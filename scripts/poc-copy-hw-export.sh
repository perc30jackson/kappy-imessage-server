#!/usr/bin/env bash
# Copy or symlink an existing hardware export into poc/shared/hw-export.bin.
# Idempotent — safe to re-run; prints what it did.
#
# Usage: ./scripts/poc-copy-hw-export.sh [--copy|--symlink]
#
# Sources (first match wins):
#   spike/pilot-hw-export.bin, spike/utm-hw-export.bin, spike/*hw*export*.bin
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${KAPPY_HW_EXPORT:-$ROOT/poc/shared/hw-export.bin}"
MODE=symlink

case "${1:-}" in
  --copy) MODE=copy ;;
  --symlink|'') MODE=symlink ;;
  *)
    echo "usage: poc-copy-hw-export.sh [--copy|--symlink]" >&2
    exit 1
    ;;
esac

log() { printf '[poc-copy-hw] %s\n' "$*"; }

print_export_help() {
  cat <<'EOF'
Export hardware identity for lines 2–3 (same blob as line 1; ~20 activations per export):

  Mac Hardware Info app (OpenBubbles):
    1. Open Mac Hardware Info on this PoC Mac
       https://github.com/OpenBubbles/Mac-Hardware-Info
    2. Export activation payload (file or clipboard)
    3. Save raw bytes to poc/shared/hw-export.bin

  Or kappy-hw-export on this Mac:
    cd tools/hw-export && swift build -c release
    .build/release/kappy-hw-export > poc/shared/hw-export.bin

Then re-run: ./scripts/poc-copy-hw-export.sh
EOF
}

mkdir -p "$(dirname "$DEST")"

if [[ -f "$DEST" ]]; then
  log "already present: $DEST ($(wc -c <"$DEST" | tr -d ' ') bytes)"
  exit 0
fi

find_source() {
  local candidate
  for candidate in \
    "$ROOT/spike/pilot-hw-export.bin" \
    "$ROOT/spike/utm-hw-export.bin"; do
    if [[ -s "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  for candidate in "$ROOT"/spike/*hw*export*.bin; do
    [[ -e "$candidate" ]] || continue
    if [[ -s "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if SOURCE="$(find_source)"; then
  if [[ "$MODE" == "symlink" ]]; then
    rel="$(python3 -c "import os.path; print(os.path.relpath('$SOURCE', '$(dirname "$DEST")'))")"
    ln -s "$rel" "$DEST"
    log "symlinked $SOURCE → $DEST"
  else
    cp "$SOURCE" "$DEST"
    log "copied $SOURCE → $DEST ($(wc -c <"$DEST" | tr -d ' ') bytes)"
  fi
  exit 0
fi

if [[ -f "$ROOT/spike/state/hw_info.plist" ]]; then
  log "line 1 already activated (spike/state/hw_info.plist present)"
  log "no raw hw-export.bin found under spike/ — export once for lines 2–3:"
  echo
  print_export_help
  exit 1
fi

log "missing hardware export: $DEST"
log "activate line 1 first, or export from this Mac:"
echo
print_export_help
exit 1
