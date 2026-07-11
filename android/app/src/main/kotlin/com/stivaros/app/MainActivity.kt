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
        if (requestCode == StivarosVpnService.VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                val intent = Intent(this, StivarosVpnService::class.java).apply {
                    action = StivarosVpnService.ACTION_START
                    putExtras(data?.extras ?: Intent().extras ?: return)
                }
                startForegroundService(intent)
            }
        }
    }
}
