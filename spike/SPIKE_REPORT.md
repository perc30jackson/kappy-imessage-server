# U0 R1 Spike Report

**Date:**  
**Pilot Mac OS:**  
**rustpush commit:**  
**kappy-spike commit:**  
**Operator:**

## Checklist (plan T0.1–T0.5)

| ID | Scenario | Pass? | Notes |
|----|----------|-------|-------|
| T0.1 | `register` succeeds with MADRID_SERVICE | | |
| T0.2 | Outbound DM delivered to test iPhone | | |
| T0.3 | Inbound reply logged by `listen` | | |
| T0.4 | Process restart + reconnect without re-importing HwInfo | | |
| T0.5 | Validation refresh ≥2 submit cycles | | |

## Activation path used

- [ ] Mac-Hardware-Info → `activate --hw-info`
- [ ] `mac-registration-provider -once` → `inject-validation`
- [ ] Submit sidecar → `validation-server` + `run-validation-sidecar.sh`

## Blockers

## Decision

- [ ] **PASS** — proceed to U1 (`kappy-imessage-server` gRPC scaffold)
- [ ] **FAIL** — document fallback (jesec/imessage-rs or relay)
