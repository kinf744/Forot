package com.stivaros.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val prefs = context.getSharedPreferences("stivaros_prefs", Context.MODE_PRIVATE)
            if (prefs.getBoolean("auto_connect", false)) {
                val serviceIntent = Intent(context, StivarosVpnService::class.java).apply {
                    action = StivarosVpnService.ACTION_START
                    putExtra("address", prefs.getString("server_address", ""))
                    putExtra("port", prefs.getInt("server_port", 443))
                    putExtra("uuid", prefs.getString("server_uuid", ""))
                    putExtra("protocol", prefs.getString("server_protocol", "vless"))
                    putExtra("transport", prefs.getString("server_transport", "tcp"))
                    putExtra("tls", prefs.getBoolean("server_tls", true))
                    putExtra("sni", prefs.getString("server_sni", ""))
                }
                context.startForegroundService(serviceIntent)
            }
        }
    }
}
