# Frida NAC capture (macOS 26.5.1 PAC bypass)

Hooks **inside** `identityservicesd` where NAC already runs with valid PAC chains. Use this to capture `validation_data` when external `dlopen` + offset casts fail.

## Prerequisites

```bash
pip install frida-tools
# Frida gadget/server version should match your macOS arch (arm64)
```

`identityservicesd` must be running:

```bash
pgrep -x identityservicesd || open -a Messages
```

Attaching to `identityservicesd` on **macOS 26.x** usually fails with `unexpected early end-of-stream` even with **sudo** and SIP disabled — the kernel blocks Frida from instrumenting system daemons. **Use lldb instead** (see below).

Attaching on older macOS may require **sudo** and Developer Mode.

## Recommended on macOS 26.5.1: lldb capture

```bash
chmod +x scripts/physical-pilot-lldb-register.sh
./scripts/physical-pilot-lldb-register.sh
```

In another terminal, trigger NAC by toggling iMessage in Messages.app (Settings → iMessage off/on). **Do not** use `kappy-spike register` — it does not call NACSign. lldb breaks on `NACSign`, dumps `validation-pilot.json`, then injects + registers.

Or run the all-in-one helper (toggle iMessage when prompted):

```bash
./scripts/physical-pilot-capture-and-register.sh
```

## Frida (macOS ≤15 VM or if attach works on your build)

**Terminal 1** — attach hooks:

```bash
chmod +x tools/nac-validation-provider/frida/run-frida-nac.sh
./tools/nac-validation-provider/frida/run-frida-nac.sh
```

**Terminal 2** — trigger NAC (physical pilot):

```bash
cd spike
export KAPPY_SPIKE_STATE_DIR=./state
./target/release/kappy-spike register
# or: toggle iMessage off/on in Messages.app
```

When `NACSign` succeeds, the script prints:

```
[kappy-nac] VALIDATION_JSON={"validation_data":"...","valid_until":"..."}
```

`run-frida-nac.sh` also writes `validation.json` in the repo root.

**Inject into spike:**

```bash
cd spike
./target/release/kappy-spike inject-validation --file ../validation.json
./target/release/kappy-spike register
```

## Manual frida CLI

```bash
sudo frida -n identityservicesd \
  -l tools/nac-validation-provider/frida/nac_hooks.js \
  --parameters '{"profile":"26.5.1"}'
```

macOS **15.0** VM helper:

```bash
sudo frida -n identityservicesd \
  -l tools/nac-validation-provider/frida/nac_hooks.js \
  --parameters '{"profile":"15.0"}'
```

## Offset profiles

| Profile | NACInit | NACKeyEst | NACSign |
|---------|---------|-----------|---------|
| `26.5.1` | `0x8832cc` (braa wrapper) | `0x7e3a44` | `0x7fd004` |
| `15.0` | `0x66b05c` | `0x64e200` | `0x67e4d8` |

RVAs are from the `identityservicesd` Mach-O base. Re-verify after OS updates with:

```bash
python3 tools/nac-validation-provider/scripts/arm64e_string_xrefs.py /tmp/ids-pilot-26-arm64e-thin
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `unexpected early end-of-stream` (macOS 26) | **Expected** — use `./scripts/physical-pilot-lldb-register.sh` instead |
| `module not loaded` | Start Messages / run spike login first |
| `unable to attach` | `sudo`, disable SIP partially, or use Developer Mode |
| Hooks fire, no `VALIDATION_JSON` | Registration path may not reach NACSign; try Messages iMessage toggle |
| Wrong offsets after OS update | Re-run string-xref RE, update `PROFILES` in `nac_hooks.js` |

## Security

Captured validation is tied to **this Mac's hardware**. Use only on the machine that will register with the same `hw_info`.
