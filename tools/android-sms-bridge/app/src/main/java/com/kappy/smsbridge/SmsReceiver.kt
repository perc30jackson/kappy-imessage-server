package com.kappy.smsbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import kotlin.concurrent.thread

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        val body = messages.joinToString(separator = "") { it.messageBody ?: "" }
        if (!body.contains("REG-RESP")) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val macUrl = prefs.getString(KEY_MAC_URL, null) ?: return

        val pendingResult = goAsync()
        thread(name = "kappy-sms-bridge-forward") {
            try {
                val resp = BridgeClient.postRegResp(macUrl, body.trim())
                Log.i(TAG, "forwarded REG-RESP to Mac: $resp")
                Prefs.appendLog(context, "REG-RESP forwarded to Mac")
            } catch (e: Exception) {
                Log.e(TAG, "failed to forward REG-RESP", e)
                Prefs.appendLog(context, "forward failed: ${e.message}")
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        private const val TAG = "KappySmsBridge"
        const val PREFS = "kappy_sms_bridge"
        const val KEY_MAC_URL = "mac_url"
    }
}
