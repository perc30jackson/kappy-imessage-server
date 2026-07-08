# kappy-api REST reference

Base URL: `http://127.0.0.1:8080` (configurable in `poc/lines.toml`)

Auth: `Authorization: Bearer <token>` when `api.token` is set (not `change-me-in-production`).

CORS is enabled for browser portals.

## Quick start

```bash
cp poc/lines.toml.example poc/lines.toml
./scripts/kappy-app.sh    # API + web portal (opens browser)
# or API only:
./scripts/poc-api.sh
```

Web portal: `http://127.0.0.1:8080/` — forms for login, register, send, recover auth.

## Endpoints

### Health

```http
GET /health
```

```json
{
  "ok": true,
  "version": "0.1.0",
  "lines_online": 1,
  "lines_total": 3
}
```

### List lines

```http
GET /v1/lines
```

Returns array of line status objects:

| Field | Description |
|-------|-------------|
| `id` | `"1"`, `"2"`, `"3"` |
| `label` | Display name |
| `connection` | `online` \| `offline` \| `not_activated` |
| `handles` | Registered `mailto:` / `tel:` handles |
| `validation_seconds_remaining` | NAC blob TTL |
| `files` | Which state files exist |

### Line detail

```http
GET /v1/lines/{id}
```

### Inbound messages (poll for portal)

```http
GET /v1/lines/{id}/messages?limit=50
```

Returns recent inbound messages received while the API is running (ring buffer, max 500).

### Send message

```http
POST /v1/lines/{id}/messages
Content-Type: application/json

{
  "to": "+18606050710",
  "body": "hello from line 1"
}
```

`to` accepts email, phone, or `mailto:` / `tel:` URIs (normalized by spike).

### Doctor

```http
GET /v1/lines/{id}/doctor
```

### Lifecycle — activate (lines 2–3)

Requires `poc/shared/hw-export.bin` (see `poc-copy-hw-export.sh`).

```http
POST /v1/lines/2/lifecycle/activate
```

### Lifecycle — login

```http
POST /v1/lines/2/lifecycle/login
Content-Type: application/json

{
  "apple_id": "line2@example.com",
  "password": "...",
  "two_fa_code": "123456"
}
```

### Lifecycle — register

```http
POST /v1/lines/2/lifecycle/register
```

### Lifecycle — refresh validation

Uses nacserv from config, or falls back to `validation-pilot.json` at repo root.

```http
POST /v1/lines/1/lifecycle/refresh-validation
```

### Capture validation (lldb)

Runs `poc-refresh-validation.sh --capture`. May take several minutes; toggle iMessage in Messages when prompted.

```http
POST /v1/lines/1/lifecycle/capture-validation
```

### Recover auth (validation → login → register)

```http
POST /v1/lines/1/lifecycle/recover-auth
Content-Type: application/json

{
  "capture": false,
  "apple_id": "optional@example.com",
  "password": "optional",
  "two_fa_code": "123456"
}
```

Credentials fall back to `poc/lines/line-N.env` when omitted.

## Deploying lines 2 and 3

Prerequisites per line:

1. **Dedicated Apple ID** (not shared with line 1)
2. **Shared hw-export** — one Mac Hardware Info export for all lines
3. **Validation** — lldb capture or helper VM nacserv

```bash
# One-time shared export
./scripts/poc-copy-hw-export.sh /path/to/MacHardwareInfo-export.bin

# Per line
./scripts/poc-setup-line.sh 2
./scripts/poc-recover-auth.sh 2 --capture   # or lifecycle endpoints via API
```

## Architecture

```
┌─────────────────────────────────────────┐
│  Web portal (your app)                  │
│  fetch /v1/lines, POST /messages        │
└──────────────────┬──────────────────────┘
                   │ HTTP :8080
┌──────────────────▼──────────────────────┐
│  kappy-api (axum)                       │
│  ├─ LineWorker 1 → spike/state          │
│  ├─ LineWorker 2 → poc/lines/line-2/... │
│  └─ LineWorker 3 → poc/lines/line-3/... │
│     each: 1 APS conn, listen + send     │
└──────────────────┬──────────────────────┘
                   │ rustpush TLS
                   ▼
              Apple APS / IDS
```

One `kappy-api` process holds **one APS connection per line**. Do not run `poc-line.sh N repl` for the same line while the API is up.

## Portal polling pattern

Built-in UI at `/` — or poll from your own app:

```javascript
// List lines
const lines = await fetch('/v1/lines').then(r => r.json());

// Poll inbound every 2s
setInterval(async () => {
  for (const line of lines) {
    const msgs = await fetch(`/v1/lines/${line.id}/messages?limit=20`).then(r => r.json());
    // render msgs...
  }
}, 2000);
```
