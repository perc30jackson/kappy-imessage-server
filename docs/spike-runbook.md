# U0 R1 feasibility spike runbook

Run on **macOS on the pilot Mac**. For validation generation on **macOS 26+**, use the local NAC wrapper in `tools/nac-validation-provider` (Beeper's archived `mac-registration-provider` only supports through 14.3).

## Prerequisites

1. Dedicated Apple ID for the fleet line (SMS-verified once in Messages.app on the pilot Mac).
2. [Mac-Hardware-Info](https://github.com/OpenBubbles/Mac-Hardware-Info) built or installed on the pilot Mac.
3. Xcode CLI tools + Rust toolchain.
4. For validation on macOS 26+: build `tools/nac-validation-provider` (see its README).

## Bootstrap

```bash
cd kappy-imessage-server
chmod +x scripts/*.sh
./scripts/vendor-rustpush.sh
cd spike
cargo build --release
```

Binary: `target/release/kappy-spike`

## Spike flow

### 1. Export hardware identity

On the pilot Mac, open **Mac Hardware Info** → copy activation payload (base64 or QR export file).

Save to e.g. `~/kappy-spike/hw-export.bin` (raw bytes or base64-decoded OABS payload).

### 2. Activate (creates `state/hw_info.plist`)

```bash
export KAPPY_SPIKE_STATE_DIR=./state
./target/release/kappy-spike activate --hw-info ~/kappy-spike/hw-export.bin
```

### 3. Apple login (creates `state/id.plist`)

```bash
export KAPPY_APPLE_ID='you@icloud.com'
export KAPPY_APPLE_PASSWORD='...'
./target/release/kappy-spike login
```

Complete 2FA on a trusted device if prompted.

### 4. Validation data (pick one)

**macOS 26+ note:** Local NAC generation via `identityservicesd` offsets is blocked by PAC trampolines on `NACKeyEstablishment` / `NACSign` ([OpenBubbles/rustpush#21](https://github.com/OpenBubbles/rustpush/issues/21)). Use one of the alternate paths below instead of `-find-offsets`.

**Option A — one-shot (macOS 26+ wrapper, when offsets work):**

```bash
make -C tools/nac-validation-provider
./tools/nac-validation-provider/kappy-nac-validation-provider -once > validation.json
cd spike && ./target/release/kappy-spike inject-validation --file ../validation.json
```

**Option A′ — one-shot (macOS ≤14.3, Beeper provider):**

```bash
mac-registration-provider -once > validation.json
./target/release/kappy-spike inject-validation --file validation.json
```

**Option B — remote Mac pushes to pilot (recommended for macOS 26):**

On the **pilot Mac** (macOS 26):

```bash
./target/release/kappy-spike validation-server --listen 0.0.0.0:8787
```

On a **helper Mac** (macOS ≤14.3 with `mac-registration-provider`):

```bash
export VALIDATION_SUBMIT_URL=http://PILOT_IP:8787/internal/validation
./scripts/run-remote-validation-pusher.sh
```

**Option C — Beeper registration relay:**

On helper Mac (once, to get a relay code):

```bash
mac-registration-provider -relay
```

On pilot Mac:

```bash
export KAPPY_RELAY_CODE='<code from helper Mac>'
./target/release/kappy-spike fetch-validation-relay
# or ongoing refresh:
./scripts/run-validation-relay-fetch.sh
```

**Option C′ — kappy-nacserv (self-hosted HTTP, recommended for fleet):**

On helper Mac (macOS ≤14.3 with working NAC):

```bash
make -C tools/nac-validation-provider   # or install mac-registration-provider
./scripts/run-kappy-nacserv.sh --listen 0.0.0.0:8788
# token: ~/.config/kappy-nacserv/token
```

On pilot Mac (macOS 26):

```bash
export KAPPY_NACSERV_URL=http://HELPER_IP:8788
export KAPPY_NACSERV_TOKEN='<token>'
./target/release/kappy-spike fetch-validation-nacserv
# or ongoing:
./scripts/run-validation-nacserv-poller.sh
```

See `tools/kappy-nacserv/README.md`.

**Option D — ongoing refresh via local sidecar (macOS ≤14.3 only):**

Terminal 1:

```bash
./target/release/kappy-spike validation-server --listen 127.0.0.1:8787
```

Terminal 2:

```bash
./scripts/run-validation-sidecar.sh
```

### 5. Register IDS (iMessage)

```bash
./target/release/kappy-spike register
```

### 6. Send + receive

```bash
./target/release/kappy-spike send --to '+15551234567' --body 'kappy spike ping'
./target/release/kappy-spike listen
```

Reply from the test phone; confirm `INBOUND iMessage` in logs.

### 7. Restart persistence (T0.4)

```bash
./target/release/kappy-spike save-state
# exit and rerun:
./target/release/kappy-spike listen
```

Should reconnect without re-running `activate`.

## Report

Fill in `spike/SPIKE_REPORT.md` and attach commit SHAs. A **PASS** unblocks plan unit U1.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `Validation data missing` on register | Run fetch-validation-relay, inject-validation, or validation-server + remote pusher |
| `no IDS users` on register | Run `login` first |
| NAC wrapper unsupported / sanity check fails | On macOS 26+, use relay or remote Mac path (Options B/C in runbook) |
| mac-registration-provider exits immediately | macOS >14.3 — use remote Mac or Beeper relay |
| Relay fetch returns 404 | Helper Mac not running `mac-registration-provider -relay`, or wrong code |
| APS setup warning | Network/firewall; retry on wired connection |

## References

- `linkedin_connector/docs/brainstorms/2026-07-07-rustpush-grpc-server-requirements.md`
- OpenBubbles `openbubbles-app` `rustpush` branch `rust/src/api/api.rs`
