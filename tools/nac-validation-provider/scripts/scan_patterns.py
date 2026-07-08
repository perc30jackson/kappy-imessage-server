#!/usr/bin/env python3
import re
import struct

BINARY = "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd"

PATTERNS = {
    "NACInit": (
        "7f2303d5fc6fbaa9fa6701a9f85f02a9f65703a9f44f04a9fd7b05a9fd43019109"
        "....00..10....f91f0a3fd6ff0740d1ff....d1....00..08....f9080140f9a8....f8"
        "......d2......f2......f2......f2e9"
    ),
    "NACKeyEstablishment": (
        "7f2303d5ff....d1fc6f..a9fa67..a9f85f..a9f657..a9f44f..a9fd7b..a9fd..0591"
        "....00..08....f9080140f9a8....f8......52"
    ),
    "NACSign": (
        "7f2303d5fc6fbaa9fa6701a9f85f02a9f65703a9f44f04a9fd7b05a9fd430191ff"
        "....d1................08....f9"
    ),
}


def arm64e_slice(data: bytes) -> bytes:
    nfat = struct.unpack(">I", data[4:8])[0]
    off = 8
    for _ in range(nfat):
        cputype, _cpusub, offset, size, _align = struct.unpack(">5I", data[off : off + 20])
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


def main() -> None:
    blob = arm64e_slice(open(BINARY, "rb").read())
    for name, pat in PATTERNS.items():
        regex = pattern_to_regex(pat)
        matches = [hex(m.start()) for m in regex.finditer(blob)]
        print(f"{name}: {len(matches)} matches")
        for m in matches[:20]:
            print(" ", m)


if __name__ == "__main__":
    main()
