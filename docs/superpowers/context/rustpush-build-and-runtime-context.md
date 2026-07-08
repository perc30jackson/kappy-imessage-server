# Rustpush build + runtime context (mined from agent transcripts)

**Sources:** [Rustpush compilation errors](2c79ee1a-9b07-4938-8cb3-7dcb27e30c0a), [3-line PoC session](d1689bff-7ce5-42c5-b6b7-6a012cace64a)

## Build pipeline (must work before PoC)

```bash
./scripts/vendor-rustpush.sh   # FairPlay stubs + ActivationInfo export patch
cd spike && cargo build --release
```

### rustpush: 20 compile errors → FairPlay certs

| Symptom | Root cause | Fix |
|---------|------------|-----|
| `could not compile rustpush (lib) due to 20 previous errors` | `activation.rs` uses `include_bytes!` on `certs/fairplay/*`; real keys are gitignored | `vendor-rustpush.sh` copies `certs/legacy-fairplay/fairplay.{crt,pem}` → 10 named pairs in `certs/fairplay/` (mirrors rustpush CI) |

Stub certs are sufficient for **compile + Albert activation** in dev; production FairPlay may need real keys.

### kappy-spike: 9 compile errors → API drift from vendored rustpush

| Error | Fix |
|-------|-----|
| Private `activation::ActivationInfo` | `pub use activation::ActivationInfo` in vendored `lib.rs`; auto-patched by `vendor-rustpush.sh` |
| Private `util::encode_hex` | Use `crate::util::encode_hex` in spike |
| Stray `#[serde(skip)]` on non-serde struct | Removed from `mac_config.rs` |
| `APSConnectionResource::new` type mismatch | Pass `Arc<dyn OSConfig>` via `config.clone()`, not `&dyn OSConfig` |
| `await` in sync `persist_push_state` | Made `async`; callers `.await` |
| `MessageInst` not `Debug` | Log `inst.id` + `inst.sender` |
| `HwInfo::decode` missing | `use prost::Message` in `hwinfo.rs` |
| `to_file_xml` on unsized `[IDSUser]` slice | Serialize `users.to_vec()` |

**After re-vendoring rustpush:** always re-run `./scripts/vendor-rustpush.sh` (re-applies FairPlay + export patch).

## Runtime constraints (PoC)

### One APS connection per line

`listen` and `send` in **separate processes** → `Resource has been closed!`. Use:

```bash
./scripts/poc-line.sh 1 repl   # single task: inbound + stdin send
```

### Validation (~15 min TTL)

| Method | Safe for Messages? | When |
|--------|-------------------|------|
| Helper VM nacserv + poller | Yes | VM reachable at `192.168.64.2`/`.3` |
| `poc-validation-daemon.sh --loop` | Yes | nacserv or inject pilot json only |
| lldb capture (`--capture`) | **No** — pauses identityservicesd | Manual when stale; stop repl first |

macOS 26: local NAC provider blocked by PAC; lldb capture or helper VM nacserv.

### IDS registration errors

| Code | Meaning | Recovery |
|------|---------|----------|
| **6005** Bad auth cert | `id.plist` auth cert ≠ `keystore.plist` signing keys (GUI/`import-ids-export`) | `login` (not `refresh-login`) → fresh validation → `register` |
| **6004** | Request gate rejection (hw/validation mismatch, stale NAC) | Align validation source with `hw_info`; refresh validation |
| `ICLOUD_UNSUPPORTED_DEVICE` | `refresh-login` rejected on this hw profile | Skip refresh-login; use `login` + capture |

**Inbound can work while outbound fails:** receive uses cached madrid keys; send calls `ensure_ready()` → register → 6005 closes identity resource.

### Line 1 current state (2026-07-08)

- **Receive:** working in `repl`
- **Send:** blocked on `6005` until `login` + `register` recovery
- **Handles:** `mailto:henry@jabronicapital.com`, `tel:+16462660558`
- **State:** `spike/state/` (line 1 legacy path)

## PoC plan status

| Task | Status |
|------|--------|
| 1 Scaffolding | Done |
| 2 Line 1 send+receive | Receive OK; send blocked on 6005 |
| 3–4 Lines 2–3 | Deferred until line 1 outbound works |
| 5 Concurrent 3 lines | Not started |
| 6 Docker + REST | Deferred |

## Related files

- `scripts/vendor-rustpush.sh` — build prerequisites
- `poc/DECISIONS.md` — locked PoC choices
- `docs/superpowers/plans/2026-07-08-poc-3-line-mac-plan.md` — implementation plan
- `docs/utm-macos15-fresh-vm.md` — helper VM + 6005 row
- `spike/src/engine.rs` — `listen_repl`, `wait_identity_ready`
