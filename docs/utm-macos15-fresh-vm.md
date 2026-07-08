# Fresh macOS 15+ UTM helper VM (Apple iCloud path)

Use this when the **macOS 14.1** helper VM fails iCloud / GSA login with **invalid MID** (`-80009`). Apple only supports iCloud in VMs when:

- **Host** runs macOS 15+ (your pilot: macOS 26.5.1 — OK)
- **Guest** is a **fresh** install from a macOS 15+ `.ipsw` (not an in-place upgrade from 14.x)

Reference: [Using iCloud with macOS virtual machines](https://developer.apple.com/documentation/virtualization/using_icloud_with_macos_virtual_machines)

## Why recreate (not upgrade)

Your current VM (`macOS.utm`, guest **14.1**) cannot gain iCloud support by upgrading to 15. Virtualization.framework assigns a Sequoia-capable VM identity only at **create-from-IPSW** time. Upgrading 14 → 15 keeps the old identity.

## Phase 1 — Create the VM in UTM

1. **Shut down** the old `macOS.utm` VM (keep it for nacserv-only experiments, or archive it).
2. UTM → **Create a New Virtual Machine** → **Virtualize** → **macOS 12+**.
3. **IPSW:** Let UTM auto-download the latest compatible macOS, **or** pick a Sequoia IPSW from [ipsw.me](https://ipsw.me/product/Mac) (Universal restore image).
4. **Resources:** ≥ 8 GB RAM, ≥ 4 cores, ≥ 80 GB disk.
5. Name it e.g. `kappy-helper-15` and finish setup.
6. Complete macOS Setup Assistant in the VM:
   - Create user `worker` (same as today) for script compatibility
   - Enable **Remote Login** (SSH): System Settings → General → Sharing → Remote Login

### iCloud sign-in (required before `kappy-spike login`)

1. System Settings → **Apple Account** → sign in with the fleet Apple ID.
2. If you see **Verification Failed** / **unknown error**:
   - Remove **hardware security keys** (YubiKey) from the Apple ID temporarily ([UTM #7316](https://github.com/utmapp/UTM/issues/7316))
   - Try **VirtualBuddy** instead of UTM if UTM keeps failing (same Virtualization.framework; some users report better Apple ID UX)
   - Do **not** use an upgraded-from-14 VM
3. Confirm iCloud Drive / Passwords sync starts (App Store may still fail — that is expected in VMs).

## Phase 2 — Network + SSH from pilot

Default UTM bridged IP is often still `192.168.64.2`, but verify:

```bash
# From pilot — replace IP after you know the new VM address
ping -c1 192.168.64.2
ssh-copy-id -i ~/.ssh/id_ed25519 worker@192.168.64.2
ssh worker@192.168.64.2 sw_vers
# Expect: ProductVersion 15.x or 16.x (not 14.x)
```

Install Xcode Command Line Tools on the **guest** (needed to build NAC provider if not pushed as binary):

```bash
ssh worker@192.168.64.2 'xcode-select -p || xcode-select --install'
```

## Phase 3 — Deploy kappy stack on the new VM

From the repo on the **pilot Mac**:

```bash
cd kappy-imessage-server

# Build host artifacts
make -C tools/nac-validation-provider
CARGO_TARGET_DIR=tools/kappy-nacserv/target cargo build --release \
  --manifest-path tools/kappy-nacserv/Cargo.toml
cd spike && CARGO_TARGET_DIR=target cargo build --release && cd ..

# Point at new VM IP if it changed
export HELPER_HOST=192.168.64.2   # update if needed
export HELPER_USER=worker

./scripts/remote-setup-helper-vm.sh
```

`remote-setup-helper-vm.sh` detects guest macOS ≥ 15 and installs **`kappy-nac-validation-provider`** instead of archived `mac-registration-provider` (which only supports ≤ 14.3).

Verify nacserv from pilot:

```bash
source spike/.env.helper
curl -fsS -H "Authorization: Bearer $KAPPY_NACSERV_TOKEN" \
  "$KAPPY_NACSERV_URL/health"
```

## Phase 4 — Full spike stack on the VM

Sign into iCloud in the VM **first**, then:

```bash
export HELPER_HOST=192.168.64.2
export KAPPY_APPLE_ID='henry@jabronicapital.com'
export KAPPY_APPLE_PASSWORD='…'   # rotate if exposed in shell history

./scripts/test-vm-full-stack.sh
```

Expected progression:

| Step | macOS 14.1 VM | Fresh macOS 15+ VM |
|------|---------------|---------------------|
| activate | OK | OK |
| fetch-validation-nacserv | OK | OK (via kappy-nac-validation-provider) |
| login (AOSKit/raw) | `-80009` invalid MID | **Should reach LoggedIn** after iCloud sign-in |
| register | blocked | try after login |

If login still fails with `-80009`:

```bash
# On VM — clear stale anisette state, retry raw AOSKit
ssh worker@192.168.64.2 'rm -rf ~/kappy-spike-state/anisette'
export KAPPY_ANISETTE=raw
./scripts/test-vm-full-stack.sh
```

If login fails with `-80035` on the **pilot** while using VM hardware export — that is the split-fleet anti-pattern; run login **on the VM** (this doc), not on the pilot with VirtualMac identity.

## Phase 5 — Pilot split (optional)

If the VM stack works end-to-end, you can either:

- **All-in-VM:** run `listen` / `send` on the VM (simplest identity alignment), or
- **Split:** pilot polls VM nacserv for validation only, but pilot must use **physical** `hw_info` + pilot login (not VirtualMac on pilot)

For the original split-fleet goal (VirtualMac login on physical host), Apple still blocks GSA init (`-80035`). The macOS 15 VM path fixes **VM-local** login, not pilot-as-VirtualMac.

## Troubleshooting

| Symptom | Action |
|---------|--------|
| iCloud “Verification Failed” in VM | Fresh IPSW install; remove hardware keys; try VirtualBuddy |
| `helper-vm-setup` dies on macOS 15 | Use updated script (nac-validation-provider path) |
| nacserv `provider -once failed` | On VM: `kappy-nac-validation-provider -check-compatibility` and `-find-offsets` |
| `6004` on register | Validation does not match this machine's `hw_info`. On the **VM**, run `fetch-validation-nacserv` against **local** nacserv (`127.0.0.1:8788`), not the physical pilot. See `scripts/vm-refresh-validation-and-register.sh`. |
| `6001 Incompatible` on register | 1) Disable ADP + Contact Key Verification on Apple ID. 2) On the **VM**, open **Messages** → enable iMessage → complete phone/SMS verification (runbook prerequisite). 3) If still failing: UTM `VirtualMac2,1` has **zero MLB** in IORegistry — Apple may reject headless register even when iMessage GUI works. |
| `lldb` / `python3` fails on VM | Install Xcode CLT on the VM (`xcode-select --install`) — required for `kappy-ids-export` and nacserv lldb capture refresh. |
| `lldb attach denied` / `cannot get permission to debug` | Enable **Developer Mode** (System Settings → Privacy & Security → Developer Mode). Run `capture-ids.sh` from **Terminal.app on the VM** (SSH is non-interactive and cannot approve attach). |
| `Not allowed to attach to process` | **SIP blocks lldb** on hardened `identityservicesd` (VM has SIP on; physical pilot has SIP off). Disable SIP in VM Recovery (`csrutil disable`) or use `import-gui-registration --synthesize` instead of lldb export. |
| `6005` on register after `import-ids-export` | GUI export overwrote `auth_keypair.cert` but spike still signs with software keys in `keystore.plist`. Re-run `kappy-spike login` on the VM, then `register` again. |
| Stuck `kappy-spike login` at 100% CPU | `ssh worker@VM 'pkill -9 -f kappy-spike; xattr -cr /tmp/kappy-spike'` |

## References

- [UTM macOS guest docs](https://docs.getutm.app/guest-support/macos/)
- [Eclectic Light — Build a VM with iCloud access in Sequoia](https://eclecticlight.co/2024/09/18/build-a-vm-with-icloud-access-in-sequoia-on-apple-silicon/)
- `docs/spike-runbook.md` — validation options
- `scripts/test-vm-full-stack.sh` — automated VM smoke test
