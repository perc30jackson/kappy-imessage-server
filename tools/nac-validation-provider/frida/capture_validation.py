#!/usr/bin/env python3
"""Attach Frida to identityservicesd and save captured validation JSON."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
HOOKS_JS = SCRIPT_DIR / "nac_hooks.js"


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture NAC validation via Frida")
    parser.add_argument(
        "--process",
        default="identityservicesd",
        help="Process name to attach (default: identityservicesd)",
    )
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="Attach by PID (use when multiple identityservicesd instances exist)",
    )
    parser.add_argument(
        "--profile",
        default="26.5.1",
        choices=["26.5.1", "15.0"],
        help="Offset profile (default: 26.5.1)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("validation.json"),
        help="Output path for spike inject-validation (default: validation.json)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Seconds to wait for a capture (default: 300)",
    )
    args = parser.parse_args()

    try:
        import frida
    except ImportError:
        print("pip install frida-tools", file=sys.stderr)
        return 1

    preamble = f'var profile = "{args.profile}";\n'
    source = preamble + HOOKS_JS.read_text(encoding="utf-8")
    captured: dict | None = None

    def on_message(message, _data):
        nonlocal captured
        if message.get("type") == "send":
            payload = message.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "validation":
                captured = payload
                print(f"capture: {payload['len']} bytes from {payload.get('source')}", flush=True)

    device = frida.get_local_device()
    try:
        if args.pid is not None:
            session = device.attach(args.pid)
            target = f"pid {args.pid}"
        else:
            session = device.attach(args.process)
            target = args.process
    except frida.ProcessNotFoundError:
        print(f"process not found: {args.pid or args.process}", file=sys.stderr)
        return 1
    except frida.ProcessNotRespondingError as exc:
        print(
            f"attach failed ({exc}). On macOS 26.x use lldb: ./scripts/physical-pilot-lldb-register.sh",
            file=sys.stderr,
        )
        return 1

    script = session.create_script(source)
    script.on("message", on_message)
    script.load()

    print(f"attached to {target}; trigger validation (register / iMessage / login)", flush=True)
    deadline = time.time() + args.timeout
    while captured is None and time.time() < deadline:
        time.sleep(0.2)

    session.detach()

    if captured is None:
        print("no validation captured before timeout", file=sys.stderr)
        return 2

    out = {
        "validation_data": captured["validation_data"],
        "valid_until": captured["valid_until"],
        "nacserv_commit": captured.get("nacserv_commit", "kappy-frida-nac-hook"),
    }
    args.output.write_text(json.dumps(out) + "\n", encoding="utf-8")
    print(f"wrote {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
