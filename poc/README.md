# 3-Line / 1-Mac PoC Runbook

**PoC Mac:** this machine (macOS 26.5.1). See [`DECISIONS.md`](DECISIONS.md) for locked-in choices.

## Quick setup

```bash
cd kappy-imessage-server
chmod +x scripts/poc-*.sh

cp poc/shared.env.example poc/shared.env   # if needed
cp poc/lines/line-1.env.example poc/lines/line-1.env

./scripts/poc-status.sh 1
```

## Validation (macOS 26)

**Primary:** lldb NAC capture on this Mac (`validation-pilot.json`).

```bash
# Refresh (auto: nacserv if up, else inject fresh pilot json)
./scripts/poc-refresh-validation.sh 1

# Force new capture — toggle iMessage OFF→ON in Messages when prompted
./scripts/poc-refresh-validation.sh 1 --capture
```

### Automated refresh (safe vs manual)

| Method | Safe for Messages? | Command |
|--------|-------------------|---------|
| **Helper VM nacserv + poller** | Yes | `./scripts/poc-line.sh 1 validation-nacserv-poller --interval-secs 300` |
| **Safe daemon** | Yes | `./scripts/poc-validation-daemon.sh --loop` (nacserv / inject only) |
| **lldb capture** | **No** — pauses identityservicesd, can sign you out | `./scripts/poc-refresh-validation.sh 1 --capture` (manual only) |

**Do not** use `--auto-toggle` — it was removed; toggling iMessage OFF signs you out.

```bash
# Safe background poller (no lldb):
./scripts/poc-validation-daemon.sh --loop

# Manual capture only when stale (stop listen/send first):
./scripts/poc-refresh-validation.sh 1 --capture
```

**Fallback:** helper VM `kappy-nacserv` at `192.168.64.2` or `.3` when reachable.

## Line 1 (uses `spike/state`)

Registered handles: `henry@jabronicapital.com`, `+16462660558`.

```bash
./scripts/poc-refresh-validation.sh 1 --capture   # if validation stale
./scripts/poc-line.sh 1 repl
# type: send +18606050710 poc line 1 outbound
```

**Note:** `listen` and `send` cannot run in separate terminals — only one APS connection per line.
Use `repl` for both, or stop listen before a one-shot send.

**Do not** use placeholder numbers like `+1XXXXXXXXXX`.

**Avoid** `refresh-login` unless fixing `6005` after GUI import — can trigger `ICLOUD_UNSUPPORTED_DEVICE`.

Background poller (when helper VM nacserv is up):

```bash
./scripts/poc-line.sh 1 validation-nacserv-poller --interval-secs 300
```

## REST API (portal backend)

```bash
cp poc/lines.toml.example poc/lines.toml
./scripts/poc-api.sh
# → http://127.0.0.1:8080
```

See [`docs/API.md`](../docs/API.md) for endpoints. **Do not** run `repl` for a line while `kappy-api` holds its APS connection.

## Lines 2 and 3 (after line 1 works)

```bash
./scripts/poc-copy-hw-export.sh          # symlink from spike/pilot-hw-export.bin if present
./scripts/poc-setup-line.sh 2
./scripts/poc-recover-auth.sh 2 --capture
```

## Scripts

| Script | Purpose |
|--------|---------|
| `poc-line.sh <N> <cmd>` | Run spike for line N |
| `poc-status.sh [N]` | State + validation + nacserv health |
| `poc-preflight.sh <N>` | Pre-repl checks (files, validation expiry, `doctor`) |
| `poc-recover-auth.sh <N>` | Full auth recovery: validation → login → register |
| `poc-refresh-validation.sh <N>` | Refresh validation (nacserv → pilot → capture) |
| `poc-capture-validation-only.sh` | lldb capture only |
| `poc-init-line.sh <2\|3>` | Activate new line from shared hw-export |
| `poc-copy-hw-export.sh` | Symlink/copy hw-export → `poc/shared/hw-export.bin` |
| `poc-setup-line.sh <2\|3>` | Env + hw-export + init checklist |
| `poc-api.sh` | Start REST API (`docs/API.md`) |
| `poc-run-pollers.sh` | Background validation pollers (see `poc/CONCURRENT.md`) |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Resource has been closed` | `./scripts/poc-recover-auth.sh N` then `./scripts/poc-line.sh N repl` |
| `6005` on register / send | `./scripts/poc-recover-auth.sh N` (login, not `refresh-login`) |
| Before repl/send | `./scripts/poc-preflight.sh N` |
| Validation stale (< 2 min) | `./scripts/poc-refresh-validation.sh N` |
| Placeholder tel error | Use real recipient address |
| nacserv unreachable | `poc-recover-auth.sh N --capture` or manual `--capture` |

**Auth recovery path** (6005 / closed identity resource):

```bash
./scripts/poc-recover-auth.sh 1              # uses poc/lines/line-1.env
./scripts/poc-recover-auth.sh 1 --capture    # allow lldb if validation stale
./scripts/poc-line.sh 1 repl
```

Credentials live in `poc/lines/line-N.env` (gitignored). No manual `export` needed.

**Do not** use `refresh-login` for 6005 — it can fail with `ICLOUD_UNSUPPORTED_DEVICE`.

## Next steps

Plan: [`docs/superpowers/plans/2026-07-08-poc-3-line-mac-plan.md`](../docs/superpowers/plans/2026-07-08-poc-3-line-mac-plan.md)

REST API: [`docs/API.md`](../docs/API.md). Concurrent CLI ops: [`poc/CONCURRENT.md`](CONCURRENT.md).
