# kappy-nac-validation-provider

Local `identityservicesd` NAC wrapper for macOS 26+. Forked from [Beeper mac-registration-provider](https://github.com/beeper/mac-registration-provider): it `dlopen`s Apple's `identityservicesd` binary and calls `NACInit` / `NACKeyEstablishment` / `NACSign` via hardcoded per-build offsets.

**macOS 26 status:** `NACKeyEstablishment` and `NACSign` are PAC-protected trampolines and cannot be called via raw function-pointer casts ([OpenBubbles/rustpush#21](https://github.com/OpenBubbles/rustpush/issues/21)). Offset discovery alone is unlikely to unblock local generation. For the spike on macOS 26, use an alternate validation path in `docs/spike-runbook.md` (remote Mac pusher or Beeper relay).

## Build

```bash
make -C tools/nac-validation-provider
```

## Discover offsets (new macOS build)

When Apple updates `identityservicesd`, offsets must be re-derived. On macOS 26+, also see `docs/nac-pac-research.md` and try:

```bash
./tools/nac-validation-provider/kappy-nac-validation-provider -pac-scan
./tools/nac-validation-provider/kappy-nac-validation-provider -pac-resolve
```

```bash
./tools/nac-validation-provider/kappy-nac-validation-provider -find-offsets
```

The fast scanner uses arm64 function-prologue filtering (~30 candidates instead of ~130k), a single `dlopen`, and live progress output. It usually finishes in seconds.

Check current binary hash:

```bash
shasum -a 256 /System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd
```

## Generate validation once

```bash
./tools/nac-validation-provider/kappy-nac-validation-provider -once > validation.json
cd spike && ./target/release/kappy-spike inject-validation --file ../validation.json
```

## Submit sidecar (spike validation-server)

```bash
./target/release/kappy-spike validation-server --listen 127.0.0.1:8787
./scripts/run-validation-sidecar.sh
```

## Compatibility check

```bash
./tools/nac-validation-provider/kappy-nac-validation-provider -check-compatibility
```
