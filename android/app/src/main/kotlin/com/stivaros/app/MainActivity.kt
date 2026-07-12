package com.stivaros.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(StivarosPlugin())
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        NativeLogger.i("MainActivity", "onActivityResult: requestCode=$requestCode resultCode=$resultCode")
        if (requestCode == StivarosVpnService.VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                NativeLogger.i("MainActivity", "VPN permission granted — checking pending params")
                val params = StivarosPlugin.consumePendingParams()
                if (params != null) {
                    NativeLogger.i("MainActivity", "Starting VPN with pending params")
                    StivarosPlugin.startPendingVpn(params)
                } else {
                    NativeLogger.w("MainActivity", "No pending params")
                }
            } else {
                NativeLogger.w("MainActivity", "VPN permission denied")
            }
        }
    }
}
