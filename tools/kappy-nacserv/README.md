# kappy-nacserv

Miniature NAC validation HTTP server for the kappy fleet. Wraps `kappy-nac-validation-provider -once` or `mac-registration-provider -once` behind a cached HTTP API.

Run on a **helper Mac** with working local NAC (macOS ≤14.3 with `mac-registration-provider`, or any Mac once local generation works). Pilot Macs on macOS 26 poll this service instead of generating validation locally.

## Build

```bash
cargo build --release --manifest-path tools/kappy-nacserv/Cargo.toml
```

Binary: `tools/kappy-nacserv/target/release/kappy-nacserv`

## Run

```bash
# Build NAC provider first (or install mac-registration-provider on PATH)
make -C tools/nac-validation-provider

export KAPPY_NAC_PROVIDER=$PWD/tools/nac-validation-provider/kappy-nac-validation-provider
./scripts/run-kappy-nacserv.sh
```

On first run, a bearer token is generated at `~/.config/kappy-nacserv/token`.

## API

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/health` | GET | no | Liveness |
| `/` | GET | Bearer | Beeper direct [nacserv](https://github.com/beeper/imessage/blob/main/imessage/direct/nacserv/client.go) |
| `/validation-data` | POST | Bearer | [jasonlaguidice/imessage](https://github.com/jasonlaguidice/imessage) relay style (base64 body) |
| `/api/v1/bridge/get-validation-data` | POST | Bearer | Beeper registration-relay compatible |
| `/api/v1/bridge/get-version-info` | POST | Bearer | Host version metadata |
| `/internal/validation` | POST | Bearer | kappy spike ingest (same shape as `validation-server`) |

Validation blobs are cached for ~15 minutes (refreshed 60s before expiry by default).

## Spike client

On the pilot Mac:

```bash
export KAPPY_NACSERV_URL=http://HELPER_IP:8788
export KAPPY_NACSERV_TOKEN='<token from helper ~/.config/kappy-nacserv/token>'

./target/release/kappy-spike fetch-validation-nacserv
# or ongoing:
./scripts/run-validation-nacserv-poller.sh
```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPPY_NACSERV_LISTEN` | `127.0.0.1:8788` | Bind address |
| `KAPPY_NACSERV_TOKEN` | auto-generated | Bearer token |
| `KAPPY_NAC_PROVIDER` | `../nac-validation-provider/...` | Provider binary for `-once` |

## macOS 26 note

Local generation via `kappy-nac-validation-provider` is still blocked by PAC on macOS 26. Run **kappy-nacserv on a helper Mac** (≤14.3) with `mac-registration-provider` as the provider.
