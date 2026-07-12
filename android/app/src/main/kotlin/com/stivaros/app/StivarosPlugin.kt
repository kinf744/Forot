package com.stivaros.app

import android.app.usage.NetworkStatsManager
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.TrafficStats
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

class StivarosPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private lateinit var statusEventChannel: EventChannel
    private lateinit var context: Context
    private var xrayManager: XrayManager? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingConnectParams: Map<String, Any?>? = null

    companion object {
        @JvmStatic
        fun consumePendingParams(): Map<String, Any?>? {
            val plugin = instance ?: return null
            val params = plugin.pendingConnectParams
            plugin.pendingConnectParams = null
            return params
        }

        @JvmStatic
        fun startPendingVpn(params: Map<String, Any?>) {
            instance?.startVpnService(params)
        }

        private var instance: StivarosPlugin? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        instance = this
        context = binding.applicationContext
        NativeLogger.init(File(context.filesDir, "native_log.txt"))
        NativeLogger.i("StivarosPlugin", "onAttachedToEngine")
        channel = MethodChannel(binding.binaryMessenger, "com.stivaros.app/vpn")
        channel.setMethodCallHandler(this)
        statusEventChannel = EventChannel(binding.binaryMessenger, "com.stivaros.app/vpnStatus")
        statusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            private var receiver: BroadcastReceiver? = null

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val filter = IntentFilter(StivarosVpnService.BROADCAST_STATUS)
                receiver = object : BroadcastReceiver() {
                    override fun onReceive(ctx: Context, intent: Intent) {
                        val status = intent.getStringExtra(StivarosVpnService.EXTRA_STATUS) ?: "DISCONNECTED"
                        val message = intent.getStringExtra(StivarosVpnService.EXTRA_MESSAGE) ?: ""
                        events.success(mapOf("status" to status, "message" to message))
                    }
                }
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            }

            override fun onCancel(arguments: Any?) {
                receiver?.let { context.unregisterReceiver(it) }
                receiver = null
            }
        })
        xrayManager = XrayManager(context)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        statusEventChannel.setStreamHandler(null)
        xrayManager?.stop()
        instance = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivity() {
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding = null
    }

    private fun startVpnService(params: Map<String, Any?>) {
        NativeLogger.i("Plugin", "Starting StivarosVpnService with params")
        val serviceIntent = Intent(context, StivarosVpnService::class.java).apply {
            action = StivarosVpnService.ACTION_START
            putExtra("address", params["address"] as? String ?: "")
            putExtra("port", (params["port"] as? Int) ?: 443)
            putExtra("uuid", params["uuid"] as? String ?: "")
            putExtra("protocol", params["protocol"] as? String ?: "vless")
            putExtra("transport", params["transport"] as? String ?: "xhttp")
            putExtra("tls", (params["tls"] as? Boolean) ?: true)
            putExtra("sni", params["sni"] as? String ?: "")
            putExtra("host", params["host"] as? String ?: "")
            putExtra("publicKey", params["publicKey"] as? String ?: "")
            putExtra("shortId", params["shortId"] as? String ?: "")
            putExtra("flow", params["flow"] as? String ?: "")
        }
        context.startForegroundService(serviceIntent)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "connect" -> {
                val params = mutableMapOf<String, Any?>()
                params["address"] = call.argument<String>("address") ?: ""
                params["port"] = call.argument<Int>("port") ?: 443
                params["uuid"] = call.argument<String>("uuid") ?: ""
                params["protocol"] = call.argument<String>("protocol") ?: "vless"
                params["transport"] = call.argument<String>("transport") ?: "xhttp"
                params["tls"] = call.argument<Boolean>("tls") ?: true
                params["sni"] = call.argument<String>("sni") ?: (params["address"] as? String ?: "")
                params["host"] = call.argument<String>("host") ?: (params["sni"] as? String ?: "")
                params["publicKey"] = call.argument<String>("publicKey") ?: ""
                params["shortId"] = call.argument<String>("shortId") ?: ""
                params["flow"] = call.argument<String>("flow") ?: ""

                NativeLogger.i("Plugin", "connect called: address=${params["address"]} port=${params["port"]} uuid=${params["uuid"]}")

                // Check VPN permission
                val vpnIntent = android.net.VpnService.prepare(context)
                if (vpnIntent != null) {
                    // Permission not granted — store params and show dialog
                    NativeLogger.w("Plugin", "VPN permission not granted, storing pending params")
                    pendingConnectParams = params
                    val activity = activityBinding?.activity
                    if (activity != null) {
                        activity.startActivityForResult(vpnIntent, StivarosVpnService.VPN_REQUEST_CODE)
                    }
                    result.success(false)
                    return@onMethodCall
                }

                // Permission already granted
                NativeLogger.i("Plugin", "VPN permission OK, starting service")
                pendingConnectParams = null
                startVpnService(params)
                result.success(true)
            }
            "disconnect" -> {
                NativeLogger.i("Plugin", "disconnect called")
                StivarosVpnService.instance?.stopVpn()
                pendingConnectParams = null
                result.success(true)
            }
            "getStatus" -> {
                val status = StivarosVpnService.currentStatus
                NativeLogger.i("Plugin", "getStatus: $status")
                result.success(status)
            }
            "requestVpnPermission" -> {
                val activity = activityBinding?.activity
                if (activity != null) {
                    val intent = android.net.VpnService.prepare(context)
                    if (intent != null) {
                        NativeLogger.w("Plugin", "VPN permission not granted, showing dialog")
                        activity.startActivityForResult(intent, StivarosVpnService.VPN_REQUEST_CODE)
                        result.success(false)
                    } else {
                        NativeLogger.i("Plugin", "VPN permission already granted")
                        result.success(true)
                    }
                } else {
                    NativeLogger.e("Plugin", "No activity for VPN permission request")
                    result.error("NO_ACTIVITY", "No activity available", null)
                }
            }
            "getHardwareId" -> {
                val hwid = ActivationHelper.getHardwareId(context)
                NativeLogger.i("Plugin", "getHardwareId: ${hwid.take(20)}...")
                result.success(hwid)
            }
            "getTrafficStats" -> {
                try {
                    val rxBytes = TrafficStats.getTotalRxBytes()
                    val txBytes = TrafficStats.getTotalTxBytes()
                    result.success(mapOf("rxBytes" to rxBytes, "txBytes" to txBytes))
                } catch (e: Exception) {
                    result.success(mapOf("rxBytes" to 0L, "txBytes" to 0L))
                }
            }
            "saveToDownloads" -> {
                val source = call.argument<String>("source") ?: ""
                try {
                    val srcFile = File(source)
                    if (!srcFile.exists()) {
                        NativeLogger.w("Plugin", "saveToDownloads: source not found: $source")
                        result.success(false)
                        return@onMethodCall
                    }

                    // Merge native log into the Dart log file
                    val nativeLog = File(context.filesDir, "native_log.txt")
                    if (nativeLog.exists()) {
                        srcFile.appendText("\n\n===== NATIVE LOGS =====\n")
                        srcFile.appendText(nativeLog.readText())
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val values = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, "mtn.txt")
                            put(MediaStore.Downloads.MIME_TYPE, "text/plain")
                            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                        }
                        val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        if (uri != null) {
                            context.contentResolver.openOutputStream(uri)?.use { out ->
                                srcFile.inputStream().use { it.copyTo(out) }
                            }
                            NativeLogger.i("Plugin", "Log saved to Downloads/mtn.txt")
                        } else {
                            NativeLogger.e("Plugin", "Failed to create MediaStore entry")
                        }
                    } else {
                        val dest = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "mtn.txt")
                        srcFile.copyTo(dest, overwrite = true)
                        NativeLogger.i("Plugin", "Log saved to ${dest.absolutePath}")
                    }
                    result.success(true)
                } catch (e: Exception) {
                    NativeLogger.e("Plugin", "saveToDownloads error: ${e.message}")
                    result.success(false)
                }
            }
            "getNativeLog" -> {
                val nativeLog = File(context.filesDir, "native_log.txt")
                if (nativeLog.exists()) {
                    result.success(nativeLog.readText())
                } else {
                    result.success("")
                }
            }
            else -> result.notImplemented()
        }
    }
}
