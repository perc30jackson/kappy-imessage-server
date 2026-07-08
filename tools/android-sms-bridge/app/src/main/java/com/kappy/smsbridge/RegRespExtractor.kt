package com.kappy.smsbridge

import android.telephony.SmsMessage
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets

object RegRespExtractor {
    fun fromSmsMessages(messages: Array<SmsMessage>?): String? {
        if (messages.isNullOrEmpty()) return null

        val textBody = messages.joinToString(separator = "") { msg ->
            msg.messageBody
                ?: msg.displayMessageBody
                ?: ""
        }
        extract(textBody)?.let { return it }

        val userData = messages.joinToString(separator = "") { msg ->
            decodeUserData(msg.userData)
        }
        return extract(userData)
    }

    fun extract(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        val idx = raw.indexOf("REG-RESP")
        if (idx < 0) return null
        val from = raw.substring(idx)
        val end = from.indexOfFirst { it == '\n' || it == '\r' || it == '\u0000' }
        val line = (if (end >= 0) from.substring(0, end) else from).trim()
        return line.takeIf { it.startsWith("REG-RESP") && it.contains("s=") }
    }

    private fun decodeUserData(data: ByteArray?): String {
        if (data == null || data.isEmpty()) return ""
        val asUtf8 = String(data, StandardCharsets.UTF_8)
        if (asUtf8.contains("REG-RESP")) return asUtf8
        val asLatin1 = String(data, Charset.forName("ISO-8859-1"))
        if (asLatin1.contains("REG-RESP")) return asLatin1
        return data.map { (it.toInt() and 0xFF).toChar() }.joinToString("")
    }
}
