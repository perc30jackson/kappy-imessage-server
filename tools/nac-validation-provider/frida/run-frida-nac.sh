#!/usr/bin/env bash
# Attach Frida NAC hooks to identityservicesd (macOS 26.5.1 arm64e).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${KAPPY_NAC_FRIDA_PROFILE:-26.5.1}"
PROCESS="${KAPPY_NAC_FRIDA_PROCESS:-identityservicesd}"
OUT="${KAPPY_NAC_FRIDA_OUT:-validation.json}"
IDS_PID="${KAPPY_NAC_FRIDA_PID:-$(ps -ax -o user=,pid=,comm= | awk -v u="$(whoami)" '$3 ~ /identityservicesd$/ && $1 == u {print $2; exit}')}"

if ! command -v frida >/dev/null 2>&1; then
  echo "install: pip install frida-tools" >&2
  exit 1
fi

if [[ -z "$IDS_PID" ]]; then
  echo "no identityservicesd for $(whoami) — open Messages or run spike login" >&2
  exit 1
fi

echo "==> attaching to pid $IDS_PID (profile $PROFILE)"
echo "    trigger: cd spike && ./target/release/kappy-spike register"
echo "    or toggle iMessage in Messages.app"
echo ""

# Needs root on many macOS builds for system daemon injection.
sudo frida -p "$IDS_PID" \
  -l "$ROOT/nac_hooks.js" \
  --parameters "{\"profile\":\"$PROFILE\"}" \
  2>&1 | tee /tmp/kappy-frida-nac.log

# Extract last VALIDATION_JSON line if present
if grep -q 'VALIDATION_JSON=' /tmp/kappy-frida-nac.log; then
  python3 - "$OUT" <<'PY'
import json, re, sys
out_path = sys.argv[1]
text = open("/tmp/kappy-frida-nac.log").read()
matches = re.findall(r"VALIDATION_JSON=(\{.*\})", text)
if not matches:
    sys.exit(1)
payload = json.loads(matches[-1])
with open(out_path, "w") as f:
    json.dump({
        "validation_data": payload["validation_data"],
        "valid_until": payload["valid_until"],
        "nacserv_commit": payload.get("nacserv_commit", "kappy-frida-nac-hook"),
    }, f)
    f.write("\n")
print(f"wrote {out_path} ({payload['len']} bytes)")
PY
fi
