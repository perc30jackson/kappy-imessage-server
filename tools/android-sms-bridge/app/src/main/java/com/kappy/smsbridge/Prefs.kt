package com.kappy.smsbridge

import android.content.Context

object Prefs {
    private const val KEY_GATEWAY = "gateway"
    private const val KEY_LOG = "log"

    fun saveMacUrl(context: Context, url: String) {
        context.getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(SmsReceiver.KEY_MAC_URL, url.trim())
            .apply()
    }

    fun saveGateway(context: Context, gateway: String) {
        context.getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_GATEWAY, gateway.trim())
            .apply()
    }

    fun macUrl(context: Context): String? =
        context.getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
            .getString(SmsReceiver.KEY_MAC_URL, null)

    fun gateway(context: Context): String =
        context.getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
            .getString(KEY_GATEWAY, "28818773") ?: "28818773"

    fun appendLog(context: Context, line: String) {
        val prefs = context.getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
        val prev = prefs.getString(KEY_LOG, "") ?: ""
        val next = (prev + "\n" + line).trim().takeLast(4000)
        prefs.edit().putString(KEY_LOG, next).apply()
    }

    fun log(context: Context): String =
        context.getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
            .getString(KEY_LOG, "") ?: ""
}
