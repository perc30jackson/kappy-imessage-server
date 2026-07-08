# kappy-imessage-server

Self-hosted **Photon `photon.imessage.v1` gRPC server** on [OpenBubbles rustpush](https://github.com/OpenBubbles/rustpush) for Kappy fleet `photon_grpc` lines.

## Status

| Phase | Description |
|-------|-------------|
| **U0 spike** (`spike/`) | R1 feasibility — headless rustpush send/receive on macOS |
| U1+ | Full gRPC server (see `linkedin_connector` plan) |

**Planning docs** (sibling repo):

- `linkedin_connector/docs/brainstorms/2026-07-07-rustpush-grpc-server-requirements.md`
- `linkedin_connector/docs/plans/2026-07-07-001-feat-rustpush-grpc-server-plan.md`

## Quick start (U0 spike — macOS only)

**Build:** [`docs/BUILD.md`](docs/BUILD.md) (Rust, Xcode CLT, `vendor-rustpush.sh`, FairPlay stubs).

```bash
./scripts/vendor-rustpush.sh
cd spike && cargo build --release
```

**Run:** [`docs/spike-runbook.md`](docs/spike-runbook.md)

**3-line PoC + REST API:** [`poc/README.md`](poc/README.md), [`docs/API.md`](docs/API.md)

```bash
cp poc/lines.toml.example poc/lines.toml
./scripts/poc-api.sh    # http://127.0.0.1:8080
```

**3-line plan:** [`docs/superpowers/plans/2026-07-08-poc-3-line-mac-plan.md`](docs/superpowers/plans/2026-07-08-poc-3-line-mac-plan.md).

Spike binary: `target/release/kappy-spike` or `spike/target/release/kappy-spike`  
API binary: `target/release/kappy-api`

## Layout

```
kappy-imessage-server/
  api/             # kappy-api REST server (3-line fleet)
  spike/           # U0 R1 feasibility binary + library
  scripts/         # rustpush vendor + PoC helpers
  docs/            # runbooks + API.md
  poc/             # 3-line config (lines.toml, line envs)
```
