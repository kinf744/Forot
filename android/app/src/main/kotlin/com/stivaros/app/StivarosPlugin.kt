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
import android.os.Handler
import android.os.Looper
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

    private var statusEventSink: EventChannel.EventSink? = null
    private var statusReceiver: BroadcastReceiver? = null

    companion object {
        @Volatile
        private var pendingConnectParams: Map<String, Any?>? = null

        @JvmStatic
        fun consumePendingParams(): Map<String, Any?>? {
            val params = pendingConnectParams
            pendingConnectParams = null
            return params
        }

        @JvmStatic
        fun startPendingVpn(params: Map<String, Any?>) {
            val plugin = instance ?: run {
                NativeLogger.e("StivarosPlugin", "startPendingVpn: instance is null!")
                return
            }
            plugin.startVpnService(params)
        }

        @Volatile
        private var instance: StivarosPlugin? = null

        @JvmStatic
        fun sendStatusEvent(status: String, message: String = "") {
            NativeLogger.i("StivarosPlugin", "sendStatusEvent: $status $message to ${instance?.statusEventSink}")
            val sink = instance?.statusEventSink
            if (sink != null) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        sink.success(mapOf("status" to status, "message" to message))
                        NativeLogger.i("StivarosPlugin", "sendStatusEvent: success")
                    } catch (e: Exception) {
                        NativeLogger.e("StivarosPlugin", "sendStatusEvent error: ${e.message}")
                    }
                }
            } else {
                NativeLogger.w("StivarosPlugin", "sendStatusEvent: no EventSink, caching status")
                instance?.cachedStatus = status
                instance?.cachedMessage = message
            }
        }
    }

    private var cachedStatus: String = "DISCONNECTED"
    private var cachedMessage: String = ""

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        instance = this
        context = binding.applicationContext
        NativeLogger.i("StivarosPlugin", "onAttachedToEngine")
        channel = MethodChannel(binding.binaryMessenger, "com.stivaros.app/vpn")
        channel.setMethodCallHandler(this)
        statusEventChannel = EventChannel(binding.binaryMessenger, "com.stivaros.app/vpnStatus")
        statusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                NativeLogger.i("StivarosPlugin", "statusEventChannel onListen called")
                statusEventSink = events
                val filter = IntentFilter(StivarosVpnService.BROADCAST_STATUS)
                if (statusReceiver != null) {
                    try { context.unregisterReceiver(statusReceiver) } catch (_: Exception) {}
                }
                statusReceiver = object : BroadcastReceiver() {
                    override fun onReceive(ctx: Context, intent: Intent) {
                        val status = intent.getStringExtra(StivarosVpnService.EXTRA_STATUS) ?: "DISCONNECTED"
                        val message = intent.getStringExtra(StivarosVpnService.EXTRA_MESSAGE) ?: ""
                        NativeLogger.i("StivarosPlugin", "status broadcast received: $status $message")
                        sendStatusEvent(status, message)
                    }
                }
                context.registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                NativeLogger.i("StivarosPlugin", "BroadcastReceiver registered")

                val vpnStatus = StivarosVpnService.currentStatus
                if (cachedStatus != "DISCONNECTED" || cachedMessage != "") {
                    NativeLogger.i("StivarosPlugin", "Resending cached status: $cachedStatus $cachedMessage")
                    sendStatusEvent(cachedStatus, cachedMessage)
                } else if (vpnStatus != "DISCONNECTED") {
                    NativeLogger.i("StivarosPlugin", "Resending VpnService.currentStatus: $vpnStatus")
                    sendStatusEvent(vpnStatus, "")
                }
            }

            override fun onCancel(arguments: Any?) {
                NativeLogger.i("StivarosPlugin", "statusEventChannel onCancel called")
                statusEventSink = null
            }
        })
        xrayManager = XrayManager(context)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeLogger.i("StivarosPlugin", "onDetachedFromEngine")
        channel.setMethodCallHandler(null)
        statusEventChannel.setStreamHandler(null)
        statusEventSink = null
        if (statusReceiver != null) {
            try { context.unregisterReceiver(statusReceiver) } catch (_: Exception) {}
            statusReceiver = null
        }
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
                    // Permission not granted — store params (in companion object) and show dialog
                    NativeLogger.w("Plugin", "VPN permission not granted, storing pending params")
                    pendingConnectParams = params
                    val activity = activityBinding?.activity
                    if (activity != null) {
                        activity.startActivityForResult(vpnIntent, StivarosVpnService.VPN_REQUEST_CODE)
                    } else {
                        NativeLogger.e("Plugin", "No activity for VPN permission request")
                    }
                    result.success(false)
                    return@onMethodCall
                }

                // Permission already granted
                NativeLogger.i("Plugin", "VPN permission OK, starting service")
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
                val status = cachedStatus
                NativeLogger.i("Plugin", "getStatus: $status (msg: $cachedMessage)")
                result.success(mapOf("status" to status, "message" to cachedMessage))
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
            "initNativeLogger" -> {
                val path = call.argument<String>("path") ?: ""
                if (path.isNotBlank()) {
                    NativeLogger.setFile(File(path))
                    NativeLogger.i("StivarosPlugin", "NativeLogger redirected to: $path")
                }
                result.success(true)
            }
            "detectNetworkProvider" -> {
                try {
                    val provider = NetworkProviderDetector.detect(context)
                    NativeLogger.i("Plugin", "detectNetworkProvider: ${provider.providerName} (${provider.connectionType}) isp=${provider.isp}")
                    result.success(mapOf(
                        "connectionType" to provider.connectionType,
                        "providerName" to provider.providerName,
                        "fullProviderName" to provider.fullProviderName,
                        "confidence" to provider.confidence.name,
                        "country" to provider.country,
                        "mcc" to (provider.mcc ?: ""),
                        "mnc" to (provider.mnc ?: ""),
                        "isp" to (provider.isp ?: ""),
                        "isRoaming" to provider.isRoaming,
                        "isVpnConnected" to provider.isVpnConnected
                    ))
                } catch (e: Exception) {
                    NativeLogger.e("Plugin", "detectNetworkProvider error: ${e.message}")
                    result.success(mapOf(
                        "connectionType" to "unknown", "providerName" to "Unknown",
                        "fullProviderName" to "", "confidence" to "NONE",
                        "country" to "", "mcc" to "", "mnc" to "",
                        "isp" to "", "isRoaming" to false, "isVpnConnected" to false
                    ))
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
