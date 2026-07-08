package com.kappy.smsbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SmsMessage
import android.util.Log
import kotlin.concurrent.thread

object RegRespForwarder {
    fun handle(context: Context, intent: Intent, source: String, pendingResult: BroadcastReceiver.PendingResult) {
        val messages = messagesFromIntent(intent)
        if (messages == null) {
            pendingResult.finish()
            return
        }
        val body = RegRespExtractor.fromSmsMessages(messages)
        if (body == null) {
            Log.d(TAG, "SMS ignored (no REG-RESP), source=$source from=${messages.firstOrNull()?.originatingAddress}")
            pendingResult.finish()
            return
        }

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val macUrl = prefs.getString(KEY_MAC_URL, null)
        if (macUrl == null) {
            Prefs.appendLog(context, "REG-RESP seen but Mac URL not set")
            pendingResult.finish()
            return
        }

        Prefs.appendLog(
            context,
            "REG-RESP via $source from ${messages.firstOrNull()?.originatingAddress}",
        )

        thread(name = "kappy-sms-bridge-forward") {
            try {
                val resp = BridgeClient.postRegResp(macUrl, body)
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

    fun messagesFromIntent(intent: Intent): Array<SmsMessage>? {
        Telephony.Sms.Intents.getMessagesFromIntent(intent)?.takeIf { it.isNotEmpty() }?.let {
            return it
        }
        val pdus = intent.extras?.get("pdus") as? Array<*> ?: return null
        val format = intent.getStringExtra("format")
        return pdus.mapNotNull { pdu ->
            val bytes = pdu as? ByteArray ?: return@mapNotNull null
            if (format != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                SmsMessage.createFromPdu(bytes, format)
            } else {
                @Suppress("DEPRECATION")
                SmsMessage.createFromPdu(bytes)
            }
        }.toTypedArray().ifEmpty { null }
    }

    const val TAG = "KappySmsBridge"
    const val PREFS = "kappy_sms_bridge"
    const val KEY_MAC_URL = "mac_url"
}

/** Normal SMS_RECEIVED (some carriers deliver REG-RESP this way). */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        RegRespForwarder.handle(context, intent, "SMS", goAsync())
    }
}

/** Apple often returns REG-RESP as data SMS (PNRGatewayClient PDUReceiver). */
class DataSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "android.intent.action.DATA_SMS_RECEIVED") return
        RegRespForwarder.handle(context, intent, "data-SMS", goAsync())
    }
}
