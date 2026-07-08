# Concurrent 3-line PoC

Run validation pollers and REPL sessions for all configured lines on one Mac.

**Constraints**

- One APS connection per line — use `repl`, not separate `listen` + `send`.
- Safe validation only in automation — no lldb (`poc-validation-daemon` policy).
- Full 3-line test needs **3 Apple IDs** (lines 2–3 need their own `poc/lines/line-N.env`).

## 1. Start validation pollers (background, safe)

```bash
./scripts/poc-run-pollers.sh
# logs: poc/logs/line-N-poller.log
# pids: poc/run/line-N-poller.pid

./scripts/poc-run-pollers.sh --stop
```

Uses `validation-nacserv-poller` per line (nacserv fetch only). Manual lldb when stale:

```bash
./scripts/poc-refresh-validation.sh 1 --capture   # stop repl first
```

## 2. Open REPL panes (tmux)

```bash
./poc/concurrent-tmux.sh
```

Session name: `poc` (override with `KAPPY_POC_TMUX_SESSION`).

In each pane, send with real handles:

```
send tel:+18606050710 poc line 1 outbound
send mailto:henry@jabronicapital.com hello from line 1
```

## 3. Smoke test

```bash
./scripts/poc-smoke-test.sh
./scripts/poc-smoke-test.sh --line 1 --to tel:+18606050710
```

## Verify isolation

1. Send from line 1 → test recipient; confirm sender is line 1's Apple ID / handle.
2. Send from line 2 → same recipient; confirm different sender.
3. Inbound to each line should appear only in that line's repl pane.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/poc-run-pollers.sh` | Background safe pollers for all lines |
| `poc/concurrent-tmux.sh` | tmux layout with repl per line |
| `scripts/poc-smoke-test.sh` | Status/preflight + optional one-shot send |
