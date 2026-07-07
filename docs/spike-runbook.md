# U0 R1 feasibility spike runbook

Run on a **supported macOS version** for [Beeper mac-registration-provider](https://github.com/beeper/mac-registration-provider#supported-macos-versions). Windows/Linux cannot run this spike.

## Prerequisites

1. Dedicated Apple ID for the fleet line (SMS-verified once in Messages.app on the pilot Mac).
2. [Mac-Hardware-Info](https://github.com/OpenBubbles/Mac-Hardware-Info) built or installed on the pilot Mac.
3. `mac-registration-provider` binary from Beeper releases (or nightly build).
4. Xcode CLI tools + Rust toolchain.

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

**Option A — one-shot (spike only):**

```bash
mac-registration-provider -once > validation.json
./target/release/kappy-spike inject-validation --file validation.json
```

**Option B — ongoing refresh (fleet-like):**

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
| `Validation data missing` on register | Run inject-validation or validation-server + sidecar first |
| `no IDS users` on register | Run `login` first |
| mac-registration-provider exits immediately | macOS version not in Beeper allowlist |
| APS setup warning | Network/firewall; retry on wired connection |

## References

- `linkedin_connector/docs/brainstorms/2026-07-07-rustpush-grpc-server-requirements.md`
- OpenBubbles `openbubbles-app` `rustpush` branch `rust/src/api/api.rs`
