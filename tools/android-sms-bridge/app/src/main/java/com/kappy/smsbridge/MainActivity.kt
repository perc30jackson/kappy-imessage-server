package com.kappy.smsbridge

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {
    private lateinit var macUrl: EditText
    private lateinit var gateway: EditText
    private lateinit var regReqBody: EditText
    private lateinit var logView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        macUrl = findViewById(R.id.macUrl)
        gateway = findViewById(R.id.gateway)
        regReqBody = findViewById(R.id.regReqBody)
        logView = findViewById(R.id.log)

        Prefs.macUrl(this)?.let { macUrl.setText(it) }
        gateway.setText(Prefs.gateway(this))
        refreshLog()

        findViewById<Button>(R.id.fetchPending).setOnClickListener { fetchPending() }
        findViewById<Button>(R.id.sendRegReq).setOnClickListener { sendRegReq() }

        ensureSmsPermission()
    }

    override fun onResume() {
        super.onResume()
        refreshLog()
    }

    private fun refreshLog() {
        logView.text = Prefs.log(this).ifBlank { "Ready." }
    }

    private fun appendLog(line: String) {
        Prefs.appendLog(this, line)
        runOnUiThread { refreshLog() }
    }

    private fun ensureSmsPermission() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS)
            == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.SEND_SMS, Manifest.permission.RECEIVE_SMS),
            REQ_SMS,
        )
    }

    private fun fetchPending() {
        val url = macUrl.text.toString().trim()
        if (url.isEmpty()) {
            toast("Set Mac URL first")
            return
        }
        Prefs.saveMacUrl(this, url)
        Prefs.saveGateway(this, gateway.text.toString())

        appendLog("Fetching pending REG-REQ…")
        thread {
            try {
                val json = BridgeClient.fetchPending(url)
                val pending = json.getJSONObject("pending")
                val body = pending.getString("reg_req_body")
                val gw = pending.optString("gateway", Prefs.gateway(this@MainActivity))
                runOnUiThread {
                    regReqBody.setText(body)
                    gateway.setText(gw)
                    appendLog("Fetched pending r=${pending.optLong("request_id")}")
                }
            } catch (e: Exception) {
                runOnUiThread {
                    appendLog("Fetch failed: ${e.message}")
                    toast(e.message ?: "fetch failed")
                }
            }
        }
    }

    private fun sendRegReq() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            toast("Grant SMS permission")
            ensureSmsPermission()
            return
        }

        val url = macUrl.text.toString().trim()
        val gw = gateway.text.toString().trim()
        val body = regReqBody.text.toString().trim()
        if (url.isEmpty() || gw.isEmpty() || body.isEmpty()) {
            toast("Mac URL, gateway, and REG-REQ body required")
            return
        }
        if (!body.startsWith("REG-REQ")) {
            toast("Body must start with REG-REQ")
            return
        }

        Prefs.saveMacUrl(this, url)
        Prefs.saveGateway(this, gw)

        try {
            val sms = smsManagerForTelnyxLine()
            sms.sendTextMessage(gw, null, body, null, null)
            appendLog("Sent REG-REQ → $gw")
            toast("REG-REQ sent")
        } catch (e: Exception) {
            appendLog("Send failed: ${e.message}")
            toast(e.message ?: "send failed")
        }
    }

    private fun smsManagerForTelnyxLine(): SmsManager {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.LOLLIPOP_MR1) {
            return SmsManager.getDefault()
        }
        val subMgr = getSystemService(SubscriptionManager::class.java)
        val subs = subMgr?.activeSubscriptionInfoList.orEmpty()
        if (subs.size <= 1) {
            return SmsManager.getDefault()
        }
        // Prefer non-default SIM if user installed Telnyx as second line
        val subId = subs.lastOrNull()?.subscriptionId ?: SubscriptionManager.getDefaultSmsSubscriptionId()
        return SmsManager.getSmsManagerForSubscriptionId(subId)
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val REQ_SMS = 1001
    }
}
