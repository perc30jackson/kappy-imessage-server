# 3-Line / 1-Mac PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run three independent iMessage lines on the PoC Mac (macOS 26.5.1) sharing one Mac Hardware Info export and one validation source.

**Architecture:** Three isolated `SpikeStateDir` trees under `poc/lines/line-{1,2,3}/state/`, one shared `hw-export.bin`, validation via helper VM `kappy-nacserv` or lldb capture on the PoC Mac. No Docker until line 1 send/receive works.

**Tech Stack:** `kappy-spike`, `kappy-nacserv`, Mac Hardware Info, optional UTM helper VM

---

## Build prerequisites

Before Tasks 2–5, ensure spike compiles on the PoC Mac. See [`docs/BUILD.md`](../../BUILD.md):

- Rust + Xcode Command Line Tools
- `./scripts/vendor-rustpush.sh` (FairPlay cert stubs + `ActivationInfo` export)
- `cd spike && cargo build --release`

Re-run `vendor-rustpush.sh` after any rustpush vendor update.

---

## File map

| File | Responsibility |
|------|----------------|
| `poc/README.md` | Operator runbook for this Mac |
| `poc/shared.env` | Shared nacserv URL, token, spike binary (gitignored) |
| `poc/lines/line-N.env` | Per-line Apple ID, state dir (gitignored) |
| `poc/shared/hw-export.bin` | Shared hardware activation blob (gitignored) |
| `scripts/poc-line.sh` | Wrapper: `poc-line.sh <line> <spike-subcommand> [args]` |
| `scripts/poc-init-line.sh` | Activate a new line from shared hw-export |
| `scripts/poc-copy-hw-export.sh` | Seed `poc/shared/hw-export.bin` from spike export |
| `spike/state/` | Line 1 legacy state (migrate or alias to line-1) |

---

### Task 1: PoC scaffolding

**Status:** Complete (2026-07-08).

**Files:**
- Create: `poc/README.md`, `poc/shared.env.example`, `poc/lines/line-1.env.example`, `poc/lines/line-2.env.example`, `poc/lines/line-3.env.example`
- Create: `scripts/poc-line.sh`, `scripts/poc-init-line.sh`
- Modify: `.gitignore` (poc secrets, state)

- [x] **Step 1:** Add `poc/shared.env.example` and line env examples
- [x] **Step 2:** Add `scripts/poc-line.sh` sourcing shared + line env
- [x] **Step 3:** Add `scripts/poc-init-line.sh` for activate on new lines
- [x] **Step 4:** Write `poc/README.md` runbook
- [x] **Step 5:** Add `poc/DECISIONS.md`, `poc-refresh-validation.sh`, `poc-status.sh`

---

### Task 2: Line 1 — complete send/receive

**Status (2026-07-08):** **Receive OK** in `repl`; **send blocked** on IDS **6005** (auth cert ≠ keystore signing keys). Recovery: `./scripts/poc-recover-auth.sh 1` (validation → login → register); preflight: `./scripts/poc-preflight.sh 1`; spike `doctor`.

**Prerequisite:** `spike/state` has hw_info, id.plist, validation.json (already present on PoC Mac).

- [ ] **Step 1:** Source env and refresh validation

```bash
source poc/shared.env   # after copying from .example
source poc/lines/line-1.env
./scripts/poc-line.sh 1 fetch-validation-nacserv
```

Fallback if VM down:

```bash
./scripts/physical-pilot-capture-and-register.sh
```

- [ ] **Step 2:** Register (if not already)

```bash
./scripts/poc-line.sh 1 register
```

- [ ] **Step 3:** Send test message

```bash
./scripts/poc-line.sh 1 send --to '+1XXXXXXXXXX' --body 'poc line 1'
```

- [ ] **Step 4:** Listen in separate terminal

```bash
./scripts/poc-line.sh 1 listen
```

- [ ] **Step 5:** Start validation poller in background

```bash
./scripts/poc-line.sh 1 validation-nacserv-poller --interval-secs 300
```

**Expected:** outbound blue bubble; inbound message logged in listen terminal.

---

### Task 3: Line 2 — second Apple ID

**Prerequisites:** Line 1 send/receive works; dedicated Apple ID for line 2 in `poc/lines/line-2.env`.

- [ ] **Step 1:** Seed shared hw-export (symlinks `spike/pilot-hw-export.bin` when present)

```bash
./scripts/poc-copy-hw-export.sh
# or Mac Hardware Info → poc/shared/hw-export.bin
```

- [ ] **Step 2:** Init line 2

```bash
cp poc/lines/line-2.env.example poc/lines/line-2.env
# edit: KAPPY_APPLE_ID, KAPPY_APPLE_PASSWORD
./scripts/poc-init-line.sh 2
```

- [ ] **Step 3:** Login, validation, register

```bash
./scripts/poc-line.sh 2 login
./scripts/poc-line.sh 2 fetch-validation-nacserv
./scripts/poc-line.sh 2 register
```

- [ ] **Step 4:** Send + listen smoke test

---

### Task 4: Line 3 — repeat Task 3

Same steps as Task 3 with `line-3`.

---

### Task 5: Concurrent operation

- [ ] **Step 1:** Start safe validation pollers (lines 1–3)

```bash
./scripts/poc-run-pollers.sh
# logs: poc/logs/line-N-poller.log — stop with --stop
```

- [ ] **Step 2:** REPL per line (one APS conn each — not separate listen + send)

```bash
./poc/concurrent-tmux.sh
# or: ./scripts/poc-line.sh N repl  (one terminal per line)
```

- [ ] **Step 3:** Smoke test + send from each line; verify isolation

```bash
./scripts/poc-smoke-test.sh --line 1 --to tel:+18606050710
# send from each repl pane; see poc/CONCURRENT.md
```

**Expected:** Each line uses same hw serial in config but distinct APS sessions and Apple IDs.

---

### Task 6 (deferred): Docker + REST

After Task 5 passes:

- [ ] Daemonize spike as `kappy-worker` per line in `docker-compose.poc.yml`
- [ ] Thin REST wrapper (`POST /v1/lines/{id}/messages`)

---

## Self-review

| Spec requirement | Task |
|------------------|------|
| 3 lines / 1 Mac | Tasks 1–5 |
| Shared hw export | Task 1, 3 |
| macOS 26 validation | Task 2 fallback paths |
| Per-line state | Tasks 2–4 |
| Docker deferred | Task 6 |
