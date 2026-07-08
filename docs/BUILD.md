# Build prerequisites

How to get `kappy-spike` compiling on macOS. Mined from agent transcripts — see [`superpowers/context/rustpush-build-and-runtime-context.md`](superpowers/context/rustpush-build-and-runtime-context.md).

For runtime validation, APS sessions, and IDS recovery after a successful build, see [`spike-runbook.md`](spike-runbook.md).

## Prerequisites

| Requirement | Why |
|-------------|-----|
| **Rust toolchain** | `kappy-spike` and vendored `rustpush` are Rust crates |
| **Xcode Command Line Tools** | Native deps (`apple-private-apis`, prost, etc.) need `clang` / SDK headers |
| **`./scripts/vendor-rustpush.sh`** | Clones/updates `vendor/rustpush`, submodules, FairPlay cert stubs, and `ActivationInfo` export patch |

```bash
# Install Xcode CLT (if needed)
xcode-select --install

# Vendor + patch rustpush
./scripts/vendor-rustpush.sh

# Build spike
cd spike && cargo build --release
```

Binary: `spike/target/release/kappy-spike`

### What `vendor-rustpush.sh` does

1. Clone or fast-forward `vendor/rustpush` from [OpenBubbles/rustpush](https://github.com/OpenBubbles/rustpush)
2. Clone submodules over HTTPS (`apple-private-apis`, `open-absinthe` stub) — upstream `.gitmodules` uses `git@` URLs that fail in many shells
3. **`setup_fairplay_certs`** — copy legacy stub certs into `certs/fairplay/` (see below)
4. **`ensure_rustpush_exports`** — add `pub use activation::ActivationInfo;` to vendored `lib.rs` so spike can implement `OSConfig`

Always re-run the vendor script after pulling a new `rustpush` revision.

## FairPlay certs (rustpush: 20 compile errors)

**Symptom:**

```
could not compile rustpush (lib) due to 20 previous errors
```

**Root cause:** `activation.rs` embeds FairPlay material at compile time via `include_bytes!` on `certs/fairplay/*`. Real keys are gitignored; a fresh clone has no files in that directory.

**Fix:** `vendor-rustpush.sh` mirrors rustpush CI — copies `certs/legacy-fairplay/fairplay.{crt,pem}` into 10 named pairs under `certs/fairplay/`:

| Named cert ID | Files created |
|---------------|---------------|
| `4056631661436364584235346952193` … `2201`, `2208` | `{id}.pem`, `{id}.crt` |

Stub certs are enough for **compile + Albert activation** in dev. Production FairPlay may need real keys.

## kappy-spike: 9 compile errors (API drift)

After rustpush builds, spike may still fail until spike code matches the vendored API. Known fixes from the PoC bring-up:

| Error | Fix |
|-------|-----|
| Private `activation::ActivationInfo` | `pub use activation::ActivationInfo` in vendored `lib.rs` (auto-patched by `vendor-rustpush.sh`) |
| Private `util::encode_hex` | Use `crate::util::encode_hex` in spike |
| Stray `#[serde(skip)]` on non-serde struct | Removed from `mac_config.rs` |
| `APSConnectionResource::new` type mismatch | Pass `Arc<dyn OSConfig>` via `config.clone()`, not `&dyn OSConfig` |
| `await` in sync `persist_push_state` | Made `async`; callers `.await` |
| `MessageInst` not `Debug` | Log `inst.id` + `inst.sender` |
| `HwInfo::decode` missing | `use prost::Message` in `hwinfo.rs` |
| `to_file_xml` on unsized `[IDSUser]` slice | Serialize `users.to_vec()` |

If you see new errors after re-vendoring, compare spike against upstream rustpush API changes before patching spike.

## Re-vendor checklist

Use this whenever you update `vendor/rustpush` or pull main:

- [ ] `./scripts/vendor-rustpush.sh` (FairPlay stubs + `ActivationInfo` export)
- [ ] `cd spike && cargo build --release`
- [ ] Fix any new kappy-spike API drift (table above)
- [ ] Re-run spike smoke test per [`spike-runbook.md`](spike-runbook.md)

## Related docs

- [`spike-runbook.md`](spike-runbook.md) — validation, login, register, listen/send
- [`poc/README.md`](../poc/README.md) — 3-line PoC on this Mac
- [`superpowers/context/rustpush-build-and-runtime-context.md`](superpowers/context/rustpush-build-and-runtime-context.md) — full build + runtime notes
