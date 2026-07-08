#!/usr/bin/env python3
"""Find arm64e ADRP+ADD xrefs to cstring targets in a thin Mach-O binary."""

import struct
import subprocess
import sys
from pathlib import Path

IMAGE_BASE = 0x100000000


def parse_macho(path: bytes):
    magic = struct.unpack("<I", path[:4])[0]
    if magic != 0xFEEDFACF:
        raise SystemExit("expected 64-bit Mach-O (use: lipo -thin arm64e -output …)")
    ncmds, _ = struct.unpack("<II", path[16:24])
    off = 32
    segs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", path[off : off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = path[off + 8 : off + 24].split(b"\0", 1)[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", path[off + 24 : off + 56])
            segs.append((segname, vmaddr, vmsize, fileoff, filesize))
        off += cmdsize
    return segs


def file_to_vm(segs, fileoff: int) -> int | None:
    for _, vm, _, fo, fsz in segs:
        if fo <= fileoff < fo + fsz:
            return vm + (fileoff - fo)
    return None


def vm_to_file(segs, vmaddr: int) -> int | None:
    for _, vm, vsz, fo, _ in segs:
        if vm <= vmaddr < vm + vsz:
            return fo + (vmaddr - vm)
    return None


def decode_adrp(insn: int, pc: int) -> int | None:
    if (insn & 0x9F000000) != 0x90000000:
        return None
    immhi = (insn >> 5) & 0x7FFFF
    immlo = (insn >> 29) & 0x3
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


def decode_add_imm12(insn: int) -> int | None:
    if (insn & 0xFF800000) not in (0x91000000, 0x11000000):
        return None
    return (insn >> 10) & 0xFFF


def find_xrefs(blob: bytes, segs, target_vm: int, text_vm: int, text_file: int, text_size: int):
    hits = []
    text = blob[text_file : text_file + text_size]
    for i in range(0, len(text) - 8, 4):
        pc_vm = text_vm + i
        w0 = struct.unpack("<I", text[i : i + 4])[0]
        w1 = struct.unpack("<I", text[i + 4 : i + 8])[0]
        page = decode_adrp(w0, pc_vm)
        if page is None:
            continue
        imm12 = decode_add_imm12(w1)
        if imm12 is None:
            continue
        if page + imm12 == target_vm:
            hits.append(pc_vm)
    return hits


def scan_bl(blob: bytes, segs, site_vm: int, window: int = 0x200):
    start = max(segs[0][1], site_vm - window)
    end = site_vm + 0x100
    start_off = vm_to_file(segs, start)
    end_off = vm_to_file(segs, end)
    if start_off is None or end_off is None:
        return []
    chunk = blob[start_off:end_off]
    base_vm = start
    bls = []
    for i in range(0, len(chunk) - 4, 4):
        w = struct.unpack("<I", chunk[i : i + 4])[0]
        if (w & 0xFC000000) != 0x94000000:
            continue
        imm26 = w & 0x03FFFFFF
        if imm26 & (1 << 25):
            imm26 -= 1 << 26
        pc = base_vm + i
        tgt = pc + (imm26 << 2)
        bls.append((pc, tgt))
    return bls


def discover_strings(path: Path, needles: list[str]) -> dict[str, int]:
    out = subprocess.check_output(["strings", "-t", "x", str(path)], text=True)
    found: dict[str, int] = {}
    for line in out.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        file_off = int(parts[0], 16)
        text = parts[1]
        for needle in needles:
            if needle in text and needle not in found:
                found[needle] = file_off
    return found


def fmt_off(vm: int) -> str:
    return f"@{vm - IMAGE_BASE:#x}"


def main():
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {sys.argv[0]} <thin-arm64e-identityservicesd>")
    path = Path(sys.argv[1])
    blob = path.read_bytes()
    segs = parse_macho(blob)
    text_vm = text_file = text_size = None
    for name, vm, vsz, fo, fsz in segs:
        if name == "__TEXT":
            text_vm, text_file, text_size = vm, fo, fsz
    if text_vm is None:
        raise SystemExit("no __TEXT")

    needles = [
        "Calling NACInit with",
        "Received validation initialization request",
        "Successfully signed: %@",
        "Failed building validation data",
    ]
    if len(sys.argv) > 2:
        needles = sys.argv[2:]

    targets = discover_strings(path, needles)
    missing = [n for n in needles if n not in targets]
    if missing:
        print("missing strings:", ", ".join(missing), file=sys.stderr)

    for label in needles:
        if label not in targets:
            continue
        file_off = targets[label]
        vm = file_to_vm(segs, file_off)
        print(f"\n== {label} ==")
        print(f"  file={file_off:#x} vm={vm:#x}")
        xrefs = find_xrefs(blob, segs, vm, text_vm, text_file, text_size)
        print(f"  xrefs: {len(xrefs)}")
        for x in xrefs[:4]:
            print(f"    adrp+add {fmt_off(x)}")
            for pc, tgt in scan_bl(blob, segs, x):
                if pc >= x - 0x120 and pc <= x + 0x180:
                    rel_tgt = tgt - IMAGE_BASE
                    if rel_tgt < 0x200000 or rel_tgt >= 0xA00000:
                        continue
                    print(f"      bl {fmt_off(pc)} -> {fmt_off(tgt)}")


if __name__ == "__main__":
    main()
