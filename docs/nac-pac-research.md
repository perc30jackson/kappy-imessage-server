# NAC / PAC research notes (macOS 26)

Local validation via `dlopen(identityservicesd)` broke on macOS 26 because `NACKeyEstablishment` and `NACSign` are no longer plain callable functions — they sit behind **pointer-authenticated** indirection ([OpenBubbles/rustpush#21](https://github.com/OpenBubbles/rustpush/issues/21)).

This doc catalogs open resources, RE tooling, and the PAC-aware path added to `tools/nac-validation-provider`.

## What broke

| Era | Calling model | Works with raw offset cast? |
|-----|---------------|------------------------------|
| macOS ≤14.3 | Direct `pacibsp` implementations | Yes (Beeper `mac-registration-provider`) |
| macOS 26 | `__auth_stubs` → `__auth_got` → `braa` | **No** for implementation bodies found by prologue scan |

On macOS 26.5.1 arm64e `identityservicesd`:

- `NACInit` body at `0x2a7360` — `pacibsp`, cert probe passes
- `NACKeyEstablishment` body at `0x7e530c` — `pacibsp`, not behind `braa` stub in export table
- `0x6d5d98` — `br x17` thunk (not the canonical 16-byte `braa` stub)
- `__auth_stubs` section at `0x9f2168` — **10,478** `braa x16,x17` thunks
- `__auth_got` at `0xcb8000` — signed function pointers (valid only after `dlopen`)

`ptrauth_sign_unauthenticated` on the implementation address **does not** fix calls — the signed target in `__auth_got` uses **address diversity** (discriminator = GOT slot address per [LLVM arm64e stub layout](https://github.com/llvm/llvm-project/pull/188378)).

## Open-source resources

### Directly relevant

| Resource | What it offers | PAC / macOS 26? |
|----------|----------------|-----------------|
| [OpenBubbles/rustpush#21](https://github.com/OpenBubbles/rustpush/issues/21) | Confirms PAC breakage, lists failed workarounds | Documents blocker |
| [beeper/mac-registration-provider](https://github.com/beeper/mac-registration-provider) | Offset table + `dlopen` proxy | **Archived**, ≤14.3 only |
| [beeper/registration-relay](https://github.com/beeper/registration-relay) | Relay protocol we already integrated in spike | Bypasses local NAC |
| [jasonlaguidice/imessage](https://github.com/jasonlaguidice/imessage) | `tools/nac-relay` HTTP relay; `rustpush/open-absinthe` NAC emulator for **Linux/Intel** | Mac relay still uses old NAC path |
| [OpenAbsinthe-Stub](https://github.com/OpenBubbles/OpenAbsinthe-Stub) | Public API surface (`ValidationCtx`) | **Closed source** — real impl not public |
| [blacktop/ipsw-diffs](https://github.com/blacktop/ipsw-diffs) | Per-build `identityservicesd` diffs between macOS versions | Offset drift tracking |

### Beeper iMessage stack (relay, not PAC fix)

| Resource | Notes |
|----------|-------|
| [beeper/imessage `nacserv`](https://github.com/beeper/imessage/tree/main/imessage/direct/nacserv) | Client for validation relay — same API spike uses |
| [phone-registration-provider](https://github.com/beeper/phone-registration-provider) | Jailbroken iPhone alternative to Mac provider |

### PAC / arm64e references

| Resource | Use |
|----------|-----|
| [Apple: Pointer authentication](https://developer.apple.com/documentation/apple-silicon/improving-control-flow-integrity-with-pointer-authentication) | `ptrauth_auth_function`, discriminators, keys |
| [Clang PointerAuthentication.rst](https://github.com/apple/llvm-project/blob/apple/main/clang/docs/PointerAuthentication.rst) | arm64e ABI: C fn ptrs use IA key, discriminator 0; auth_got stubs use address diversity |
| [LLVM MachO arm64e linking PR #188378](https://github.com/llvm/llvm-project/pull/188378) | Exact `braa` stub encoding: `adrp/add/ldr/braa` |
| [Reverse Society PAC blog (2026)](https://blog.reversesociety.co/blog/2026/pointer-authentication-code-for-ios) | Practical PAC key/discriminator mental model |

## Reverse-engineering tooling

| Tool | Role for this problem |
|------|----------------------|
| **Hopper / IDA / Ghidra** | Map `__auth_stubs` → `__auth_got` → implementation; find `NACInit` string xrefs |
| **lldb** | Break on `braa`, inspect `x16`/`x17` at stub entry; watch `identityservicesd` `exit()` |
| **otool / objdump** | Section layout, disassembly (`otool -t -V identityservicesd`) |
| **ipsw** ([blacktop/ipsw](https://github.com/blacktop/ipsw)) | Extract & diff dylibs across macOS builds |
| **class-dump / objc4** | `IDSValidationSession` API surface (entitlement-gated) |
| **Frida** | Hook NAC from inside a process that already calls them legitimately |
| **dtrace / Instruments** | Trace callers of validation in Messages/identityservicesd |

No Cursor plugin replaces a disassembler here — use Hopper/IDA locally and paste stub→impl mappings into `offsets.h`.

## Approaches (hardest → easiest)

### 1. Call `__auth_stubs` instead of implementation bodies (implemented — probe only)

`kappy-nac-validation-provider -pac-scan` loads `identityservicesd`, walks `__auth_stubs`, reads live `__auth_got`, and maps stub → target.

**Finding on macOS 26.5.1:** All 1,712 `__auth_got` entries resolve to **external** dylibs (Foundation, libsystem, etc.). **Zero** map to in-image `__text`. NAC bodies at `0x2a7360` / `0x7e530c` have **no** auth stub — they are internal `pacibsp` functions, not export thunks.

So the rustpush#21 PAC breakage is **not** fixable by swapping offset → auth_stub on this build. The failure mode is likely internal (wrong target, thread context, or `exit()` guard), not missing `braa` stub indirection.

### 2. Manual `ptrauth_auth_function` from `__auth_got`

Replicate stub behavior without calling the stub:

```c
void *slot = image_base + got_offset;
void *signed_fn = *(void **)slot;
void *fn = ptrauth_auth_function(
    signed_fn,
    ptrauth_key_process_independent_code,
    ptrauth_blend_discriminator(slot, 0));
```

Implemented in `nac_pac.m` (`strip_code_ptr`). Use when stub address is known but you need the raw target for logging.

### 3. `IDSValidationSession` (ObjC API)

Mentioned in [rustpush#21](https://github.com/OpenBubbles/rustpush/issues/21) — crashes without entitlements. Would require running inside an entitled context (Messages.app XPC, `identityservicesd` host process). High effort; likely not viable for headless spike.

### 4. In-process injection / XPC

Inject into `identityservicesd` or call via XPC to the daemon that already holds valid PAC chains. Essentially building a miniature `nacserv`. Beeper's archived Go stack explored this; not open sourced for macOS 26.

### 5. Reimplement NAC (OpenAbsinthe path)

Reverse Apple's protocol entirely — cert fetch → session init → key establishment → sign. OpenBubbles ships this closed. Public `open-absinthe` crate is `todo!()`. Person-years of crypto RE.

### 6. External relay (pragmatic)

See `docs/spike-runbook.md` Options B/C — still the recommended production path.

## Code map

| File | Purpose |
|------|---------|
| `nac_pac.m` | Runtime `__auth_stubs` / `__auth_got` walker, `-pac-scan`, `-pac-resolve` |
| `nac_proxy.m` | Raw function-pointer calls (pre-PAC model) |
| `nac_scan.m` | Prologue / cert-based offset discovery |
| `nac_validate.m` | Full pipeline + fork-isolated worker |

## Next RE steps if `-pac-resolve` fails

1. In Hopper: xref strings `NACInit`, `validation`, `session-info` to find true symbol boundaries
2. For each candidate KeyEst/Sign **body**, check whether an `__auth_stubs` entry points to it (our `-pac-scan` watch list)
3. If bodies have **no** auth stub (only direct internal calls), the fix may require calling from **inside** the dyld image's intended call graph, not external `dlopen`
4. Compare macOS 15 vs 26 `identityservicesd` in [ipsw-diffs](https://github.com/blacktop/ipsw-diffs) for when KeyEst moved behind stubs
5. Evaluate Frida hook on `IDSValidationSession` in Messages during a real registration

## Honest assessment

PAC-aware stub calling is the **most promising open-source-local path**, but success is not guaranteed:

- `NACInit` working suggests `dlopen` itself is fine
- KeyEst/Sign may abort via `exit()` (rc `-99`) for reasons beyond PAC (wrong function, missing thread context, MeowMemory)
- OpenBubbles almost certainly solves this in **closed** OpenAbsinthe, not via Beeper's offset hack

Use relay for fleet uptime; use `-pac-scan` / `-pac-resolve` for continued RE.
