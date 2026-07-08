# Virtual Android iMessage Fleet — Design Spec

**Date:** 2026-07-07  
**Status:** Approved — PoC in progress on physical Mac (macOS 26.5.1)  
**Repo:** `kappy-imessage-server`

## Summary

Design for a **fully virtual, cloud-oriented** fleet of iMessage lines. Each line is a programmatic endpoint reachable via **REST** and **Photon `photon.imessage.v1` gRPC**. Lines run as **Docker-based virtual Android workers** with **webhook eSIM numbers** (no cellular radio). **NAC validation** is brokered through an **Oasis-style service** that routes to a pool of **physical Mac hardware** running `kappy-nacserv` (POC), later cloud Mac slots (production).

### Decisions locked in

| Decision | Choice |
|----------|--------|
| Device model | Fully virtual — Docker, no physical Android phones |
| Validation | Oasis broker → dedicated Mac slot per line (OpenBubbles Hosted pattern) |
| POC infrastructure | Docker Compose + physical Mac Minis on LAN |
| Virtualization | Redroid (Android-in-Docker); Linux rustpush sidecar for R0/R1 |
| eSIM / telephony | Telnyx API — programmatic numbers, SMS via webhook |
| Public API | Photon gRPC primary, REST gateway for HTTP clients |
| State model | Reuse spike `SpikeStateDir` layout per line |

---

## 1. System overview

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Control Plane (Photon gRPC + REST)          │
│  FleetService · IMessageService · orchestration          │
└────────────┬──────────────────────────────┬─────────────┘
             │                              │
    ┌────────▼────────┐          ┌─────────▼──────────┐
    │  Line Worker       │   ...    │  Oasis Broker        │
    │  (Docker/Redroid)  │          │  validation router   │
    └────────┬──────────┘          └─────────┬──────────┘
             │                              │
             │                    ┌─────────▼──────────┐
             │                    │  Mac Slot Pool       │
             │                    │  kappy-nacserv       │
             │                    │  (physical Mac POC)  │
             │                    └──────────────────────┘
    ┌────────▼──────────┐
    │  Telephony Service │
    │  Telnyx eSIM API   │
    └────────────────────┘
```

### Core principle

Each **line** maps 1:1 to:

| Resource | Role |
|----------|------|
| **Virtual Android worker** (Docker pod) | Headless `rustpush` daemon; APS session, message keys, line state |
| **Dedicated Mac slot** | NAC validation via `kappy-nacserv`; invisible to API consumers |
| **eSIM phone number** | Apple ID 2FA; optional SMS bridging (v2) |

Lines never contact Mac slots directly. They call **Oasis**, which routes validation to the slot bound to that line.

### Three runtime services

1. **Fleet Control Plane** — line CRUD, messaging API, health, Docker orchestration
2. **Oasis Broker** — slot pool, 1:1 line↔slot binding, validation routing, 15-min cache
3. **Line Worker** — one container set per active line: Redroid + `kappy-worker` sidecar

### Hard constraints (from spike + OpenBubbles)

1. **NAC validation requires genuine Apple hardware** — blobs expire every ~15 min.
2. **Identity coherence** — hw identity, Apple ID login, anisette, and validation must align per line or Apple returns `-80035` / `-80009`.
3. **APS requires persistent background process** — worker must stay alive with TLS socket open.
4. **eSIM on virtual Android** — no radio; numbers are API-provisioned with SMS via webhook.
5. **Phone numbers** — Apple ID 2FA and iMessage registration need SMS reachability.

---

## 2. Oasis broker

Oasis sits between line workers and the Mac slot pool.

### Slot lifecycle

```
Free → Bound → Active → Renewing → Active
                    ↓ Degraded → Rebinding → Bound
                    ↓ DeleteLine → Free
```

Each Mac slot runs:

| Component | Role |
|-----------|------|
| `kappy-nacserv` | Cached NAC HTTP API (existing binary) |
| `kappy-nac-validation-provider` or `mac-registration-provider` | Local NAC generation |
| Slot agent (POC: manual registration) | Health heartbeat, bind/unbind |

### Validation protocol

Line workers call Oasis (not `kappy-nacserv` directly):

```
POST /oasis/v1/lines/{line_id}/validation
Authorization: Bearer <fleet-token>

→ 200 { "validation_data": "<base64>", "expires_at": "..." }
```

Oasis internally:

1. Looks up `line_id → slot_id`
2. Checks Redis cache (TTL ~14 min; refresh 60s before expiry)
3. On miss, calls slot's `kappy-nacserv`:
   ```
   POST http://{slot_ip}:8788/api/v1/bridge/get-validation-data
   Authorization: Bearer {slot_token}
   ```
4. Caches and returns blob

Reuses spike `fetch-validation-nacserv` / `nacserv_refresh_loop` client logic.

### Allocation rules

| Rule | Detail |
|------|--------|
| 1:1 binding | One Mac slot per active line for the line's lifetime |
| Sticky binding | Slot only changes on unrecoverable failure |
| No cross-line sharing | Line A never gets validation from slot B |
| Pre-warm buffer | Maintain N free slots (production); POC: manual slot list |

### Oasis components

```
oasis/
  allocator/     # slot pool, bind/unbind
  router/        # line_id → slot_id, validation proxy
  cache/         # Redis: validation blobs
  registry/      # Postgres: lines, slots, bindings, health
  provisioner/   # EC2 Mac (production only; POC uses slots.json)
```

### Health and failover

| Failure | Response |
|---------|----------|
| Slot down | Degrade → allocate replacement → Rebinding |
| NAC provider fails | Retry 3x → degrade slot |
| Line active during rebind | Worker gets 503; re-register after new slot binds |
| Pool exhausted | `CreateLine` returns `RESOURCE_EXHAUSTED` |

Rebinding may require re-running activate/login/register. Accepted for v1.

### Security

| Actor | Can see |
|-------|---------|
| API client | `line_id`, messaging API, line status |
| Line worker | Oasis validation endpoint only |
| Oasis | Slot IPs, nacserv tokens, bindings |
| Mac slot | nacserv traffic from Oasis only |

### POC slot registration

Physical Macs registered via `poc/slots.json`:

```json
[
  {
    "slot_id": "mac-mini-1",
    "nacserv_url": "http://192.168.1.50:8788",
    "nacserv_token": "<from ~/.config/kappy-nacserv/token>",
    "status": "free"
  }
]
```

---

## 3. Virtual Android line worker

### Pod layout (Docker Compose POC)

| Container | Image | Responsibility |
|-----------|-------|----------------|
| `redroid` | `redroid/redroid:13.0.0-latest` | Android userspace; anisette/SMS hooks if needed |
| `kappy-worker` | Custom Rust (extends spike) | `rustpush`, Oasis poller, internal gRPC, state PVC |

The **sidecar is source of truth** for messaging. Redroid provides Android environment when needed.

### Per-line state (reuses spike layout)

```
/state/
  hw_info.plist
  id.plist
  gsa.plist
  validation.json
  anisette/
  keystore.plist
  line.meta.json
```

### Worker lifecycle

1. Control plane provisions Docker worker + PVC
2. `activate` — generate hardware identity
3. `login` — Apple ID + 2FA via telephony SMS webhook
4. Fetch validation from Oasis → `register` (MADRID_SERVICE)
5. Persistent APS loop + validation poller (~14 min)
6. On delete: IDS deregister → disconnect APS → unbind slot

### rustpush on Android — phased approach

| Phase | Approach |
|-------|----------|
| **R0/R1 (POC)** | `kappy-worker` on **Linux** with `SpikeAndroidConfig`; Redroid for anisette if needed |
| **v1 production** | Cross-compile for Android aarch64, run inside Redroid (Option 3b) |

R0 proves end-to-end before investing in Android-native build.

### Validation poller

Background task mirroring `spike/src/validation.rs` `nacserv_refresh_loop`, calling Oasis instead of raw nacserv.

### APS persistence

- Worker process must not exit on active lines
- Restart restores from PVC via `connect_aps()` (spike `engine.rs`)
- Graceful shutdown deregisters IDS before teardown

### Internal gRPC (worker-local)

```
LineWorkerService
  GetHealth()
  SendMessage(to, body)
  SubscribeMessages() → stream
  GetState()
```

Only fleet control plane calls workers.

### Resource estimate (per line)

| Resource | Estimate |
|----------|----------|
| CPU | 0.5–1 core |
| Memory | 1–2 GiB |
| PVC | 256 MiB |

---

## 4. eSIM and telephony

Virtual workers have no cellular radio. Numbers come from **Telnyx** (or Gigs) via API; SMS delivered by webhook.

### Number lifecycle

Bound 1:1 to line:

| Event | Action |
|-------|--------|
| `CreateLine` | Order eSIM profile, assign e164, store in registry |
| `Login` | Route inbound SMS to worker; auto-extract 2FA code |
| `DeleteLine` | Release number / destroy profile |

eSIM profile is **not installed on Redroid** — number exists at carrier; SMS via API.

### SMS webhook

```
POST /telephony/v1/webhooks/telnyx
```

Routes `to` (e164) → `line_id`. During `LOGGING_IN`, forwards to worker 2FA handler. Regex extracts 6-digit Apple code. Timeout 120s → `LOGIN_FAILED`.

### Number registry

```sql
CREATE TABLE phone_numbers (
    line_id         UUID PRIMARY KEY,
    e164            TEXT NOT NULL UNIQUE,
    telnyx_sim_id   TEXT NOT NULL,
    status          TEXT NOT NULL,
    provisioned_at  TIMESTAMPTZ NOT NULL,
    released_at     TIMESTAMPTZ
);
```

### Apple ID strategy (v1)

- Dedicated Apple ID per line (pre-seeded pool)
- Password in secrets manager
- Trusted phone = Telnyx e164
- Automated Apple ID signup out of scope for v1

### Out of scope v1

- Real eSIM install on Redroid
- MMS, voice, FaceTime
- SMS forwarding to external endpoints
- Multi-number per line

---

## 5. Fleet control plane API

### POC topology

Docker Compose on one host; 1–2 physical Mac Minis on LAN for nacserv slots.

### Service boundaries

| Service | Visibility |
|---------|------------|
| `photon.imessage.v1.IMessageService` | Public |
| `kappy.fleet.v1.FleetService` | Public |
| `kappy.oasis.v1.OasisService` | Internal (workers) |
| `kappy.telephony.v1.TelephonyService` | Internal (fleet) |

REST gateway mirrors gRPC.

### FleetService

```protobuf
service FleetService {
  rpc CreateLine(CreateLineRequest) returns (Line);
  rpc GetLine(GetLineRequest) returns (Line);
  rpc ListLines(ListLinesRequest) returns (ListLinesResponse);
  rpc DeleteLine(DeleteLineRequest) returns (DeleteLineResponse);
  rpc RetryLogin(RetryLoginRequest) returns (Line);
}

enum LineStatus {
  PROVISIONING = 1;
  LOGGING_IN = 2;
  REGISTERING = 3;
  ACTIVE = 4;
  DEGRADED = 5;
  LOGIN_FAILED = 6;
  DELETING = 7;
}
```

**CreateLine orchestration:**

1. Oasis: bind Mac slot
2. Telephony: provision Telnyx number
3. `docker compose` up line worker
4. Worker: activate → login → register (async)
5. Return `PROVISIONING`; client polls `GetLine`

### IMessageService

```protobuf
service IMessageService {
  rpc SendMessage(SendMessageRequest) returns (SendMessageResponse);
  rpc SubscribeMessages(SubscribeMessagesRequest) returns (stream MessageEvent);
}
```

Fleet proxies to worker `LineWorkerService`.

### REST mapping (POC)

| REST | gRPC |
|------|------|
| `POST /v1/lines` | `CreateLine` |
| `GET /v1/lines/{id}` | `GetLine` |
| `DELETE /v1/lines/{id}` | `DeleteLine` |
| `POST /v1/lines/{id}/messages` | `SendMessage` |
| `GET /v1/lines/{id}/messages/stream` | `SubscribeMessages` (SSE) |

Auth: `Authorization: Bearer <fleet-api-key>`.

### Event bus (POC: Redis pub/sub)

| Event | Publisher |
|-------|-----------|
| `line.status_changed` | Fleet |
| `message.received` | Worker → Fleet |
| `sms.received` | Telephony |
| `slot.degraded` | Oasis |

### DeleteLine cleanup

1. IDS deregister
2. APS disconnect
3. Oasis unbind slot
4. Telephony release number
5. Remove Docker worker + PVC

---

## 6. Phased rollout

| Phase | Scope | Infrastructure | Success criteria |
|-------|-------|----------------|------------------|
| **R0** | Single line, manual | spike + 1 Redroid container + physical Mac nacserv | Send + receive 1 iMessage |
| **R1 POC** | 2–3 lines, API | `docker compose` + physical Mac slots + Telnyx | `POST /v1/lines` → ACTIVE → REST send/receive |
| **R2** | Oasis extracted | Oasis service + slot registry + cache | Lines don't know Mac IPs |
| **R3** | Photon gRPC | `tonic` server | Kappy `photon_grpc` integration |
| **R4** | Scale | K8s + cloud Mac slots | Autoscaling, >10 lines |

### R1 POC build order

1. `kappy-worker` — daemonized spike in Docker (Linux sidecar + Redroid)
2. `oasis` — thin proxy to physical Mac `kappy-nacserv` (`slots.json`)
3. `fleet` — CreateLine / GetLine / SendMessage / SSE
4. `telephony` — Telnyx provision + SMS webhook (manual number OK for first line)
5. `docker-compose.poc.yml`

### POC deferrals

- K8s / Nomad
- EC2 Mac provisioner
- Android-native worker (3b)
- Automated Apple ID creation
- MMS / attachments

### Cost drivers (planning)

| Item | ~$/month/line |
|------|----------------|
| Telnyx number | $1–3 |
| EC2 Mac slot (production) | $50–80 |
| Docker worker compute | $5–15 |

Mac slots dominate unit economics.

---

## 7. Risks and mitigations

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Apple blocks Linux/Android spoofed identity | Medium | R0 spike first; fallback to Android-native worker (3b) |
| Redroid APS reliability | Medium | Benchmark in R0; tune resources |
| Mac slot rebind forces re-register | High (known) | 1:1 sticky slots; minimize rebinds |
| Apple ID pool exhaustion | Medium | Pre-seed pool; monitor signup limits |
| Ghost IDS registrations on crash | Medium | Deregister on DeleteLine; imessage-cleanup patterns |
| Telnyx SMS delivery delay for 2FA | Low | 120s timeout + RetryLogin RPC |

---

## 8. Relationship to existing repo

| Existing | Reuse in fleet |
|----------|----------------|
| `spike/` engine, state, validation, login | Core of `kappy-worker` |
| `kappy-nacserv` | Mac slot validation endpoint |
| `kappy-nac-validation-provider` | NAC backend on Mac slots |
| UTM VM scripts | Not used in POC (physical Mac instead) |
| Photon gRPC | Greenfield in `fleet/` (R3) |

---

## Appendix: docker-compose POC sketch

```yaml
services:
  postgres:
    image: postgres:16
  redis:
    image: redis:7
  oasis:
    build: ./oasis
    volumes:
      - ./poc/slots.json:/config/slots.json
  telephony:
    build: ./telephony
  fleet:
    build: ./fleet
    ports: ["50051:50051", "8080:8080"]
    depends_on: [postgres, redis, oasis, telephony]
```

Line workers spawned dynamically by fleet orchestrator via compose overrides.

---

## 9. Immediate PoC: 3 lines / 1 Mac (this machine)

**PoC Mac:** developer workstation, macOS 26.5.1, arm64. Serves as pilot host and (when helper VM is up) validation consumer. Does **not** need 3 physical Macs.

### Topology

```
PoC Mac (this machine, macOS 26.5.1)
  ├── spike × 3 state dirs (line-1 … line-3)
  ├── shared Mac Hardware Info export (one hw-export.bin)
  └── validation path (pick one):
        A) Helper VM kappy-nacserv (192.168.64.x:8788) — preferred when VM up
        B) lldb NAC capture on PoC Mac (physical-pilot-capture-and-register.sh)
        C) Beeper registration relay

Optional later: docker-compose.poc.yml wrapping 3 kappy-worker containers.
```

### Sharing rules (1 Mac, 3 lines)

| Shared | Per line |
|--------|----------|
| `poc/shared/hw-export.bin` | `poc/lines/line-N/state/` |
| `KAPPY_NACSERV_URL` + token | Apple ID + password |
| One validation poller endpoint | Phone number (2FA) |
| | Own APS push token (created at activate) |

OpenBubbles documents up to ~20 activations per Mac hardware export. Three lines is well within limits.

### PoC file layout

```
poc/
  README.md                 # operational runbook
  shared.env.example        # nacserv URL, spike binary path
  lines/
    line-1.env.example      # KAPPY_APPLE_ID, state dir
    line-2.env.example
    line-3.env.example
  shared/
    hw-export.bin           # copy once from Mac Hardware Info app
scripts/
  poc-line.sh               # run spike subcommands for line N
```

### Success criteria (R1 PoC)

1. Line 1: send + receive iMessage via `kappy-spike` (existing `spike/state` or `poc/lines/line-1/state`)
2. Line 2: activate with same hw-export → login → register → send
3. Line 3: same as line 2
4. Three concurrent `listen` processes on different state dirs
5. Validation poller per line (or one poller script per terminal)

### macOS 26 note

Local `kappy-nac-validation-provider -once` is blocked by PAC on macOS 26. PoC Mac uses helper VM nacserv or lldb capture — not local provider on the pilot.
