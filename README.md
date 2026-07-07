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

```bash
# 1. Vendor rustpush (submodules required)
./scripts/vendor-rustpush.sh

# 2. Build spike
cd spike
cargo build --release

# 3. Follow spike runbook
open ../docs/spike-runbook.md
```

Spike binary: `spike/target/release/kappy-spike`

## Layout

```
kappy-imessage-server/
  spike/           # U0 R1 feasibility binary
  scripts/         # rustpush vendor + validation sidecar helpers
  docs/            # runbooks
```
