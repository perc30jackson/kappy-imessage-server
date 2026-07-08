#!/usr/bin/env python3
"""Send REG-REQ via USB LTE modem AT+CMGS (Telnyx IoT SIM).

Usage:
  ./scripts/poc-sms-reg-modem.py --port /dev/cu.usbserial-XXXX --gateway 28818773 \\
    --body 'REG-REQ?v=3;t=...;r=...'

  # Or read body from pending file:
  ./scripts/poc-sms-reg-modem.py --port /dev/cu.usbserial-XXXX \\
    --pending poc/lines/line-2/state/sms-reg-pending.json

Requires: pyserial (pip install pyserial)
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

try:
    import serial
except ImportError:
    print("pip install pyserial", file=sys.stderr)
    raise


def at_cmd(ser: serial.Serial, cmd: str, wait: float = 0.5) -> str:
    ser.reset_input_buffer()
    ser.write((cmd + "\r").encode())
    time.sleep(wait)
    out = ser.read(ser.in_waiting or 1).decode(errors="replace")
    return out


def send_sms_text_mode(ser: serial.Serial, gateway: str, body: str) -> str:
    logs = []
    for cmd in ("AT", "AT+CMGF=1", "AT+CREG?"):
        logs.append(at_cmd(ser, cmd))

    ser.reset_input_buffer()
    ser.write(f'AT+CMGS="{gateway}"\r'.encode())
    time.sleep(0.8)
    prompt = ser.read(ser.in_waiting or 1).decode(errors="replace")
    logs.append(prompt)
    if ">" not in prompt:
        raise RuntimeError(f"modem did not prompt for text: {prompt!r}")

    ser.write(body.encode())
    ser.write(b"\x1a")  # Ctrl+Z
    time.sleep(3.0)
    resp = ser.read(ser.in_waiting or 1).decode(errors="replace")
    logs.append(resp)
    if "ERROR" in resp or "+CMS ERROR" in resp:
        raise RuntimeError("modem rejected SMS:\n" + "\n".join(logs))
    return "\n".join(logs)


def main() -> None:
    p = argparse.ArgumentParser(description="Send REG-REQ via modem AT+CMGS")
    p.add_argument("--port", required=True, help="Serial port e.g. /dev/cu.usbserial-1410")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--gateway", default="28818773")
    p.add_argument("--body", help="REG-REQ body")
    p.add_argument("--pending", type=Path, help="sms-reg-pending.json from dry-run")
    args = p.parse_args()

    body = args.body
    gateway = args.gateway
    if args.pending:
        data = json.loads(args.pending.read_text())
        body = data["reg_req_body"]
        gateway = data.get("gateway", gateway)

    if not body or not body.startswith("REG-REQ"):
        raise SystemExit("missing REG-REQ body (use --body or --pending)")

    with serial.Serial(args.port, args.baud, timeout=1) as ser:
        log = send_sms_text_mode(ser, gateway, body)
        print(log)
        print(f"sent REG-REQ → {gateway}")


if __name__ == "__main__":
    main()
