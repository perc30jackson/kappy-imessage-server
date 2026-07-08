#!/usr/bin/env python3
import re
import struct
import subprocess
import sys

BINARY = "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd"
PATTERN = (
    "7f2303d5ff....d1fc6f..a9fa67..a9f85f..a9f657..a9f44f..a9fd7b..a9fd..0591"
    "....00..08....f9080140f9a8....f8......52"
)


def arm64e_slice(data: bytes) -> bytes:
    if data[:4] != b"\xca\xfe\xba\xbe":
        return data
    nfat = struct.unpack(">I", data[4:8])[0]
    off = 8
    for _ in range(nfat):
        cputype, cpusub, offset, size, _align = struct.unpack(">5I", data[off : off + 20])
        off += 20
        if cputype == 0x0100000C:
            return data[offset : offset + size]
    raise RuntimeError("arm64e slice not found")


def pattern_to_regex(pat: str) -> re.Pattern[bytes]:
    parts = []
    i = 0
    while i < len(pat):
        if pat[i] == ".":
            parts.append(b".")
            i += 1
        else:
            parts.append(bytes.fromhex(pat[i : i + 2]))
            i += 2
    return re.compile(b"".join(parts), re.DOTALL)


def main() -> int:
    data = open(BINARY, "rb").read()
    blob = arm64e_slice(data)
    regex = pattern_to_regex(PATTERN)
    matches = [m.start() for m in regex.finditer(blob)]
    print(f"matches: {len(matches)}")
    for m in matches:
        print(hex(m))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
