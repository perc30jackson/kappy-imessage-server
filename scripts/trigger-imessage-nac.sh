#!/usr/bin/env bash
# Open Messages and remind how to trigger NACSign while lldb is attached.
# kappy-spike register does NOT invoke identityservicesd NAC — only Messages does.
set -euo pipefail

open -a Messages
cat <<'EOF'

==> Trigger NAC validation (while lldb is running with breakpoint set)

  1. In Messages: menu Messages → Settings… (⌘,)
  2. Open the "iMessage" tab
  3. Turn iMessage OFF → wait ~3 seconds → turn ON
     (If already off, turn ON once; if stuck, Sign Out then Sign In)

lldb should print:
  [kappy-nac] NACSign enter ...
  [kappy-nac] wrote validation-pilot.json (... bytes)

EOF
