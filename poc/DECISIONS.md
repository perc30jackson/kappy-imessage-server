# PoC Decisions (2026-07-08)

Decisions made for the 3-line / 1-Mac PoC on **this machine** (macOS 26.5.1, arm64).

## Infrastructure

| Decision | Choice | Rationale |
|----------|--------|-----------|
| PoC Mac | This workstation | User directive; spike state already here |
| Helper VM | Optional fallback | `192.168.64.2` / `.3` currently down; probe at refresh time |
| Validation (primary) | **lldb NAC capture** on PoC Mac | macOS 26 PAC blocks local provider; lldb capture proven (`validation-pilot.json`) |
| Validation (fallback) | Helper VM `kappy-nacserv` | Use when VM is reachable — **only fully automated path** |
| Validation automation | `poc-validation-daemon.sh --loop` (safe) | nacserv + inject only; **never lldb in loop** — lldb pauses identityservicesd and signs out Messages |
| Lines 2–3 | Ready via `poc-setup-line.sh` + REST lifecycle | Needs 2 more Apple IDs + hw-export |
| Docker | Deferred | `kappy-api` runs natively on PoC Mac |
| REST API | **`kappy-api` on :8080** | See `docs/API.md`; portal polls `/v1/lines` |
| Telnyx / eSIM | Deferred | Use existing Apple ID handles for line 1 |
| Oasis broker service | Deferred | Direct validation inject for PoC; broker at R2 |

## Identity (3 lines / 1 Mac)

| Decision | Choice |
|----------|--------|
| Hardware export | **One** `poc/shared/hw-export.bin` for all lines |
| Line 1 state | Keep `spike/state` (already activated + registered) |
| Lines 2–3 state | `poc/lines/line-{2,3}/state/` after line 1 works |
| Apple IDs | One dedicated ID per line (line 1: `henry@jabronicapital.com`) |

## Line 1 registered handles

- `mailto:henry@jabronicapital.com`
- `tel:+16462660558`

Send/recipient tests must use **real addresses**, not placeholders like `+1XXXXXXXXXX`.

## Validation refresh workflow

```bash
./scripts/poc-refresh-validation.sh 1        # probe nacserv → inject or capture
./scripts/poc-refresh-validation.sh 1 --capture  # force lldb capture (toggle iMessage once)
./scripts/poc-line.sh 1 register             # only if register fails or handles change
./scripts/poc-line.sh 1 send --to 'recipient@example.com' --body 'ping'
```

**Do not** run `refresh-login` unless docs say so after GUI import (`6005`). It can fail with `ICLOUD_UNSUPPORTED_DEVICE` on this hardware profile.

## Known errors

| Error | Meaning | Action |
|-------|---------|--------|
| `Resource has been closed` | Stale APS session / expired validation | `poc-refresh-validation.sh` then retry send |
| `6005` on register | Auth cert mismatch (often after GUI import) | `login` not `refresh-login`; or re-capture + register |
| `tel:+1XXXXXXXXXX no longer exists` | Placeholder recipient | Use real email or phone |
| `ICLOUD_UNSUPPORTED_DEVICE` on refresh-login | Apple rejects device for new iCloud delegate | Skip refresh-login; use capture + register |
