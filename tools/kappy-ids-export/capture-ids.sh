#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KAPPY_LLDB_PY_PATH="$ROOT/lldb"
export KAPPY_LLDB_PY_PATH
export KAPPY_IDS_CAPTURE_OUT="${KAPPY_IDS_CAPTURE_OUT:-${1:-ids-export.json}}"
export KAPPY_IDS_USER="${KAPPY_IDS_USER:-${SUDO_USER:-${USER:-}}}"

if [[ -z "${KAPPY_IDS_USER}" || "${KAPPY_IDS_USER}" == "root" ]]; then
  KAPPY_IDS_USER="$(stat -f %Su /dev/console 2>/dev/null || true)"
  export KAPPY_IDS_USER
fi

if [[ "${KAPPY_IDS_CAPTURE_OUT}" != /* ]]; then
  KAPPY_IDS_CAPTURE_OUT="$(pwd)/${KAPPY_IDS_CAPTURE_OUT}"
  export KAPPY_IDS_CAPTURE_OUT
fi

PID="$(pgrep -u "${KAPPY_IDS_USER}" -x identityservicesd 2>/dev/null | head -1 || true)"
if [[ -z "${PID}" ]]; then
  PID="$(ps -ax -o pid=,user=,comm= | awk -v u="$KAPPY_IDS_USER" '$3 ~ /identityservicesd$/ && ($2 == u || u == "") { print $1; exit }' || true)"
fi
if [[ -z "${PID}" ]]; then
  echo "identityservicesd not running for user ${KAPPY_IDS_USER:-<current>}" >&2
  echo "Run without sudo: bash ~/vm-gui-capture-local.sh <path>" >&2
  exit 1
fi

echo "Exporting IDS registrations from identityservicesd pid=${PID} -> ${KAPPY_IDS_CAPTURE_OUT}"
LLDB_LOG="$(mktemp)"
trap 'rm -f "${LLDB_LOG}"' EXIT
set +e
lldb -batch -p "${PID}" -s "${KAPPY_LLDB_PY_PATH}/capture_ids.lldb" >"${LLDB_LOG}" 2>&1
LLDB_EXIT=$?
set -e
cat "${LLDB_LOG}"
if [[ "${LLDB_EXIT}" -ne 0 ]] || grep -qE '^error:' "${LLDB_LOG}"; then
  if grep -q "cannot get permission to debug" "${LLDB_LOG}"; then
    echo "lldb attach denied (non-interactive session or Developer Mode off)." >&2
    echo "On the VM: System Settings -> Privacy & Security -> Developer Mode -> On," >&2
    echo "reboot, then: sudo DevToolsSecurity -enable" >&2
    echo "Run this script from Terminal.app (not SSH), or approve the attach prompt." >&2
  elif grep -q "Not allowed to attach" "${LLDB_LOG}"; then
    echo "lldb attach denied: identityservicesd is hardened (no get-task-allow)." >&2
    if csrutil status 2>/dev/null | grep -qi "enabled"; then
      echo "This Mac has SIP enabled. lldb attach to identityservicesd requires SIP off." >&2
      echo "Fix (VM): reboot to Recovery (hold power in UTM), Terminal:" >&2
      echo "  csrutil disable" >&2
      echo "  reboot" >&2
      echo "Then: sudo DevToolsSecurity -enable" >&2
      echo "Alternative (no SIP change): use import-gui-registration --synthesize on this VM." >&2
    else
      echo "Try: sudo DevToolsSecurity -enable" >&2
      echo "Approve 'Developer Tool Access' if macOS prompts in Terminal." >&2
    fi
  fi
  exit 1
fi

if [[ ! -f "${KAPPY_IDS_CAPTURE_OUT}" ]]; then
  echo "export failed: ${KAPPY_IDS_CAPTURE_OUT} not written" >&2
  exit 1
fi

echo "OK: $(wc -c <"${KAPPY_IDS_CAPTURE_OUT}") bytes -> ${KAPPY_IDS_CAPTURE_OUT}"
