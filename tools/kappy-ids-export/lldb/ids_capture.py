"""lldb helpers to export GUI IDS registrations from identityservicesd."""

from __future__ import annotations

import base64
import json
import os
import struct
from datetime import datetime, timezone

import lldb

OUT_PATH = os.environ.get("KAPPY_IDS_CAPTURE_OUT", "ids-export.json")
# identityservicesd login user (default: current user)
IDS_USER = os.environ.get("KAPPY_IDS_USER", os.environ.get("USER", ""))
# reloadFromKeychain disrupts active iMessage sessions — off by default
FORCE_RELOAD = os.environ.get("KAPPY_IDS_FORCE_RELOAD", "").lower() in (
    "1",
    "true",
    "yes",
)
SKIP_PRIVATE_KEY = os.environ.get("KAPPY_IDS_SKIP_PRIVATE_KEY", "").lower() in (
    "1",
    "true",
    "yes",
)

# GUI service type -> spike/rustpush registration key
SPIKE_SERVICES = {
    "iMessage": "com.apple.madrid",
    "FaceTime": "com.apple.ess",
    "Multiway": "com.apple.private.alloy.facetime.multi",
    "com.apple.private.alloy.multiplex1": "com.apple.private.alloy.multiplex1",
}


def _identityservicesd_pid() -> int | None:
    import subprocess

    user = IDS_USER
    try:
        out = subprocess.check_output(
            ["ps", "-ax", "-o", "pid=,user=,comm="],
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        pid_s, proc_user, comm = parts
        if comm.endswith("identityservicesd"):
            continue
        if user and proc_user != user:
            continue
        return int(pid_s)
    return None


def _eval(frame: lldb.SBFrame, expr: str) -> lldb.SBValue:
    val = frame.EvaluateExpression(expr)
    if not val.IsValid():
        err = val.GetError()
        raise RuntimeError(f"expr failed: {expr!r} ({err})")
    return val


def _eval_bool(frame: lldb.SBFrame, expr: str) -> bool:
    val = _eval(frame, expr)
    return bool(val.GetValueAsUnsigned())


def _eval_u64(frame: lldb.SBFrame, expr: str) -> int:
    val = _eval(frame, expr)
    return int(val.GetValueAsUnsigned())


def _eval_nsdata_b64(frame: lldb.SBFrame, expr: str) -> str:
    data_expr = f"(NSData*){expr}"
    length = _eval_u64(frame, f"[{data_expr} length]")
    if length == 0:
        raise RuntimeError(f"empty NSData for {expr!r}")
    ptr = _eval_u64(frame, f"(uint64_t)[{data_expr} bytes]")
    process = frame.GetThread().GetProcess()
    error = lldb.SBError()
    blob = process.ReadMemory(ptr, length, error)
    if not error.Success():
        raise RuntimeError(f"read NSData failed for {expr!r}: {error}")
    return base64.b64encode(blob).decode("ascii")


def _eval_nsstring(frame: lldb.SBFrame, expr: str) -> str:
    val = _eval(frame, f"(NSString*){expr}")
    s = val.GetSummary() or val.GetValue() or ""
    s = s.strip()
    if s.startswith('@'):
        s = s[1:]
    return s.strip().strip('"')


def _eval_nsarray_strings(frame: lldb.SBFrame, expr: str) -> list[str]:
    count = _eval_u64(frame, f"[(NSArray*){expr} count]")
    items: list[str] = []
    for i in range(count):
        item_expr = f"[(NSArray*){expr} objectAtIndex:{i}]"
        items.append(_eval_nsstring(frame, item_expr))
    return items


def _nsdate_to_epoch_s(frame: lldb.SBFrame, expr: str) -> int:
    secs = _eval(frame, f"[(NSDate*){expr} timeIntervalSince1970]")
    return int(float(secs.GetValue()))


def _malloc(frame: lldb.SBFrame, size: int) -> int:
    return _eval_u64(frame, f"(uint64_t)malloc({size})")


def _read_ptr(frame: lldb.SBFrame, addr: int) -> int:
    process = frame.GetThread().GetProcess()
    error = lldb.SBError()
    data = process.ReadMemory(addr, 8, error)
    if not error.Success():
        raise RuntimeError(f"read_ptr {addr:#x}: {error}")
    return struct.unpack("<Q", data)[0]


def _export_private_key_der_b64(
    frame: lldb.SBFrame, profile_id: str | None
) -> tuple[str | None, bool]:
    """Return (der_b64, sign_capable) via IDSRegistrationKeyManagerKeyPairProvider.

    Must be called before reloadFromKeychain (reload clears key-pair cache).
    """
    if profile_id is None:
        profile_id = "D:19478336641"
    try:
        _eval(frame, "(void)[[IDSRegistrationKeyManager sharedInstance] keyPairProvider]")
    except RuntimeError:
        return None, False

    pubp = _malloc(frame, 8)
    privp = _malloc(frame, 8)
    sigp = _malloc(frame, 8)
    migp = _malloc(frame, 8)
    upp = _malloc(frame, 8)
    for addr in (pubp, privp, sigp, migp, upp):
        _eval(frame, f"(void)memset((void*){addr}, 0, 8)")

    _eval(
        frame,
        f"(void)[(id)[[IDSRegistrationKeyManager sharedInstance] keyPairProvider] "
        f'copyRegistrationKeyPairForIdentifier:@"{profile_id}" '
        f"publicKey:(void **){pubp} privateKey:(void **){privp} "
        f"keyPairSignature:(id *){sigp} isMigratedSignature:(BOOL *){migp} "
        f'isUpgradePending:(BOOL *){upp}]',
    )
    priv = _read_ptr(frame, privp)
    if not priv:
        return None, False

    sign_capable = False
    digest_addr = _malloc(frame, 20)
    _eval(frame, f'(void)CC_SHA1("kappy", 5, (unsigned char *){digest_addr})')
    try:
        sig_len = _eval_u64(
            frame,
            f"(uint64_t)CFDataGetLength(SecKeyCreateSignature((SecKeyRef){priv}, "
            f"kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, "
            f"CFDataCreate(NULL, (const UInt8 *){digest_addr}, 20), NULL))",
        )
        sign_capable = sig_len > 0
    except RuntimeError:
        try:
            sig_len = _eval_u64(
                frame,
                f"""
{{
  CFDataRef digest = CFDataCreate(NULL, (const UInt8 *){digest_addr}, 20);
  CFDataRef sig = SecKeyCreateSignature((SecKeyRef){priv},
      kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, digest, NULL);
  (uint64_t)CFDataGetLength(sig);
}}
""",
            )
            sign_capable = sig_len > 0
        except RuntimeError:
            sign_capable = False

    der_ptr = _eval_u64(
        frame, f"(uint64_t)SecKeyCopyExternalRepresentation((SecKeyRef){priv}, NULL)"
    )
    if not der_ptr:
        return None, sign_capable

    length = _eval_u64(frame, f"(uint64_t)CFDataGetLength((CFDataRef){der_ptr})")
    if length < 256:
        return None, sign_capable

    bytes_ptr = _eval_u64(frame, f"(uint64_t)CFDataGetBytePtr((CFDataRef){der_ptr})")
    process = frame.GetThread().GetProcess()
    error = lldb.SBError()
    blob = process.ReadMemory(bytes_ptr, length, error)
    if not error.Success():
        return None, sign_capable
    return base64.b64encode(blob).decode("ascii"), sign_capable


def dump_ids_registrations(debugger, _command, result, _internal_dict) -> None:
    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        print("[kappy-ids] no target; attach to identityservicesd first")
        return

    process = target.GetProcess()
    thread = process.GetSelectedThread()
    frame = thread.GetSelectedFrame()
    if not frame.IsValid():
        print("[kappy-ids] no frame")
        return

    # Read in-memory registrations first. Do NOT call reloadFromKeychain unless
    # forced — it invalidates the live GUI session and logs Messages out.
    regs_expr = "[[IDSRegistrationKeychainManager sharedInstance] registrations]"
    count = _eval_u64(frame, f"[(NSArray*){regs_expr} count]")
    if count == 0 and FORCE_RELOAD:
        print("[kappy-ids] no in-memory registrations; reloadFromKeychain (forced)")
        _eval(
            frame,
            "(void)[[IDSRegistrationKeychainManager sharedInstance] reloadFromKeychain]",
        )
        count = _eval_u64(frame, f"[(NSArray*){regs_expr} count]")
    elif count == 0:
        print(
            "[kappy-ids] no registrations in memory — open Messages, enable "
            "iMessage, then retry (avoid KAPPY_IDS_FORCE_RELOAD; it logs you out)"
        )
        return

    peek_profile: str | None = None
    for i in range(count):
        reg = f"[(NSArray*){regs_expr} objectAtIndex:{i}]"
        try:
            peek_profile = _eval_nsstring(frame, f"[(id){reg} profileID]")
            if peek_profile:
                break
        except RuntimeError:
            continue

    private_key_der_b64: str | None = None
    private_key_sign_capable = False
    if not SKIP_PRIVATE_KEY:
        private_key_der_b64, private_key_sign_capable = _export_private_key_der_b64(
            frame, peek_profile
        )

    profile_id: str | None = None
    auth_cert_b64: str | None = None
    private_key_alias: str | None = None
    registrations: list[dict] = []

    for i in range(count):
        reg = f"[(NSArray*){regs_expr} objectAtIndex:{i}]"
        gui_type = _eval_nsstring(frame, f"[(id){reg} serviceType]")
        spike_name = SPIKE_SERVICES.get(gui_type)
        if spike_name is None:
            continue

        pid = _eval_nsstring(frame, f"[(id){reg} profileID]")
        if profile_id is None:
            profile_id = pid
            private_key_alias = f"ids:{pid}"
        elif pid != profile_id:
            print(f"[kappy-ids] skip {gui_type}: profile {pid} != {profile_id}")
            continue

        if auth_cert_b64 is None:
            try:
                auth_cert_b64 = _eval_nsdata_b64(
                    frame, f"[(id){reg} authenticationCert]"
                )
            except RuntimeError as err:
                print(f"[kappy-ids] warn: no authenticationCert: {err}")

        handles = _eval_nsarray_strings(frame, f"[(id){reg} uris]")
        reg_cert_b64 = _eval_nsdata_b64(
            frame, f"[(id){reg} registrationCert]"
        )
        registered_at_s = _nsdate_to_epoch_s(
            frame, f"[(id){reg} registrationDate]"
        )

        registrations.append(
            {
                "gui_service_type": gui_type,
                "spike_service": spike_name,
                "handles": handles,
                "registration_cert_b64": reg_cert_b64,
                "registered_at_s": registered_at_s,
            }
        )
        print(
            f"[kappy-ids] {gui_type} -> {spike_name}: "
            f"{len(handles)} handle(s), cert {len(base64.b64decode(reg_cert_b64))} bytes"
        )

    if not registrations:
        print("[kappy-ids] no spike-relevant registrations found (is iMessage enabled?)")
        return

    if private_key_alias is None and profile_id:
        private_key_alias = f"ids:{profile_id}"

    payload = {
        "exported_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "profile_id": profile_id,
        "private_key_alias": private_key_alias,
        "auth_cert_b64": auth_cert_b64,
        "private_key_der_b64": private_key_der_b64,
        "private_key_sign_capable": private_key_sign_capable,
        "registrations": registrations,
    }

    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")

    print(f"[kappy-ids] wrote {OUT_PATH} ({len(registrations)} service(s))")
    if private_key_der_b64:
        print("[kappy-ids] exported RSA private key (DER)")
    elif private_key_sign_capable:
        print(
            "[kappy-ids] WARN: private key is non-exportable but sign-capable inside "
            "identityservicesd — spike software keystore cannot use it; headless send "
            "requires a prior successful `kappy-spike register` on this machine"
        )
    else:
        print(
            "[kappy-ids] WARN: private key not exported — "
            "spike keystore must already contain "
            f"{private_key_alias} or import will fail at send/register"
        )
    result.SetStatus(lldb.eReturnStatusSuccessFinishResult)


def attach_and_dump(debugger, _command, result, _internal_dict) -> None:
    pid = _identityservicesd_pid()
    if pid is None:
        print(f"[kappy-ids] identityservicesd not found for user {IDS_USER!r}")
        result.SetStatus(lldb.eReturnStatusFailed)
        return

    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        debugger.CreateTarget("")
        target = debugger.GetSelectedTarget()

    err = lldb.SBError()
    process = target.AttachToProcessWithID(debugger, pid, err)
    if err.Fail():
        print(f"[kappy-ids] attach failed pid={pid}: {err}")
        result.SetStatus(lldb.eReturnStatusFailed)
        return

    print(f"[kappy-ids] attached to identityservicesd pid={pid}")
    dump_ids_registrations(debugger, None, result, None)
