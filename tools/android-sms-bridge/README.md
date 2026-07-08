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

Apple often sends REG-RESP as a **data SMS** (not shown in Messages). This app listens for both:

- `android.provider.Telephony.SMS_RECEIVED`
- `android.intent.action.DATA_SMS_RECEIVED` (same as [PNRGatewayClient](https://github.com/iswheeler/PNRGatewayClient))

If capture fails but you still have the REG-RESP text, paste it into **Paste REG-RESP** and tap **Forward REG-RESP to Mac**. Or on the Mac:

```bash
./scripts/poc-line.sh 2 sms-reg-complete --text 'REG-RESP?v=3;r=…;n=+1…;s=…' --register
```

## API endpoints (Mac)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/webhooks/sms-reg/pending` | Phone fetches REG-REQ body |
| POST | `/webhooks/sms-reg/bridge` | `{"text":"REG-RESP?..."}` |
| POST | `/webhooks/telnyx/sms-reg` | Telnyx inbound (optional) |

## After REG-RESP hits the Mac

With `--register`, the webhook runs `authenticate_phone` + `register_ids`. Check:

```bash
./scripts/poc-line.sh 2 doctor-handles
```

You want a `tel:+…` handle alongside `mailto:`.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| **Fetch failed** | Mac firewall / wrong IP / webhook not running; same Wi‑Fi |
| **Send fails** | Telnyx wireless may not support handset SMS → USB modem (`poc-sms-reg-modem.py`) or prepaid SIM |
| **Sent OK, no REG-RESP** | Outbound never reached Apple, **or** reply was data SMS and old APK lacked `DATA_SMS_RECEIVED` — rebuild/reinstall |
| **Wrong SIM** | Dual-SIM: install Telnyx as line 2; app prefers last active subscription |
| **Mac logs nothing** | Phone never POSTed; check app log for “forwarded” / “forward failed” |

Pending endpoint smoke test (Mac):

```bash
curl -sS http://127.0.0.1:8790/webhooks/sms-reg/pending
```
