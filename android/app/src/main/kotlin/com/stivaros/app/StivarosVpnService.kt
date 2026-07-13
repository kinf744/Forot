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
    private var relayPfd: ParcelFileDescriptor? = null
    private var serviceJob = SupervisorJob()
    private var serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)
    private var xrayManager: XrayManager? = null
    private var zivpnManager: ZivpnManager? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        xrayManager = XrayManager(this)
        zivpnManager = ZivpnManager(this)
        NativeLogger.i("VpnService", "onCreate: managers created")
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
                val mode = intent.getStringExtra("mode") ?: "xray"
                val serverAddress = intent.getStringExtra("address") ?: return@launch
                val uuid = intent.getStringExtra("uuid") ?: return@launch

                NativeLogger.i("VpnService", "startVpn: mode=$mode address=$serverAddress uuid=$uuid")

                val socksPort: Int

                if (mode == "zivpn") {
                    val zivpnPort = intent.getStringExtra("zivpnPort") ?: "6000-7750,7751-9500,9501-11250,11251-13000,13001-14750,14751-16500,16501-18250,18251-19999"
                    val zivpnPassword = intent.getStringExtra("zivpnPassword") ?: uuid
                    val zivpnObfs = intent.getStringExtra("zivpnObfs") ?: "hu``hqb`c"

                    zivpnManager?.errorCallback = { msg ->
                        NativeLogger.e("VpnService", "Zivpn error callback: $msg")
                        updateStatus("ERROR", msg)
                    }

                    zivpnManager?.start(serverAddress, zivpnPort, zivpnPassword, zivpnObfs)
                    socksPort = zivpnManager?.getSocksPort() ?: 0
                    NativeLogger.i("VpnService", "Zivpn started, SOCKS port=$socksPort")
                    if (socksPort == 0) throw Exception("Failed to get Zivpn SOCKS port")
                } else {
                    val serverPort = intent.getIntExtra("port", 443)
                    val protocol = intent.getStringExtra("protocol") ?: "vless"
                    val transport = intent.getStringExtra("transport") ?: "xhttp"
                    val tls = intent.getBooleanExtra("tls", true)
                    val sni = intent.getStringExtra("sni") ?: serverAddress
                    val host = intent.getStringExtra("host") ?: sni
                    val publicKey = intent.getStringExtra("publicKey") ?: ""
                    val shortId = intent.getStringExtra("shortId") ?: ""
                    val flow = intent.getStringExtra("flow") ?: ""

                    xrayManager?.errorCallback = { msg ->
                        NativeLogger.e("VpnService", "Xray error callback: $msg")
                        updateStatus("ERROR", msg)
                    }

                    xrayManager?.start(
                        serverAddress, serverPort, uuid, protocol,
                        transport, tls, sni, host, publicKey, shortId, flow
                    )
                    socksPort = xrayManager?.getSocksPort() ?: 0
                    NativeLogger.i("VpnService", "Xray started, SOCKS port=$socksPort")
                    if (socksPort == 0) throw Exception("Failed to get SOCKS port")
                }

                // Build VPN interface
                NativeLogger.i("VpnService", "Building VPN interface...")
                NativeLogger.i("VpnService", "Builder params: mtu=1400 blocking=true")

                val builder = Builder()
                    .setSession("Stivaros")
                    .addAddress("10.0.0.2", 24)
                    .addRoute("0.0.0.0", 0)
                    .addDnsServer("8.8.8.8")
                    .addDnsServer("1.1.1.1")
                    .setMtu(1400)
                    .setBlocking(true)
                    .addDisallowedApplication(packageName)

                NativeLogger.i("VpnService", "Calling establish()...")
                val fd = builder.establish()
                NativeLogger.i("VpnService", "establish() returned fd=${fd?.fd ?: "null"}")

                if (fd == null) {
                    NativeLogger.e("VpnService", "VPN interface is null! Permission not granted?")
                    throw Exception("Failed to establish VPN interface")
                }
                vpnInterface = fd
                NativeLogger.i("VpnService", "VPN interface established: fd=$fd")

                // Start native HevTun2Socks routing
                NativeLogger.i("VpnService", "Starting HevTun2Socks (fd=${fd.fd}, socksPort=$socksPort)")
                HevTun2Socks.init()
                if (HevTun2Socks.isAvailable) {
                    HevTun2Socks.start(this, fd.fd, socksPort, 1400)
                    updateStatus("CONNECTED", "Connected")
                    updateNotification("Connected")
                    NativeLogger.i("VpnService", "VPN fully connected via HevTun2Socks!")
                } else {
                    NativeLogger.e("VpnService", "HevTun2Socks not available, falling back to Kotlin relay")
                    startSocksRelay(fd.fd, socksPort)
                    updateStatus("CONNECTED", "Connected")
                    updateNotification("Connected")
                    NativeLogger.i("VpnService", "VPN fully connected via Kotlin relay!")
                }

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
                relayPfd = ParcelFileDescriptor.fromFd(fd)
                val relay = Tun2SocksRelay(
                    relayPfd!!.fileDescriptor,
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
        zivpnManager?.stop()
        HevTun2Socks.stop()
        try { vpnInterface?.close(); NativeLogger.i("VpnService", "VPN interface closed") } catch (_: Exception) {}
        vpnInterface = null
        try { relayPfd?.close(); NativeLogger.i("VpnService", "Relay PFD closed") } catch (_: Exception) {}
        relayPfd = null
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
        StivarosPlugin.sendStatusEvent(status, message)
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
