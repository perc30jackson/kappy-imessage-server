package com.kappy.smsbridge

import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

object BridgeClient {
    fun fetchPending(macBaseUrl: String): JSONObject {
        val base = macBaseUrl.trimEnd('/')
        return getJson("$base/webhooks/sms-reg/pending")
    }

    fun postRegResp(macBaseUrl: String, text: String): JSONObject {
        val base = macBaseUrl.trimEnd('/')
        val url = URL("$base/webhooks/sms-reg/bridge")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 60_000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
        }
        val body = JSONObject().put("text", text).toString()
        conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val resp = stream.bufferedReader().use(BufferedReader::readText)
        if (code !in 200..299) {
            throw IllegalStateException("HTTP $code: $resp")
        }
        return JSONObject(resp)
    }

    private fun getJson(urlString: String): JSONObject {
        val conn = (URL(urlString).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 30_000
        }
        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val resp = stream.bufferedReader().use(BufferedReader::readText)
        if (code !in 200..299) {
            throw IllegalStateException("HTTP $code: $resp")
        }
        return JSONObject(resp)
    }
}
