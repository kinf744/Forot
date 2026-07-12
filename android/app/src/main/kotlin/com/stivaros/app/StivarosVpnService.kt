package com.stivaros.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*

class StivarosVpnService : VpnService() {

    companion object {
        const val TAG = "StivarosVpn"
        const val NOTIFICATION_ID = 1001
        const val CHANNEL_ID = "stivaros_vpn"
        const val ACTION_START = "com.stivaros.app.START"
        const val ACTION_STOP = "com.stivaros.app.STOP"
        const val VPN_REQUEST_CODE = 1000
        const val BROADCAST_STATUS = "com.stivaros.app.STATUS"
        const val EXTRA_STATUS = "status"
        const val EXTRA_MESSAGE = "message"

        var instance: StivarosVpnService? = null
        var currentStatus = "DISCONNECTED"
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var serviceJob = SupervisorJob()
    private var serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)
    private var xrayManager: XrayManager? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        xrayManager = XrayManager(this)
        NativeLogger.i("VpnService", "onCreate: xrayManager created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        NativeLogger.i("VpnService", "onStartCommand: action=${intent?.action}")
        startForeground(NOTIFICATION_ID, buildNotification("Starting..."))
        when (intent?.action) {
            ACTION_START -> startVpn(intent)
            ACTION_STOP -> stopVpn()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    override fun onRevoke() {
        NativeLogger.w("VpnService", "VPN revoked by system")
        stopVpn()
    }

    override fun onDestroy() {
        NativeLogger.i("VpnService", "onDestroy")
        stopVpn()
        serviceJob.cancel()
        instance = null
        super.onDestroy()
    }

    private fun startVpn(intent: Intent) {
        serviceScope.launch {
            try {
                val serverAddress = intent.getStringExtra("address") ?: return@launch
                val serverPort = intent.getIntExtra("port", 443)
                val uuid = intent.getStringExtra("uuid") ?: return@launch
                val protocol = intent.getStringExtra("protocol") ?: "vless"
                val transport = intent.getStringExtra("transport") ?: "xhttp"
                val tls = intent.getBooleanExtra("tls", true)
                val sni = intent.getStringExtra("sni") ?: serverAddress
                val host = intent.getStringExtra("host") ?: sni
                val publicKey = intent.getStringExtra("publicKey") ?: ""
                val shortId = intent.getStringExtra("shortId") ?: ""
                val flow = intent.getStringExtra("flow") ?: ""

                NativeLogger.i("VpnService", "startVpn: $serverAddress:$serverPort uuid=$uuid transport=$transport sni=$sni host=$host")

                // Wire up Xray error callback
                xrayManager?.errorCallback = { msg ->
                    NativeLogger.e("VpnService", "Xray error callback: $msg")
                    updateStatus("ERROR", msg)
                }

                // Start Xray
                NativeLogger.i("VpnService", "Starting Xray...")
                xrayManager?.start(
                    serverAddress, serverPort, uuid, protocol,
                    transport, tls, sni, host, publicKey, shortId, flow
                )
                val socksPort = xrayManager?.getSocksPort() ?: 0
                NativeLogger.i("VpnService", "Xray started, SOCKS port=$socksPort")
                if (socksPort == 0) throw Exception("Failed to get SOCKS port")

                // Build VPN interface
                NativeLogger.i("VpnService", "Building VPN interface...")
                vpnInterface = Builder()
                    .setSession("Stivaros")
                    .addAddress("10.0.0.2", 24)
                    .addRoute("0.0.0.0", 0)
                    .addDnsServer("8.8.8.8")
                    .addDnsServer("8.8.4.4")
                    .setMtu(1400)
                    .setBlocking(true)
                    .addDisallowedApplication(packageName)
                    .establish()

                if (vpnInterface == null) {
                    NativeLogger.e("VpnService", "VPN interface is null! Permission not granted?")
                    throw Exception("Failed to establish VPN interface")
                }
                NativeLogger.i("VpnService", "VPN interface established: fd=${vpnInterface!!.fd}")

                // Start SOCKS5 routing via tun2socks relay
                NativeLogger.i("VpnService", "Starting SOCKS relay (fd=${vpnInterface!!.fd}, socksPort=$socksPort)")
                startSocksRelay(vpnInterface!!.fd, socksPort)
                updateStatus("CONNECTED", "Connected")
                updateNotification("Connected")
                NativeLogger.i("VpnService", "VPN fully connected!")

            } catch (e: Exception) {
                NativeLogger.e("VpnService", "VPN start error: ${e.message}")
                Log.e(TAG, "VPN start error: ${e.message}")
                updateStatus("ERROR", e.message ?: "Connection failed")
                stopVpn()
            }
        }
    }

    private fun startSocksRelay(fd: Int, socksPort: Int) {
        serviceScope.launch(Dispatchers.IO) {
            try {
                NativeLogger.i("VpnService", "startSocksRelay: fd=$fd socksPort=$socksPort")
                val relay = Tun2SocksRelay(
                    ParcelFileDescriptor.fromFd(fd).fileDescriptor,
                    "127.0.0.1", socksPort
                )
                relay.start()
                NativeLogger.i("VpnService", "SOCKS relay thread started")
            } catch (e: Exception) {
                NativeLogger.e("VpnService", "Socks relay error: ${e.message}")
                Log.e(TAG, "Socks relay error: ${e.message}")
            }
        }
    }

    fun stopVpn() {
        NativeLogger.i("VpnService", "stopVpn()")
        xrayManager?.stop()
        try { vpnInterface?.close(); NativeLogger.i("VpnService", "VPN interface closed") } catch (_: Exception) {}
        vpnInterface = null
        try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
        updateStatus("DISCONNECTED", "Disconnected")
    }

    private fun updateStatus(status: String, message: String = "") {
        NativeLogger.i("VpnService", "updateStatus: $status $message")
        currentStatus = status
        sendBroadcast(Intent(BROADCAST_STATUS).apply {
            putExtra(EXTRA_STATUS, status)
            putExtra(EXTRA_MESSAGE, message)
        })
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Stivaros VPN",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "VPN connection status"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, StivarosVpnService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Stivaros VPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", stopIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
