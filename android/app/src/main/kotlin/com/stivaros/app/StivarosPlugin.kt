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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
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

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "connect" -> {
                val serverAddress = call.argument<String>("address") ?: ""
                val serverPort = call.argument<Int>("port") ?: 443
                val uuid = call.argument<String>("uuid") ?: ""
                val protocol = call.argument<String>("protocol") ?: "vless"
                val transport = call.argument<String>("transport") ?: "xhttp"
                val tls = call.argument<Boolean>("tls") ?: true
                val sni = call.argument<String>("sni") ?: serverAddress
                val publicKey = call.argument<String>("publicKey") ?: ""
                val shortId = call.argument<String>("shortId") ?: ""
                val flow = call.argument<String>("flow") ?: ""

                xrayManager?.errorCallback = { msg ->
                    val intent = Intent(StivarosVpnService.BROADCAST_STATUS).apply {
                        putExtra(StivarosVpnService.EXTRA_STATUS, "ERROR")
                        putExtra(StivarosVpnService.EXTRA_MESSAGE, msg)
                    }
                    context.sendBroadcast(intent)
                }

                try {
                    xrayManager?.start(
                        serverAddress, serverPort, uuid, protocol,
                        transport, tls, sni, publicKey, shortId, flow
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.error("CONNECT_FAILED", e.message, null)
                }
            }
            "disconnect" -> {
                xrayManager?.stop()
                result.success(true)
            }
            "getStatus" -> {
                val isRunning = xrayManager?.isRunning() ?: false
                val status = if (isRunning) "CONNECTED" else StivarosVpnService.currentStatus
                result.success(status)
            }
            "requestVpnPermission" -> {
                val activity = activityBinding?.activity
                if (activity != null) {
                    val intent = android.net.VpnService.prepare(context)
                    if (intent != null) {
                        activity.startActivityForResult(intent, StivarosVpnService.VPN_REQUEST_CODE)
                        result.success(false)
                    } else {
                        result.success(true)
                    }
                } else {
                    result.error("NO_ACTIVITY", "No activity available", null)
                }
            }
            "getHardwareId" -> {
                result.success(ActivationHelper.getHardwareId(context))
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
                        }
                    } else {
                        val dest = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "mtn.txt")
                        srcFile.copyTo(dest, overwrite = true)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    android.util.Log.e("StivarosPlugin", "saveToDownloads error: ${e.message}")
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }
}
