"""lldb helpers to dump NACSign output from identityservicesd."""

from __future__ import annotations

import base64
import json
import os
from datetime import datetime, timedelta, timezone

import lldb

SIGN_OFF = int(os.environ.get("KAPPY_NAC_SIGN_OFF", "0x7fd004"), 0)
KEY_EST_OFF = int(os.environ["KAPPY_NAC_KEY_EST_OFF"], 0) if os.environ.get("KAPPY_NAC_KEY_EST_OFF") else None
INIT_OFF = int(os.environ["KAPPY_NAC_INIT_OFF"], 0) if os.environ.get("KAPPY_NAC_INIT_OFF") else None
OUT_PATH = os.environ.get("KAPPY_NAC_CAPTURE_OUT", "validation-pilot.json")
PREFERRED_VM = 0x100000000
_INVALID_LOAD = 0xFFFFFFFFFFFFFFFF
# thread_id -> (out_data_ptr_addr, out_len_ptr_addr, return_addr)
_pending_sign: dict[int, tuple[int, int, int]] = {}
_nac_sign_load_addr: int | None = None
_HANDLER = "nac_capture.on_nac_sign_handler"


def _valid_load(addr: int) -> bool:
    return addr not in (0, _INVALID_LOAD, getattr(lldb, "LLDB_INVALID_ADDRESS", _INVALID_LOAD))


def _text_section(module: lldb.SBModule) -> lldb.SBSection | None:
    for i in range(module.GetNumSections()):
        sec = module.GetSectionAtIndex(i)
        if not sec.IsValid():
            continue
        name = sec.GetName()
        if name in ("__TEXT", "__text"):
            return sec
    for name in ("__TEXT", "__text"):
        sec = module.FindSection(name)
        if sec.IsValid():
            return sec
    return None


def _nac_sign_load_address(target: lldb.SBTarget, module: lldb.SBModule, sign_off: int) -> int | None:
    sec = _text_section(module)
    if sec is not None:
        text_load = sec.GetLoadAddress(target)
        text_file = sec.GetFileAddress()
        if _valid_load(text_load):
            if text_file in (PREFERRED_VM, 0):
                return text_load + sign_off
            return text_load + (sign_off - (PREFERRED_VM - text_file))

    for file_addr in (PREFERRED_VM + sign_off, sign_off):
        addr = module.ResolveFileAddress(file_addr)
        if not addr.IsValid():
            continue
        load_addr = addr.GetLoadAddress(target)
        if _valid_load(load_addr):
            return load_addr
    return None


def _install_trace_breakpoint(target, module, name: str, rva: int, callback: str) -> None:
    load_addr = _nac_sign_load_address(target, module, rva)
    if load_addr is None:
        print(f"[kappy-nac] could not resolve {name} at rva {rva:#x}")
        return
    bp = target.BreakpointCreateByAddress(load_addr)
    if not bp.IsValid():
        print(f"[kappy-nac] failed to set {name} breakpoint at {load_addr:#x}")
        return
    bp.SetScriptCallbackFunction(callback)
    print(f"[kappy-nac] breakpoint on {name} {rva:#x} -> {load_addr:#x} (id {bp.GetID()})")


def install_nac_sign_breakpoint(debugger, _command, _result, _internal_dict) -> None:
    global _nac_sign_load_addr

    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        print("[kappy-nac] no target")
        return
    module = target.FindModule(lldb.SBFileSpec("identityservicesd", False))
    if not module.IsValid():
        print("[kappy-nac] identityservicesd module not found")
        return

    if INIT_OFF is not None:
        _install_trace_breakpoint(target, module, "NACInit", INIT_OFF, "nac_capture.on_nac_trace")
    if KEY_EST_OFF is not None:
        _install_trace_breakpoint(target, module, "NACKeyEst", KEY_EST_OFF, "nac_capture.on_nac_trace")

    load_addr = _nac_sign_load_address(target, module, SIGN_OFF)
    if load_addr is None:
        sec = _text_section(module)
        if sec is not None:
            print(
                f"[kappy-nac] debug: __TEXT file={sec.GetFileAddress():#x} "
                f"load={sec.GetLoadAddress(target):#x} sections={module.GetNumSections()}"
            )
        print(f"[kappy-nac] could not resolve NACSign load address for offset {SIGN_OFF:#x}")
        return

    _nac_sign_load_addr = load_addr
    bp = target.BreakpointCreateByAddress(load_addr)
    if not bp.IsValid():
        print(f"[kappy-nac] failed to set NACSign breakpoint at {load_addr:#x}")
        return

    bp.SetScriptCallbackFunction(_HANDLER)
    print(f"[kappy-nac] breakpoint on NACSign {SIGN_OFF:#x} -> {load_addr:#x} (id {bp.GetID()})")
    print(
        "[kappy-nac] NOTE: kappy-spike register does NOT call NACSign — "
        "toggle iMessage in Messages.app (Settings → iMessage off/on)"
    )


def _valid_until() -> str:
    return (
        datetime.now(timezone.utc) + timedelta(minutes=15)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")


def on_nac_trace(frame, _bp_loc, _extra_args, _internal_dict) -> bool:
    pc = frame.GetPC()
    print(f"[kappy-nac] hit NAC trace @ {pc:#x}")
    return False


def _dump_nac_sign_output(frame, out_data_ptr_addr: int, out_len_ptr_addr: int) -> bool:
    process = frame.GetThread().GetProcess()
    error = lldb.SBError()
    rc = frame.FindRegister("x0").GetValueAsSigned()
    if rc != 0:
        print(f"[kappy-nac] NACSign returned {rc}")
        return False

    data_ptr = process.ReadUnsignedFromMemory(out_data_ptr_addr, 8, error)
    if not error.Success():
        print(f"[kappy-nac] read out ptr failed: {error}")
        return False
    data_len = process.ReadUnsignedFromMemory(out_len_ptr_addr, 4, error)
    if not error.Success() or data_len == 0 or data_len > 16 * 1024 * 1024:
        print(f"[kappy-nac] bad out len: {data_len}")
        return False

    blob = process.ReadMemory(data_ptr, data_len, error)
    if not error.Success():
        print(f"[kappy-nac] read blob failed: {error}")
        return False

    payload = {
        "validation_data": base64.b64encode(blob).decode("ascii"),
        "valid_until": _valid_until(),
        "nacserv_commit": "kappy-lldb-nac-capture",
    }
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)
        fh.write("\n")
    print(f"[kappy-nac] wrote {OUT_PATH} ({data_len} bytes)")
    print("[kappy-nac] VALIDATION_JSON=" + json.dumps(payload))
    return False


def _schedule_sign_return(debugger: lldb.SBDebugger, target: lldb.SBTarget, return_addr: int) -> bool:
    ret_bp = target.BreakpointCreateByAddress(return_addr)
    if not ret_bp.IsValid():
        print(f"[kappy-nac] failed to set return breakpoint at {return_addr:#x}")
        return False
    ret_bp.SetOneShot(True)
    bp_id = ret_bp.GetID()
    # llvm 20: `breakpoint command add -o "<cmd>" <id>` (-c is not valid here)
    cmd = (
        f'breakpoint command add '
        f'-o "script import nac_capture; nac_capture.complete_sign_capture()" '
        f'{bp_id}'
    )
    result = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(cmd, result)
    if not result.Succeeded():
        print(f"[kappy-nac] breakpoint command add failed: {result.GetError()}")
        target.BreakpointDelete(bp_id)
        return False
    print(f"[kappy-nac] scheduled return breakpoint @ {return_addr:#x} (id {bp_id})")
    return True


def complete_sign_capture() -> None:
    debugger = lldb.debugger
    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        print("[kappy-nac] complete_sign_capture: no target")
        return
    process = target.GetProcess()
    thread = process.GetSelectedThread()
    frame = thread.GetSelectedFrame()
    if not frame.IsValid():
        print("[kappy-nac] complete_sign_capture: no frame")
        return

    thread_id = thread.GetThreadID()
    pending = _pending_sign.pop(thread_id, None)
    if pending is None:
        print("[kappy-nac] complete_sign_capture: no pending state")
        return

    out_data_ptr_addr, out_len_ptr_addr, _return_addr = pending
    print(f"[kappy-nac] NACSign return @ {frame.GetPC():#x}")
    _dump_nac_sign_output(frame, out_data_ptr_addr, out_len_ptr_addr)
    if process.IsValid() and process.GetState() == lldb.eStateStopped:
        process.Continue()


def on_nac_sign_handler(frame, _bp_loc, _extra_args, _internal_dict) -> bool:
    thread = frame.GetThread()
    target = thread.GetProcess().GetTarget()
    thread_id = thread.GetThreadID()
    pc = frame.GetPC()

    if _nac_sign_load_addr is None or pc != _nac_sign_load_addr:
        return False

    out_data_ptr_addr = frame.FindRegister("x3").GetValueAsUnsigned()
    out_len_ptr_addr = frame.FindRegister("x4").GetValueAsUnsigned()
    return_addr = frame.FindRegister("lr").GetValueAsUnsigned()
    _pending_sign[thread_id] = (out_data_ptr_addr, out_len_ptr_addr, return_addr)
    print(
        f"[kappy-nac] NACSign enter out@x3={out_data_ptr_addr:#x} "
        f"len@x4={out_len_ptr_addr:#x} ret={return_addr:#x}"
    )

    if not _schedule_sign_return(lldb.debugger, target, return_addr):
        _pending_sign.pop(thread_id, None)
        return False
    # Continue into NACSign; return breakpoint dumps output when it completes.
    return False


# lldb registers callbacks by name at import time; keep aliases for older scripts.
on_nac_sign_entry = on_nac_sign_handler
on_nac_sign_return = on_nac_sign_handler
