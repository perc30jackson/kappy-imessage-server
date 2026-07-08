# kappy-ids-export

Export GUI iMessage / IDS registration certificates from the running
`identityservicesd` process (same user session). Output is JSON consumed by
`kappy-spike import-ids-export`.

## Why lldb attach?

`IDSRegistrationKeychainManager` only returns registrations when queried from
inside `identityservicesd`. A standalone `dlopen` tool sees an empty list.

## Usage

```bash
# Physical Mac or VM (GUI iMessage must be enabled / signed in)
cd tools/kappy-ids-export
chmod +x capture-ids.sh
./capture-ids.sh /path/to/ids-export.json

# Import into spike state
cd ../../spike
./target/release/kappy-spike import-ids-export --file /path/to/ids-export.json
```

### Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `KAPPY_IDS_CAPTURE_OUT` | `ids-export.json` | Output path |
| `KAPPY_IDS_USER` | `$USER` | Login user whose `identityservicesd` to attach |
| `KAPPY_LLDB_PY_PATH` | `./lldb` | Directory containing `ids_capture.py` |

## JSON format

Exports spike services only:

- `iMessage` → `com.apple.madrid`
- `FaceTime` → `com.apple.ess`
- `Multiway` → `com.apple.private.alloy.facetime.multi`
- `com.apple.private.alloy.multiplex1` → same

Includes `auth_cert_b64`, per-service `registration_cert_b64`, handles, and
`private_key_der_b64` when extractable via `IDSRegistrationKeyManager`.

`private_key_sign_capable: true` means the GUI key can sign inside
`identityservicesd` but is **not exportable** to spike's software keystore.

## Notes

- Attach requires the same user that owns `identityservicesd` (not root on another user's daemon).
- **Do not use `KAPPY_IDS_FORCE_RELOAD`** unless registrations are empty — `reloadFromKeychain` logs Messages out.
- Default VM capture sets `KAPPY_IDS_SKIP_PRIVATE_KEY=1` (certs/handles only; keys are non-exportable anyway).
- Apple stores IDS private keys as **non-exportable** Secure Enclave / token keys. `SecKeyCopyExternalRepresentation` fails even from inside `identityservicesd`. Signing works only in-process via `IDSRegistrationKeyManager`.
- Spike's software `keystore.plist` cannot use GUI keys unless you previously ran successful `kappy-spike register` on the **same machine** (which created exportable keys in software keystore — distinct from GUI keys).
- For VM headless line: GUI import supplies certs/handles but **cannot** bridge GUI signing keys into spike today. Fixing `register` 6001 on VM (or using physical pilot) remains the production path.
- `validation_data` / `hw_info` must still come from the same machine (VM vs physical pilot rule unchanged).

## VM test

Requires **Xcode Command Line Tools** on the VM (`xcode-select --install`).

**lldb attach requires SIP disabled** on the guest (same as the physical pilot). With SIP enabled,
`identityservicesd` rejects attach (`Not allowed to attach to process`) even with Developer Mode on.
Disable in VM Recovery: `csrutil disable`, reboot, then `sudo DevToolsSecurity -enable`.

**Without disabling SIP**, use handle import only:

```bash
~/kappy-spike-bin/kappy-spike --state-dir ~/kappy-spike-state import-gui-registration --synthesize
```

Full cert export (`capture-ids.sh`) on VM (SIP must be off):

```bash
# Deploy from host:
rsync -az tools/kappy-ids-export spike/target/release/kappy-spike scripts/vm-gui-ids-import-test.sh \
  henrynguyen@192.168.64.3:~/

# On VM after GUI iMessage works:
mkdir -p ~/kappy-imessage-server/tools ~/kappy-spike-bin
mv ~/kappy-spike ~/kappy-spike-bin/  # if rsync'd to home
mv ~/kappy-ids-export ~/kappy-imessage-server/tools/
chmod +x ~/vm-gui-ids-import-test.sh ~/kappy-imessage-server/tools/kappy-ids-export/capture-ids.sh
KAPPY_SPIKE_BIN=~/kappy-spike-bin/kappy-spike \
  ~/vm-gui-ids-import-test.sh ~/ids-export.json
```
