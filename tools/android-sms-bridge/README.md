# Kappy SMS Bridge (Android)

Minimal Android app that sends **REG-REQ** to Apple's carrier SMS gateway and forwards **REG-RESP** back to your Mac running `kappy-spike sms-reg-webhook`.

Use this when Telnyx IoT eSIM SMS does not work in the stock Messages app but may work via `SmsManager` (same radio — may still fail on data-only wireless SKUs).

## Build

1. Open `tools/android-sms-bridge` in **Android Studio**
2. Build → Build APK(s)
3. Install on spare phone with Telnyx eSIM (same Wi‑Fi as Mac)

Or from CLI (with Android SDK installed):

```bash
cd tools/android-sms-bridge
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Mac setup

Terminal 1 — webhook on LAN (phone must reach your Mac):

```bash
./scripts/poc-sms-reg-bridge.sh 2 --register
```

Terminal 2 — create pending REG-REQ:

```bash
./scripts/poc-line.sh 2 sms-reg-send --dry-run
```

Find your Mac's LAN IP: `ipconfig getifaddr en0` (e.g. `192.168.1.10`).

## Phone setup

1. Install **Kappy SMS Bridge**
2. Grant **SMS** permissions
3. Set **Mac URL**: `http://192.168.1.10:8790`
4. Set **gateway**: `28818773` (AT&T) or `22223333` (T-Mobile)
5. Tap **Fetch REG-REQ** → **Send REG-REQ**
6. When **REG-RESP** arrives, the app auto-posts to Mac (`/webhooks/sms-reg/bridge`)

## API endpoints (Mac)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/webhooks/sms-reg/pending` | Phone fetches REG-REQ body |
| POST | `/webhooks/sms-reg/bridge` | `{"text":"REG-RESP?..."}` |
| POST | `/webhooks/telnyx/sms-reg` | Telnyx inbound (optional) |

## Troubleshooting

- **Send fails** — Telnyx wireless may not support handset SMS; try USB modem + AT+CMGS (`scripts/poc-sms-reg-modem.py`)
- **Fetch failed** — Mac firewall; allow port 8790; same Wi‑Fi; use `0.0.0.0` listener (`poc-sms-reg-bridge.sh`)
- **Wrong SIM** — dual-SIM phones: install Telnyx on line 2; app uses last active subscription
