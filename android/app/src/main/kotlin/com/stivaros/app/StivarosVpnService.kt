package com.stivaros.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.PowerManager
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
        const val ACTION_RECONNECT = "com.stivaros.app.RECONNECT"
        const val VPN_REQUEST_CODE = 1000
        const val BROADCAST_STATUS = "com.stivaros.app.STATUS"
        const val EXTRA_STATUS = "status"
        const val EXTRA_MESSAGE = "message"
        const val MAX_RECONNECT = 20
        const val RECONNECT_DELAY = 3000L

        var instance: StivarosVpnService? = null
        var currentStatus = "DISCONNECTED"
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var relayPfd: ParcelFileDescriptor? = null
    private var serviceJob = SupervisorJob()
    private var serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)
    private var xrayManager: XrayManager? = null
    private var zivpnManager: ZivpnManager? = null
    private var isStartingVpn = false
    private var userRequestedStop = false
    private var reconnectAttempts = 0
    private var wakeLock: PowerManager.WakeLock? = null
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var pendingIntent: Intent? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        xrayManager = XrayManager(this)
        zivpnManager = ZivpnManager(this)
        registerNetworkCallback()
        NativeLogger.i("VpnService", "onCreate: managers created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        NativeLogger.i("VpnService", "onStartCommand: action=${intent?.action}")
        if (intent?.action == ACTION_START && intent.extras != null) {
            pendingIntent = intent
        }
        startForeground(NOTIFICATION_ID, buildNotification("Starting..."))
        when (intent?.action) {
            ACTION_START -> startVpn(intent)
            ACTION_STOP -> { userRequestedStop = true; stopVpn() }
            ACTION_RECONNECT -> reconnect()
        }
        return if (userRequestedStop) START_NOT_STICKY else START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    override fun onRevoke() {
        NativeLogger.w("VpnService", "VPN revoked by system")
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null
        if (!userRequestedStop) {
            serviceScope.launch {
                isStartingVpn = false
                delay(300)
                startVpn(pendingIntent)
            }
        }
    }

    override fun onDestroy() {
        NativeLogger.i("VpnService", "onDestroy")
        unregisterNetworkCallback()
        stopVpn()
        serviceJob.cancel()
        instance = null
        super.onDestroy()
    }

    private fun startVpn(intent: Intent?) {
        if (isStartingVpn) return
        isStartingVpn = true
        userRequestedStop = false

        if (wakeLock == null || wakeLock?.isHeld == false) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "StivarosVPN::WakeLock")
            wakeLock?.acquire(8 * 60 * 60 * 1000L)
        }

        serviceScope.launch {
            try {
                if (intent == null) { isStartingVpn = false; return@launch }
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
                        if (!userRequestedStop) triggerReconnect()
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
                        if (!userRequestedStop) triggerReconnect()
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
                    .setSession("ST")
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
                    HevTun2Socks.start(this@StivarosVpnService, fd.fd, socksPort, 1400)
                    reconnectAttempts = 0
                    updateStatus("CONNECTED", "Connected")
                    updateNotification("Connected")
                    NativeLogger.i("VpnService", "VPN fully connected via HevTun2Socks!")
                } else {
                    NativeLogger.e("VpnService", "HevTun2Socks not available, falling back to Kotlin relay")
                    startSocksRelay(fd.fd, socksPort)
                    reconnectAttempts = 0
                    updateStatus("CONNECTED", "Connected")
                    updateNotification("Connected")
                    NativeLogger.i("VpnService", "VPN fully connected via Kotlin relay!")
                }

            } catch (e: Exception) {
                NativeLogger.e("VpnService", "VPN start error: ${e.message}")
                Log.e(TAG, "VPN start error: ${e.message}")
                updateStatus("ERROR", e.message ?: "Connection failed")
                if (!userRequestedStop && reconnectAttempts < MAX_RECONNECT) {
                    isStartingVpn = false
                    reconnectAttempts++
                    delay(RECONNECT_DELAY)
                    startVpn(pendingIntent)
                } else {
                    stopVpn()
                }
            }
            isStartingVpn = false
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
        isStartingVpn = false
        xrayManager?.stop()
        zivpnManager?.stop()
        HevTun2Socks.stop()
        try { vpnInterface?.close(); NativeLogger.i("VpnService", "VPN interface closed") } catch (_: Exception) {}
        vpnInterface = null
        try { relayPfd?.close(); NativeLogger.i("VpnService", "Relay PFD closed") } catch (_: Exception) {}
        relayPfd = null
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
        wakeLock = null
        reconnectAttempts = 0
        try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
        updateStatus("DISCONNECTED", "Disconnected")
    }

    private fun triggerReconnect() {
        if (userRequestedStop) return
        serviceScope.launch {
            delay(2000)
            if (!userRequestedStop && currentStatus != "CONNECTED") {
                NativeLogger.i("VpnService", "triggerReconnect: network may be back, reconnecting...")
                reconnect()
            }
        }
    }

    private fun reconnect() {
        if (isStartingVpn || userRequestedStop) return
        serviceScope.launch {
            try {
                xrayManager?.stop()
                zivpnManager?.stop()
                HevTun2Socks.stop()
                try { vpnInterface?.close() } catch (_: Exception) {}
                vpnInterface = null
            } catch (_: Exception) {}
            isStartingVpn = false
            delay(1500)
            startVpn(pendingIntent)
        }
    }

    private fun registerNetworkCallback() {
        try {
            connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    NativeLogger.i("VpnService", "Network available -> checking state")
                    if (!userRequestedStop) {
                        serviceScope.launch {
                            delay(1500)
                            if (!userRequestedStop &&
                                currentStatus != "CONNECTING" &&
                                currentStatus != "CONNECTED") {
                                NativeLogger.i("VpnService", "Network restored -> reconnecting")
                                reconnect()
                            }
                        }
                    }
                }
                override fun onLost(network: Network) {
                    NativeLogger.i("VpnService", "Network lost")
                    if (!userRequestedStop && currentStatus == "CONNECTED") {
                        updateStatus("DISCONNECTED", "Network lost")
                    }
                }
            }
            connectivityManager?.registerNetworkCallback(request, networkCallback!!)
        } catch (e: Exception) {
            NativeLogger.e("VpnService", "registerNetworkCallback error: ${e.message}")
        }
    }

    private fun unregisterNetworkCallback() {
        try {
            networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}
        networkCallback = null
        connectivityManager = null
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
                CHANNEL_ID, "ST",
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
            .setContentTitle("ST")
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
